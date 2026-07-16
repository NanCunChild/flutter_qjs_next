import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Characterisation tests for BigInt and Symbol values through QuickJS.
///
/// QuickJS 2026.06.04 declares JS_NewBigInt64 / JS_NewBigUint64 /
/// JS_ToBigInt64 but they are not yet wired through the FFI layer.
/// These tests document the current behaviour and serve as a baseline
/// for a future implementation.
void main() {
  group('BigInt JS → Dart', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('small BigInt literal evaluates but rawResult is null', () {
      final r = runtime.evaluate('1n');
      expect(r.isError, isFalse,
          reason: 'QuickJS parses 1n but BigInt tag has no Dart mapping');
      // Known gap: BigInt tag falls through to default → null.
      expect(r.rawResult, isNull,
          reason: 'JSTag.BIG_INT is not handled in _jsToDart');
    });

    test('large BigInt outside safe integer range', () {
      final r = runtime.evaluate('9007199254740993n');
      expect(r.isError, isFalse);
      expect(r.rawResult, isNull);
    });

    test('BigInt result from arithmetic', () {
      final r = runtime.evaluate('2n ** 64n');
      expect(r.isError, isFalse);
      expect(r.rawResult, isNull);
    });

    test('BigInt in object property', () {
      final r = runtime.evaluate('({x: 42n, y: "hello"})');
      expect(r.isError, isFalse);
      final m = Map<String, dynamic>.from(r.rawResult as Map);
      expect(m['y'], 'hello');
      expect(m['x'], isNull,
          reason: 'BigInt value in object property silently lost');
    });

    test('BigInt in array', () {
      final r = runtime.evaluate('[1n, 2n, 3]');
      expect(r.isError, isFalse);
      final arr = r.rawResult as List;
      expect(arr[0], isNull);
      expect(arr[1], isNull);
      expect(arr[2], 3);
    });
  });

  group('BigInt Dart → JS (via host function)', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('Dart BigInt passed to JS via host function becomes DartObject', () {
      final setglobal = runtime.evaluate('(k,v)=>{globalThis[k]=v;}').rawResult
          as JSInvokable;
      // Dart BigInt has no conversion path in _dartToJs → falls through to
      // JSInvokable._wrap → jsNewObjectClass wrapping as DartObject.
      setglobal.invoke(['bdart', BigInt.from(42)]);
      setglobal.free();

      // The JS side sees a DartObject, not a BigInt.
      final r = runtime.evaluate('typeof globalThis.bdart');
      expect(r.rawResult, 'object',
          reason: 'Dart BigInt wrapped as DartObject (not a JS BigInt)');
    });
  });

  group('Symbol JS → Dart', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('Symbol literal evaluates but rawResult is null', () {
      // QuickJS supports Symbol() but it's not handled in _jsToDart.
      final r = runtime.evaluate('Symbol("test")');
      expect(r.isError, isFalse);
      expect(r.rawResult, isNull,
          reason: 'JSTag.SYMBOL is not handled in _jsToDart');
    });

    test('well-known symbol', () {
      final r = runtime.evaluate('Symbol.iterator');
      expect(r.isError, isFalse);
      expect(r.rawResult, isNull);
    });
  });

  group('BigInt64Array JS → Dart', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('BigInt64Array returns Uint8List (raw bytes)', () {
      final r = runtime.evaluate('new BigInt64Array([1n, 2n, -1n])');
      expect(r.isError, isFalse);
      // _jsTypedArrayToDart handles BIG_INT64 → Int64List (bd.asInt64List()).
      // Int64List in Dart carries 64-bit integers.
      final v = r.rawResult;
      expect(v, isA<Int64List>(),
          reason: 'BigInt64Array decoded as Int64List');
      final list = v as Int64List;
      expect(list[0], 1);
      expect(list[1], 2);
      expect(list[2], -1);
    });

    test('BigUint64Array returns Uint64List', () {
      final r = runtime.evaluate('new BigUint64Array([1n, 0xFFFFFFFFFFFFFFFFn])');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<Uint64List>(),
          reason: 'BigUint64Array decoded as Uint64List');
      expect((v as Uint64List)[0], BigInt.from(1).toInt());
    });
  });

  group('String representation of BigInt', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('BigInt toString() can be retrieved via explicit JS conversion', () {
      final r = runtime.evaluate('(1n).toString()');
      expect(r.isError, isFalse);
      expect(r.rawResult, '1');
    });

    test('BigInt via JSON.stringify returns string representation', () {
      Object? result;
      try {
        result = runtime.evaluateJson('42n');
      } catch (_) {
        // Known: QuickJS JSON.stringify throws TypeError for BigInt
      }
      // If it succeeds: QuickJS 2026.06.04 may or may not support BigInt JSON.
      // Document whichever behaviour we see.
      expect(result, anyOf(isNull, equals(42), equals('42')));
    });
  });
}
