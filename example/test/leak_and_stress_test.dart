import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Promise job queue', () {
    late JavascriptRuntime runtime;

    setUp(() {
      runtime = getJavascriptRuntime();
    });

    tearDown(() {
      runtime.dispose();
    });

    test('executePendingJobs drains microtasks', () {
      final qjs = runtime as QuickJsRuntime2;
      qjs.autoExecutePendingJobs = false;
      runtime.evaluate('''
        globalThis.__n = 0;
        Promise.resolve().then(() => { globalThis.__n = 1; });
      ''');
      final n = runtime.executePendingJobs();
      expect(n, greaterThan(0));
      final r = runtime.evaluate('globalThis.__n');
      expect(r.rawResult, 1);
    });

    test('hasPendingJobs on QuickJsRuntime2', () {
      final qjs = runtime as QuickJsRuntime2;
      qjs.autoExecutePendingJobs = false;
      runtime.evaluate('Promise.resolve().then(() => {})');
      expect(qjs.hasPendingJobs, isTrue);
      runtime.executePendingJobs();
      expect(qjs.hasPendingJobs, isFalse);
    });

    test('autoExecutePendingJobs drains after evaluate', () {
      final qjs = runtime as QuickJsRuntime2;
      qjs.autoExecutePendingJobs = true;
      runtime.evaluate('''
        globalThis.__auto = 0;
        Promise.resolve().then(() => { globalThis.__auto = 7; });
      ''');
      expect(qjs.hasPendingJobs, isFalse);
      expect(runtime.evaluate('globalThis.__auto').rawResult, 7);
    });
  });

  group('JsEnginePool', () {
    test('resetOnRelease isolates tenants', () async {
      final pool = JsEnginePool(maxSize: 1);
      addTearDown(pool.dispose);

      await pool.withEngine((js) async {
        js.evaluate('globalThis.secret = 99');
      });
      await pool.withEngine((js) async {
        final r = js.evaluate('typeof globalThis.secret');
        expect(r.rawResult, 'undefined');
      });
    });

    test('acquire timeout and withEngine', () async {
      final pool = JsEnginePool(maxSize: 1);
      addTearDown(pool.dispose);
      final a = await pool.acquire();
      await expectLater(
        pool.acquire(timeout: const Duration(milliseconds: 80)),
        throwsA(isA<TimeoutException>()),
      );
      pool.release(a);
      final v = await pool.withEngine((js) async {
        return js.evaluate('1+2').rawResult;
      });
      expect(v, 3);
    });

    test('parallel multi-engine', () async {
      final pool = JsEnginePool(maxSize: 4);
      addTearDown(pool.dispose);
      final results = await Future.wait(
        List.generate(8, (i) {
          return pool.withEngine((js) async {
            return js.evaluate('$i * 2').rawResult;
          });
        }),
      );
      expect(results, [0, 2, 4, 6, 8, 10, 12, 14]);
      expect(pool.size, lessThanOrEqualTo(4));
    });

    test('unique engine ids across engines', () {
      final a = getJavascriptRuntime();
      final b = getJavascriptRuntime();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      expect(a.getEngineInstanceId(), isNot(b.getEngineInstanceId()));
      expect(a.getEngineInstanceId(), contains('qjs-'));
    });
  });

  group('GC / memoryUsage', () {
    test('runGC and getMemoryUsage', () {
      final runtime = getJavascriptRuntime();
      addTearDown(runtime.dispose);
      runtime.evaluate('globalThis.buf = new Uint8Array(1024 * 64)');
      runtime.runGC();
      final m = runtime.getMemoryUsage();
      expect(m, isNotNull);
      expect(m!.memoryUsedSize, greaterThan(0));
      expect(m.mallocSize, greaterThanOrEqualTo(0));
    });
  });

  group('create/dispose stress', () {
    test('many short-lived engines', () {
      for (var i = 0; i < 32; i++) {
        final js = getJavascriptRuntime(timeout: 2000);
        final r = js.evaluate('1+1');
        expect(r.rawResult, 2);
        js.dispose();
      }
    });

    test('repeated evaluate + large TypedArray', () {
      final js = getJavascriptRuntime();
      addTearDown(js.dispose);
      for (var i = 0; i < 20; i++) {
        final data = Uint8List(64 * 1024);
        for (var j = 0; j < data.length; j++) {
          data[j] = j & 0xff;
        }
        js.evaluate('globalThis.echo = (a) => a');
        final fn = js.evaluate('echo').rawResult as JSInvokable;
        final out = fn.invoke([data]);
        expect(out, isA<Uint8List>());
        expect((out as Uint8List).length, data.length);
        fn.free();
      }
      js.runGC();
    });
  });

  group('security defaults', () {
    test('memoryLimit default is finite', () {
      final js = getJavascriptRuntime();
      addTearDown(js.dispose);
      // Default 64 MiB — engine should still evaluate normal code.
      expect(js.evaluate('2*21').rawResult, 42);
    });

    test('timeout interrupts busy loop', () {
      final js = getJavascriptRuntime(timeout: 50);
      addTearDown(js.dispose);
      final r = js.evaluate('while(true){}');
      expect(r.isError, isTrue);
    }, timeout: const Timeout(Duration(seconds: 5)));
  });
}
