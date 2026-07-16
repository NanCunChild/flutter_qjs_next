
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('evaluateJson – normal behaviour', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('plain number', () {
      expect(runtime.evaluateJson('42'), 42);
    });

    test('plain string', () {
      expect(runtime.evaluateJson('"hello"'), 'hello');
    });

    test('boolean', () {
      expect(runtime.evaluateJson('true'), true);
      expect(runtime.evaluateJson('false'), false);
    });

    test('null', () {
      expect(runtime.evaluateJson('null'), isNull);
    });

    test('flat array', () {
      final r = runtime.evaluateJson('[1, 2, 3]');
      expect(r, [1, 2, 3]);
    });

    test('flat object', () {
      final r = runtime.evaluateJson('({"a": 1, "b": "two"})');
      expect(r, {'a': 1, 'b': 'two'});
    });

    test('nested object and array', () {
      final r = runtime.evaluateJson('({"arr": [1, {"x": 2}], "str": "ok"})');
      expect(r, {'arr': [1, {'x': 2}], 'str': 'ok'});
    });
  });

  group('evaluateJson – non-JSON-serializable values', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('object containing a function — function property dropped', () {
      final r = runtime.evaluateJson('({a: 1, f: function(){ return 2; }})');
      // JSON.stringify drops functions → "f" absent.
      expect(r, isA<Map>());
      final m = r as Map;
      expect(m['a'], 1);
      expect(m.containsKey('f'), isFalse,
          reason: 'JSON.stringify omits function-valued properties');
    });

    test('array containing a function — function slots become null', () {
      final r = runtime.evaluateJson('[1, function(){ return 2; }, 3]');
      expect(r, isA<List>());
      final arr = r as List;
      expect(arr[0], 1);
      expect(arr[1], isNull,
          reason: 'JSON.stringify converts functions to null in arrays');
      expect(arr[2], 3);
    });

    test('undefined value in object', () {
      final r = runtime.evaluateJson('({a: undefined, b: 2})');
      final m = r as Map;
      expect(m['b'], 2);
      // QuickJS JSON.stringify drops undefined-valued properties.
      expect(m.containsKey('a'), isFalse,
          reason: 'undefined properties are dropped by JSON.stringify');
    });

    test('undefined in array becomes null', () {
      final r = runtime.evaluateJson('[1, undefined, 3]');
      final arr = r as List;
      expect(arr[0], 1);
      expect(arr[1], isNull,
          reason: 'undefined in arrays becomes null via JSON.stringify');
      expect(arr[2], 3);
    });

    test('BigInt value — TypeError from JSON.stringify', () {
      Object? caught;
      try {
        runtime.evaluateJson('42n');
      } catch (e) {
        caught = e;
      }
      // QuickJS JSON.stringify throws TypeError for BigInt.
      // evaluateJson propagates this as a JSError (which is not Exception).
      expect(caught, isNotNull,
          reason: 'JSON.stringify(42n) should throw TypeError');
    });

    test('circular reference — TypeError', () {
      Object? caught;
      try {
        runtime.evaluateJson('(()=>{ const o={}; o.self=o; return o; })()');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'JSON.stringify on circular structure throws TypeError');
    });

    test('NaN value', () {
      final r = runtime.evaluateJson('NaN');
      // JSON.stringify(NaN) → 'null'.
      expect(r, isNull);
    });

    test('Infinity value', () {
      final r = runtime.evaluateJson('Infinity');
      // JSON.stringify(Infinity) → 'null'.
      expect(r, isNull);
    });

    test('-Infinity value', () {
      final r = runtime.evaluateJson('-Infinity');
      expect(r, isNull);
    });
  });

  group('evaluateJson – error scenarios', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('syntax error throws', () {
      expect(
        () => runtime.evaluateJson('{invalid json syntax}}'),
        throwsA(anything),
      );
    });

    test('runtime error (undefined variable) throws', () {
      expect(
        () => runtime.evaluateJson('thisDoesNotExist + 1'),
        throwsA(anything),
      );
    });

    test('Promise is not resolved (returns empty object)', () {
      final r = runtime.evaluateJson('Promise.resolve(42)');
      // JSON.stringify on a Promise returns nothing useful.
      // QuickJS JSON.stringify on a Promise returns an empty object '{}'.
      expect(r, isA<Map>());
    });
  });
}
