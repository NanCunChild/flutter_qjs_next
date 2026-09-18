// Module selection and dependency closure (doc/design/2026-09-13-web-apis.md).
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> resolve(JsWebApis config) =>
      config.resolvedModules.map((m) => m.name).toList();

  dynamic probe(JsWebApis config, String code) {
    final js = QuickJsRuntime2(timeout: 5000, webApis: config);
    addTearDown(js.dispose);
    final result = js.evaluate(code);
    if (result.isError) fail(result.stringResult);
    return result.rawResult;
  }

  group('dependency closure', () {
    test('a module pulls in what it requires, in order', () {
      expect(resolve(const JsWebApis(modules: {JsWebModule.url})), [
        'core',
        'url',
      ]);
      expect(resolve(const JsWebApis(modules: {JsWebModule.streams})), [
        'core',
        'events',
        'streams',
      ]);
    });

    test('every module comes after everything it requires or uses', () {
      final order = JsWebApis.standard(
        fetch: const JsFetchOptions(),
      ).resolvedModules;
      for (var i = 0; i < order.length; i++) {
        for (final dependency in [...order[i].requires, ...order[i].optional]) {
          expect(
            order.indexWhere((m) => m.name == dependency.name),
            lessThan(i),
            reason: '${order[i].name} installed before ${dependency.name}',
          );
        }
      }
      expect(order.last.name, 'fetch');
    });

    test('the closure is a set: a shared dependency is installed once', () {
      final order = resolve(
        const JsWebApis(modules: {JsWebModule.http, JsWebModule.blob}),
      );
      expect(order.where((name) => name == 'streams'), hasLength(1));
      expect(order.toSet(), hasLength(order.length));
    });

    test('an optional dependency is not pulled in', () {
      expect(resolve(const JsWebApis(modules: {JsWebModule.blob})), [
        'core',
        'blob',
      ]);
      expect(
        resolve(const JsWebApis(modules: {JsWebModule.http})),
        isNot(anyOf(contains('blob'), contains('encoding'))),
      );
    });

    test('an optional dependency that is installed comes first', () {
      // Requested in the "wrong" order on purpose.
      expect(
        resolve(
            const JsWebApis(modules: {JsWebModule.blob, JsWebModule.streams})),
        ['core', 'events', 'streams', 'blob'],
      );
      expect(
        resolve(
          const JsWebApis(modules: {JsWebModule.streams, JsWebModule.encoding}),
        ),
        ['core', 'events', 'encoding', 'streams'],
      );
      final order = resolve(
        const JsWebApis(modules: {JsWebModule.http, JsWebModule.blob}),
      );
      expect(order.indexOf('blob'), lessThan(order.indexOf('http')));
    });

    test('fetch implies its dependencies but not unrelated modules', () {
      final withFetch = resolve(JsWebApis(fetch: const JsFetchOptions()));
      expect(withFetch, contains('http'));
      expect(withFetch, isNot(contains('crypto')));
      expect(withFetch, isNot(contains('blob')));
      expect(
        resolve(JsWebApis.standard(fetch: const JsFetchOptions())),
        contains('crypto'),
      );
    });
  });

  group('installed globals match the closure', () {
    test('url alone', () {
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.url}),
          '[typeof URL, typeof URLSearchParams, typeof Blob, '
          'typeof ReadableStream, typeof console]',
        ),
        ['function', 'function', 'undefined', 'undefined', 'object'],
      );
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.url}),
          "new URL('/a?b=1', 'https://example.com').href",
        ),
        'https://example.com/a?b=1',
      );
    });

    test('blob alone installs nothing else', () {
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.blob}),
          '[typeof Blob, typeof ReadableStream, typeof TextEncoder, '
          'typeof URL, typeof Headers]',
        ),
        ['function', 'undefined', 'undefined', 'undefined', 'undefined'],
      );
    });

    test('crypto alone', () {
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.crypto}),
          '[typeof crypto.subtle, typeof crypto.randomUUID, typeof Blob, '
          'typeof navigator]',
        ),
        ['object', 'function', 'undefined', 'undefined'],
      );
    });

    test('core only is the default', () {
      expect(resolve(const JsWebApis()), ['core']);
      expect(
        probe(
          const JsWebApis(),
          '[typeof console, typeof setTimeout, typeof structuredClone, '
          'typeof TextEncoder]',
        ),
        ['object', 'function', 'function', 'undefined'],
      );
    });

    test('none installs nothing', () {
      expect(resolve(const JsWebApis.none()), isEmpty);
      expect(
        probe(
          const JsWebApis.none(),
          '[typeof console, typeof setTimeout, typeof JSON]',
        ),
        ['undefined', 'undefined', 'object'],
      );
    });

    test('navigator is its own module, not part of crypto', () {
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.navigator}),
          '[typeof navigator.userAgent, typeof crypto.subtle]',
        ),
        ['string', 'undefined'],
      );
    });
  });

  group('optional dependencies', () {
    test('streams: encoding streams need encoding', () {
      const probeCode = '[typeof ReadableStream, typeof TextEncoderStream, '
          'typeof TextDecoderStream]';
      expect(
        probe(const JsWebApis(modules: {JsWebModule.streams}), probeCode),
        ['function', 'undefined', 'undefined'],
      );
      expect(
        probe(
          const JsWebApis(
            modules: {JsWebModule.streams, JsWebModule.encoding},
          ),
          probeCode,
        ),
        ['function', 'function', 'function'],
      );
    });

    test('blob: Blob.prototype.stream needs streams', () {
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.blob}),
          "['stream' in Blob.prototype, new Blob(['ab']).size]",
        ),
        [false, 2],
      );
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.blob, JsWebModule.streams}),
          "new Blob(['ab']).stream() instanceof ReadableStream",
        ),
        true,
      );
    });

    test('http: blob() and formData() need blob', () {
      const probeCode =
          "['blob' in Response.prototype, 'formData' in Request.prototype, "
          "typeof new Response('x').text]";
      expect(
        probe(const JsWebApis(modules: {JsWebModule.http}), probeCode),
        [false, false, 'function'],
      );
      expect(
        probe(
          const JsWebApis(modules: {JsWebModule.http, JsWebModule.blob}),
          probeCode,
        ),
        [true, true, 'function'],
      );
    });

    test('http without blob still takes the other body types', () async {
      final js = QuickJsRuntime2(
        timeout: 5000,
        webApis: const JsWebApis(modules: {JsWebModule.http}),
      );
      addTearDown(js.dispose);
      final started = js.evaluate('''
        Promise.all([
          new Response('text').text(),
          new Response(new Uint8Array([104, 105])).text(),
          new Request('https://example.com', {
            method: 'POST', body: new URLSearchParams('a=1&b=2'),
          }).text(),
        ]).then((v) => JSON.stringify(v))
      ''');
      if (started.isError) fail(started.stringResult);
      final settled = await js.handlePromise(
        started,
        timeout: const Duration(seconds: 5),
      );
      expect(settled.rawResult, '["text","hi","a=1&b=2"]');
    });

    test('fetch alone has fetch but not blob()', () {
      expect(
        probe(
          JsWebApis(fetch: const JsFetchOptions()),
          "[typeof fetch, 'blob' in Response.prototype, typeof Blob]",
        ),
        ['function', false, 'undefined'],
      );
    });
  });

  test('a capability module cannot be installed without its policy', () {
    expect(
      () => QuickJsRuntime2(
        webApis: const JsWebApis(modules: {JsWebModule.fetch}),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          allOf(contains('network'), contains('JsFetchOptions')),
        ),
      ),
    );
  });

  test('installs() reports the closure', () {
    const config = JsWebApis(modules: {JsWebModule.http});
    expect(config.installs(JsWebModule.streams), isTrue);
    expect(config.installs(JsWebModule.core), isTrue);
    expect(config.installs(JsWebModule.crypto), isFalse);
    expect(config.installs(JsWebModule.fetch), isFalse);
  });
}
