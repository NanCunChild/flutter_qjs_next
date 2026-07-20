#!/usr/bin/env python3
"""Render soak_metrics.jsonl into interactive HTML (line charts + path heatmaps).

No third-party deps (stdlib only). Charts use Chart.js from CDN.

Examples:
  # Single run
  scripts/plot-soak-metrics.py soak_profiles/tiny/round-01/reset_off_dumps/soak_metrics.jsonl

  # Whole tree → index + per-case reports
  scripts/plot-soak-metrics.py --root soak_profiles --output soak_profiles/report

  # Explicit multi-file comparison heatmap
  scripts/plot-soak-metrics.py a.jsonl b.jsonl --title 'A/B' -o report/out.html
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"warn: {path}:{line_no}: {e}", file=sys.stderr)
    return rows


def _num(v: Any, default: float = 0.0) -> float:
    if v is None:
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def series_from_rows(rows: list[dict[str, Any]]) -> dict[str, list[float]]:
    t: list[float] = []
    rss_mb: list[float] = []
    rss_delta_mb: list[float] = []
    peak_mb: list[float] = []
    ops: list[float] = []
    ops_rate: list[float] = []
    errors: list[float] = []
    qjs_malloc_mb: list[float] = []
    qjs_used_mb: list[float] = []
    qjs_obj: list[float] = []
    dart_refs: list[float] = []
    pool_size: list[float] = []
    pool_in_use: list[float] = []
    pool_reset: list[float] = []
    bridge_alloc: list[float] = []
    bridge_free: list[float] = []
    bridge_alloc_bytes_mb: list[float] = []
    pss_mb: list[float] = []
    private_dirty_mb: list[float] = []

    prev_t = None
    prev_ops = None
    for r in rows:
        el = _num(r.get("elapsedSec"))
        t.append(el)
        rss_mb.append(_num(r.get("rss")) / (1024 * 1024))
        rss_delta_mb.append(_num(r.get("rssDelta")) / (1024 * 1024))
        peak_mb.append(_num(r.get("peakRss")) / (1024 * 1024))
        op_total = _num(r.get("opsTotal"))
        ops.append(op_total)
        errors.append(_num(r.get("errors")))
        if prev_t is not None and el > prev_t:
            ops_rate.append((op_total - prev_ops) / (el - prev_t))
        else:
            ops_rate.append(0.0)
        prev_t, prev_ops = el, op_total

        engines = r.get("engines") or []
        mallocs = []
        useds = []
        objs = []
        refs = []
        for eng in engines:
            qjs = eng.get("qjs") or {}
            if isinstance(qjs, dict):
                mallocs.append(_num(qjs.get("mallocSize")))
                useds.append(_num(qjs.get("memoryUsedSize")))
                objs.append(_num(qjs.get("objCount")))
            if eng.get("dartRefs") is not None:
                refs.append(_num(eng.get("dartRefs")))
        n = max(len(mallocs), 1)
        qjs_malloc_mb.append(sum(mallocs) / n / (1024 * 1024))
        qjs_used_mb.append(sum(useds) / n / (1024 * 1024))
        qjs_obj.append(sum(objs) / n if objs else 0.0)
        dart_refs.append(sum(refs) / n if refs else 0.0)

        pool = r.get("pool") or {}
        pool_size.append(_num(pool.get("size")))
        pool_in_use.append(_num(pool.get("inUse")))
        pool_reset.append(_num(pool.get("resetCount")))

        bridge = r.get("bridge") or {}
        bridge_alloc.append(_num(bridge.get("allocCalls")))
        bridge_free.append(_num(bridge.get("freeCalls")))
        bridge_alloc_bytes_mb.append(_num(bridge.get("allocBytes")) / (1024 * 1024))

        proc = r.get("procMemory") or {}
        pss_mb.append(_num(proc.get("Pss")) / (1024 * 1024))
        private_dirty_mb.append(_num(proc.get("Private_Dirty")) / (1024 * 1024))

    return {
        "t": t,
        "rss_mb": rss_mb,
        "rss_delta_mb": rss_delta_mb,
        "peak_mb": peak_mb,
        "ops": ops,
        "ops_rate": ops_rate,
        "errors": errors,
        "qjs_malloc_mb": qjs_malloc_mb,
        "qjs_used_mb": qjs_used_mb,
        "qjs_obj": qjs_obj,
        "dart_refs": dart_refs,
        "pool_size": pool_size,
        "pool_in_use": pool_in_use,
        "pool_reset": pool_reset,
        "bridge_alloc": bridge_alloc,
        "bridge_free": bridge_free,
        "bridge_alloc_bytes_mb": bridge_alloc_bytes_mb,
        "pss_mb": pss_mb,
        "private_dirty_mb": private_dirty_mb,
    }


def op_path_matrix(rows: list[dict[str, Any]]) -> tuple[list[str], list[str], list[list[float]]]:
    """Return (time_labels, op_names, matrix[op][time]) of ops-per-interval."""
    if not rows:
        return [], [], []
    has = any(isinstance(r.get("opCounts"), dict) for r in rows)
    if not has:
        return [], [], []

    # Stable op name order from first non-empty + later keys
    names: list[str] = []
    seen: set[str] = set()
    for r in rows:
        oc = r.get("opCounts") or {}
        if not isinstance(oc, dict):
            continue
        for k in oc:
            if k not in seen:
                seen.add(k)
                names.append(k)
    if not names:
        return [], [], []

    prev = {k: 0 for k in names}
    labels: list[str] = []
    cols: list[list[float]] = []  # each col is values for all ops at time i
    for r in rows:
        el = _num(r.get("elapsedSec"))
        labels.append(f"{el:.0f}s")
        oc = r.get("opCounts") or {}
        col = []
        for k in names:
            cur = int(_num(oc.get(k)))
            col.append(float(max(0, cur - prev[k])))
            prev[k] = cur
        cols.append(col)

    # matrix[op_index][time_index]
    matrix = [[cols[t][o] for t in range(len(cols))] for o in range(len(names))]
    return labels, names, matrix


def bridge_path_matrix(rows: list[dict[str, Any]]) -> tuple[list[str], list[str], list[list[float]]]:
    """Heatmap of bridge counter *deltas* over time (fallback path view)."""
    keys = [
        "allocCalls",
        "freeCalls",
        "memcpyCalls",
        "copyCalls",
        "ownedTypedArrayCalls",
        "typedArrayDataCalls",
        "allocBytes",
        "memcpyBytes",
        "copyBytes",
    ]
    if not rows:
        return [], [], []
    labels: list[str] = []
    prev = {k: 0.0 for k in keys}
    cols: list[list[float]] = []
    for r in rows:
        el = _num(r.get("elapsedSec"))
        labels.append(f"{el:.0f}s")
        br = r.get("bridge") or {}
        col = []
        for k in keys:
            cur = _num(br.get(k))
            delta = max(0.0, cur - prev[k])
            # bytes → MiB for scale readability
            if k.endswith("Bytes"):
                delta = delta / (1024 * 1024)
            col.append(delta)
            prev[k] = cur
        cols.append(col)
    display = [
        "allocCalls",
        "freeCalls",
        "memcpyCalls",
        "copyCalls",
        "ownedTA",
        "typedArrayData",
        "allocMiB",
        "memcpyMiB",
        "copyMiB",
    ]
    matrix = [[cols[t][o] for t in range(len(cols))] for o in range(len(keys))]
    return labels, display, matrix


def summarize(path: Path, rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not rows:
        return {
            "path": str(path),
            "label": path.parent.name if path.name == "soak_metrics.jsonl" else path.stem,
            "samples": 0,
        }
    first, last = rows[0], rows[-1]
    s = series_from_rows(rows)
    t0 = s["t"][0] if s["t"] else 0.0
    t1 = s["t"][-1] if s["t"] else 0.0
    dt = max(t1 - t0, 1e-9)
    ops0 = s["ops"][0] if s["ops"] else 0.0
    ops1 = s["ops"][-1] if s["ops"] else 0.0
    rss0 = s["rss_mb"][0] if s["rss_mb"] else 0.0
    rss1 = s["rss_mb"][-1] if s["rss_mb"] else 0.0
    profile = last.get("profile") or first.get("profile") or ""
    reset = last.get("resetOnRelease")
    if reset is None:
        # Infer from path: reset_on_dumps / reset_off_dumps
        p = str(path)
        if "reset_on" in p:
            reset = True
        elif "reset_off" in p:
            reset = False
    label = _label_for_path(path, profile, reset)
    return {
        "path": str(path),
        "label": label,
        "samples": len(rows),
        "elapsed_sec": t1,
        "ops_total": int(ops1),
        "ops_per_sec": (ops1 - ops0) / dt,
        "rss_start_mb": rss0,
        "rss_end_mb": rss1,
        "rss_delta_mb": rss1 - rss0,
        "rss_peak_mb": max(s["peak_mb"]) if s["peak_mb"] else 0.0,
        "errors": int(s["errors"][-1]) if s["errors"] else 0,
        "qjs_malloc_end_mb": s["qjs_malloc_mb"][-1] if s["qjs_malloc_mb"] else 0.0,
        "qjs_malloc_delta_mb": (
            (s["qjs_malloc_mb"][-1] - s["qjs_malloc_mb"][0]) if s["qjs_malloc_mb"] else 0.0
        ),
        "bridge_alloc_end": s["bridge_alloc"][-1] if s["bridge_alloc"] else 0.0,
        "bridge_free_end": s["bridge_free"][-1] if s["bridge_free"] else 0.0,
        "profile": profile,
        "resetOnRelease": reset,
    }


def _label_for_path(path: Path, profile: Any, reset: Any) -> str:
    parts = list(path.parts)
    # .../<profile>/round-XX/<case>_dumps/soak_metrics.jsonl
    try:
        idx = parts.index("soak_metrics.jsonl") if "soak_metrics.jsonl" in parts else -1
    except ValueError:
        idx = -1
    profile_s = str(profile) if profile else ""
    for i, p in enumerate(parts):
        if p.startswith("round-") and i > 0:
            profile_s = profile_s or parts[i - 1]
            break
    case = path.parent.name.replace("_dumps", "")
    if reset is True:
        case = "reset_on"
    elif reset is False:
        case = "reset_off"
    if profile_s:
        return f"{profile_s}/{case}"
    return case or path.stem


def discover_jsonl(root: Path) -> list[Path]:
    return sorted(root.rglob("soak_metrics.jsonl"))


def js_array(vals: list[float], prec: int = 4) -> str:
    out = []
    for v in vals:
        if v is None or (isinstance(v, float) and (math.isnan(v) or math.isinf(v))):
            out.append("null")
        else:
            out.append(f"{float(v):.{prec}f}".rstrip("0").rstrip(".") if isinstance(v, float) else str(v))
    return "[" + ",".join(out) + "]"


def render_heatmap_section(
    title: str,
    x_labels: list[str],
    y_labels: list[str],
    matrix: list[list[float]],
    canvas_id: str,
    note: str = "",
) -> str:
    if not x_labels or not y_labels or not matrix:
        return f"<section><h2>{html.escape(title)}</h2><p class='muted'>No data.</p></section>"
    # downsample x if too wide
    max_x = 120
    if len(x_labels) > max_x:
        step = math.ceil(len(x_labels) / max_x)
        idxs = list(range(0, len(x_labels), step))
        if idxs[-1] != len(x_labels) - 1:
            idxs.append(len(x_labels) - 1)
        x_labels = [x_labels[i] for i in idxs]
        matrix = [[row[i] for i in idxs] for row in matrix]

    payload = {
        "x": x_labels,
        "y": y_labels,
        "z": matrix,
    }
    note_html = f"<p class='muted'>{html.escape(note)}</p>" if note else ""
    return f"""
