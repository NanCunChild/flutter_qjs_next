import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_qjs_next/quickjs/ffi.dart' show jsAllocBuffer, jsMemcpy;

/// Micro-benchmarks for evaluate / marshalling / TypedArray paths.
/// Run via [example/test/benchmark_test.dart] or the example app UI — not `dart run`.
class BenchmarkResult {
  BenchmarkResult(this.name, this.avgUsPerOp, this.iterations, {this.bytes});

  final String name;
  final double avgUsPerOp;
  final int iterations;
  final int? bytes;

  double? get mbPerSec {
    if (bytes == null || avgUsPerOp <= 0) return null;
    return bytes! / (avgUsPerOp * 1e-6) / (1024 * 1024);
  }

  @override
  String toString() {
    final thr = mbPerSec;
    final thrStr = thr == null ? '' : '  ${thr.toStringAsFixed(1)} MiB/s';
    return '$name: ${avgUsPerOp.toStringAsFixed(1)} us/op '
        '($iterations iters)$thrStr';
  }
}

/// Mean (and optional σ) over [BenchmarkSuite.runs] single-engine suites.
class AggregatedBenchmarkResult {
  AggregatedBenchmarkResult({
    required this.name,
    required this.meanUsPerOp,
    required this.stdevUsPerOp,
    required this.runs,
    required this.iterationsPerRun,
    this.bytes,
  });

  final String name;
  final double meanUsPerOp;
  final double stdevUsPerOp;
  final int runs;
  final int iterationsPerRun;
  final int? bytes;

  double? get mbPerSec {
    if (bytes == null || meanUsPerOp <= 0) return null;
    return bytes! / (meanUsPerOp * 1e-6) / (1024 * 1024);
  }

  @override
  String toString() {
    final thr = mbPerSec;
    final thrStr = thr == null ? '' : '  ${thr.toStringAsFixed(1)} MiB/s';
    final sigma = runs > 1 ? ' σ=${stdevUsPerOp.toStringAsFixed(1)}' : '';
    return '$name: ${meanUsPerOp.toStringAsFixed(1)} us/op '
        '(n=$runs$sigma, $iterationsPerRun iters/run)$thrStr';
  }
}

/// Multi-run suite: mean ± σ across distinct RNG seeds.
class BenchmarkSuite {
  BenchmarkSuite({
    required this.results,
    required this.runs,
    required this.seeds,
    required this.length,
    required this.iterations,
  });

  final List<AggregatedBenchmarkResult> results;
  final int runs;
  final List<int> seeds;
  final int length;
  final int iterations;

  @override
  String toString() {
    final buf = StringBuffer()
      ..writeln(
        'benchmark suite: runs=$runs seeds=$seeds '
        'length=$length iterations=$iterations',
      );
    for (final r in results) {
      buf.writeln(r);
    }
    return buf.toString().trimRight();
  }
}

/// Fixed RNG seed so multi-size buffer payloads are comparable across commits.
const int kBenchmarkSeed = 0x714A5;

/// Default multi-seed set (8) used for mean/σ when [runs] > 1.
const List<int> kBenchmarkDefaultSeeds = <int>[
  464037,
  1118481,
  2236962,
  3355443,
  11259375,
  5613141,
  14593470,
  12648430,
];

List<int> _resolveSeeds({
  required int runs,
  required int baseSeed,
  List<int>? seeds,
}) {
  if (runs < 1) {
    throw ArgumentError.value(runs, 'runs', 'must be >= 1');
  }
  if (seeds != null) {
    if (seeds.length < runs) {
      throw ArgumentError(
        'seeds.length (${seeds.length}) must be >= runs ($runs)',
      );
    }
    return seeds.take(runs).toList(growable: false);
  }
  if (runs == 1) {
    return <int>[baseSeed];
  }
  if (runs <= kBenchmarkDefaultSeeds.length) {
    return kBenchmarkDefaultSeeds.take(runs).toList(growable: false);
  }
  final out = List<int>.from(kBenchmarkDefaultSeeds);
  var s = baseSeed ^ 0x9E3779B9;
  while (out.length < runs) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out.add(s);
  }
  return out;
}

double _mean(List<double> xs) {
  var sum = 0.0;
  for (final x in xs) {
    sum += x;
  }
  return sum / xs.length;
}

/// Sample standard deviation (n−1); 0 when n < 2.
double _stdev(List<double> xs, double mean) {
  if (xs.length < 2) return 0;
  var acc = 0.0;
  for (final x in xs) {
    final d = x - mean;
    acc += d * d;
  }
  return sqrt(acc / (xs.length - 1));
}

