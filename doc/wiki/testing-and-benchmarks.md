# Testing & benchmarks

All paths below assume the **example** Flutter app (plugin consumer).

```bash
cd example
flutter pub get
```

## Unit / integration tests

| File | Focus |
|------|--------|
| `test/typed_array_test.dart` | TypedArray / ArrayBuffer marshalling |
| `test/bridge_diagnostics_test.dart` | Native bridge allocation/copy counters |
| `test/bridge_counter_benchmark_test.dart` | Counter benchmark for representative bridge paths |
| `test/leak_and_stress_test.dart` | Jobs, pool, dispose, stress |
| `test/benchmark_test.dart` | Micro-benchmarks |
| `test/soak_stress_test.dart` | Short soak (~30 s smoke) |

```bash
flutter test test/typed_array_test.dart
flutter test test/bridge_diagnostics_test.dart
flutter test test/bridge_counter_benchmark_test.dart
flutter test test/leak_and_stress_test.dart
flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=1
flutter test test/soak_stress_test.dart
```

## Benchmark notes

- Default seed count can be reduced with `BENCH_RUNS`.  
- Results are host-dependent; use for **relative** comparisons.  
- Optional CI artifacts may live under `benchmark_results/` when generated.
- Counter benchmark logs are stored under `benchmark_results/<commit-short-hash>/`.

## In-app tools

`example/lib/main.dart` exposes UI for demos and may open a benchmarks screen.  
`example/lib/soak_stress_runner.dart` drives longer soaks.

## Minimal smoke for app authors

```dart
test('qjs smoke', () {
  final js = getJavascriptRuntime(timeout: 3000);
  addTearDown(js.dispose);
  final r = js.evaluate('1+1');
  expect(r.isError, isFalse);
  expect(r.rawResult, 2);
});
```

Run with **`flutter test`**, not standalone `dart test` without plugin linkage.

## Analyze

```bash
flutter analyze
```