<section>
  <h2>{html.escape(title)}</h2>
  {note_html}
  <canvas id="{html.escape(canvas_id)}" class="heatmap"></canvas>
  <script type="application/json" id="{html.escape(canvas_id)}-data">{json.dumps(payload)}</script>
</section>
"""


def render_run_html(
    path: Path,
    rows: list[dict[str, Any]],
    title: str | None = None,
) -> str:
    s = series_from_rows(rows)
    summary = summarize(path, rows)
    run_title = title or summary["label"] or path.name
    op_x, op_y, op_z = op_path_matrix(rows)
    br_x, br_y, br_z = bridge_path_matrix(rows)

    charts = [
        ("RSS / PSS (MiB)", [
            ("RSS", s["rss_mb"], "#2563eb"),
            ("Peak RSS", s["peak_mb"], "#93c5fd"),
            ("PSS", s["pss_mb"], "#7c3aed"),
            ("Private Dirty", s["private_dirty_mb"], "#db2777"),
            ("RSS Δ", s["rss_delta_mb"], "#f59e0b"),
        ]),
        ("Throughput", [
            ("ops/s (interval)", s["ops_rate"], "#059669"),
            ("ops total / 1e6", [v / 1e6 for v in s["ops"]], "#34d399"),
            ("errors", s["errors"], "#dc2626"),
        ]),
        ("QuickJS heap (avg idle engine)", [
            ("malloc MiB", s["qjs_malloc_mb"], "#0891b2"),
            ("memoryUsed MiB", s["qjs_used_mb"], "#06b6d4"),
            ("objCount", s["qjs_obj"], "#0e7490"),
            ("dartRefs", s["dart_refs"], "#6366f1"),
        ]),
        ("Pool", [
            ("size", s["pool_size"], "#4b5563"),
            ("inUse", s["pool_in_use"], "#f97316"),
            ("resetCount", s["pool_reset"], "#a855f7"),
        ]),
        ("Bridge counters (cumulative)", [
            ("allocCalls", s["bridge_alloc"], "#ea580c"),
            ("freeCalls", s["bridge_free"], "#16a34a"),
            ("allocBytes MiB", s["bridge_alloc_bytes_mb"], "#b45309"),
        ]),
    ]

    chart_sections = []
    chart_specs = []
    for i, (ctitle, series_list) in enumerate(charts):
        cid = f"chart_{i}"
        datasets = []
        for name, data, color in series_list:
            if not data or all(v == 0 for v in data):
                # still include if any non-zero elsewhere; skip fully empty non-rss
                if name not in ("RSS", "Peak RSS", "ops/s (interval)", "ops total / 1e6") and all(
                    v == 0 for v in data
                ):
                    continue
            datasets.append(
                {
                    "label": name,
                    "data": data,
                    "borderColor": color,
                    "backgroundColor": color + "33",
                    "tension": 0.15,
                    "pointRadius": 0,
                    "borderWidth": 1.5,
                }
            )
        chart_specs.append({"id": cid, "title": ctitle, "labels": s["t"], "datasets": datasets})
        chart_sections.append(
            f"""
