import 'package:flutter_qjs_example/soak_stress_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Long-haul soak / stress entry (loads plugin native library via Flutter).
///
/// Default is a **short smoke** (~30s). For real burn-in (≥1h):
///
/// ```bash
/// cd example
/// flutter test test/soak_stress_test.dart \
///   --dart-define=SOAK_DURATION_SEC=3600 \
///   --dart-define=SOAK_POOL_SIZE=8 \
///   --dart-define=SOAK_WORKERS=32
/// ```
///
/// Other defines: see header in `lib/soak_stress_runner.dart`.
///
/// Do **not** use bare `dart run` — same FFI constraint as benchmarks.
void main() {
  test('flutter_qjs_next soak / stress', () async {
    final result = await runSoakStress(log: print);
    // ignore: avoid_print
    print(result);
    expect(result.ok, isTrue);
    expect(result.totalOps, greaterThan(0));
  }, timeout: Timeout.none);
}
