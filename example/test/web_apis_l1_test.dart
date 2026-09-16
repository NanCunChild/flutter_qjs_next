// Web APIs L1 (doc/design/2026-09-13-web-apis.md).
// Expected values were cross-checked against Node.js 24.
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
    js = QuickJsRuntime2(timeout: 5000, webApis: const JsWebApis.standard());
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

  group('events', () {
    test('Event fields and propagation flags', () {
      expect(
        eval(r'''
          const plain = new Event('x');
          const full = new Event('y', { bubbles: true, cancelable: true, composed: true });
          full.preventDefault();
          plain.preventDefault();
          const custom = new CustomEvent('c', { detail: { a: 1 } });
          [plain.type, plain.bubbles, plain.cancelable, plain.defaultPrevented, plain.isTrusted,
           plain.eventPhase, plain.target, typeof plain.timeStamp,
           full.defaultPrevented, full.composed, custom.detail.a, custom instanceof Event,
           Object.prototype.toString.call(plain)]
        '''),
        ['x', false, false, false, false, 0, null, 'number', true, true, 1, true, '[object Event]'],
      );
    });

    test('dispatch order, once, capture and removal', () {
      expect(
        eval(r'''
          const target = new EventTarget();
          const seen = [];
          const a = (e) => seen.push('a:' + e.type + ':' + (e.target === target) + ':' + e.eventPhase);
          target.addEventListener('t', a);
          target.addEventListener('t', a); // duplicate ignored
          target.addEventListener('t', { handleEvent: () => seen.push('obj') });
          target.addEventListener('t', () => seen.push('once'), { once: true });
          target.dispatchEvent(new Event('t'));
          target.dispatchEvent(new Event('t'));
          target.removeEventListener('t', a);
          target.dispatchEvent(new Event('t'));
          seen
        '''),
        [
          'a:t:true:2',
          'obj',
          'once',
          'a:t:true:2',
          'obj',
          'obj',
        ],
      );
    });

    test('stopImmediatePropagation, preventDefault result and listener errors', () {
      expect(
        eval(r'''
          const target = new EventTarget();
          const seen = [];
          target.addEventListener('a', (e) => { seen.push(1); e.stopImmediatePropagation(); });
          target.addEventListener('a', () => seen.push(2));
          target.dispatchEvent(new Event('a'));
          target.addEventListener('b', (e) => e.preventDefault());
          const notCancelable = target.dispatchEvent(new Event('b'));
          const cancelable = target.dispatchEvent(new Event('b', { cancelable: true }));
          target.addEventListener('c', () => { throw new Error('listener boom'); });
          target.addEventListener('c', () => seen.push(3));
          target.dispatchEvent(new Event('c'));
          [seen, notCancelable, cancelable]
        '''),
        [
          [1, 3],
          true,
          false,
        ],
      );
      expect(
        logs.map((l) => l.$2),
        contains(startsWith('Uncaught Error: listener boom')),
      );
    });

    test('AbortController and AbortSignal', () async {
      expect(
        eval(r'''
          const controller = new AbortController();
          const seen = [];
          controller.signal.addEventListener('abort', (e) => seen.push('listener:' + e.isTrusted));
          controller.signal.onabort = () => seen.push('onabort');
          controller.abort();
          controller.abort('ignored');
          const reason = controller.signal.reason;
          let thrown;
          try { controller.signal.throwIfAborted(); } catch (e) { thrown = e === reason; }
          const custom = new AbortController();
          custom.abort('why');
          const already = AbortSignal.abort();
          const target = new EventTarget();
          const removal = new AbortController();
          target.addEventListener('t', () => seen.push('should not fire'), { signal: removal.signal });
          removal.abort();
          target.dispatchEvent(new Event('t'));
          [seen, reason.name, reason instanceof DOMException, thrown, custom.signal.reason,
           already.aborted, controller.signal.aborted]
        '''),
        [
          ['listener:true', 'onabort'],
          'AbortError',
          true,
          true,
          'why',
          true,
          true,
        ],
      );
    });

    test('AbortSignal.timeout and AbortSignal.any', () async {
      eval(r'''
        globalThis.out = [];
        const timeout = AbortSignal.timeout(20);
        timeout.addEventListener('abort', () => out.push('timeout:' + timeout.reason.name));
        const controller = new AbortController();
        const any = AbortSignal.any([controller.signal, timeout]);
        any.addEventListener('abort', () => out.push('any:' + any.reason.name));
      ''');
      await wait(80);
      expect(eval('out'), ['timeout:TimeoutError', 'any:TimeoutError']);
    });

    test('events are not structured-cloneable', () {
      expect(
        eval(r'''
          [new Event('x'), new EventTarget(), new AbortController().signal].map((v) => {
            try { structuredClone(v); return 'cloned'; } catch (e) { return e.name; }
          })
        '''),
        List.filled(3, 'DataCloneError'),
      );
    });
  });

  group('encoding', () {
    test('TextEncoder encode and encodeInto', () {
      expect(
        eval(r'''
          const te = new TextEncoder();
          const exact = new Uint8Array(4);
          const exactResult = te.encodeInto('a€', exact);
          const partial = new Uint8Array(2);
          const partialResult = te.encodeInto('€x', partial);
          const pair = new Uint8Array(4);
          const pairResult = te.encodeInto('𝄞', pair);
          [te.encoding, [...te.encode('abc')], [...te.encode('a€𝄞')],
           [...te.encode('a\ud800b')], [...te.encode()],
           [exactResult.read, exactResult.written, [...exact]],
           [partialResult.read, partialResult.written, [...partial]],
           [pairResult.read, pairResult.written]]
        '''),
        [
          'utf-8',
          [97, 98, 99],
          [97, 226, 130, 172, 240, 157, 132, 158],
          [97, 239, 191, 189, 98],
          <int>[],
          [
            2,
            4,
            [97, 226, 130, 172],
          ],
          [
            0,
            0,
            [0, 0],
          ],
          [2, 4],
        ],
      );
    });

    test('TextDecoder BOM, replacement and fatal mode', () {
      expect(
        eval(r'''
          const decode = (bytes, opts, decOpts) =>
            new TextDecoder('utf-8', opts).decode(new Uint8Array(bytes), decOpts);
          let fatal;
          try {
            decode([0x61, 0xff], { fatal: true });
            fatal = 'no throw';
          } catch (e) { fatal = e.constructor.name; }
          [decode([0xef, 0xbb, 0xbf, 0x61]), decode([0xef, 0xbb, 0xbf, 0x61], { ignoreBOM: true }),
           decode([0x61, 0xff, 0x62, 0xe0, 0x80, 0x63]), decode([0x61, 0xe2, 0x82]),
           decode([0xc0, 0xaf]), decode([0xed, 0xa0, 0x80]), fatal, decode([]),
           new TextDecoder().decode(), new TextDecoder('UTF8').encoding]
        '''),
        [
          'a',
          '﻿a',
          'a�b��c',
          'a�',
          '��',
          '���',
          'TypeError',
          '',
          '',
          'utf-8',
        ],
      );
    });

    test('TextDecoder streaming splits multi-byte sequences', () {
      expect(
        eval(r'''
          const decoder = new TextDecoder();
          const parts = [decoder.decode(new Uint8Array([0x61, 0xe2]), { stream: true }),
            decoder.decode(new Uint8Array([0x82, 0xac]), { stream: true }),
            decoder.decode()];
          const bomSplit = new TextDecoder();
          const bomParts = [bomSplit.decode(new Uint8Array([0xef]), { stream: true }),
            bomSplit.decode(new Uint8Array([0xbb, 0xbf, 0x7a]), { stream: true })];
          [parts, bomParts]
        '''),
        [
          ['a', '€', ''],
          ['', 'z'],
        ],
      );
    });

    test('the JS to Dart bridge keeps a leading BOM', () {
      expect(eval(r"'\ufeffabc'"), '\ufeffabc');
      expect(eval(r"new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array([0xef, 0xbb, 0xbf]))"), '\ufeff');
    });

    test('only UTF-8 labels are accepted', () {
      expect(
        eval(r'''
          ['utf-16le', 'latin1', 'bogus'].map((label) => {
            try { new TextDecoder(label); return 'ok'; } catch (e) { return e.constructor.name; }
          })
        '''),
        List.filled(3, 'RangeError'),
      );
    });
  });

  test('L1 is off unless requested', () {
    final core = QuickJsRuntime2();
    addTearDown(core.dispose);
    expect(
      core.evaluate('[typeof Event, typeof TextEncoder, typeof structuredClone]').rawResult,
      ['undefined', 'undefined', 'function'],
    );
  });
}
