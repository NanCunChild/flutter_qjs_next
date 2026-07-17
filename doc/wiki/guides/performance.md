# Performance

## Prefer reuse

Creating a QuickJS engine is far more expensive than `evaluate` on a warm runtime.

- Long-lived feature → **one** `JavascriptRuntime`  
- Parallel short scripts → **`JsEnginePool`** with a modest `maxSize`  
- Avoid `getJavascriptRuntime()` per request in a hot loop  

## Choose the right evaluate path

| Workload | Prefer |
|----------|--------|
| Small expressions, mixed types, functions | `evaluate` |
| Large pure JSON-like trees | **`evaluateJson`** |
| Binary buffers | TypedArray / `Uint8List` bulk path, not nested JS arrays of numbers |
| Same script many times | `compile` once + `evaluateBytecode` |

## Cache host callables

```dart
final add = js.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
// invoke many times
add.free();
```

Creating a new function value every call allocates and needs free discipline.

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

## Logging

`FlutterQjsLogger` and `console.*` have cost; raise level or disable in hot production paths if needed.

## See also

- [Memory & lifecycle](memory-and-lifecycle.md)  
- [Testing & benchmarks](../testing-and-benchmarks.md)  
