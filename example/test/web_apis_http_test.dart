// Headers / Request / Response differential tests against Node.js 24.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (async JS body, JSON.stringify of the result in Node).
const _cases = <(String, String)>[
  ("const h = new Headers({ 'X-A': '1', 'content-type': 'text/plain' });\n   h.append('x-a', '2');\n   h.append('Set-Cookie', 'a=1');\n   h.append('set-cookie', 'b=2');\n   return [h.get('x-a'), h.get('X-A'), h.has('content-type'), h.get('missing'),\n     [...h.keys()], h.getSetCookie(), [...h].map((e) => e.join('=')), h.get('set-cookie')];", "[\"1, 2\",\"1, 2\",true,null,[\"content-type\",\"set-cookie\",\"set-cookie\",\"x-a\"],[\"a=1\",\"b=2\"],[\"content-type=text/plain\",\"set-cookie=a=1\",\"set-cookie=b=2\",\"x-a=1, 2\"],\"a=1, b=2\"]"),
  ("const h = new Headers([['a', ' spaced  '], ['b', '2']]);\n   h.set('a', '9');\n   h.delete('b');\n   const errors = [() => h.append('bad name', 'v'), () => h.append('ok', 'bad\\u0000value'), () => new Headers('nope')]\n     .map((f) => { try { f(); return 'ok'; } catch (e) { return e.constructor.name; } });\n   return [h.get('a'), h.has('b'), [...h.entries()], errors];", "[\"9\",false,[[\"a\",\"9\"]],[\"TypeError\",\"TypeError\",\"TypeError\"]]"),
  ("const r = new Request('http://example.com/x', { method: 'post', body: 'hello' });\n   return [r.url, r.method, r.headers.get('content-type'), await r.text(), r.bodyUsed, r.redirect, r.credentials];", "[\"http://example.com/x\",\"POST\",\"text/plain;charset=UTF-8\",\"hello\",true,\"follow\",\"same-origin\"]"),
  ("const errors = [() => new Request('relative/path'), () => new Request('http://x.test', { method: 'CONNECT' }),\n     () => new Request('http://x.test', { method: 'GET', body: 'x' }), () => new Request('http://x.test', { redirect: 'bogus' })]\n     .map((f) => { try { f(); return 'ok'; } catch (e) { return e.constructor.name; } });\n   return errors;", "[\"TypeError\",\"TypeError\",\"TypeError\",\"TypeError\"]"),
  ("const base = new Request('http://example.com/a', { method: 'PUT', body: 'payload', headers: { 'x-t': '1' } });\n   const copy = base.clone();\n   const derived = new Request(base, { method: 'DELETE' });\n   return [await copy.text(), base.bodyUsed, copy.headers.get('x-t'), derived.method, derived.url, await base.text()];", "THROWS:TypeError"),
  ("const r = new Response('body', { status: 201, statusText: 'Created', headers: { 'x-h': 'v' } });\n   return [r.status, r.ok, r.statusText, r.headers.get('x-h'), r.headers.get('content-type'),\n     r.type, r.url, r.redirected, await r.text(), r.bodyUsed];", "[201,true,\"Created\",\"v\",\"text/plain;charset=UTF-8\",\"default\",\"\",false,\"body\",true]"),
  ("const errors = [() => new Response('x', { status: 99 }), () => new Response('x', { status: 204 }),\n     () => Response.redirect('http://x.test', 200), () => Response.json({ a: 1 }, { status: 700 })]\n     .map((f) => { try { f(); return 'ok'; } catch (e) { return e.constructor.name; } });\n   return errors;", "[\"RangeError\",\"TypeError\",\"RangeError\",\"RangeError\"]"),
  ("const json = Response.json({ a: [1, 2] }, { status: 202 });\n   const redirect = Response.redirect('http://x.test/y', 301);\n   const err = Response.error();\n   let immutable;\n   try { err.headers.set('a', 'b'); immutable = 'mutable'; } catch (e) { immutable = e.constructor.name; }\n   return [json.status, json.headers.get('content-type'), JSON.stringify(await json.json()),\n     redirect.status, redirect.headers.get('location'), err.type, err.status, immutable];", "[202,\"application/json\",\"{\\\"a\\\":[1,2]}\",301,\"http://x.test/y\",\"error\",0,\"TypeError\"]"),
  ("const r = new Response(new Blob(['blobby'], { type: 'text/plain' }));\n   const blob = await r.blob();\n   return [r.headers.get('content-type'), blob.size, await blob.text()];", "[\"text/plain\",6,\"blobby\"]"),
  ("const params = new URLSearchParams({ a: '1', b: 'two words' });\n   const r = new Response(params);\n   return [r.headers.get('content-type'), await r.text()];", "[\"application/x-www-form-urlencoded;charset=UTF-8\",\"a=1&b=two+words\"]"),
  ("const fd = new FormData();\n   fd.append('field', 'value');\n   fd.append('file', new File(['content'], 'f.txt', { type: 'text/plain' }));\n   const r = new Response(fd);\n   const type = r.headers.get('content-type').split(';')[0];\n   const back = await r.formData();\n   const file = back.get('file');\n   return [type, back.get('field'), file.name, file.type, await file.text()];", "[\"multipart/form-data\",\"value\",\"f.txt\",\"text/plain\",\"content\"]"),
  ("const r = new Response(new Uint8Array([1, 2, 3]));\n   const buf = await r.arrayBuffer();\n   return [r.headers.get('content-type'), [...new Uint8Array(buf)]];", "[null,[1,2,3]]"),
  ("const r = new Response('streamed');\n   const chunks = [];\n   for await (const chunk of r.body) chunks.push(...chunk);\n   let reuse;\n   try { await r.text(); reuse = 'ok'; } catch (e) { reuse = e.constructor.name; }\n   return [chunks, r.bodyUsed, reuse];", "[[115,116,114,101,97,109,101,100],true,\"TypeError\"]"),
  ("const source = new Response('tee me');\n   const copy = source.clone();\n   return [await source.text(), await copy.text()];", "[\"tee me\",\"tee me\"]"),
  ("const r = new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array([104, 105])); c.close(); } }));\n   return [await r.text(), r.headers.get('content-type')];", "[\"hi\",null]"),
  ("const r = new Response('x=1&y=2', { headers: { 'content-type': 'application/x-www-form-urlencoded' } });\n   const fd = await r.formData();\n   return [fd.get('x'), fd.get('y')];", "[\"1\",\"2\"]"),
];

void main() {
  late QuickJsRuntime2 js;

  setUp(() {
    js = QuickJsRuntime2(timeout: 10000, webApis: const JsWebApis.standard());
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

  test('HTTP types behave like Node', () async {
    final failures = <String>[];
    for (final (body, expected) in _cases) {
      final actual = await run(body);
      if (actual != expected) {
        failures.add('$body\n  node: $expected\n  qjs : $actual');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  test('HTTP objects are not structured-cloneable', () {
    expect(
      js.evaluate(r"""
        [new Headers(), new Request('http://x.test'), new Response()].map((v) => {
          try { structuredClone(v); return 'cloned'; } catch (e) { return e.name; }
        })
      """).rawResult,
      ['DataCloneError', 'DataCloneError', 'DataCloneError'],
    );
  });
}
