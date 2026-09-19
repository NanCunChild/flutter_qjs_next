# Soak RSS analysis (2026-07, updated 2026-09-19)

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

> **Superseded in part (2026-09-19).** The non-fetch climb below was mostly a
> real Dart-side leak: `jsCall` posted a wake-up message to an event-loop port
> nobody listened to. Fixed in `9634345`; see
> [Update 2026-09-19](#update-2026-09-19--the-non-fetch-climb-was-the-event-loop-port).
> Read the table as the pre-fix state; the profiles were re-run on 1.5.0 in
> [Re-run 2026-09-19](#re-run-2026-09-19-150).

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

## Update 2026-09-17 — where the growth actually lives

The earlier reading on this page (and in `doc/design/2026-09-16-web-apis-soak.md`)
was that the climb "looks like glibc allocator fragmentation". **It is not.**
`jsNativeHeapUsage` (glibc `mallinfo2`, exported as `readNativeHeapUsage()` and
now sampled into `soak_metrics.jsonl` as `nativeHeap`) settles the question:

| | start | after 150 s of `web_fetch` |
|---|---|---|
| process RSS | 151 MB | 691 MB |
| C heap arena | 4 MB | **41 MB** |
| C heap in use | 3 MB | **5 MB** |
| `malloc_trim(0)` recovered | — | **24 MB** |

The C heap is flat. Everything that grows is outside `malloc`, i.e. the **Dart
heap**. `getAllocationProfile` over the same run shows the growth is generic
async machinery plus body bytes — `_Closure`, `Context`, `_List`, `_Future`,
`_DelayedData`, `_Uint8List` — all linear in ops, none of it QuickJS.

### Which workload

Slope over the second half of a 90–150 s run, pool 32 / workers 32,
`resetOnRelease=true`:

| Profile | MB/s | B/op |
|---|---|---|
| `tiny`, `all`, `web_url`, `web_encoding`, `web_blob`, `web_streams` | ≤ 0.05 | plateau |
| `web_core` | 0.23 | 154 |
| `web_crypto` | 0.19 | 254 |
| `mixed_all` | 0.76 | 919 |
| **`web_fetch`** | **3.04** | **6655** |

`mixed_all` is ~16 % fetch ops, which accounts for almost all of its slope: the
8 h remote run that hit `RSS growth exceeded: rss=16649916416 … factor=128.0`
was a fetch problem, not an engine-lifecycle problem. Its own counters agree —
QuickJS heap byte-for-byte constant (`mallocSize` 665 KB, `objCount` 840), bridge
`allocCalls == freeCalls`, `dartRefs` 18, fds flat.

### Which part of fetch

One operation at a time (`SOAK_PROFILE=op:<opName>`, 90 s each):

| Operation | MB/s | B/op |
|---|---|---|
| **`fetchAbort`** | **5.12** | **6654** |
| `fetchStream` | 0.26 | 546 |
| `fetchJson` | 0.18 | 269 |
| `fetchGet` | 0.13 | 186 |
| `fetchAbandoned` | 0.13 | 106 |
| `fetchUpload` | 0.12 | 214 |
| `fetchRedirect` | 0.04 | 117 |

Everything except `fetchAbort` sits in the same band as a plateauing non-web
profile. **Aborting an in-flight request is the whole leak.**

Two more controls, both with no QuickJS in the process at all
(`example/test/http_control_test.dart`, same client/server shapes, an
`HttpClient` per 8 requests force-closed like an engine lease):

| Control | ops | RSS |
|---|---|---|
| read short bodies to the end (`CONTROL_MODE=read`) | 278 k | flat ~205 MB |
| stop reading a slow response, cancel the subscription (`CONTROL_MODE=cancel`) | 43 k | flat ~228 MB |
| same, but paused between chunks like the fetch host (`CONTROL_MODE=cancelpaused`) | 13 k | flat ~223 MB |
| **`HttpClientRequest.abort()` on a slow response (`CONTROL_MODE=abort`)** | **30 k** | **150 → 1206 MB** |

The three non-abort shapes plateau; the abort shape grows linearly at roughly
40 KB per request, with no QuickJS in the process. So the retention belongs to
`dart:io`'s aborted-request path on this SDK (Flutter 3.44.1 / Dart 3.10), not
to the fetch bridge and not to QuickJS. Cancelling the response body is the
cheap way to stop reading; `abort()` is not — but `abort()` is also the only way
to stop a request whose response has not arrived yet, so `AbortSignal` support
cannot simply drop it.

The harness had a second, independent bug in the same operation: the in-process
`/slow` endpoint kept writing to a peer that had gone away. A write to an
aborted socket neither fails nor completes, so the handler parked forever and
every aborted request retained its response graph — 6682 live handlers after
10 k requests. `_startSoakServer` now watches `response.done` and bounds
`flush()`/`close()`, which keeps live handlers bounded.

**Implication for callers:** `AbortController` on `fetch` costs process memory
per abort that this package cannot reclaim. When a workload aborts at a high
rate, prefer cancelling `response.body` (or letting the response finish) over
`AbortController.abort()`, and budget RSS for it when neither is possible.

### Re-running the attribution

```bash
cd example
# one operation at a time (SOAK_PROFILE=op:<opName>)
flutter test test/soak_stress_test.dart --timeout none \
  --dart-define=SOAK_PROFILE=op:fetchStream --dart-define=SOAK_DURATION_SEC=150 \
  --dart-define=SOAK_POOL_SIZE=32 --dart-define=SOAK_WORKERS=32

# Dart heap by class: start the run paused, then attach
flutter test test/soak_stress_test.dart --timeout none --start-paused ... &
dart run tool/heap_profile.dart <printed VM service URI> 8
dart run tool/heap_histogram.dart <printed VM service URI> 120
```

Read `nativeHeap.arena` / `nativeHeap.inUse` in `soak_metrics.jsonl` first: if
they are flat while `rss` climbs, do not go looking in QuickJS or in the
allocator.

## Update 2026-09-19 — the non-fetch climb was the event-loop port

`profile=all` (no Web APIs, so no fetch) still grew linearly at ~28 B/op on
`75f5289`: 172 → 947 MB in 1 h, with the QuickJS heap, C heap, bridge, fds and
`dartRefs` all flat.

**Cause.** `jsCall` posted `#call` to the runtime's `ReceivePort` on every call,
without the `eventLoopActive` check `jsEval` already had. Only `dispatch()`
listens to that port, and pooled engines never run it. An unlistened
`ReceivePort` buffers each message as a `_DelayedData` (32 B) in its
`_PendingEvents` queue. The port is created once per engine and closed only in
`dispose()` (resets do not recreate it), so the queue grows for the life of the
engine, which for a pool is the life of the process. `JSInvokable.invoke`,
`evaluateJson` (it calls `JSON.stringify` through `jsCall`) and `callFunction`
all go through `jsCall`; the `all` mix averages ~0.7 calls per op.

**A/B** (same tree, only the guard toggled; `all`, `web=none`, pool 32 / workers
32, heap snapshot at 120 s):

| | guard removed (= `75f5289`) | guard (`9634345`) |
|---|---|---|
| `_DelayedData` on the Dart heap | **417 543, 13.4 MB** | none |
| `_PendingEvents` | 36 (≈ one per engine) | 5 |
| RSS slope, 20–115 s | 36.5 B/op | 11.4 B/op (warm-up, see below) |

417 543 messages over ~600 k ops × 32 B ≈ 22 B/op, which matches the 25 B/op gap.

**1 h confirmation** (`9634345`, same config, `SOAK_MAX_RSS_GROWTH=0`):

| | `75f5289` | `9634345` |
|---|---|---|
| ops / errors | 25.9 M / 0 | 18.9 M / 0 |
| RSS at 300 s → 3500 s | 263 → 870 MB | 207 → 209 MB |
| slope 300–1800 s | 655 MB/h, 26.1 B/op | 2.2 MB/h, 0.13 B/op |
| slope 1800–3500 s | 707 MB/h, 29.4 B/op | 3.2 MB/h, 0.17 B/op |
| end RSS / peak | 947 / 947 MB | 205 / 220 MB |

After ~5 min of warm-up RSS stays in a 203–211 MB band for the rest of the hour.

**What this means for the 2026-07 matrix.** Its pattern fits the same cause:
`tiny` (evaluate only, which goes through the guarded `jsEval`) and
`js_to_dart` plateaued, while `dart_to_js` and `no_typed_array`, which call JS
functions, climbed 1.1–1.4 GiB/h. The "fragmentation / pages not returned"
reading there was wrong for those profiles; the re-runs below no longer climb.

Regression test: `example/test/event_loop_port_test.dart` makes 1000 calls
with no `dispatch()` running and asserts nothing is waiting on `port` (it
sees 1001 messages with the guard removed).

### Re-run 2026-09-19 (1.5.0)

Same harness (pool 32 / workers 32, `web=none`, 10 min each, run back to back
under a user systemd unit on one Linux x64 host, debug build). `75f5289` and
`87a7363` (1.5.0) load the same native library; only the Dart code differs.
Slopes are least-squares fits of RSS after the first 300 s.

| Profile | reset | tree | ops/s | RSS at 300 s → end | slope | errors |
|---|---|---|---|---|---|---|
| `all` | on | `75f5289` | 5127 | 244 → 307 MB | 573 MB/h, **31 B/op** | 0 |
| `all` | on | 1.5.0 | 5348 | 208 → 222 MB | 37 MB/h, 1.9 B/op | 0 |
| `no_typed_array` | off | 1.5.0 | 6733 | 206 → 212 MB | 99 MB/h, 4.1 B/op | 0 |
| `no_typed_array` | on | 1.5.0 | 5451 | 204 → 208 MB | 51 MB/h, 2.6 B/op | 0 |
| `dart_to_js` | off | 1.5.0 | 13069 | 220 → 212 MB | 18 MB/h, 0.4 B/op | 0 |
| `tiny` | on | 1.5.0 | 21423 | 197 → 200 MB | 44 MB/h, 0.6 B/op | 0 |

- `no_typed_array` and `dart_to_js` climbed 1.1–1.4 GiB/h in 2026-07
  (≈ 190–230 MB per 10 min). On 1.5.0 they end within 10 MB of their 300 s
  value. The remaining slopes are warm-up over a 10 min window; the 1 h `all`
  run above settled at 2–3 MB/h after ~5 min. 10 min cannot rule out a slow
  drift; run 1 h before relying on a flat line for a specific profile.
- `resetOnRelease` (hard reset) no longer raises RSS (`tiny` +3 MB,
  `no_typed_array` 208 vs 212 MB without it), but it still costs throughput:
  −19 % on `no_typed_array`. The 2026-07 `tiny` + reset growth (+269 MiB/h)
  predates 1.2.2, which stopped allocating a class id per context on every
  rebuild; that is the likely cause, not re-verified here.
- The C heap arena stays at 14–27 MB in every run.

The "Executive summary" and "Results matrix" sections above describe the
pre-1.5.0 state; read them as history.

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
| 2026-09-17 | `profile=all`, `web_fetch`, `op:<name>` | C heap flat; fetch growth is `dart:io` `abort()` (see Update 2026-09-17) |
| 2026-09-19 | `profile=all` 1 h, `75f5289` vs `9634345` + 150 s A/B with heap snapshot | Non-fetch climb was `jsCall` queueing on the unlistened event-loop port; fixed, plateaus at ~207 MB |
| 2026-09-19 | 10 min each on 1.5.0: `all` (A/B vs `75f5289`), `no_typed_array` ±reset, `dart_to_js`, `tiny` + reset | 2026-07 climbs gone; hard reset costs throughput, not RSS (see Re-run 2026-09-19) |
