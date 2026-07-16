import 'package:flutter_qjs_example/benchmark_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Preferred benchmark entry (loads the plugin native library via Flutter).
///
/// ```bash
/// cd example
/// # default: 8 seeds → mean ± σ
/// flutter test test/benchmark_test.dart
///
/// # fewer / more repeats
/// flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=3
/// flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=1
///
/// # fixed base seed (used when runs=1, or as generator seed when runs>8)
/// flutter test test/benchmark_test.dart --dart-define=BENCH_SEED=464037
/// ```
///
/// Do **not** use `dart run benchmark/...` — standalone Dart can crash while
/// compiling FFI (`NativeCallable` / `Pointer.fromFunction`) on recent SDKs.
void main() {
  test('flutter_qjs_next micro-benchmarks', () {
    final runsEnv = const String.fromEnvironment('BENCH_RUNS');
    final seedEnv = const String.fromEnvironment('BENCH_SEED');
    final runs = runsEnv.isEmpty ? 8 : int.parse(runsEnv);
    final seed = seedEnv.isEmpty ? kBenchmarkSeed : int.parse(seedEnv);

    final suite = runFlutterQjsBenchmarkSuite(
      runs: runs,
      seed: seed,
      log: print,
    );
    // ignore: avoid_print
    print(suite);

    expect(suite.results, isNotEmpty);
    expect(suite.runs, runs);
    final names = suite.results.map((r) => r.name).join('\n');
    expect(names, contains('evaluate tiny'));
    expect(names, contains('invoke host'));
    expect(names, contains('string Dart'));
    expect(names, contains('small Map'));
    expect(names, contains('1024 B'));
    expect(names, contains('evaluateJson'));
    expect(names, contains('JS allocate Uint8Array'));
    expect(names, contains('fixed JS Uint8Array'));
    expect(names, contains('native memcpy'));
    for (final r in suite.results) {
      expect(r.meanUsPerOp, greaterThanOrEqualTo(0));
      expect(r.runs, runs);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
