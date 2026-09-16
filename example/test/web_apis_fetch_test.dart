// L2 fetch tests against a local HTTP server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String base;
  QuickJsRuntime2? js;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/text':
          response.headers.contentType = ContentType.text;
          response.write('hello world');
        case '/json':
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'a': 1, 'list': [1, 2]}));
        case '/echo':
          final body = await request.fold<List<int>>(
            <int>[],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'method': request.method,
              'contentType': request.headers.value('content-type'),
              'custom': request.headers.value('x-custom'),
              'auth': request.headers.value('authorization'),
              'body': utf8.decode(body, allowMalformed: true),
            }),
          );
        case '/404':
          response.statusCode = 404;
          response.write('nope');
        case '/redirect':
          response.statusCode = 302;
          response.headers.set('location', '$base/text');
        case '/redirect303':
          response.statusCode = 303;
          response.headers.set('location', '$base/echo');
        case '/redirect-loop':
          response.statusCode = 302;
          response.headers.set('location', '$base/redirect-loop');
        case '/cookies':
          response.headers.add('set-cookie', 'a=1');
          response.headers.add('set-cookie', 'b=2');
          response.write('ok');
        case '/slow':
          response.headers.contentType = ContentType.text;
          for (var i = 0; i < 3; i++) {
            response.write('chunk$i;');
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        case '/big':
          response.add(Uint8List(200 * 1024));
        default:
          response.statusCode = 500;
          response.write('unexpected ${request.uri.path}');
      }
      await response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  tearDown(() {
    js?.dispose();
    js = null;
  });

  QuickJsRuntime2 engine({JsFetchOptions options = const JsFetchOptions()}) {
    final runtime = QuickJsRuntime2(
      timeout: 20000,
      webApis: JsWebApis(fetch: options),
    );
    runtime.evaluate('globalThis.BASE = ${jsonEncode(base)}');
    js = runtime;
    return runtime;
  }

  Future<String> run(QuickJsRuntime2 runtime, String body) async {
    final started = runtime.evaluate(
      '(async () => { $body })().then('
      '(v) => { const s = JSON.stringify(v); return s === undefined ? "undefined" : s; },'
      '(e) => "THROWS:" + (e && e.name ? e.name : e) + ":" + (e && e.message ? e.message : ""))',
    );
    if (started.isError) return 'EVAL-ERROR:${started.stringResult}';
    final settled = await runtime.handlePromise(
      started,
      timeout: const Duration(seconds: 20),
    );
    return '${settled.rawResult}';
  }

  test('GET returns status, headers and body', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/text');
        return [r.status, r.ok, r.type, r.redirected, r.url === BASE + '/text',
          r.headers.get('content-type'), await r.text(), r.bodyUsed];
      '''),
      '[200,true,"basic",false,true,"text/plain; charset=utf-8","hello world",true]',
    );
  });

  test('json() and multiple set-cookie headers', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/json');
        const body = await r.json();
        const cookies = await fetch(BASE + '/cookies');
        return [body.a, body.list, cookies.headers.getSetCookie()];
      '''),
      '[1,[1,2],["a=1","b=2"]]',
    );
  });

  test('POST sends headers and body', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/echo', {
          method: 'POST', body: 'payload', headers: { 'x-custom': 'yes' },
        });
        const echoed = await r.json();
        return [echoed.method, echoed.body, echoed.custom, echoed.contentType];
      '''),
      '["POST","payload","yes","text/plain;charset=UTF-8"]',
    );
  });

  test('FormData upload round trip', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const fd = new FormData();
        fd.append('field', 'value');
        fd.append('file', new File(['content'], 'f.txt', { type: 'text/plain' }));
        const r = await fetch(BASE + '/echo', { method: 'POST', body: fd });
        const echoed = await r.json();
        const parsed = await new Response(echoed.body, {
          headers: { 'content-type': echoed.contentType },
        }).formData();
        return [echoed.contentType.split(';')[0], parsed.get('field'),
          parsed.get('file').name, await parsed.get('file').text()];
      '''),
      '["multipart/form-data","value","f.txt","content"]',
    );
  });

  test('error statuses are not exceptions', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/404');
        return [r.ok, r.status, await r.text()];
      '''),
      '[false,404,"nope"]',
    );
  });

  test('redirect modes', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const followed = await fetch(BASE + '/redirect');
        const manual = await fetch(BASE + '/redirect', { redirect: 'manual' });
        let errored;
        try { await fetch(BASE + '/redirect', { redirect: 'error' }); errored = 'resolved'; }
        catch (e) { errored = e.constructor.name; }
        const posted = await fetch(BASE + '/redirect303', { method: 'POST', body: 'x' });
        const echoed = await posted.json();
        return [followed.status, followed.redirected, followed.url === BASE + '/text',
          await followed.text(), manual.status, manual.headers.get('location') !== null,
          manual.redirected, errored, echoed.method, echoed.body];
      '''),
      '[200,true,true,"hello world",302,true,false,"TypeError","GET",""]',
    );
  });

  test('redirect limit is enforced', () async {
    final runtime = engine(options: const JsFetchOptions(maxRedirects: 3));
    expect(
      await run(runtime, r'''
        try { await fetch(BASE + '/redirect-loop'); return 'resolved'; }
        catch (e) { return [e.constructor.name, e.message.includes('too many redirects')]; }
      '''),
      '["TypeError",true]',
    );
  });

  test('streaming body is delivered chunk by chunk', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/slow');
        const reader = r.body.getReader();
        const decoder = new TextDecoder();
        const chunks = [];
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          chunks.push(decoder.decode(value, { stream: true }));
        }
        return [chunks.join('').split(';').filter(Boolean), chunks.length >= 1, r.bodyUsed];
      '''),
      '[["chunk0","chunk1","chunk2"],true,true]',
    );
  });

  test('AbortSignal rejects before and during the request', () async {
    final runtime = engine();
    expect(
      await run(runtime, r'''
        const pre = AbortSignal.abort(new DOMException('early', 'AbortError'));
        let before;
        try { await fetch(BASE + '/text', { signal: pre }); before = 'resolved'; }
        catch (e) { before = e.name + ':' + e.message; }

        const controller = new AbortController();
        const inflight = fetch(BASE + '/slow', { signal: controller.signal });
        setTimeout(() => controller.abort(), 10);
        let during;
        try { const r = await inflight; await r.text(); during = 'resolved'; }
        catch (e) { during = e.name; }
        return [before, during];
      '''),
      '["AbortError:early","AbortError"]',
    );
  });

  test('allowUrl policy blocks disallowed hosts', () async {
    final runtime = engine(
      options: JsFetchOptions(allowUrl: (url) => url.path == '/text'),
    );
    expect(
      await run(runtime, r'''
        const allowed = await fetch(BASE + '/text');
        let blocked;
        try { await fetch(BASE + '/json'); blocked = 'resolved'; }
        catch (e) { blocked = [e.constructor.name, e.message.includes('not allowed')]; }
        return [await allowed.text(), blocked];
      '''),
      '["hello world",["TypeError",true]]',
    );
  });

  test('maxResponseBytes errors the body stream', () async {
    final runtime = engine(options: const JsFetchOptions(maxResponseBytes: 1024));
    expect(
      await run(runtime, r'''
        const r = await fetch(BASE + '/big');
        try { await r.arrayBuffer(); return 'resolved'; }
        catch (e) { return [e.constructor.name, e.message.includes('maxResponseBytes')]; }
      '''),
      '["TypeError",true]',
    );
  });

  test('a custom handler replaces the network', () async {
    var seen = <String, String>{};
    final runtime = engine(
      options: JsFetchOptions(
        handler: (request) async {
          seen = {
            'url': request.url.toString(),
            'method': request.method,
            'body': utf8.decode(request.body ?? Uint8List(0)),
          };
          return JsFetchResponse(
            status: 201,
            statusText: 'Created',
            headers: const [MapEntry('content-type', 'application/json')],
            body: Stream.value(utf8.encode('{"stub":true}')),
          );
        },
      ),
    );
    expect(
      await run(runtime, r'''
        const r = await fetch('https://blocked.invalid/api', { method: 'PUT', body: 'up' });
        return [r.status, r.statusText, (await r.json()).stub];
      '''),
      '[201,"Created",true]',
    );
    expect(seen, {
      'url': 'https://blocked.invalid/api',
      'method': 'PUT',
      'body': 'up',
    });
  });

  test('fetch is absent unless configured', () {
    final plain = QuickJsRuntime2(webApis: const JsWebApis(web: true));
    addTearDown(plain.dispose);
    expect(plain.evaluate('typeof fetch').rawResult, 'undefined');
    expect(plain.evaluate('typeof Response').rawResult, 'function');
  });

  test('disposing an engine with an in-flight fetch is safe', () async {
    final runtime = engine();
    runtime.evaluate(r'''
      globalThis.done = 'pending';
      fetch(BASE + '/slow').then((r) => r.text()).then(
        (t) => { done = t; }, (e) => { done = 'error:' + e.name; });
    ''');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    runtime.dispose();
    js = null;
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
}
