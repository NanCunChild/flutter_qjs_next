// Streams differential tests: every expectation comes from Node.js 24 running
// the same JS body.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (async JS body, JSON.stringify of the result in Node).
const _cases = <(String, String)>[
  ("const rs = new ReadableStream({ start(c) { c.enqueue('a'); c.enqueue('b'); c.close(); } });\n   const reader = rs.getReader();\n   const out = [];\n   for (;;) { const { value, done } = await reader.read(); if (done) break; out.push(value); }\n   return [out, rs.locked, (await reader.closed) === undefined];", "[[\"a\",\"b\"],true,true]"),
  ("const pulls = [];\n   let i = 0;\n   const rs = new ReadableStream({ pull(c) { pulls.push(c.desiredSize); c.enqueue(i++); if (i === 4) c.close(); } }, { highWaterMark: 2 });\n   const out = [];\n   for await (const chunk of rs) out.push(chunk);\n   return [out, pulls.length >= 4, pulls.every((size) => size > 0 && size <= 2)];", "[[0,1,2,3],true,true]"),
  ("let cancelReason;\n   const rs = new ReadableStream({ start(c) { c.enqueue(1); }, cancel(r) { cancelReason = r; } });\n   await rs.cancel('stop');\n   return [cancelReason, rs.locked];", "[\"stop\",false]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue(1); } });\n   const reader = rs.getReader();\n   await reader.read();\n   const pending = reader.read().then(() => 'resolved', (e) => e.constructor.name);\n   reader.releaseLock();\n   return [await pending, rs.locked];", "[\"TypeError\",false]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue('x'); c.enqueue('y'); c.close(); } });\n   const [a, b] = rs.tee();\n   const drain = async (s) => { const out = []; for await (const v of s) out.push(v); return out; };\n   return await Promise.all([drain(a), drain(b)]);", "[[\"x\",\"y\"],[\"x\",\"y\"]]"),
  ("async function* gen() { yield 1; yield 2; yield 3; }\n   const out = [];\n   for await (const v of ReadableStream.from(gen())) out.push(v);\n   return out;", "[1,2,3]"),
  ("const chunks = [];\n   let closed = false;\n   const ws = new WritableStream({ write(chunk) { chunks.push(chunk); }, close() { closed = true; } }, { highWaterMark: 2 });\n   const writer = ws.getWriter();\n   await writer.ready;\n   const sizeBefore = writer.desiredSize;\n   await writer.write('a');\n   await writer.write('b');\n   await writer.close();\n   return [chunks, closed, sizeBefore, writer.desiredSize, ws.locked];", "[[\"a\",\"b\"],true,2,0,true]"),
  ("let abortReason;\n   const ws = new WritableStream({ write() {}, abort(r) { abortReason = r; } });\n   const writer = ws.getWriter();\n   await writer.abort('nope');\n   const closedResult = await writer.closed.then(() => 'resolved', (e) => 'rejected:' + e);\n   const writeResult = await writer.write('x').then(() => 'ok', (e) => 'rejected:' + e);\n   return [abortReason, closedResult, writeResult];", "[\"nope\",\"rejected:nope\",\"rejected:nope\"]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue('a'); c.enqueue('b'); c.close(); } });\n   const upper = new TransformStream({ transform(chunk, c) { c.enqueue(chunk.toUpperCase()); }, flush(c) { c.enqueue('!'); } });\n   const out = [];\n   for await (const v of rs.pipeThrough(upper)) out.push(v);\n   return out;", "[\"A\",\"B\",\"!\"]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.close(); } });\n   const seen = [];\n   let closed = false;\n   const ws = new WritableStream({ write(c) { seen.push(c); }, close() { closed = true; } });\n   await rs.pipeTo(ws);\n   return [seen, closed];", "[[1,2],true]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue(1); c.close(); } });\n   let closed = false;\n   const ws = new WritableStream({ write() {}, close() { closed = true; } });\n   await rs.pipeTo(ws, { preventClose: true });\n   return [closed, ws.locked];", "[false,false]"),
  ("const rs = new ReadableStream({ start(c) { c.error(new TypeError('src boom')); } });\n   let abortReason = null;\n   const ws = new WritableStream({ write() {}, abort(r) { abortReason = String(r); } });\n   const result = await rs.pipeTo(ws).then(() => 'resolved', (e) => 'rejected:' + e.message);\n   return [result, abortReason];", "[\"rejected:src boom\",\"TypeError: src boom\"]"),
  ("const rs = new ReadableStream({ start(c) { c.enqueue('he'); c.enqueue('llo \u20ac'); c.close(); } });\n   const bytes = [];\n   for await (const chunk of rs.pipeThrough(new TextEncoderStream())) bytes.push(...chunk);\n   const back = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(bytes.slice(0, 7))); c.enqueue(new Uint8Array(bytes.slice(7))); c.close(); } });\n   const text = [];\n   for await (const chunk of back.pipeThrough(new TextDecoderStream())) text.push(chunk);\n   return [bytes, text.join('')];", "[[104,101,108,108,111,32,226,130,172],\"hello \u20ac\"]"),
  ("const count = new CountQueuingStrategy({ highWaterMark: 3 });\n   const bytes = new ByteLengthQueuingStrategy({ highWaterMark: 16 });\n   const rs = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(4)); } }, bytes);\n   const reader = rs.getReader();\n   await reader.read();\n   return [count.highWaterMark, count.size(), bytes.highWaterMark, bytes.size(new Uint8Array(5))];", "[3,1,16,5]"),
  ("const rs = new ReadableStream({ start(c) { c.close(); } });\n   rs.getReader();\n   const second = (() => { try { rs.getReader(); return 'ok'; } catch (e) { return e.constructor.name; } })();\n   let enqueueAfterClose;\n   const rs2 = new ReadableStream({ start(c) { c.close(); try { c.enqueue(1); enqueueAfterClose = 'ok'; } catch (e) { enqueueAfterClose = e.constructor.name; } } });\n   await Promise.resolve();\n   return [second, enqueueAfterClose, rs.locked];", "[\"TypeError\",\"TypeError\",true]"),
];

