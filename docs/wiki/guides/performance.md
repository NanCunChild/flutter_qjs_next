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

Illustrative relative results (single host, see root README / `benchmark_results/` for raw logs):

- `evaluateJson` vs full `evaluate` on large arrays can be **~100×**  
- Owned TypedArray Dart→JS vs element-wise **~1000×** at larger sizes  

Treat numbers as order-of-magnitude, not guarantees.

## Logging

`FlutterQjsLogger` and `console.*` have cost; raise level or disable in hot production paths if needed.

## See also

- [Memory & lifecycle](memory-and-lifecycle.md)  
- [Testing & benchmarks](../testing-and-benchmarks.md)  