/// Run the suite [runs] times (default **8**), each with a different seed,
/// and return per-metric mean ± σ.
///
/// ```dart
/// // default: 8 seeds
/// final suite = runFlutterQjsBenchmarkSuite(log: print);
///
/// // fewer / more repeats
/// runFlutterQjsBenchmarkSuite(runs: 3, log: print);
/// runFlutterQjsBenchmarkSuite(runs: 1, seed: kBenchmarkSeed, log: print);
/// ```
///
/// CLI (via `example/test/benchmark_test.dart`):
/// `--dart-define=BENCH_RUNS=8` · `--dart-define=BENCH_SEED=464037`
BenchmarkSuite runFlutterQjsBenchmarkSuite({
  int runs = 8,
  int length = 10000,
  int iterations = 40,
  int seed = kBenchmarkSeed,
  List<int>? seeds,
  void Function(String line)? log,
}) {
  void emit(String line) {
    log?.call(line);
    FlutterQjsLogger.info(line);
  }

  final resolved = _resolveSeeds(runs: runs, baseSeed: seed, seeds: seeds);
  emit(
    'benchmark suite: runs=${resolved.length} seeds=$resolved '
    'length=$length iterations=$iterations',
  );

  final byName = <String, List<double>>{};
  final meta = <String, ({int iterations, int? bytes})>{};

  for (var i = 0; i < resolved.length; i++) {
    final s = resolved[i];
    emit('--- run ${i + 1}/${resolved.length} seed=$s ---');
    final one = runFlutterQjsBenchmarks(
      length: length,
      iterations: iterations,
      seed: s,
      log: log,
    );
    for (final r in one) {
      byName.putIfAbsent(r.name, () => <double>[]).add(r.avgUsPerOp);
      meta.putIfAbsent(
        r.name,
        () => (iterations: r.iterations, bytes: r.bytes),
      );
    }
  }

  final aggregated = <AggregatedBenchmarkResult>[];
  for (final name in byName.keys) {
    final samples = byName[name]!;
    final m = _mean(samples);
    final sd = _stdev(samples, m);
    final info = meta[name]!;
    final ar = AggregatedBenchmarkResult(
      name: name,
      meanUsPerOp: m,
      stdevUsPerOp: sd,
      runs: samples.length,
      iterationsPerRun: info.iterations,
      bytes: info.bytes,
    );
    emit(ar.toString());
    aggregated.add(ar);
  }

  return BenchmarkSuite(
    results: aggregated,
    runs: resolved.length,
    seeds: resolved,
    length: length,
    iterations: iterations,
  );
}

