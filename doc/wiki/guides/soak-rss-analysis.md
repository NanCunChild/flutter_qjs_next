# Soak RSS analysis (2026-07)

Long-haul stress results for process RSS vs QuickJS heap / bridge counters.
This page records **what we measured**, **how to interpret it**, and **how to re-run**.

Related: [Testing & benchmarks](../testing-and-benchmarks.md) · [Memory & lifecycle](memory-and-lifecycle.md)

## Artifacts (local)

| Path | Content |
|------|---------|
| `soak_profiles/` | Full **1 h** matrix: `tiny`, `no_typed_array`, `dart_to_js` × reset on/off + HTML `report/` |
| `20260722T114650Z/` | Full **1 h** `js_to_dart` A/B + HTML `report/` |
| `20260722T080602Z/` | Earlier 1 h `dart_to_js` A/B (same conclusion as matrix) |
| `soak_profiles_postfix/` | Intermediate multi-profile runs (shorter / mixed) |

Each case stores `soak_metrics.jsonl` (5 s samples), logs, and optional HTML under `report/`.

Harness knobs (`config.txt` / `run-soak-ab.sh`):

```text
pool_size=32  workers=32  ops_per_burst=8  metrics_sec=5  rss_factor=128  duration_sec=3600
started_utc ≈ 2026-07-22T11:46–11:48Z  (all cases exit_status=0)
```

Open charts: `soak_profiles/report/index.html`, `20260722T114650Z/report/index.html`.

---

## Executive summary

| Question | Answer |
|----------|--------|
| Is the old `JSValue*` / defineProperty box leak back? | **No** — bridge `allocCalls == freeCalls`; QJS heap flat or **down** |
| Can process RSS still climb under stress? | **Yes** — path-dependent |
| Healthiest path | **`tiny` + `resetOnRelease=false`**: warm-up then **plateau** (~+18 MiB, slope ~0 after 15 min) |
| Also healthy | **`js_to_dart` + reset_off**: ~+30 MiB then **plateau** |
| Worst path | **`dart_to_js`**: ~**+1.1–1.4 GiB/h**, QJS flat, bridge balanced |
| Surprising | **`no_typed_array` + reset_off**: ~**+1.1 GiB/h** linear (no bridge alloc) — not TypedArray-only |
| Does `resetOnRelease` help RSS? | **No** as a general cure: worse on `tiny`/`js_to_dart`; slightly lower absolute end RSS on heavy paths but still climbs hard |
| True logical leak? | **No** for engine/bridge bookkeeping; RSS = **Dart/native residency + fragmentation / pages not returned to OS**, sometimes with GC sawtooth |

**Bottom line for app authors:** process RSS ≠ QuickJS `mallocSize`. Prefer **engine reuse without per-op reset**. Budget RSS carefully for high-rate large Dart→JS buffers and for mixed “no_typed_array” churn (evaluate/string/map/array/createDispose). JS→Dart TypedArray alone looks much safer on these runs.

---

## How to read metrics

| Field | Use |
|-------|-----|
| `rss` / `procMemory.Private_Dirty` / `Pss` | Process residency |
| `engines[].qjs.mallocSize` / `memoryUsedSize` | Live QuickJS heap (sum across pool) |
| `engines[].dartRefs` | Dart-side refs for engines |
| `bridge.allocCalls` / `freeCalls` / `allocBytes` | Native bridge buffer accounting |
| `pool.resetCount` | Reset-on-release count |
| `opCounts` | Per-op-kind totals |
| `errors` | Must stay 0 |

### Leak vs “false” RSS growth

| Signal | True retained leak | Allocator / GC / fragmentation |
|--------|--------------------|--------------------------------|
| Σ QJS `mallocSize` | Tracks ops upward | Flat or decreases |
| `allocCalls − freeCalls` | Stays ≫ 0 | ~0 |
| `dartRefs` | Unbounded climb | Stable (or 0 after reset) |
| RSS curve | Monotone, little reclaim | Sawtooth and/or rising floor |
| `tiny` + no reset | Also linear forever | **Plateaus** after warm-up |

---

## Results matrix (1 h, all exit 0 / errors 0)

### Summary table

