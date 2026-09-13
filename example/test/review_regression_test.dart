// Regression tests for doc/review/2026-09-13-code-review.md (R1–R7).
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('R1 compile() frees QuickJS-owned bytecode buffer', () {
    test('repeated compile + evaluateBytecode does not crash or drift', () {
      final js = QuickJsRuntime2(timeout: 2000);
      addTearDown(js.dispose);

      final source = List.generate(
        300,
        (i) => 'function f$i(a) { return a + $i; }',
      ).join('\n');
      final bytecode = js.compile('$source\nf299(1);', 'r1.js');
      expect(js.evaluateBytecode(bytecode).rawResult, 300);

      js.runGC();
      final before = js.getMemoryUsage()!.mallocSize;
      for (var i = 0; i < 500; i++) {
        js.compile(source, 'r1.js');
      }
      js.runGC();
      final after = js.getMemoryUsage()!.mallocSize;
      // Leaked accounting would grow by ~bytecode size per compile.
      expect(after - before, lessThan(bytecode.length * 10));
    });
  });

  group('R2 Dart→JS shared references', () {
    late QuickJsRuntime2 js;

    setUp(() {
      js = QuickJsRuntime2(timeout: 2000);
    });

    tearDown(() {
      js.dispose();
    });

    test('same List / Map referenced several times keeps its value', () {
      final stringify =
          js.evaluate('(x) => JSON.stringify(x)').rawResult as JSInvokable;
      addTearDown(stringify.free);

      final a = [1, 2, 3];
      final m = {'v': a};
      final out = stringify.invoke([
        [
          a,
          {
            'k': [9, 8, a],
          },
          m,
          m,
          a,
        ],
      ]);
      expect(
        out,
        '[[1,2,3],{"k":[9,8,[1,2,3]]},{"v":[1,2,3]},{"v":[1,2,3]},[1,2,3]]',
      );
    });

    test('shared reference stays identical on the JS side', () {
      final same =
          js.evaluate('(x) => x[0] === x[1] && x[1] === x[2].k').rawResult
              as JSInvokable;
      addTearDown(same.free);

      final a = [1];
      expect(
        same.invoke([
          [
            a,
            a,
            {'k': a},
          ],
        ]),
        isTrue,
      );
    });

    test('cyclic List still converts to a cyclic JS array', () {
      final isCyclic =
          js.evaluate('(x) => x[1] === x && x[0] === 1').rawResult
              as JSInvokable;
      addTearDown(isCyclic.free);

      final a = <dynamic>[1];
      a.add(a);
      expect(isCyclic.invoke([a]), isTrue);
    });

    test('repeated shared conversions do not leak JS heap', () {
      final count =
          js.evaluate('(x) => x.length').rawResult as JSInvokable;
      addTearDown(count.free);

      final a = List.generate(20, (i) => {'i': i});
      final payload = [a, a, {'a': a}];
      count.invoke([payload]);
      js.runGC();
      final before = js.getMemoryUsage()!.objCount;
      for (var i = 0; i < 500; i++) {
        count.invoke([payload]);
      }
      js.runGC();
      expect(js.getMemoryUsage()!.objCount, before);
    });
  });

  group('R3 softReset isolates tenants', () {
    late QuickJsRuntime2 js;

    setUp(() {
      js = QuickJsRuntime2(timeout: 2000);
    });

    tearDown(() {
      js.dispose();
    });

    const globalNames = 'Object.getOwnPropertyNames(globalThis).sort().join()';

    test('global var / let / const / function / class are dropped', () {
      final r = js.evaluate('''
        var secretVar = 1;
        let secretLet = 2;
        const secretConst = 3;
        function secretFn() {}
        class SecretClass {}
        globalThis.secretProp = 4;
        0
      ''');
      expect(r.isError, isFalse, reason: r.stringResult);

      js.softReset();

      for (final name in [
        'secretVar',
        'secretLet',
        'secretConst',
        'secretFn',
        'SecretClass',
        'secretProp',
      ]) {
        expect(js.evaluate('typeof $name').rawResult, 'undefined',
            reason: name);
      }
      final redeclare = js.evaluate('let secretLet = 5; secretLet');
      expect(redeclare.isError, isFalse, reason: redeclare.stringResult);
      expect(redeclare.rawResult, 5);
    });

    test('builtins survive and prototype pollution is dropped', () {
      final fresh = js.evaluate(globalNames).rawResult;
      js.evaluate('Array.prototype.evil = 1; JSON.stringify = null;');

      js.softReset();

      expect(js.evaluate(globalNames).rawResult, fresh);
      expect(js.evaluate('[].evil').rawResult, isNull);
      expect(js.evaluate('JSON.stringify([1])').rawResult, '[1]');
    });

    test('keeps instance id; channels and console work after reset', () {
      final id = js.getEngineInstanceId();
      js.onMessage('tenantA', (_) {});

      js.softReset();

      expect(js.getEngineInstanceId(), id);
      expect(
        JavascriptRuntime.channelFunctionsRegistered[id]?.containsKey(
          'tenantA',
        ),
        isFalse,
      );
      dynamic received;
      js.onMessage('tenantB', (args) => received = args);
      final r = js.evaluate('console.log("x"); sendMessage("tenantB", "{\\"a\\":1}")');
      expect(r.isError, isFalse, reason: r.stringResult);
      expect(received, {'a': 1});
    });

    test('Dart functions from the old tenant are released', () {
      final set = js.evaluate('(k, v) => { globalThis[k] = v; }').rawResult
          as JSInvokable;
      set.invoke(['hostFn', (int a) => a + 1]);
      set.free();
      expect(js.evaluate('hostFn(1)').rawResult, 2);

      js.softReset();

      expect(js.evaluate('typeof hostFn').rawResult, 'undefined');
    });

    test('repeated softReset keeps JS heap flat', () {
      js.softReset();
      js.runGC();
      final first = js.getMemoryUsage()!.objCount;
      for (var i = 0; i < 200; i++) {
        js.evaluate('var t$i = { data: new Array(100).fill($i) }; let l = t$i;');
        js.softReset();
      }
      js.runGC();
      expect(js.getMemoryUsage()!.objCount, lessThanOrEqualTo(first + 10));
    });
  });

  group('R4 timeout covers JS run during result conversion', () {
    late QuickJsRuntime2 js;

    setUp(() {
      js = QuickJsRuntime2(timeout: 200);
    });

    tearDown(() {
      js.dispose();
    });

    // Bounded busy loop so a regression fails instead of hanging.
    const busy = 'var t = Date.now(); while (Date.now() - t < 1500) {}';

    void expectInterrupted(JsEvalResult r, Stopwatch sw) {
      expect(r.isError, isTrue, reason: r.stringResult);
      expect(r.stringResult, contains('interrupted'));
      expect(sw.elapsedMilliseconds, lessThan(1000));
    }

    test('object getter', () {
      final sw = Stopwatch()..start();
      final r = js.evaluate('({ a: 1, get x() { $busy return 1; } })');
      expectInterrupted(r, sw);
    });

    test('nested array element getter', () {
      final sw = Stopwatch()..start();
      final r = js.evaluate('''
        ({ list: [1, Object.defineProperty({}, 'y', {
          enumerable: true,
          get() { $busy return 2; },
        })] })
      ''');
      expectInterrupted(r, sw);
    });

    test('Proxy ownKeys trap', () {
      final sw = Stopwatch()..start();
      final r = js.evaluate(
        'new Proxy({}, { ownKeys() { $busy return []; } })',
      );
      expectInterrupted(r, sw);
    });

    test('JSInvokable.invoke result conversion throws', () {
      final fn = js.evaluate('() => ({ get x() { $busy return 1; } })')
          .rawResult as JSInvokable;
      addTearDown(fn.free);
      final sw = Stopwatch()..start();
      expect(() => fn.invoke([]), throwsA(isA<JSError>()));
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('throwing getter is reported instead of becoming null', () {
      final r = js.evaluate(
        '({ a: { b: [{ get c() { throw new Error("getter boom"); } }] } })',
      );
      expect(r.isError, isTrue);
      expect(r.stringResult, contains('getter boom'));
    });

    test('engine stays usable and plain conversions are unaffected', () {
      js.evaluate('({ get x() { $busy return 1; } })');
      final r = js.evaluate(
        '({ a: [1, 2, { b: "c" }], get d() { return 4; } })',
      );
      expect(r.isError, isFalse, reason: r.stringResult);
      expect(r.rawResult, {
        'a': [
          1,
          2,
          {'b': 'c'},
        ],
        'd': 4,
      });
    });
  });

  group('R5 strings with embedded NUL', () {
    late QuickJsRuntime2 js;

    setUp(() {
      js = QuickJsRuntime2(timeout: 2000);
    });

    tearDown(() {
      js.dispose();
    });

    test('JS → Dart keeps every code unit', () {
      final r = js.evaluate(
        'var z = String.fromCharCode(0); "a" + z + "b" + z',
      );
      expect(r.rawResult, 'a\u0000b\u0000');
      expect((r.rawResult as String).length, 4);
    });

    test('Dart → JS keeps every code unit', () {
      final len = js.evaluate('(s) => s.length').rawResult as JSInvokable;
      addTearDown(len.free);
      expect(len.invoke(['a\u0000b']), 3);
      expect(len.invoke(['']), 0);
    });

    test('round trip of values, keys and unicode', () {
      final id = js.evaluate('(x) => x').rawResult as JSInvokable;
      addTearDown(id.free);
      const s = 'x\u0000y😀中\u0000';
      expect(id.invoke([s]), s);
      expect(id.invoke([
        {'k\u0000ey': s, 'plain': ''},
      ]), {'k\u0000ey': s, 'plain': ''});
    });
  });

  group('R6 throwing host function releases JSRef arguments', () {
    late QuickJsRuntime2 js;

    setUp(() {
      js = QuickJsRuntime2(timeout: 2000);
      final set = js.evaluate('(k, v) => { globalThis[k] = v; }').rawResult
          as JSInvokable;
      set.invoke(['bad', (dynamic arg) => throw StateError('host boom')]);
      set.invoke([
        'badThis',
        (dynamic arg, {dynamic thisVal}) => throw StateError('host boom'),
      ]);
      set.invoke(['good', (dynamic arg) => 'ok']);
      set.free();
    });

    tearDown(() {
      js.dispose();
    });

    test('function / object arguments do not accumulate refs', () {
      final before = js.debugReferenceCount;
      final r = js.evaluate('''
        var caught = 0;
        for (let i = 0; i < 1000; i++) {
          try { bad(function () { return i; }); } catch (e) { caught++; }
          try { badThis.call(function () {}, [function () {}]); }
          catch (e) { caught++; }
        }
        caught
      ''');
      expect(r.rawResult, 2000, reason: r.stringResult);
      expect(js.debugReferenceCount, before);
    });

    test('host error still reaches JS and good calls are unaffected', () {
      final r = js.evaluate('''
        var msg;
        try { bad(function () {}); } catch (e) { msg = String(e.message); }
        [msg, good(function () {})]
      ''');
      expect(r.rawResult, [contains('host boom'), 'ok']);
      final before = js.debugReferenceCount;
      js.evaluate('for (let i = 0; i < 100; i++) good(function () {});');
      expect(js.debugReferenceCount, before);
    });
  });

  group('R7 DartObject class id is allocated once per process', () {
    test('fresh engine size does not grow with engines created before', () {
      final js = QuickJsRuntime2(timeout: 2000);
      addTearDown(js.dispose);

      js.runGC();
      final first = js.getMemoryUsage()!.mallocSize;
      for (var i = 0; i < 3000; i++) {
        js.reinitialize();
      }
      js.runGC();
      final last = js.getMemoryUsage()!.mallocSize;
      // Per-engine class ids grew class_array by ~55 bytes per engine
      // (~165KB after 3000 engines).
      expect(last - first, lessThan(16 * 1024));

      final set = js.evaluate('(k, v) => { globalThis[k] = v; }').rawResult
          as JSInvokable;
      set.invoke(['inc', (int a) => a + 1]);
      set.free();
      expect(js.evaluate('inc(41)').rawResult, 42);
    });

    test('separate engines and soft resets share the class id', () {
      final engines = List.generate(
        50,
        (_) => QuickJsRuntime2(timeout: 2000),
      );
      final js = QuickJsRuntime2(timeout: 2000);
      addTearDown(js.dispose);
      for (final e in engines) {
        e.dispose();
      }
      js.runGC();
      // Compare live bytes: mallocSize also counts free arenas the QuickJS
      // allocator keeps around, which fluctuates across context churn.
      final first = js.getMemoryUsage()!;
      for (var i = 0; i < 500; i++) {
        js.softReset();
      }
      js.runGC();
      final last = js.getMemoryUsage()!;
      expect(last.memoryUsedSize - first.memoryUsedSize, lessThan(1024));
      expect(last.objCount, first.objCount);
      expect(
        js.evaluate('typeof sendMessage === "function"').rawResult,
        isTrue,
      );
    });
  });
}
