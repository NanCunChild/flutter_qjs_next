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

The checked-in results below are the reference results for this revision. They were
collected on a ThinkBook 2024 with an Intel Ultra 7 155H, 32 GB DDR5 RAM, and
ArchLinux `7.1.3-arch1-3 SMP`, using `BENCH_RUNS=32`:

| Scenario | Baseline | Current | Speedup |
|----------|---------:|--------:|--------:|
| Dart `Uint8List` → JS, 1 MiB | 110 us/op | 35.7 us/op | 3.1x |
| Dart `Float64List` → JS, 10k | 1567 us/op | 4.0 us/op | 392x |
| JS `Uint8Array` → Dart, 1 MiB | 931803 us/op | 25239 us/op | 37x |
| JS `Float64Array` → Dart, 10k | 6779 us/op | 711.6 us/op | 9.5x |
| Large array, full `jsToDart` | 2571 us/op | 1647.7 us/op | 1.6x |
| Large array, `evaluateJson` | not recorded | 1094.4 us/op | n/a |
| Large object, full `jsToDart` | 4983 us/op | 4431.1 us/op | 1.1x |
| Large object, `evaluateJson` | not recorded | 795.6 us/op | n/a |

The complete logs are `benchmark_results/baseline_3261eb4_BENCH_RUNS32.txt`
and `benchmark_results/main_BENCH_RUNS32.txt`. These are single-host
microbenchmarks and should be used for relative comparisons, not product SLOs.

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

## Logging

`FlutterQjsLogger` and `console.*` have cost; raise level or disable in hot production paths if needed.

## See also

- [Memory & lifecycle](memory-and-lifecycle.md)  
- [Testing & benchmarks](../testing-and-benchmarks.md)  