| Profile | reset | ops | ops/s | ΔRSS | peak RSS | Σ QJS malloc | bridge bal | overall slope | last 20% slope | drops >5 MiB |
|---------|-------|-----|-------|------|----------|--------------|------------|---------------|----------------|--------------|
| **tiny** | **off** | 326 M | 90 600 | **+17.8 MiB** | 188 | **Δ0** (5.47) | n/a | **~0.9 MiB/h** | **~0** | 0 |
| tiny | on | 70 M | 19 462 | +269 MiB | 456 | **−16.5** | n/a | ~267 MiB/h | ~269 | 1 |
| **no_typed_array** | **off** | 52 M | 14 431 | **+1108 MiB** | 1278 | **Δ0** | 0 | ~1116 MiB/h | ~1099 | **0** |
| no_typed_array | on | 33 M | 9076 | +720 MiB | 906 | **−14.3** | 0 | ~703 MiB/h | ~761 | 1 |
| **dart_to_js** | **off** | 24 M | 6728 | **+1412 MiB** | 1629 | **Δ0** | **0** | ~1200 MiB/h | ~1245 | **337** |
| dart_to_js | on | 19 M | 5357 | +1100 MiB | 1437 | **−8.0** | **0** | ~1002 MiB/h | ~891 | 324 |
| **js_to_dart** | **off** | 4.5 M | 1239 | **+30 MiB** | 198 | **Δ0** | 0 | **~0.3 MiB/h** | **~4** | 0 |
| js_to_dart | on | 4.4 M | 1217 | +79 MiB | 330 | **−1.4** | 0 | ~0.9 MiB/h* | ~21 | 1 |

\* `js_to_dart` + reset_on: early spike then low slope; end still ~247 MiB vs ~195 MiB off.

Approx. net process bytes per op (ΔRSS / Δops, whole hour):

| Case | B/op |
|------|------|
| tiny / off | ~0.1 |
| tiny / on | ~4.0 |
| no_typed_array / off | ~22 |
| no_typed_array / on | ~23 |
| dart_to_js / off | ~61 |
| dart_to_js / on | ~60 |
| js_to_dart / off | ~7 |
| js_to_dart / on | ~19 |

### `tiny` — healthy baseline (reset_off)

- 326 M `evaluateTiny` ops; QJS sum **constant** 5.47 MiB; dartRefs **32**.
- RSS: 167 → 185 MiB; floor after ~5 min stuck at **~185 MiB**.
- Windows 15–60 min slope ≈ **0**. This is the pass criterion for “engine reuse is fine”.

`reset_on` (8.8 M resets): QJS shrinks after warm-up, but RSS **linear +269 MiB/h** — reinit churn is not free.

### `js_to_dart` — healthy for TypedArray out (reset_off)

- 100% `jsUint8ToDart` (sizes from runner: 1 KiB / 64 KiB).
- QJS flat; bridge alloc/free **0** (path may not use the counted native alloc API the same way as dart→js).
- RSS +30 MiB then **plateau** (~194 MiB quarters flat).  
  → **JS → Dart TypedArray is not the same problem as Dart → JS.**

`reset_on`: mild climb of floor (~167 → 247); still far better than dart_to_js.

### `dart_to_js` — high churn Dart → JS

- 100% `dartUint8ToJs` (1 KiB / 64 KiB / 256 KiB; ~110 KiB avg `allocBytes/call`).
- Bridge: **allocCalls == freeCalls** (tens of millions); QJS **Δ0**.
- RSS: sawtooth (**300+** drops >5 MiB) + **rising floor** (~179 → 1073+ MiB mins per 5 min).
- reset_on does **not** fix residency (~1 GiB/h still); lower throughput.

### `no_typed_array` — linear climb without TypedArray

Even mix (~equal counts): `evaluateTiny`, `invokeCached`, `stringRoundTrip`, `mapRoundTrip`, `evaluateJsonArray`, `evaluateFullArray`, `promiseMicrotask`, `createDisposeEngine`, `runGcSample`.

- **reset_off**: RSS almost **perfectly linear** (+1108 MiB), **zero** large drops, QJS flat, bridge unused.
- **reset_on**: still linear (~+720 MiB), fewer ops.

So the problem is **not only** large TypedArray bridges. Mixed object/string/array/evaluate/createDispose churn also leaves process residency climbing while QuickJS accounting stays flat — strong signal for **Dart heap / FFI / allocator fragmentation**, not “forgot free JSValue*”.

---

## Interpretation

```text
                    ┌─────────────────────────────────────┐
                    │  Process RSS / Private_Dirty        │
                    │  (what soak plots show climbing)    │
                    └─────────────────────────────────────┘
                         ▲                ▲
           Dart + Flutter heap    glibc / arena / pages
           temporary objects      not returned to OS
                         ▲
              ┌──────────┴──────────┐
              │  Bridge copies      │  QJS live heap
              │  (alloc==free OK)   │  (flat on healthy
              │                     │   engines)
              └─────────────────────┘
```

1. **Engine bookkeeping looks sound** on this build for all 1 h cases above.
2. **Two failure modes for RSS** (not exclusive):
   - **Sawtooth + rising floor** (`dart_to_js`): GC reclaims large blobs; floor still climbs.
   - **Smooth linear** (`no_typed_array` reset_off): little visible reclaim; ~22 B/op process-level.
3. **Hard `reinitialize` / `resetOnRelease: true`** clears QJS state (malloc down) but **does not** give a free RSS win; on `tiny` it **creates** a climb.
4. Prefer **`EngineResetMode.soft` for isolation** under churn; use **hard** only when you need a full native rebuild — not as a memory strategy.
5. Production risk depends on traffic shape:
   - mostly tiny evaluate / JS→Dart bytes → closer to **plateau**;
   - sustained Dart→JS large buffers or heavy mixed marshalling → plan multi‑hundred‑MiB to multi‑GiB RSS over hours.