<section>
  <h2>{html.escape(ctitle)}</h2>
  <div class="chart-wrap"><canvas id="{cid}"></canvas></div>
</section>
"""
        )

    summary_rows = "".join(
        f"<tr><th>{html.escape(k)}</th><td>{html.escape(str(v))}</td></tr>"
        for k, v in [
            ("source", path),
            ("label", summary.get("label")),
            ("samples", summary.get("samples")),
            ("elapsed_sec", f"{summary.get('elapsed_sec', 0):.1f}"),
            ("ops_total", summary.get("ops_total")),
            ("ops_per_sec", f"{summary.get('ops_per_sec', 0):.1f}"),
            ("rss_start_mb", f"{summary.get('rss_start_mb', 0):.1f}"),
            ("rss_end_mb", f"{summary.get('rss_end_mb', 0):.1f}"),
            ("rss_delta_mb", f"{summary.get('rss_delta_mb', 0):.1f}"),
            ("rss_peak_mb", f"{summary.get('rss_peak_mb', 0):.1f}"),
            ("qjs_malloc_delta_mb", f"{summary.get('qjs_malloc_delta_mb', 0):.3f}"),
            ("bridge_alloc/free", f"{summary.get('bridge_alloc_end')}/{summary.get('bridge_free_end')}"),
            ("errors", summary.get("errors")),
            ("profile", summary.get("profile")),
            ("resetOnRelease", summary.get("resetOnRelease")),
        ]
    )

    heatmaps = []
    heatmaps.append(
        render_heatmap_section(
            "Path heatmap — op kinds (ops / metrics interval)",
            op_x,
            op_y,
            op_z,
            "hm_ops",
            note="Requires opCounts in JSONL (new soak runs). Color = ops completed in that interval.",
        )
    )
    heatmaps.append(
        render_heatmap_section(
            "Path heatmap — bridge counter deltas",
            br_x,
            br_y,
            br_z,
            "hm_bridge",
            note="Bytes shown as MiB deltas. Useful when opCounts are absent.",
        )
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{html.escape(str(run_title))} — soak report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  :root {{
    --bg: #0b1220;
    --card: #121a2b;
    --text: #e5e7eb;
    --muted: #9ca3af;
    --border: #1f2937;
    --accent: #38bdf8;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 24px;
    font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.45;
  }}
  h1 {{ font-size: 1.4rem; margin: 0 0 8px; }}
  h2 {{ font-size: 1.05rem; margin: 0 0 12px; color: var(--accent); }}
  .muted {{ color: var(--muted); font-size: 0.9rem; }}
  section {{
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 16px 18px; margin: 16px 0;
  }}
  table.summary {{ border-collapse: collapse; width: 100%; max-width: 720px; }}
  table.summary th, table.summary td {{
    text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--border);
    font-size: 0.9rem; vertical-align: top;
  }}
  table.summary th {{ color: var(--muted); width: 40%; font-weight: 500; }}
  .chart-wrap {{ position: relative; height: 320px; }}
  canvas.heatmap {{ width: 100%; max-width: 100%; height: auto; display: block; background: #0a0f1a; border-radius: 8px; }}
  a {{ color: #7dd3fc; }}
</style>
</head>
<body>
  <h1>{html.escape(str(run_title))}</h1>
  <p class="muted">Generated from {html.escape(str(path))} · {len(rows)} samples</p>
  <section>
    <h2>Summary</h2>
    <table class="summary">{summary_rows}</table>
  </section>
  {''.join(chart_sections)}
  {''.join(heatmaps)}
<script>
const chartSpecs = {json.dumps(chart_specs)};
for (const spec of chartSpecs) {{
  const el = document.getElementById(spec.id);
  if (!el) continue;
  new Chart(el, {{
    type: 'line',
    data: {{
      labels: spec.labels.map(v => Number(v).toFixed(0)),
      datasets: spec.datasets.map(ds => ({{
        ...ds,
        data: ds.data,
        fill: false,
      }})),
    }},
    options: {{
      responsive: true,
      maintainAspectRatio: false,
      interaction: {{ mode: 'index', intersect: false }},
      plugins: {{
        legend: {{ labels: {{ color: '#e5e7eb' }} }},
        title: {{ display: false }},
      }},
      scales: {{
        x: {{
          title: {{ display: true, text: 'elapsed (s)', color: '#9ca3af' }},
          ticks: {{ color: '#9ca3af', maxTicksLimit: 12 }},
          grid: {{ color: '#1f2937' }},
        }},
        y: {{
          ticks: {{ color: '#9ca3af' }},
          grid: {{ color: '#1f2937' }},
        }},
      }},
    }},
  }});
}}

function drawHeatmap(canvasId) {{
  const canvas = document.getElementById(canvasId);
  const dataEl = document.getElementById(canvasId + '-data');
  if (!canvas || !dataEl) return;
  const payload = JSON.parse(dataEl.textContent);
  const x = payload.x || [];
  const y = payload.y || [];
  const z = payload.z || [];
  if (!x.length || !y.length) return;

  const cellW = Math.max(6, Math.min(28, Math.floor(1100 / x.length)));
  const cellH = 26;
  const left = 140;
  const top = 20;
  const width = left + cellW * x.length + 20;
  const height = top + cellH * y.length + 60;
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#0a0f1a';
  ctx.fillRect(0, 0, width, height);

  let maxV = 0;
  for (const row of z) for (const v of row) if (v > maxV) maxV = v;
  if (maxV <= 0) maxV = 1;

  function color(v) {{
    const t = Math.sqrt(v / maxV); // emphasize mid/low
    // dark blue → cyan → yellow
    const r = Math.round(20 + 235 * Math.min(1, t * 1.2));
    const g = Math.round(30 + 180 * t);
    const b = Math.round(80 + 100 * (1 - t));
    return `rgb(${{r}},${{g}},${{b}})`;
  }}

  ctx.font = '12px ui-sans-serif, system-ui, sans-serif';
  for (let i = 0; i < y.length; i++) {{
    ctx.fillStyle = '#9ca3af';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    ctx.fillText(y[i], left - 8, top + i * cellH + cellH / 2);
    for (let j = 0; j < x.length; j++) {{
      const v = (z[i] && z[i][j]) || 0;
      ctx.fillStyle = color(v);
      ctx.fillRect(left + j * cellW, top + i * cellH, cellW - 1, cellH - 1);
    }}
  }}
  // x labels (sparse)
  ctx.fillStyle = '#9ca3af';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  const step = Math.max(1, Math.ceil(x.length / 10));
  for (let j = 0; j < x.length; j += step) {{
    ctx.fillText(x[j], left + j * cellW + cellW / 2, top + y.length * cellH + 8);
  }}
  ctx.fillStyle = '#6b7280';
  ctx.textAlign = 'left';
  ctx.fillText('max=' + maxV.toFixed(2) + ' (sqrt scale)', left, top + y.length * cellH + 32);
}}

drawHeatmap('hm_ops');
drawHeatmap('hm_bridge');
</script>
</body>
</html>
"""


