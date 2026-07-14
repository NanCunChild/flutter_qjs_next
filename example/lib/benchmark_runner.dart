import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';

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
    final thrStr =
        thr == null ? '' : '  ${thr.toStringAsFixed(1)} MiB/s';
    return '$name: ${avgUsPerOp.toStringAsFixed(1)} us/op '
        '($iterations iters)$thrStr';
  }
}

/// Fixed RNG seed so multi-size buffer payloads are comparable across commits.
const int kBenchmarkSeed = 0x714A5;

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

  final runtime = getJavascriptRuntime();
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
    // --- 1) Hot path: tiny evaluate + cached invoke ---
    bench('evaluate tiny (1+1)', () {
      runtime.evaluate('1+1');
    }, iters: iterations * 5);

    final addFn =
        runtime.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
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
      const s =
          'hello-flutter-qjs-next-benchmark-string-payload-0123456789';
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

    // JS → Dart typed arrays (always one memcpy today)
    for (final size in const [1024, 64 * 1024, 1024 * 1024]) {
      bench(
        'JS Uint8Array→Dart ($size B)',
        () {
          runtime.evaluate('new Uint8Array($size)');
        },
        bytes: size,
        iters: size >= 1024 * 1024 ? (iterations ~/ 2).clamp(4, 20) : null,
      );
    }
    bench('JS Float64Array→Dart ($length)', () {
      runtime.evaluate('new Float64Array($length)');
    }, bytes: length * 8);
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
