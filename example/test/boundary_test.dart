import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_qjs_next/quickjs/quickjs_runtime2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Float16Array handling', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('Float16Array JS → Dart returns raw bytes', () {
      final r = runtime.evaluate('new Float16Array([1.0, 2.5, Infinity])');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<Uint8List>(),
          reason: 'FLOAT16 not in _jsTypedArrayToDart switch → default Uint8List');
      expect((v as Uint8List).length, 6);
    });

    test('Float16Array round-trip via identity host function', () {
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final r = runtime.evaluate(r'''
        (function() {
          const arr = new Float16Array([1.0, 2.5]);
          arr[0] = 3.0;
          return arr.length;
        })()
      ''');
      expect(r.rawResult, 2);
      id.free();
    });
  });

  group('DataView handling', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('DataView JS → Dart returns plain object (not a TypedArray)', () {
      final r = runtime.evaluate(r'''
        (function() {
          const buf = new ArrayBuffer(8);
          const view = new DataView(buf);
          view.setUint8(0, 42);
          view.setUint8(7, 99);
          return view;
        })()
      ''');
      expect(r.isError, isFalse);
      // DataView is not a TypedArray → jsGetTypedArrayData returns NULL,
      // and jsGetArrayBuffer may also fail. Falls through to property
      // enumeration → plain Dart Map.
      final v = r.rawResult;
      expect(v, isA<Map>(),
          reason: 'DataView falls through to property enumeration');
    });

    test('SharedArrayBuffer returns Uint8List', () {
      final r = runtime.evaluate(
        'new Uint8Array(new SharedArrayBuffer(4))',
      );
      expect(r.isError, isFalse);
      final v = r.rawResult;
      // _jsTypedArrayToDart should detect this as Uint8Array.
      expect(v, isA<Uint8List>(),
          reason: 'SharedArrayBuffer-backed Uint8Array should decode as Uint8List');
    });
  });

  group('Timeout / interrupt nesting', () {
    test('timeout during evaluateJson JSON.stringify on large object', () {
      final runtime = getJavascriptRuntime(timeout: 30, memoryLimit: 0);
      addTearDown(runtime.dispose);

      // Large nested structure that takes time to stringify.
      final r = runtime.evaluate(r'''
        (function() {
          var obj = {};
          var cur = obj;
          for (var i = 0; i < 20000; i++) {
            cur.nested = {};
            cur = cur.nested;
          }
          return obj;
        })()
      ''');
      // If engine times out during JSON.stringify, it throws; otherwise returns Map.
      // Either way, engine should not crash.
      expect(r.isError || r.rawResult is Map || r.rawResult == null, isTrue);
    });

    test('timeout during host function call inside evaluate', () {
      final runtime = getJavascriptRuntime(timeout: 500, memoryLimit: 0);
      addTearDown(runtime.dispose);

      final setter = runtime.evaluate('(k,v)=>{globalThis[k]=v;}').rawResult
          as JSInvokable;
      setter.invoke(['busy', () {
        var x = 0;
        for (var i = 0; i < 5000000; i++) x += i;
        return x;
      }]);
      setter.free();

      // Host function runs in Dart; timeout only tracks JS wall-clock.
      final r = runtime.evaluate('busy()');
      expect(r.isError, isFalse);
      // Large Dart int may become float64 in JS if > 2^53.
      expect(r.rawResult, isA<num>());
    });

    test('nested evaluate calls do not deadlock', () {
      final runtime = getJavascriptRuntime(timeout: 1000, memoryLimit: 0);
      addTearDown(runtime.dispose);

      // Suppress return of function value to avoid JSRef tracking.
      runtime.evaluate('''
        globalThis.nestedEval = function(expr) {
          return eval(expr);
        };
        undefined
      ''');

      final r = runtime.evaluate('globalThis.nestedEval("1+2")');
      expect(r.rawResult, 3);

      // Clean up so dispose doesn't report reference leak.
      runtime.evaluate('delete globalThis.nestedEval;');
    });

    test('zero timeout means no interrupt', () {
      final runtime = getJavascriptRuntime(timeout: 0, memoryLimit: 0);
      addTearDown(runtime.dispose);

      // A moderate loop should not be interrupted.
      final r = runtime.evaluate('(function(){var s=0;for(var i=0;i<10000;i++)s+=i;return s;})()');
      expect(r.rawResult, isA<int>());
    });
  });

  group('dispose race conditions', () {
    test('dispose while setTimeout callback is pending', () {
      final runtime = getJavascriptRuntime(timeout: 2000);
      runtime.evaluate('setTimeout(() => { globalThis.fired = 1; }, 50)');
      expect(() => runtime.dispose(), returnsNormally);
    });

    test('dispose during dispatch() loop', () async {
      final runtime = getJavascriptRuntime(timeout: 2000) as QuickJsRuntime2;
      final dispatchFuture = runtime.dispatch().catchError((_) {});
      runtime.evaluate('setTimeout(() => {}, 0)');
      await Future.delayed(const Duration(milliseconds: 30));
      runtime.dispose();
      await dispatchFuture;
    });

    test('dispose immediately after evaluate (no chance to drain jobs)', () {
      final runtime = getJavascriptRuntime(timeout: 2000) as QuickJsRuntime2;
      runtime.autoExecutePendingJobs = false;
      runtime.evaluate('Promise.resolve().then(() => {})');
      expect(() => runtime.dispose(), returnsNormally);
    });

    test('dispose after evaluateAsync', () {
      final runtime = getJavascriptRuntime(timeout: 2000);
      runtime.evaluateAsync('42');
      expect(() => runtime.dispose(), returnsNormally);
    });
  });

  group('JS Map and Set handling', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('JS Map returns as plain Dart Map via property enumeration', () {
      final r = runtime.evaluate('new Map([["a", 1], ["b", 2]])');
      expect(r.isError, isFalse);
      final m = r.rawResult;
      expect(m, isA<Map>());
    });

    test('JS Set returns as plain Dart Map', () {
      final r = runtime.evaluate('new Set([1, 2, 3])');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<Map>());
    });
  });

  group('NaN / Infinity float marshaling', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('NaN JS → Dart', () {
      final r = runtime.evaluate('NaN');
      expect(r.isError, isFalse);
      final v = r.rawResult;
      expect(v, isA<double>());
      expect((v as double).isNaN, isTrue);
    });

    test('Infinity JS → Dart', () {
      final r = runtime.evaluate('Infinity');
      final v = r.rawResult as double;
      expect(v, double.infinity);
    });

    test('-Infinity JS → Dart', () {
      final r = runtime.evaluate('-Infinity');
      final v = r.rawResult as double;
      expect(v, double.negativeInfinity);
    });

    test('NaN Dart → JS → Dart round-trip', () {
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final out = id.invoke([double.nan]);
      id.free();
      expect(out, isA<double>());
      expect((out as double).isNaN, isTrue);
    });

    test('Infinity Dart → JS → Dart round-trip', () {
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final out = id.invoke([double.infinity]);
      id.free();
      expect(out, double.infinity);
    });
  });

  group('Zero values', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime(timeout: 2000);
    });

    tearDown(() {
      runtime.dispose();
    });

    test('negative zero JS → Dart', () {
      final r = runtime.evaluate('-0.0');
      expect(r.rawResult, isA<double>());
    });

    test('0 Dart → JS → Dart round-trip', () {
      final id = runtime.evaluate('(x) => x').rawResult as JSInvokable;
      final out = id.invoke([0]);
      id.free();
      expect(out, 0);
    });
  });

  group('Module loading edge cases', () {
    test('missing module — engine survives', () {
      final runtime = QuickJsRuntime2(
        timeout: 2000,
        memoryLimit: 0,
        moduleHandler: (name) {
          throw Exception('Module not found: $name');
        },
      );
      addTearDown(runtime.dispose);

      final r = runtime.evaluate(
        'try { import("./nonexistent.js"); 0; } catch(e) { 1; }',
      );
      expect(r.rawResult, anyOf(0, 1),
          reason: 'Module load failure should be catchable or engine survives');
    });

    test('module handler returns valid JS', () {
      final runtime = QuickJsRuntime2(
        timeout: 2000,
        memoryLimit: 0,
        moduleHandler: (name) {
          return 'export const answer = 42;';
        },
      );
      addTearDown(runtime.dispose);

      final r = runtime.evaluate(r'''
        (async () => {
          const m = await import("./test.js");
          return m.answer;
        })()
      ''');
      expect(r.isPromise, isTrue);
      expect(r.isError, isFalse);
    });

    test('cyclic module imports', () {
      final sources = <String, String>{};
      sources['a.js'] = r'''
        import { b } from "./b.js";
        export const a = 1;
        export const sum = b + 1;
      ''';
      sources['b.js'] = r'''
        import { a } from "./a.js";
        export const b = 2;
        export const sum = a + 2;
      ''';

      final runtime = QuickJsRuntime2(
        timeout: 2000,
        memoryLimit: 0,
        moduleHandler: (name) {
          final base = name.split('/').last;
          return sources[base] ?? 'export const x = 0;';
        },
      );
      addTearDown(runtime.dispose);

      final r = runtime.evaluate(r'''
        (async () => {
          try {
            const m = await import("./a.js");
            return { a: m.a, sum: m.sum };
          } catch(e) { return { error: e.toString() }; }
        })()
      ''');
      expect(r.isPromise, isTrue);
      expect(r.isError, isFalse);
    });
  });

  group('Memory limit boundary', () {
    test('engine with tiny memory limit can still evaluate', () {
      final runtime = getJavascriptRuntime(
        timeout: 500,
        memoryLimit: 256 * 1024,
      );
      addTearDown(runtime.dispose);

      final r = runtime.evaluate('1 + 1');
      expect(r.rawResult, 2);
    });

    test('exceeding memory limit with large allocation', () {
      final runtime = getJavascriptRuntime(
        timeout: 1000,
        memoryLimit: 512 * 1024,
      );
      addTearDown(runtime.dispose);

      final r = runtime.evaluate(
        'new Uint8Array(2 * 1024 * 1024)',
      );
      expect(r.isError, isTrue,
          reason: 'Exceeding memory limit should cause error');
    });
  });
}
