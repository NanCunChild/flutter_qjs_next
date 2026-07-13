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
    for (final r in results) {
      expect(r.avgUsPerOp, greaterThanOrEqualTo(0));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
