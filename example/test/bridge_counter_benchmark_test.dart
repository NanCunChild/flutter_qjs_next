import 'dart:convert';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_qjs_next/quickjs/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late JavascriptRuntime runtime;

  setUp(() {
    runtime = getJavascriptRuntime();
  });

  tearDown(() {
    runtime.dispose();
  });

  test('bridge operation counter benchmark', () {
    final size = 1024 * 1024;
    final dartBytes = Uint8List(size);
    final length = runtime.evaluate('(x) => x.length').rawResult as JSInvokable;
    final factory = runtime.evaluate('() => new Uint8Array($size)').rawResult
        as JSInvokable;
    final cases = <String, Map<String, int>>{};

    try {
      jsBridgeStatsReset();
      expect(length.invoke([dartBytes]), size);
      cases['dart_to_js_typed_array'] = readBridgeStats();

      jsBridgeStatsReset();
      expect(factory.invoke(const []), isA<Uint8List>());
      cases['js_to_dart_typed_array'] = readBridgeStats();

      jsBridgeStatsReset();
      final jsonResult = runtime.evaluateJson(
        'Array.from({length: 10000}, (_, i) => i)',
      );
      expect(jsonResult, isA<List>());
      cases['evaluate_json_large_array'] = readBridgeStats();

      jsBridgeStatsReset();
      final source = jsAllocBuffer(size);
      final destination = jsAllocBuffer(size);
      try {
        jsMemcpy(destination, source, size);
        cases['native_memcpy'] = readBridgeStats();
      } finally {
        malloc.free(source);
        malloc.free(destination);
      }

      for (final entry in cases.entries) {
        // ignore: avoid_print
        print('BRIDGE_COUNTER_BENCH ${entry.key} ${jsonEncode(entry.value)}');
      }
      // ignore: avoid_print
      print('BRIDGE_COUNTER_BENCH_SUMMARY ${jsonEncode(cases)}');
    } finally {
      length.free();
      factory.free();
    }

    expect(cases, hasLength(4));
    expect(cases['dart_to_js_typed_array']!['copyBytes'], size);
    expect(cases['js_to_dart_typed_array']!['copyBytes'], size);
    expect(cases['native_memcpy']!['memcpyBytes'], size);
  });
}
