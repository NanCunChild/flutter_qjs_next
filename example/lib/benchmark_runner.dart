import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';

/// Micro-benchmarks for evaluate / TypedArray marshalling.
/// Run via [example/test/benchmark_test.dart] or the example app UI — not `dart run`.
class BenchmarkResult {
  BenchmarkResult(this.name, this.avgUsPerOp, this.iterations);

  final String name;
  final double avgUsPerOp;
  final int iterations;

  @override
  String toString() =>
      '$name: ${avgUsPerOp.toStringAsFixed(1)} us/op ($iterations iters)';
}

List<BenchmarkResult> runFlutterQjsBenchmarks({
  int length = 10000,
  int iterations = 20,
  void Function(String line)? log,
}) {
  void emit(String line) {
    log?.call(line);
    FlutterQjsLogger.info(line);
  }

  final runtime = getJavascriptRuntime();
  final results = <BenchmarkResult>[];
  try {
    final bytes =
        Uint8List.fromList(List<int>.generate(length, (i) => i & 0xff));
    final floats = Float64List.fromList(
      List<double>.generate(length, (i) => i.toDouble()),
    );

    BenchmarkResult bench(String name, void Function() body) {
      body();
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        body();
      }
      watch.stop();
      final avgUs = watch.elapsedMicroseconds / iterations;
      final r = BenchmarkResult(name, avgUs, iterations);
      emit(r.toString());
      results.add(r);
      return r;
    }

    bench('evaluate large array', () {
      runtime.evaluate('Array.from({length: $length}, (_, i) => i)');
    });
    bench('evaluateJson large array', () {
      runtime.evaluateJson('Array.from({length: $length}, (_, i) => i)');
    });
    bench('Dart Uint8List to JS Uint8Array', () {
      final fn = runtime.evaluate('(v) => v.length').rawResult as JSInvokable;
      try {
        fn.invoke([bytes]);
      } finally {
        fn.free();
      }
    });
    bench('Dart Float64List to JS Float64Array', () {
      final fn = runtime.evaluate('(v) => v.length').rawResult as JSInvokable;
      try {
        fn.invoke([floats]);
      } finally {
        fn.free();
      }
    });
    bench('JS Uint8Array to Dart', () {
      runtime.evaluate('new Uint8Array($length)');
    });
    bench('JS Float64Array to Dart', () {
      runtime.evaluate('new Float64Array($length)');
    });
  } finally {
    runtime.dispose();
  }
  return results;
}