### Optional follow-ups

- Fixed-size `dart_to_js` (1 KiB only vs 256 KiB only).
- Disable individual `no_typed_array` ops (bisect createDispose vs string vs array).
- Periodic `runGC()` + diagnostic `malloc_trim` after idle.
- Sample `/proc/self/smaps` when QJS flat but Private_Dirty rises.

---

## Test instructions

Use **Flutter’s test harness** (plugin native library). Do **not** use bare `dart run` for these FFI plugin tests.

### Prerequisites

```bash
cd /path/to/flutter_qjs_next
cd example && flutter pub get && cd ..
```

Linux desktop assumed for RSS / `/proc` metrics.

### Quick smoke (~30 s)

```bash
cd example
flutter test test/soak_stress_test.dart
```

### Reproduce the local matrix

```bash
# From repo root — matches soak_profiles/
scripts/run-soak-ab.sh \
  --full-test \
  --profiles tiny,no_typed_array,dart_to_js \
  --duration 3600 \
  --rss-factor 128 \
  --output soak_profiles

# js_to_dart alone — matches 20260722T114650Z/
scripts/run-soak-ab.sh \
  --profile js_to_dart \
  --duration 3600 \
  --rss-factor 128 \
  --output 20260722T_js_to_dart \
  --plot
```

### Single profile A/B

```bash
scripts/run-soak-ab.sh --profile tiny --duration 3600 --rss-factor 128 --output soak_tiny --plot
scripts/run-soak-ab.sh --profile dart_to_js --duration 3600 --rss-factor 128 --output soak_d2j --plot
```

Profiles: `all`, `tiny`, `no_typed_array`, `dart_to_js`, `js_to_dart`, `typed_array`.

### Plot existing dumps

```bash
scripts/run-soak-ab.sh --plot-only soak_profiles
scripts/run-soak-ab.sh --plot-only 20260722T114650Z
# or
python3 scripts/plot-soak-metrics.py --root soak_profiles --output soak_profiles/report
python3 scripts/plot-soak-metrics.py path/to/soak_metrics.jsonl -o report.html
```

Open `…/report/index.html` (Chart.js CDN).

### Common flags

| Flag | Meaning |
|------|---------|
| `--profile NAME` | Workload profile |
| `--duration SEC` | Per case wall time |
| `--rss-factor N` | RSS limit / stop heuristic factor (128 used here) |
| `--output DIR` | Artifact root |
| `--plot` / `--no-plot` | HTML reports |
| `--full-test` | Multi-profile matrix (plot on by default) |

See `scripts/run-soak-ab.sh --help` and each run’s `config.txt`.

### What to check after a run

1. `summary.tsv` — all `exit_status=0`.
2. Last sample of each `**/soak_metrics.jsonl`:
   - `errors == 0`
   - when used: `bridge.allocCalls == bridge.freeCalls`
   - Σ `engines[].qjs.mallocSize` not unbounded vs time
3. RSS: start / end / peak; late-window slope; floor mins (HTML report or JSONL script).
4. Compare **reset_on vs reset_off** for the same profile.

### Regression heuristics

| Check | Pass if |
|-------|---------|
| Correctness | `errors=0`, exit 0 |
| Bridge | `allocCalls == freeCalls` on dart_to_js |
| QJS | Σ `mallocSize` not growing with ops on stable engines |
| RSS baseline | **`tiny` + reset_off** ~1 h: small Δ, late slope ≈ 0 |
| RSS reference | **`js_to_dart` + reset_off** also plateaus |
| Stress context | `dart_to_js` / `no_typed_array` may climb; **fail** if QJS/bridge break, or tiny baseline stops plateauing |

Do **not** fail a build on absolute `dart_to_js` RSS alone without QJS/bridge context — host allocator and GC timing differ.

### Short unit / bridge tests

```bash
cd example
flutter test test/bridge_diagnostics_test.dart
flutter test test/bridge_counter_benchmark_test.dart
flutter test test/leak_and_stress_test.dart
flutter test test/typed_array_test.dart
```

---

## Changelog of this analysis

| Date (UTC) | Dataset | Note |
|------------|---------|------|
| 2026-07-22 | `soak_profiles_postfix` | Intermediate; tiny/reset_off healthy |
| 2026-07-22 | `20260722T080602Z` | 1 h dart_to_js A/B; sawtooth + rising floor |
| 2026-07-22 | **`soak_profiles/`** | Full 1 h tiny / no_typed_array / dart_to_js; **no_typed_array linear without TA** |
| 2026-07-22 | **`20260722T114650Z/`** | Full 1 h js_to_dart; **reset_off plateaus** |