void main() {
  late QuickJsRuntime2 js;

  setUp(() {
    js = QuickJsRuntime2(timeout: 10000, webApis: const JsWebApis(web: true));
  });
  tearDown(() => js.dispose());

  Future<String> run(String body) async {
    final started = js.evaluate(
      '(async () => { $body })().then('
      '(v) => { const s = JSON.stringify(v); return s === undefined ? "undefined" : s; },'
      '(e) => "THROWS:" + e.constructor.name)',
    );
    if (started.isError) return 'EVAL-ERROR:${started.stringResult}';
    final settled = await js.handlePromise(
      started,
      timeout: const Duration(seconds: 10),
    );
    return '${settled.rawResult}';
  }

  test('streams behave like Node', () async {
    final failures = <String>[];
    for (final (body, expected) in _cases) {
      final actual = await run(body);
      if (actual != expected) {
        failures.add('$body\n  node: $expected\n  qjs : $actual');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  test('byte streams are rejected explicitly', () {
    expect(
      js.evaluate(r"""
        [() => new ReadableStream({ type: 'bytes' }),
         () => new ReadableStream().getReader({ mode: 'byob' })]
          .map((f) => { try { f(); return 'ok'; } catch (e) { return e.constructor.name; } })
      """).rawResult,
      ['TypeError', 'TypeError'],
    );
  });

  test('streams are not structured-cloneable', () {
    expect(
      js.evaluate(r"""
        [new ReadableStream(), new WritableStream()].map((s) => {
          try { structuredClone(s); return 'cloned'; } catch (e) { return e.name; }
        })
      """).rawResult,
      ['DataCloneError', 'DataCloneError'],
    );
  });
}