List<BenchmarkResult> runFlutterQjsBenchmarks({
  int length = 10000,
  int iterations = 40,
  int seed = kBenchmarkSeed,
  void Function(String line)? log,
}) {
  void emit(String line) {
    log?.call(line);
    FlutterQjsLogger.info(line);
  }

  emit(_machineBanner(seed: seed, length: length, iterations: iterations));

  final runtime = getJavascriptRuntime() as QuickJsRuntime2;
  final results = <BenchmarkResult>[];
  final rng = Random(seed);

  BenchmarkResult bench(
    String name,
    void Function() body, {
    int? bytes,
    int? iters,
  }) {
    final n = iters ?? iterations;
    body(); // warmup
    final watch = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      body();
    }
    watch.stop();
    final avgUs = watch.elapsedMicroseconds / n;
    final r = BenchmarkResult(name, avgUs, n, bytes: bytes);
    emit(r.toString());
    results.add(r);
    return r;
  }

  try {
    // --- 1) Evaluate and automatic job-drain controls ---
    bench('evaluate tiny (auto jobs on)', () {
      runtime.evaluate('1+1');
    }, iters: iterations * 5);
    runtime.autoExecutePendingJobs = false;
    bench('evaluate tiny (auto jobs off)', () {
      runtime.evaluate('1+1');
    }, iters: iterations * 5);
    runtime.autoExecutePendingJobs = true;

    final addFn = runtime.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
    try {
      bench('invoke host (a,b)=>a+b', () {
        addFn.invoke([1, 2]);
      }, iters: iterations * 5);
    } finally {
      addFn.free();
    }

    final idFn = runtime.evaluate('(x)=>x').rawResult as JSInvokable;
    final lenFn = runtime.evaluate('(v)=>v.length').rawResult as JSInvokable;
    try {
      // --- 2) String / small Map marshalling ---
      const s = 'hello-flutter-qjs-next-benchmark-string-payload-0123456789';
      bench('string Dart→JS→Dart (identity)', () {
        idFn.invoke([s]);
      });

      final smallMap = <String, dynamic>{
        'a': 1,
        'b': 'two',
        'c': true,
        'd': [1, 2, 3],
      };
      bench('small Map Dart→JS→Dart (identity)', () {
        idFn.invoke([smallMap]);
      });

      // --- 3) Buffer size ladder: Dart→JS owned path (JS only reads .length) ---
      for (final size in const [1024, 64 * 1024, 1024 * 1024]) {
        final bytes = _seededUint8(size, rng);
        bench(
          'Dart Uint8List→JS length ($size B)',
          () {
            lenFn.invoke([bytes]);
          },
          bytes: size,
          iters: size >= 1024 * 1024 ? (iterations ~/ 2).clamp(4, 20) : null,
        );
      }

      final f64 = Float64List.fromList(
        List<double>.generate(length, (i) => i.toDouble()),
      );
      bench('Dart Float64List→JS length ($length)', () {
        lenFn.invoke([f64]);
      }, bytes: f64.lengthInBytes);
    } finally {
      idFn.free();
      lenFn.free();
    }

    // --- 4) evaluateJson vs full evaluate (jsToDart) ---
    final arraySrc = 'Array.from({length: $length}, (_, i) => i)';
    bench('evaluate large array (full jsToDart)', () {
      runtime.evaluate(arraySrc);
    });
    bench('evaluateJson large array', () {
      runtime.evaluateJson(arraySrc);
    });

    // Object-shaped payload: JSON path should stay cheaper than deep walk.
    final objectSrc =
        '({n:$length, items: Array.from({length: ${length ~/ 10}}, '
        '(_, i) => ({i, s: "x"+i}))})';
    bench('evaluate large object (full jsToDart)', () {
      runtime.evaluate(objectSrc);
    });
    bench('evaluateJson large object', () {
      runtime.evaluateJson(objectSrc);
    });

    // --- 5) JS allocation + JS → Dart conversion ---
    for (final size in const [1024, 64 * 1024, 1024 * 1024]) {
      final allocateAndReturn =
          runtime.evaluate('(n) => new Uint8Array(n)').rawResult as JSInvokable;
      bench(
        'JS allocate Uint8Array→Dart ($size B)',
        () {
          allocateAndReturn.invoke([size]);
        },
        bytes: size,
        iters: size >= 1024 * 1024 ? (iterations ~/ 2).clamp(4, 20) : null,
      );
      allocateAndReturn.free();

      // The same JS TypedArray is returned repeatedly, so this excludes JS
      // allocation and measures the bridge conversion plus its Dart copy.
      final fixed = runtime.evaluate('''
        (() => {
          const value = new Uint8Array($size);
          return () => value;
        })()
      ''').rawResult as JSInvokable;
      bench(
        'fixed JS Uint8Array→Dart ($size B)',
        () => fixed.invoke(const []),
        bytes: size,
        iters: size >= 1024 * 1024 ? (iterations ~/ 2).clamp(4, 20) : null,
      );
      fixed.free();
    }
    bench('JS Float64Array→Dart ($length)', () {
      runtime.evaluate('new Float64Array($length)');
    }, bytes: length * 8);

    // --- 6) Native memcpy only ---
    for (final size in const [1024, 64 * 1024, 1024 * 1024]) {
      final src = jsAllocBuffer(size);
      final dst = jsAllocBuffer(size);
      if (src.address == 0 || dst.address == 0) {
        if (src.address != 0) malloc.free(src);
        if (dst.address != 0) malloc.free(dst);
        throw StateError('Unable to allocate memcpy benchmark buffers');
      }
      src.asTypedList(size).fillRange(0, size, 0xA5);
      try {
        bench(
          'native memcpy ($size B)',
          () => jsMemcpy(dst, src, size),
          bytes: size,
          iters: size >= 1024 * 1024
              ? (iterations ~/ 2).clamp(4, 20)
              : iterations * 20,
        );
      } finally {
        malloc.free(src);
        malloc.free(dst);
      }
    }
  } finally {
    runtime.dispose();
  }
  return results;
}

String _machineBanner({
  required int seed,
  required int length,
  required int iterations,
}) {
  final os = Platform.operatingSystem;
  final ver = Platform.operatingSystemVersion;
  final processors = Platform.numberOfProcessors;
  final exe = Platform.resolvedExecutable;
  return 'benchmark env: os=$os processors=$processors seed=$seed '
      'length=$length iterations=$iterations\n'
      '  osVersion=$ver\n'
      '  executable=$exe';
}

Uint8List _seededUint8(int length, Random rng) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}
