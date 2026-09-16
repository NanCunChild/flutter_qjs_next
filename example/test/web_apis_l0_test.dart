// Web APIs L0 (doc/design/2026-09-13-web-apis.md): timers, microtasks,
// console, structuredClone, base64, DOMException, performance, crypto.
// Expected strings were cross-checked against Node.js 24.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late QuickJsRuntime2 js;
  final logs = <(FlutterQjsLogLevel, String)>[];

  setUp(() {
    logs.clear();
    FlutterQjsLogger.level = FlutterQjsLogLevel.debug;
    FlutterQjsLogger.handler = (level, message, error) {
      logs.add((level, message));
    };
    js = QuickJsRuntime2(timeout: 2000);
  });

  tearDown(() {
    js.dispose();
    FlutterQjsLogger.handler = null;
    FlutterQjsLogger.level = FlutterQjsLogLevel.info;
  });

  dynamic eval(String code) {
    final result = js.evaluate(code);
    if (result.isError) fail(result.stringResult);
    return result.rawResult;
  }

  Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

  List<String> messages() => logs.map((l) => l.$2).toList();

  test('globals are installed without enumerable or internal names', () {
    expect(
      eval(r'''
        [setTimeout, setInterval, clearTimeout, clearInterval, queueMicrotask,
         reportError, structuredClone, atob, btoa, DOMException, Performance, Crypto]
          .every((f) => typeof f === 'function') &&
        typeof console.log === 'function' &&
        typeof performance.now === 'function' &&
        typeof crypto.getRandomValues === 'function'
      '''),
      true,
    );
    expect(
      eval(r'''Object.keys(globalThis).filter((k) =>
        ['console', 'setTimeout', 'performance', 'crypto', 'structuredClone'].includes(k) ||
        k.startsWith('__NATIVE_FLUTTER_JS__'))'''),
      isEmpty,
    );
  });

  group('timers', () {
    test('setTimeout passes arguments and orders by delay', () async {
      eval(r'''
        globalThis.out = [];
        setTimeout((a, b) => out.push(a + b), 20, 1, 2);
        setTimeout(() => out.push('first'), 0);
      ''');
      await wait(60);
      expect(eval('out'), ['first', 3]);
    });

    test('clearTimeout cancels', () async {
      eval(r'''
        globalThis.hit = 0;
        clearTimeout(setTimeout(() => hit++, 10));
        clearTimeout(undefined);
      ''');
      await wait(40);
      expect(eval('hit'), 0);
    });

    test('setInterval repeats until cleared from its own callback', () async {
      eval(r'''
        globalThis.n = 0;
        globalThis.iv = setInterval(() => { if (++n === 3) clearInterval(iv); }, 5);
      ''');
      await wait(120);
      expect(eval('n'), 3);
    });

    test('microtasks queued by a timer run without a manual pump', () async {
      eval(r'''
        globalThis.done = 0;
        setTimeout(() => { Promise.resolve().then(() => { done = 1; }); }, 5);
      ''');
      await wait(40);
      // Read happens before evaluate drains its own jobs.
      expect(eval('done'), 1);
    });

    test('callback errors are reported and later timers still run', () async {
      eval(r'''
        setTimeout(() => { throw new TypeError('boom'); }, 0);
        setTimeout(() => { globalThis.after = true; }, 5);
      ''');
      await wait(40);
      expect(eval('after'), true);
      expect(
        logs.any(
          (l) =>
              l.$1 == FlutterQjsLogLevel.error &&
              l.$2.startsWith('Uncaught TypeError: boom'),
        ),
        isTrue,
      );
    });

    test('string handlers and invalid delays', () async {
      eval(r'''
        globalThis.s = 0;
        setTimeout('s += 1', -5);
        setTimeout(() => { s += 10; }, NaN);
      ''');
      await wait(30);
      expect(eval('s'), 11);
    });

    test('softReset cancels pending intervals', () async {
      eval('setInterval(() => console.log("tick"), 5)');
      await wait(30);
      js.softReset();
      final ticks = messages().where((m) => m == 'tick').length;
      expect(ticks, greaterThan(0));
      await wait(40);
      expect(messages().where((m) => m == 'tick').length, ticks);
    });

    test('autoExecutePendingJobs=false leaves microtasks to the caller', () async {
      final manual = QuickJsRuntime2(autoExecutePendingJobs: false);
      addTearDown(manual.dispose);
      manual.evaluate(r'''
        globalThis.done = 0;
        setTimeout(() => Promise.resolve().then(() => { done = 1; }), 0);
      ''');
      await wait(30);
      expect(manual.evaluate('done').rawResult, 0);
      manual.executePendingJobs();
      expect(manual.evaluate('done').rawResult, 1);
    });
  });

  test('queueMicrotask runs in FIFO order with promise jobs', () {
    expect(
      eval(r'''
        const log = [];
        queueMicrotask(() => log.push('micro'));
        Promise.resolve().then(() => log.push('promise'));
        queueMicrotask(() => { throw new Error('micro boom'); });
        log.push('sync');
        log
      '''),
      ['sync'],
    );
    expect(eval('log'), ['sync', 'micro', 'promise']);
    expect(messages(), contains(startsWith('Uncaught Error: micro boom')));
    expect(js.evaluate('queueMicrotask(1)').isError, isTrue);
  });

  group('console', () {
    test('formats like util.format / util.inspect', () {
      eval(r'''
        console.log('a %s b %d c %i %f %%', 'x', 42.5, 42.9, '1.5', 'rest');
        console.log({ k: [1, 2n, 'str'], nested: { deep: { deeper: { deepest: 1 } } } });
        console.log(new Map([['a', 1]]), new Set([1]), new Uint8Array([1, 2]), undefined, null, Symbol('s'), -0);
        console.log(function named() {}, class Klass {}, () => {});
        const cyc = { name: 'c' }; cyc.self = cyc;
        console.log(cyc);
        console.log({ get a() { throw 1; } });
      ''');
      expect(messages(), [
        'a x b 42.5 c 42 1.5 % rest',
        "{ k: [ 1, 2n, 'str' ], nested: { deep: { deeper: [Object] } } }",
        "Map(1) { 'a' => 1 } Set(1) { 1 } Uint8Array(2) [ 1, 2 ] undefined null Symbol(s) -0",
        '[Function: named] [class Klass] [Function (anonymous)]',
        "{ name: 'c', self: [Circular] }",
        '{ a: [Getter] }',
      ]);
    });

    test('levels, errors, groups, counters and timers', () {
      eval(r'''
        console.warn('w'); console.error('e'); console.debug('d'); console.info('i');
        console.error(new RangeError('bad'));
        console.group('G'); console.log('inner'); console.groupEnd(); console.log('outer');
        console.count(); console.count(); console.count('x'); console.countReset(); console.count();
        console.assert(1 === 2, 'nope %s', 'x'); console.assert(true, 'ignored');
        console.time('t'); console.timeEnd('t');
      ''');
      expect(logs.take(4).map((l) => l.$1), [
        FlutterQjsLogLevel.warning,
        FlutterQjsLogLevel.error,
        FlutterQjsLogLevel.debug,
        FlutterQjsLogLevel.info,
      ]);
      final m = messages();
      expect(m[4], startsWith('RangeError: bad'));
      expect(m.sublist(5, 13), [
        'G',
        '  inner',
        'outer',
        'default: 1',
        'default: 2',
        'x: 1',
        'default: 1',
        'Assertion failed: nope x',
      ]);
      expect(m[13], matches(RegExp(r'^t: \d+(\.\d+)?ms$')));
    });
  });

  group('structuredClone', () {
    test('clones built-in types, cycles and shared references', () {
      expect(
        eval(r'''
          const src = {
            date: new Date(5), re: /a+/gi, map: new Map([[1, { x: 1 }]]), set: new Set(['s']),
            ta: new Uint16Array([1, 2, 3]), big: 10n, boxed: Object('str'),
            err: new RangeError('r'), arr: [1, , 3], dom: new DOMException('m', 'AbortError'),
          };
          src.self = src;
          src.view = new DataView(src.ta.buffer, 2, 2);
          const c = structuredClone(src);
          [c !== src, c.self === c, c.date.getTime() === 5, c.re.source === 'a+' && c.re.flags === 'gi',
           c.map.get(1).x === 1 && c.map.get(1) !== src.map.get(1), c.set.has('s'),
           c.ta instanceof Uint16Array && c.ta[2] === 3 && c.ta.buffer !== src.ta.buffer,
           c.view.buffer === c.ta.buffer, c.big === 10n, c.boxed instanceof String && c.boxed.valueOf() === 'str',
           c.err instanceof RangeError && c.err.message === 'r', !(1 in c.arr) && c.arr.length === 3,
           c.dom instanceof DOMException && c.dom.name === 'AbortError']
        '''),
        everyElement(true),
      );
    });

    test('rejects functions and transfers buffers', () {
      expect(
        eval(r'''
          let name;
          try { structuredClone({ f() {} }); } catch (e) { name = e.name + ':' + (e instanceof DOMException); }
          const buf = new ArrayBuffer(4);
          new Uint8Array(buf)[0] = 7;
          const out = structuredClone({ buf }, { transfer: [buf] });
          [name, buf.byteLength, buf.detached, new Uint8Array(out.buf)[0]]
        '''),
        ['DataCloneError:true', 0, true, 7],
      );
    });
  });

  test('atob / btoa follow forgiving-base64', () {
    expect(
      eval(r'''[btoa('hello'), btoa(''), btoa('\xff\xfe'), atob(' aGVs bG8= '), atob('aGVsbG8'), atob('YQ'), atob('')]'''),
      ['aGVsbG8=', '', '//4=', 'hello', 'hello', 'a', ''],
    );
    expect(
      eval(r'''[() => btoa('€'), () => atob('a'), () => atob('ab=c'), () => atob('aGVsbG8===')]
        .map((f) => { try { f(); return 'ok'; } catch (e) { return e.name; } })'''),
      List.filled(4, 'InvalidCharacterError'),
    );
  });

  test('DOMException', () {
    expect(
      eval(r'''
        const e = new DOMException('gone', 'AbortError');
        const d = new DOMException();
        const c = new DOMException('m', { name: 'DataCloneError', cause: 1 });
        [e.name, e.message, e.code, e instanceof Error, String(e), d.name, d.message, d.code,
         DOMException.ABORT_ERR, c.name, c.cause, Object.prototype.toString.call(e)]
      '''),
      [
        'AbortError',
        'gone',
        20,
        true,
        'AbortError: gone',
        'Error',
        '',
        0,
        20,
        'DataCloneError',
        1,
        '[object DOMException]',
      ],
    );
    final thrown = js.evaluate('throw new DOMException("x", "TimeoutError")');
    expect(thrown.isError, isTrue);
    expect(thrown.stringResult, startsWith('TimeoutError: x'));
  });

  test('performance clock', () async {
    final a = eval('performance.now()') as num;
    await wait(15);
    final b = eval('performance.now()') as num;
    expect(b - a, greaterThanOrEqualTo(10));
    expect(
      eval('Math.abs(performance.timeOrigin + performance.now() - Date.now()) < 50'),
      true,
    );
    expect(eval('typeof performance.toJSON().timeOrigin'), 'number');
    expect(js.evaluate('new Performance()').isError, isTrue);
  });

  test('crypto random values', () {
    expect(
      eval(r'''
        const a = crypto.getRandomValues(new Uint8Array(64));
        const b = crypto.getRandomValues(new BigUint64Array(4));
        // WebIDL: a non-ArrayBufferView argument is a TypeError (Node reports TypeMismatchError).
        const errors = [() => crypto.getRandomValues(new Float64Array(1)),
          () => crypto.getRandomValues(new Uint8Array(65537)), () => crypto.getRandomValues({})]
          .map((f) => { try { f(); return 'ok'; } catch (e) { return e.name; } });
        const ids = new Set(Array.from({ length: 100 }, () => crypto.randomUUID()));
        [a.some((x) => x !== 0), b.some((x) => x !== 0n), errors, ids.size,
         [...ids].every((id) => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id))]
      '''),
      [
        true,
        true,
        ['TypeMismatchError', 'QuotaExceededError', 'TypeError'],
        100,
        true,
      ],
    );
  });

  test('softReset / reinitialize reinstall without reference growth', () {
    eval('setTimeout(() => {}, 10000); setInterval(() => {}, 10000)');
    js.softReset();
    final baseline = js.debugReferenceCount;
    for (var i = 0; i < 50; i++) {
      eval('setTimeout(() => {}, 10000); console.log(structuredClone({ a: 1 }).a)');
      js.softReset();
    }
    expect(js.debugReferenceCount, baseline);
    for (var i = 0; i < 20; i++) {
      js.reinitialize();
    }
    expect(eval('typeof setTimeout + typeof crypto.randomUUID()'), 'functionstring');
  });
}
