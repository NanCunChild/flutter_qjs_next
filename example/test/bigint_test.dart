import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BigInt JS → Dart', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 1000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('small BigInt literal evaluates to Dart BigInt', () {
      final r = runtime.evaluate('1n');
      expect(r.isError, isFalse);
      expect(r.rawResult, BigInt.from(1));
    });

    test('negative BigInt', () {
      final r = runtime.evaluate('-42n');
      expect(r.isError, isFalse);
      expect(r.rawResult, BigInt.from(-42));
    });

    test('large BigInt outside safe integer range', () {
      final r = runtime.evaluate('9007199254740993n');
      expect(r.isError, isFalse);
      expect(r.rawResult, BigInt.parse('9007199254740993'));
    });

    test('BigInt result from arithmetic', () {
      final r = runtime.evaluate('2n ** 64n');
      expect(r.isError, isFalse);
      expect(r.rawResult, BigInt.from(2).pow(64));
    });

    test('BigInt in object property is preserved', () {
      final r = runtime.evaluate('({x: 42n, y: "hello"})');
      expect(r.isError, isFalse);
      final m = Map<String, dynamic>.from(r.rawResult as Map);
      expect(m['y'], 'hello');
      expect(m['x'], BigInt.from(42));
    });

    test('BigInt in array is preserved', () {
      final r = runtime.evaluate('[1n, 2n, 3]');
      expect(r.isError, isFalse);
      final arr = r.rawResult as List;
      expect(arr[0], BigInt.from(1));
      expect(arr[1], BigInt.from(2));
      expect(arr[2], 3);
    });

    test('nested BigInt in complex object', () {
      final r = runtime.evaluate('({a: [1n, {b: -5n}], c: 7n})');
      expect(r.isError, isFalse);
      final m = Map<String, dynamic>.from(r.rawResult as Map);
      expect(m['c'], BigInt.from(7));
      final arr = m['a'] as List;
      expect(arr[0], BigInt.from(1));
      final inner = Map<String, dynamic>.from(arr[1] as Map);
      expect(inner['b'], BigInt.from(-5));
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

    test('Dart BigInt round-trips correctly through JS', () {
      final id = runtime.evaluate('(x) => typeof x === "bigint" ? x : null')
          .rawResult as JSInvokable;
      final out = id.invoke([BigInt.from(42)]);
      id.free();
      expect(out, BigInt.from(42));
    });

    test('Dart BigInt in array round-trips', () {
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final out = id.invoke([
        [BigInt.from(1), BigInt.from(2), 3],
      ]);
      id.free();
      expect(out, isA<List>());
      final list = out as List;
      expect(list[0], BigInt.from(1));
      expect(list[1], BigInt.from(2));
      expect(list[2], 3);
    });

    test('Dart BigInt set on globalThis then read back', () {
      final setglobal = runtime.evaluate('(k,v)=>{globalThis[k]=v;}').rawResult
          as JSInvokable;
      setglobal.invoke(['bdart', BigInt.from(99)]);
      setglobal.free();

      final r = runtime.evaluate('globalThis.bdart');
      expect(r.rawResult, BigInt.from(99));

      runtime.evaluate('delete globalThis.bdart;');
    });

    test('large Dart BigInt (> 2^63) round-trips', () {
      final large = BigInt.parse('123456789012345678901234567890');
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final out = id.invoke([large]);
      id.free();
      expect(out, large);
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

    test('BigInt64Array returns Int64List', () {
      final r = runtime.evaluate('new BigInt64Array([1n, 2n, -1n])');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<Int64List>());
      final list = v as Int64List;
      expect(list[0], 1);
      expect(list[1], 2);
      expect(list[2], -1);
    });

    test('BigUint64Array returns Uint64List', () {
      final r = runtime.evaluate('new BigUint64Array([1n, 0xFFFFFFFFFFFFFFFFn])');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<Uint64List>());
    });
  });
}
