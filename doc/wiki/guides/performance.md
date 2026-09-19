# Performance

Production issues are often **process RSS, UI jank, and integration misuse** rather than us/op on small expressions. Ship with the [Production integration checklist](production-checklist.md).

## Prefer reuse

Creating a QuickJS engine is far more expensive than `evaluate` on a warm runtime.

- Long-lived feature → **one** `JavascriptRuntime`  
- Parallel short scripts → **`JsEnginePool`** with a modest `maxSize`  
- Avoid `getJavascriptRuntime()` per request in a hot loop  
- Multi-tenant: prefer **`resetMode: soft`**. Do **not** use `hard` / `resetOnRelease: true` as a generic “memory fix” — it rebuilds the engine on every release (~19 % less throughput in the `no_typed_array` soak) and process RSS ends no lower. See [Soak RSS analysis](soak-rss-analysis.md).

## Choose the right evaluate path

| Workload | Prefer |
|----------|--------|
| Small expressions, mixed types, functions | `evaluate` |
| Large pure JSON-like trees | **`evaluateJson`** |
| Binary buffers | TypedArray / `Uint8List` bulk path, not nested JS arrays of numbers |
| Same script many times | `compile` once + `evaluateBytecode` |

**Misuse that burns CPU and memory:** deep `evaluate` on multi‑MiB graphs, binary as `number[]`, and Dart→JS bulk copies in a tight UI-isolate loop.

## Cache host callables

```dart
final add = js.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
// invoke many times
add.free();
```

Creating a new function value every call allocates and needs free discipline.

### Call cost since 1.5.0

Calls into JS became much cheaper in 1.5.0. Before it, `JSInvokable.invoke`,
`evaluateJson` and `callFunction` posted a message to the engine's event-loop
port on every call, and nothing read it unless `dispatch()` was running. The
cost grew with the backlog. One engine, no `dispatch()`, millions of calls
(`benchmark_results/87a7363/`):

| Call | 1.4 (`75f5289`) | 1.5.0 | |
|---|---:|---:|---:|
| `invoke` `(a,b)=>a+b` | 2.09 µs | 0.50 µs | 4.2× |
| `invoke` identity, short string | 4.12 µs | 0.71 µs | 5.8× |
| `invoke` identity, 1 KiB `Uint8List` | 10.3 µs | 2.6 µs | 4.0× |
| `evaluateJson('[1,2,3]')` | 13.8 µs | 8.1 µs | 1.7× |
| `evaluate('1+1')` (no port message either way) | 5.5 µs | 3.6 µs | 1.5× |
| process RSS after the run | 2.7 GiB | 173 MiB | |

`evaluate` never posted the message; it got slower on 1.4 only because the
backlog from the earlier cases had grown the Dart heap. In the standard suite
(`benchmark_test.dart`, a few hundred calls per case, so little backlog) the
same fix shows as 2.2× on `invoke host`, 1.7× on string identity and 1.2–1.7×
on the small TypedArray calls; large copies and `evaluate` are unchanged.

## Jobs

Default `autoExecutePendingJobs: true` drains the job queue after evaluates. For micro-benchmarks of pure sync work you may disable it; for real apps leave it on unless you pump yourself.

## Benchmarks in this repo

```bash
cd example
flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=1
```

The checked-in reference comparison uses `BENCH_RUNS=32` on Linux with the
current runner. Results are grouped by commit under `benchmark_results/`:

- `benchmark_results/3261eb4/3261eb4_BENCH_RUNS32.txt`
- `benchmark_results/1c9561d/optimized_BENCH_RUNS32_clamped.txt`

The `3261eb4` log is a compatibility baseline. That old implementation cannot
complete the 16 MiB JS→Dart case in a practical 32-seed run, so that case is
omitted and its 1 MiB steady cases use two iterations. Use the comparison for
directional evidence, not product SLOs or exact apples-to-apples ratios.

The largest gains come from TypedArray bulk paths: the bridge avoids per-element
FFI conversion and performs a native-buffer copy. This is **not zero-copy**.
The current Dart → JS path copies Dart memory into a native buffer, while the
JS → Dart path copies JS-owned memory into a Dart-owned list.

Bridge operation counters are available in the independent diagnostic test:

```bash
cd example
flutter test test/bridge_diagnostics_test.dart
```

The test prints `BRIDGE_STATS` JSON records containing native allocation calls and
bytes, bridge copy calls and bytes, explicit native `memcpy` calls and bytes,
owned-buffer release callbacks, and TypedArray creation/data-access counts. The
counters are diagnostic only and do not prove zero-copy behavior.

For a one-shot counter benchmark covering representative 1 MiB paths, run:

```bash
cd example
flutter test test/bridge_counter_benchmark_test.dart
```

Captured results are stored under `benchmark_results/<commit-short-hash>/` so
measurements from different revisions remain separate.

## UI isolate

`evaluate` / `evaluateJson` / bulk bridge work is **synchronous on the calling isolate**. Multi‑ms or multi‑MiB work on the UI isolate causes jank — move it off-UI when latency matters.

## Logging

`FlutterQjsLogger` and `console.*` have cost; raise level or disable in hot production paths if needed.

## See also

- [Production integration checklist](production-checklist.md)  
- [Memory & lifecycle](memory-and-lifecycle.md)  
- [Multi-tenant pool](../recipes/multi-tenant-pool.md)  
- [Testing & benchmarks](../testing-and-benchmarks.md)  