def render_index_html(
    runs: list[dict[str, Any]],
    comparison_matrix: tuple[list[str], list[str], list[list[float]]] | None,
    title: str,
) -> str:
    rows_html = []
    for r in runs:
        link = html.escape(r.get("report_rel", "#"))
        rows_html.append(
            "<tr>"
            f"<td><a href=\"{link}\">{html.escape(r.get('label',''))}</a></td>"
            f"<td>{r.get('elapsed_sec', 0):.0f}</td>"
            f"<td>{r.get('ops_total', 0):,}</td>"
            f"<td>{r.get('ops_per_sec', 0):.0f}</td>"
            f"<td>{r.get('rss_start_mb', 0):.1f}</td>"
            f"<td>{r.get('rss_end_mb', 0):.1f}</td>"
            f"<td>{r.get('rss_delta_mb', 0):.1f}</td>"
            f"<td>{r.get('qjs_malloc_delta_mb', 0):.3f}</td>"
            f"<td>{r.get('errors', 0)}</td>"
            "</tr>"
        )

    hm = ""
    if comparison_matrix:
        x, y, z = comparison_matrix
        hm = render_heatmap_section(
            "Comparison heatmap — residual growth & rate",
            x,
            y,
            z,
            "hm_compare",
            note="Rows = metrics, columns = runs. RSS Δ and QJS Δ in MiB; ops/s absolute.",
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{html.escape(title)}</title>
<style>
  :root {{ --bg:#0b1220; --card:#121a2b; --text:#e5e7eb; --muted:#9ca3af; --border:#1f2937; --accent:#38bdf8; }}
  body {{ margin:0; padding:24px; font-family: ui-sans-serif, system-ui, sans-serif; background:var(--bg); color:var(--text); }}
  h1 {{ font-size:1.4rem; }} h2 {{ color:var(--accent); font-size:1.05rem; }}
  .muted {{ color:var(--muted); }}
  section {{ background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; margin:16px 0; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 0.9rem; }}
  th, td {{ padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: right; }}
  th:first-child, td:first-child {{ text-align: left; }}
  th {{ color: var(--muted); font-weight: 500; }}
  a {{ color: #7dd3fc; }}
  canvas.heatmap {{ width: 100%; background:#0a0f1a; border-radius:8px; }}
</style>
</head>
<body>
  <h1>{html.escape(title)}</h1>
  <p class="muted">{len(runs)} runs</p>
  <section>
    <h2>Runs</h2>
    <table>
      <thead>
        <tr>
          <th>run</th><th>sec</th><th>ops</th><th>ops/s</th>
          <th>RSS start</th><th>RSS end</th><th>RSS Δ MiB</th>
          <th>QJS malloc Δ</th><th>errors</th>
        </tr>
      </thead>
      <tbody>
        {''.join(rows_html)}
      </tbody>
    </table>
  </section>
  {hm}
<script>
function drawHeatmap(canvasId) {{
  const canvas = document.getElementById(canvasId);
  const dataEl = document.getElementById(canvasId + '-data');
  if (!canvas || !dataEl) return;
  const payload = JSON.parse(dataEl.textContent);
  const x = payload.x || [];
  const y = payload.y || [];
  const z = payload.z || [];
  if (!x.length || !y.length) return;
  const cellW = Math.max(48, Math.min(100, Math.floor(900 / x.length)));
  const cellH = 28;
  const left = 160;
  const top = 40;
  canvas.width = left + cellW * x.length + 20;
  canvas.height = top + cellH * y.length + 80;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#0a0f1a';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  let maxAbs = 0;
  for (const row of z) for (const v of row) if (Math.abs(v) > maxAbs) maxAbs = Math.abs(v);
  if (maxAbs <= 0) maxAbs = 1;
  function color(v) {{
    const t = v / maxAbs; // -1..1
    if (t >= 0) {{
      const u = Math.sqrt(t);
      return `rgb(${{Math.round(30+200*u)}},${{Math.round(40+40*u)}},${{Math.round(50)}} )`;
    }} else {{
      const u = Math.sqrt(-t);
      return `rgb(${{Math.round(30)}},${{Math.round(80+120*u)}},${{Math.round(120+100*u)}} )`;
    }}
  }}
  ctx.font = '12px ui-sans-serif, system-ui, sans-serif';
  for (let i = 0; i < y.length; i++) {{
    ctx.fillStyle = '#9ca3af';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    ctx.fillText(y[i], left - 8, top + i * cellH + cellH / 2);
    for (let j = 0; j < x.length; j++) {{
      const v = (z[i] && z[i][j]) || 0;
      ctx.fillStyle = color(v);
      ctx.fillRect(left + j * cellW, top + i * cellH, cellW - 1, cellH - 1);
      ctx.fillStyle = '#f9fafb';
      ctx.textAlign = 'center';
      ctx.fillText(Number(v).toFixed(1), left + j * cellW + cellW / 2, top + i * cellH + cellH / 2);
    }}
  }}
  for (let j = 0; j < x.length; j++) {{
    ctx.save();
    ctx.translate(left + j * cellW + cellW / 2, top - 8);
    ctx.rotate(-0.4);
    ctx.fillStyle = '#9ca3af';
    ctx.textAlign = 'left';
    ctx.fillText(x[j], 0, 0);
    ctx.restore();
  }}
}}
drawHeatmap('hm_compare');
</script>
</body>
</html>
"""


def build_comparison(
    summaries: list[dict[str, Any]],
) -> tuple[list[str], list[str], list[list[float]]]:
    x = [s["label"] for s in summaries]
    metrics = [
        ("RSS Δ MiB", "rss_delta_mb"),
        ("RSS peak MiB", "rss_peak_mb"),
        ("ops/s", "ops_per_sec"),
        ("QJS malloc Δ MiB", "qjs_malloc_delta_mb"),
        ("errors", "errors"),
    ]
    y = [m[0] for m in metrics]
    z = [[float(s.get(key, 0) or 0) for s in summaries] for _, key in metrics]
    return x, y, z


def safe_stem(label: str) -> str:
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("_")
    return s or "run"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", type=Path, help="soak_metrics.jsonl files")
    ap.add_argument("--root", type=Path, help="Discover all soak_metrics.jsonl under this directory")
    ap.add_argument("-o", "--output", type=Path, help="Output HTML file or directory (for multi-run)")
    ap.add_argument("--title", default="Soak metrics report")
    args = ap.parse_args(argv)

    paths: list[Path] = []
    if args.root:
        if not args.root.is_dir():
            print(f"error: --root not a directory: {args.root}", file=sys.stderr)
            return 2
        paths.extend(discover_jsonl(args.root))
    paths.extend(args.inputs)
    # unique preserve order
    seen: set[Path] = set()
    uniq: list[Path] = []
    for p in paths:
        rp = p.resolve()
        if rp not in seen:
            seen.add(rp)
            uniq.append(p)
    paths = uniq

    if not paths:
        print("error: no input jsonl; pass files or --root", file=sys.stderr)
        return 2

    multi = len(paths) > 1 or args.root is not None
    if multi:
        out_dir = args.output or Path("soak_report")
        if out_dir.suffix == ".html":
            out_dir = out_dir.with_suffix("")
        out_dir.mkdir(parents=True, exist_ok=True)
        runs_meta: list[dict[str, Any]] = []
        for p in paths:
            if not p.is_file():
                print(f"warn: missing {p}", file=sys.stderr)
                continue
            rows = load_jsonl(p)
            summary = summarize(p, rows)
            rel_name = safe_stem(summary["label"]) + ".html"
            # avoid collisions
            candidate = rel_name
            n = 2
            while any(r.get("report_rel") == candidate for r in runs_meta):
                candidate = f"{safe_stem(summary['label'])}_{n}.html"
                n += 1
            report_path = out_dir / candidate
            report_path.write_text(render_run_html(p, rows, title=summary["label"]), encoding="utf-8")
            summary["report_rel"] = candidate
            runs_meta.append(summary)
            print(f"wrote {report_path}")

        cmp_m = build_comparison(runs_meta) if runs_meta else None
        index = out_dir / "index.html"
        index.write_text(
            render_index_html(runs_meta, cmp_m, args.title),
            encoding="utf-8",
        )
        print(f"wrote {index}")
        return 0

    # single file
    p = paths[0]
    rows = load_jsonl(p)
    out = args.output
    if out is None:
        out = p.with_suffix("").parent / "soak_report.html"
    elif out.is_dir() or str(out).endswith("/"):
        out.mkdir(parents=True, exist_ok=True)
        out = out / "soak_report.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render_run_html(p, rows, title=args.title), encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
