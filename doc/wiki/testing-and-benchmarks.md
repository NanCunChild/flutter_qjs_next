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

## Soak / long-haul stress

Runner: `example/lib/soak_stress_runner.dart` (entry `example/test/soak_stress_test.dart`).

Metrics are appended as JSONL under `SOAK_DUMP_DIR/soak_metrics.jsonl` (RSS, QJS heap,
pool stats, bridge counters, per-op `opCounts`).

### A/B and full_test matrix

From the **repo root**:

```bash
# Single profile, reset on vs off (default 1h each)
scripts/run-soak-ab.sh --profile tiny --duration 3600 --rss-factor 128

# Full matrix: every profile × reset on/off, then HTML charts
scripts/run-soak-ab.sh --full-test --duration 3600 --rss-factor 128 --output soak_profiles

# Custom profile list
scripts/run-soak-ab.sh --full-test --profiles tiny,no_typed_array,dart_to_js --duration 600
```

Profiles: `all`, `tiny`, `no_typed_array`, `dart_to_js`, `js_to_dart`, `typed_array`.

### Charts (line + path heatmaps)

```bash
# After a run (or for existing dumps)
scripts/run-soak-ab.sh --plot-only soak_profiles
# or
python3 scripts/plot-soak-metrics.py --root soak_profiles --output soak_profiles/report

# Single metrics file
python3 scripts/plot-soak-metrics.py path/to/soak_metrics.jsonl -o report.html
```

Open `…/report/index.html` in a browser (Chart.js CDN; offline needs network once for the CDN).

Each case report includes:

- Line charts: RSS/PSS, throughput, QJS heap, pool, bridge counters  
- Path heatmaps: op-kind activity over time (`opCounts`) and bridge counter deltas  

`--full-test` enables plotting by default; use `--plot` / `--no-plot` to override.

### Interpreting RSS vs leaks

Long-haul results (tiny plateau vs `dart_to_js` rising floor, bridge/QJS checks):
**[Soak RSS analysis](guides/soak-rss-analysis.md)**.

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
