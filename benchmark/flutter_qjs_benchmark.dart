// ignore_for_file: avoid_print
//
// This file is intentionally not a supported entrypoint.
//
// Standalone `dart run` / `dart compile` may crash the Dart SDK while
// transforming FFI (`Pointer.fromFunction` → NativeCallable) on recent
// Dart versions. Use the Flutter test harness instead:
//
//   cd example && flutter test test/benchmark_test.dart
//
// Or open the example app and tap "Run Benchmarks".
//
// Shared implementation: example/lib/benchmark_runner.dart

void main() {
  print('''
flutter_qjs_next benchmarks must run under Flutter (not bare `dart run`).

  cd example && flutter test test/benchmark_test.dart

Or:

  cd example && flutter run
  # then tap "Run Benchmarks"
''');
}
