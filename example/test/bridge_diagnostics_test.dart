import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_qjs_next/quickjs/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late JavascriptRuntime runtime;

  setUp(() {
    runtime = getJavascriptRuntime();
    jsBridgeStatsReset();
  });

  tearDown(() {
    runtime.dispose();
    debugPrint(
      'BRIDGE_STATS after_dispose ${jsonEncode(readBridgeStats())}',
    );
  });

  test('Dart TypedData bridge logs allocation and copy operations', () {
    final length = runtime.evaluate('(x) => x.length').rawResult as JSInvokable;
    try {
      final input =
          Uint8List.fromList(List<int>.generate(4096, (i) => i & 255));
      expect(length.invoke([input]), input.length);

      final stats = readBridgeStats();
      debugPrint('BRIDGE_STATS dart_to_js ${jsonEncode(stats)}');
      expect(stats['allocCalls'], greaterThanOrEqualTo(1));
      expect(stats['allocBytes'], greaterThanOrEqualTo(input.length));
      expect(stats['copyCalls'], greaterThanOrEqualTo(1));
      expect(stats['copyBytes'], greaterThanOrEqualTo(input.length));
      expect(stats['ownedTypedArrayCalls'], greaterThanOrEqualTo(1));
    } finally {
      length.free();
    }
  });

  test('JS TypedArray bridge logs native data access', () {
    final factory =
        runtime.evaluate('() => new Uint8Array(4096)').rawResult as JSInvokable;
    try {
      final output = factory.invoke(const []);
      expect(output, isA<Uint8List>());

      final stats = readBridgeStats();
      debugPrint('BRIDGE_STATS js_to_dart ${jsonEncode(stats)}');
      expect(stats['typedArrayDataCalls'], greaterThanOrEqualTo(1));
      // The current safe path copies JS-owned memory into a Dart-owned list.
      expect(stats['copyCalls'], greaterThanOrEqualTo(1));
      expect(stats['memcpyCalls'], 0);
    } finally {
      factory.free();
    }
  });
}
