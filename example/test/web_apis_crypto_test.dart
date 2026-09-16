// crypto.subtle (SHA + HMAC) differential tests against Node.js 24, which also
// covers the FIPS vectors for SHA-1/256/384/512 and RFC 4231-style HMAC cases.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (async JS body, JSON.stringify of the result in Node).
const _cases = <(String, String)>[
  ("const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');\n   const data = new TextEncoder().encode('abc');\n   const empty = new Uint8Array(0);\n   const out = {};\n   for (const alg of ['SHA-1', 'SHA-256', 'SHA-384', 'SHA-512']) {\n     out[alg] = hex(await crypto.subtle.digest(alg, data));\n     out[alg + '-empty'] = hex(await crypto.subtle.digest(alg, empty));\n   }\n   const long = new Uint8Array(1000).fill(97);\n   out['SHA-256-long'] = hex(await crypto.subtle.digest('SHA-256', long));\n   out['SHA-512-long'] = hex(await crypto.subtle.digest('SHA-512', long));\n   return out;", "{\"SHA-1\":\"a9993e364706816aba3e25717850c26c9cd0d89d\",\"SHA-1-empty\":\"da39a3ee5e6b4b0d3255bfef95601890afd80709\",\"SHA-256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\",\"SHA-256-empty\":\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\",\"SHA-384\":\"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7\",\"SHA-384-empty\":\"38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b\",\"SHA-512\":\"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f\",\"SHA-512-empty\":\"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e\",\"SHA-256-long\":\"41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3\",\"SHA-512-long\":\"67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa634fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97\"}"),
  ("const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');\n   const raw = new TextEncoder().encode('key');\n   const data = new TextEncoder().encode('The quick brown fox jumps over the lazy dog');\n   const out = {};\n   for (const hash of ['SHA-1', 'SHA-256', 'SHA-384', 'SHA-512']) {\n     const key = await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash }, true, ['sign', 'verify']);\n     const signature = await crypto.subtle.sign('HMAC', key, data);\n     out[hash] = hex(signature);\n     out[hash + '-verify'] = await crypto.subtle.verify('HMAC', key, signature, data);\n     out[hash + '-verify-bad'] = await crypto.subtle.verify('HMAC', key, new Uint8Array(4), data);\n   }\n   return out;", "{\"SHA-1\":\"de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9\",\"SHA-1-verify\":true,\"SHA-1-verify-bad\":false,\"SHA-256\":\"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8\",\"SHA-256-verify\":true,\"SHA-256-verify-bad\":false,\"SHA-384\":\"d7f4727e2c0b39ae0f1e40cc96f60242d5b7801841cea6fc592c5d3e1ae50700582a96cf35e1e554995fe4e03381c237\",\"SHA-384-verify\":true,\"SHA-384-verify-bad\":false,\"SHA-512\":\"b42af09057bac1e2d41708e48a902e09b5ff7f12ab428a4fe86653c73dd248fb82f948a549f7b791a5b41915ee4d1ec3935357e4e2317250d0372afa2ebeeb3a\",\"SHA-512-verify\":true,\"SHA-512-verify-bad\":false}"),
  ("const longKey = new Uint8Array(200).fill(9);\n   const key = await crypto.subtle.importKey('raw', longKey, { name: 'HMAC', hash: 'SHA-256' }, true, ['sign']);\n   const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('data'));\n   return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, '0')).join('');", "\"97ef60a26cd47bcf9edefa84aaf9c633a2ac69870a88a9c7da54688d34be3100\""),
  ("const raw = new Uint8Array([1, 2, 3, 4, 5]);\n   const key = await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, true, ['sign', 'verify']);\n   const jwk = await crypto.subtle.exportKey('jwk', key);\n   const exported = new Uint8Array(await crypto.subtle.exportKey('raw', key));\n   const imported = await crypto.subtle.importKey('jwk', jwk, { name: 'HMAC', hash: 'SHA-256' }, true, ['sign']);\n   const again = new Uint8Array(await crypto.subtle.exportKey('raw', imported));\n   return [jwk.kty, jwk.k, jwk.alg, jwk.key_ops, jwk.ext, [...exported], [...again],\n     key.type, key.extractable, key.algorithm.name, key.algorithm.hash.name, key.algorithm.length, key.usages];", "[\"oct\",\"AQIDBAU\",\"HS256\",[\"sign\",\"verify\"],true,[1,2,3,4,5],[1,2,3,4,5],\"secret\",true,\"HMAC\",\"SHA-256\",40,[\"sign\",\"verify\"]]"),
  ("const key = await crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, true, ['sign', 'verify']);\n   const raw = new Uint8Array(await crypto.subtle.exportKey('raw', key));\n   const data = new TextEncoder().encode('payload');\n   const signature = await crypto.subtle.sign('HMAC', key, data);\n   return [raw.length, key.algorithm.length, await crypto.subtle.verify('HMAC', key, signature, data),\n     new Uint8Array(signature).length, raw.some((b) => b !== 0)];", "[64,512,true,32,true]"),
  ("const key = await crypto.subtle.importKey('raw', new Uint8Array([1]), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);\n   const errors = [];\n   for (const op of [() => crypto.subtle.exportKey('raw', key),\n     () => crypto.subtle.verify('HMAC', key, new Uint8Array(1), new Uint8Array(1)),\n     () => crypto.subtle.digest('MD5', new Uint8Array(1)),\n     () => crypto.subtle.importKey('raw', new Uint8Array(1), { name: 'HMAC', hash: 'MD5' }, true, ['sign'])]) {\n     try { await op(); errors.push('ok'); } catch (e) { errors.push(e.name); }\n   }\n   return errors;", "[\"InvalidAccessError\",\"InvalidAccessError\",\"NotSupportedError\",\"NotSupportedError\"]"),
];

void main() {
  late QuickJsRuntime2 js;

  setUp(() {
    js = QuickJsRuntime2(timeout: 20000, webApis: const JsWebApis.standard());
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
      timeout: const Duration(seconds: 20),
    );
    return '${settled.rawResult}';
  }

  test('digest, HMAC and key handling match Node', () async {
    final failures = <String>[];
    for (final (body, expected) in _cases) {
      final actual = await run(body);
      if (actual != expected) {
        failures.add('$body\n  node: $expected\n  qjs : $actual');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  test('unsupported algorithms reject with NotSupportedError', () async {
    expect(
      await run(r"""
        const out = [];
        for (const op of [() => crypto.subtle.encrypt({ name: 'AES-GCM' }, {}, new Uint8Array(1)),
          () => crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']),
          () => crypto.subtle.deriveBits({ name: 'PBKDF2' }, {}, 8),
          () => crypto.subtle.importKey('pkcs8', new Uint8Array(1), { name: 'HMAC', hash: 'SHA-256' }, true, ['sign'])]) {
          try { await op(); out.push('ok'); } catch (e) { out.push(e.name); }
        }
        return out;
      """),
      '["NotSupportedError","NotSupportedError","NotSupportedError","NotSupportedError"]',
    );
  });

  test('navigator reports the configured user agent', () {
    expect(js.evaluate('navigator.userAgent').rawResult, 'flutter_qjs_next');
    final custom = QuickJsRuntime2(
      webApis: const JsWebApis.standard(userAgent: 'my-app/2.0'),
    );
    addTearDown(custom.dispose);
    expect(custom.evaluate('navigator.userAgent').rawResult, 'my-app/2.0');
  });
}
