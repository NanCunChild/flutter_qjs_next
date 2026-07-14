import 'package:flutter_qjs_example/benchmark_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Preferred benchmark entry (loads the plugin native library via Flutter).
///
/// ```bash
/// cd example && flutter test test/benchmark_test.dart
/// ```
///
/// Do **not** use `dart run benchmark/...` — standalone Dart can crash while
/// compiling FFI (`NativeCallable` / `Pointer.fromFunction`) on recent SDKs.
void main() {
  test('flutter_qjs_next micro-benchmarks', () {
    final results = runFlutterQjsBenchmarks();
    expect(results, isNotEmpty);
    // Expected families: hot path, string/map, buffer ladder, json vs full, js→dart
    final names = results.map((r) => r.name).join('\n');
    expect(names, contains('evaluate tiny'));
    expect(names, contains('invoke host'));
    expect(names, contains('string Dart'));
    expect(names, contains('small Map'));
    expect(names, contains('1024 B'));
    expect(names, contains('evaluateJson'));
    expect(names, contains('JS Uint8Array'));
    for (final r in results) {
      expect(r.avgUsPerOp, greaterThanOrEqualTo(0));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
