// URL / URLSearchParams differential tests.
// Every expectation was produced by Node.js 24 (see tool/ scripts in the
// commit message); QuickJS must agree field by field.
import 'dart:convert';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (input, base, [href, protocol, username, password, host, hostname, port,
/// pathname, search, hash, origin, searchParams]) or null when Node throws.
const _parseCases = <(String, String?, List<String>?)>[
  ("http://example.com", null, ["http://example.com/", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("HTTP://ExAmPlE.com:80/Path", null, ["http://example.com/Path", "http:", "", "", "example.com", "example.com", "", "/Path", "", "", "http://example.com", ""]),
  ("https://user:pass@example.com:8443/a/b?x=1#frag", null, ["https://user:pass@example.com:8443/a/b?x=1#frag", "https:", "user", "pass", "example.com:8443", "example.com", "8443", "/a/b", "?x=1", "#frag", "https://example.com:8443", "x=1"]),
  ("http://example.com/a/b/../c/./d", null, ["http://example.com/a/c/d", "http:", "", "", "example.com", "example.com", "", "/a/c/d", "", "", "http://example.com", ""]),
  ("http://example.com/../../x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("http://example.com//double//slash", null, ["http://example.com//double//slash", "http:", "", "", "example.com", "example.com", "", "//double//slash", "", "", "http://example.com", ""]),
  ("http://example.com", null, ["http://example.com/", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://example.com:8080", null, ["http://example.com:8080/", "http:", "", "", "example.com:8080", "example.com", "8080", "/", "", "", "http://example.com:8080", ""]),
  ("http://example.com:443", null, ["http://example.com:443/", "http:", "", "", "example.com:443", "example.com", "443", "/", "", "", "http://example.com:443", ""]),
  ("https://example.com:443/x", null, ["https://example.com/x", "https:", "", "", "example.com", "example.com", "", "/x", "", "", "https://example.com", ""]),
  ("http://192.168.0.1/", null, ["http://192.168.0.1/", "http:", "", "", "192.168.0.1", "192.168.0.1", "", "/", "", "", "http://192.168.0.1", ""]),
  ("http://0x7f.1/", null, ["http://127.0.0.1/", "http:", "", "", "127.0.0.1", "127.0.0.1", "", "/", "", "", "http://127.0.0.1", ""]),
  ("http://0300.0250.0.1/", null, ["http://192.168.0.1/", "http:", "", "", "192.168.0.1", "192.168.0.1", "", "/", "", "", "http://192.168.0.1", ""]),
  ("http://2130706433/", null, ["http://127.0.0.1/", "http:", "", "", "127.0.0.1", "127.0.0.1", "", "/", "", "", "http://127.0.0.1", ""]),
  ("http://[2001:db8::1]:8080/x", null, ["http://[2001:db8::1]:8080/x", "http:", "", "", "[2001:db8::1]:8080", "[2001:db8::1]", "8080", "/x", "", "", "http://[2001:db8::1]:8080", ""]),
  ("http://[::1]/", null, ["http://[::1]/", "http:", "", "", "[::1]", "[::1]", "", "/", "", "", "http://[::1]", ""]),
  ("http://[0:0:0:0:0:0:0:1]/", null, ["http://[::1]/", "http:", "", "", "[::1]", "[::1]", "", "/", "", "", "http://[::1]", ""]),
  ("http://[::ffff:192.168.0.1]/", null, ["http://[::ffff:c0a8:1]/", "http:", "", "", "[::ffff:c0a8:1]", "[::ffff:c0a8:1]", "", "/", "", "", "http://[::ffff:c0a8:1]", ""]),
  ("http://例え.テスト/", null, ["http://xn--r8jz45g.xn--zckzah/", "http:", "", "", "xn--r8jz45g.xn--zckzah", "xn--r8jz45g.xn--zckzah", "", "/", "", "", "http://xn--r8jz45g.xn--zckzah", ""]),
  ("http://Ünïcödé.com/", null, ["http://xn--ncd-dma1a7bzb.com/", "http:", "", "", "xn--ncd-dma1a7bzb.com", "xn--ncd-dma1a7bzb.com", "", "/", "", "", "http://xn--ncd-dma1a7bzb.com", ""]),
  ("http:example.com/x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("http:/example.com/x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("http:\\\\example.com\\x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("mailto:someone@example.com", null, ["mailto:someone@example.com", "mailto:", "", "", "", "", "", "someone@example.com", "", "", "null", ""]),
  ("data:text/plain,hello world", null, ["data:text/plain,hello world", "data:", "", "", "", "", "", "text/plain,hello world", "", "", "null", ""]),
  ("javascript:alert(1)", null, ["javascript:alert(1)", "javascript:", "", "", "", "", "", "alert(1)", "", "", "null", ""]),
  ("blob:https://example.com/uuid", null, ["blob:https://example.com/uuid", "blob:", "", "", "", "", "", "https://example.com/uuid", "", "", "https://example.com", ""]),
  ("file:///C:/x/y.txt", null, ["file:///C:/x/y.txt", "file:", "", "", "", "", "", "/C:/x/y.txt", "", "", "null", ""]),
  ("file://localhost/etc/hosts", null, ["file:///etc/hosts", "file:", "", "", "", "", "", "/etc/hosts", "", "", "null", ""]),
  ("file:///a/../b", null, ["file:///b", "file:", "", "", "", "", "", "/b", "", "", "null", ""]),
  ("foo://host/path", null, ["foo://host/path", "foo:", "", "", "host", "host", "", "/path", "", "", "null", ""]),
  ("foo:/path", null, ["foo:/path", "foo:", "", "", "", "", "", "/path", "", "", "null", ""]),
  ("foo:path", null, ["foo:path", "foo:", "", "", "", "", "", "path", "", "", "null", ""]),
  ("http://example.com/?a=b&c=d#e", null, ["http://example.com/?a=b&c=d#e", "http:", "", "", "example.com", "example.com", "", "/", "?a=b&c=d", "#e", "http://example.com", "a=b&c=d"]),
  ("http://example.com/?", null, ["http://example.com/?", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://example.com/#", null, ["http://example.com/#", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://example.com/ pa th?q u#f r", null, ["http://example.com/%20pa%20th?q%20u#f%20r", "http:", "", "", "example.com", "example.com", "", "/%20pa%20th", "?q%20u", "#f%20r", "http://example.com", "q+u="]),
  ("http://example.com/%2e%2E/x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("http://example.com/a%zz", null, ["http://example.com/a%zz", "http:", "", "", "example.com", "example.com", "", "/a%zz", "", "", "http://example.com", ""]),
  ("http://example.com/€/path?€=€#€", null, ["http://example.com/%E2%82%AC/path?%E2%82%AC=%E2%82%AC#%E2%82%AC", "http:", "", "", "example.com", "example.com", "", "/%E2%82%AC/path", "?%E2%82%AC=%E2%82%AC", "#%E2%82%AC", "http://example.com", "%E2%82%AC=%E2%82%AC"]),
  ("http://example.com/\"<>`{}", null, ["http://example.com/%22%3C%3E%60%7B%7D", "http:", "", "", "example.com", "example.com", "", "/%22%3C%3E%60%7B%7D", "", "", "http://example.com", ""]),
  ("http://example.com/?it's", null, ["http://example.com/?it%27s", "http:", "", "", "example.com", "example.com", "", "/", "?it%27s", "", "http://example.com", "it%27s="]),
  ("foo://example.com/?it's", null, ["foo://example.com/?it's", "foo:", "", "", "example.com", "example.com", "", "/", "?it's", "", "null", "it%27s="]),
  ("  http://example.com/x  ", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("ht\ttp://exa\nmple.com/x", null, ["http://example.com/x", "http:", "", "", "example.com", "example.com", "", "/x", "", "", "http://example.com", ""]),
  ("//example.org/path", "http://base.example/a/b", ["http://example.org/path", "http:", "", "", "example.org", "example.org", "", "/path", "", "", "http://example.org", ""]),
  ("/abs", "http://base.example/a/b?q#f", ["http://base.example/abs", "http:", "", "", "base.example", "base.example", "", "/abs", "", "", "http://base.example", ""]),
  ("rel", "http://base.example/a/b", ["http://base.example/a/rel", "http:", "", "", "base.example", "base.example", "", "/a/rel", "", "", "http://base.example", ""]),
  ("../up", "http://base.example/a/b/c", ["http://base.example/a/up", "http:", "", "", "base.example", "base.example", "", "/a/up", "", "", "http://base.example", ""]),
  ("?newquery", "http://base.example/a/b?old#f", ["http://base.example/a/b?newquery", "http:", "", "", "base.example", "base.example", "", "/a/b", "?newquery", "", "http://base.example", "newquery="]),
  ("#newhash", "http://base.example/a/b?q#f", ["http://base.example/a/b?q#newhash", "http:", "", "", "base.example", "base.example", "", "/a/b", "?q", "#newhash", "http://base.example", "q="]),
  ("", "http://base.example/a/b?q#f", ["http://base.example/a/b?q", "http:", "", "", "base.example", "base.example", "", "/a/b", "?q", "", "http://base.example", "q="]),
  (".", "http://base.example/a/b/c", ["http://base.example/a/b/", "http:", "", "", "base.example", "base.example", "", "/a/b/", "", "", "http://base.example", ""]),
  ("..", "http://base.example/a/b/c", ["http://base.example/a/", "http:", "", "", "base.example", "base.example", "", "/a/", "", "", "http://base.example", ""]),
  ("x", "file:///a/b", ["file:///a/x", "file:", "", "", "", "", "", "/a/x", "", "", "null", ""]),
  ("#f", "mailto:a@b.c", ["mailto:a@b.c#f", "mailto:", "", "", "", "", "", "a@b.c", "", "#f", "null", ""]),
  ("http://user@example.com/", null, ["http://user@example.com/", "http:", "user", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://us er:p@ss@example.com/", null, ["http://us%20er:p%40ss@example.com/", "http:", "us%20er", "p%40ss", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://@example.com/", null, ["http://example.com/", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http://:@example.com/", null, ["http://example.com/", "http:", "", "", "example.com", "example.com", "", "/", "", "", "http://example.com", ""]),
  ("http:///no-host", null, ["http://no-host/", "http:", "", "", "no-host", "no-host", "", "/", "", "", "http://no-host", ""]),
  ("http://example.com:0/", null, ["http://example.com:0/", "http:", "", "", "example.com:0", "example.com", "0", "/", "", "", "http://example.com:0", ""]),
  ("http://example.com:65535/", null, ["http://example.com:65535/", "http:", "", "", "example.com:65535", "example.com", "65535", "/", "", "", "http://example.com:65535", ""]),
  ("http://example.com:65536/", null, null),
  ("http://exa mple.com/", null, null),
  ("http://", null, null),
  ("://nope", null, null),
  ("1http://x", null, null),
  ("http://[1:2:3:4:5:6:7:8:9]/", null, null),
  ("http://256.1.1.1/", null, null),
  ("http://1.2.3.4.5/", null, null),
  ("ws://example.com/socket", null, ["ws://example.com/socket", "ws:", "", "", "example.com", "example.com", "", "/socket", "", "", "ws://example.com", ""]),
  ("ftp://example.com/f", null, ["ftp://example.com/f", "ftp:", "", "", "example.com", "example.com", "", "/f", "", "", "ftp://example.com", ""]),
];

/// (JS body, expected result as a string) — "THROWS:Name" when Node throws.
const _opCases = <(String, String)>[
  ("const u = new URL('http://a.example/p?x=1#h'); u.protocol = 'https'; return u.href;", "https://a.example/p?x=1#h"),
  ("const u = new URL('http://a.example/p'); u.protocol = 'mailto'; return u.href;", "http://a.example/p"),
  ("const u = new URL('http://a.example/p'); u.host = 'b.example:99'; return u.href;", "http://b.example:99/p"),
  ("const u = new URL('http://a.example:99/p'); u.hostname = 'c.example'; return u.href;", "http://c.example:99/p"),
  ("const u = new URL('http://a.example/p'); u.port = '8080'; return u.href;", "http://a.example:8080/p"),
  ("const u = new URL('http://a.example:8080/p'); u.port = ''; return u.href;", "http://a.example/p"),
  ("const u = new URL('http://a.example:8080/p'); u.port = '80'; return u.href;", "http://a.example/p"),
  ("const u = new URL('http://a.example/p'); u.pathname = '/q/r'; return u.href;", "http://a.example/q/r"),
  ("const u = new URL('http://a.example/p'); u.pathname = 'q r'; return u.href;", "http://a.example/q%20r"),
  ("const u = new URL('http://a.example/p'); u.search = 'a=b c'; return u.href;", "http://a.example/p?a=b%20c"),
  ("const u = new URL('http://a.example/p?x=1'); u.search = ''; return u.href + '|' + u.searchParams.size;", "http://a.example/p|0"),
  ("const u = new URL('http://a.example/p'); u.hash = 'frag ment'; return u.href;", "http://a.example/p#frag%20ment"),
  ("const u = new URL('http://a.example/p#h'); u.hash = ''; return u.href;", "http://a.example/p"),
  ("const u = new URL('http://a.example/p'); u.username = 'u v'; u.password = 'p@w'; return u.href;", "http://u%20v:p%40w@a.example/p"),
  ("const u = new URL('http://a.example/p'); u.href = 'https://b.example/q?z=9'; return u.href + '|' + u.searchParams.get('z');", "https://b.example/q?z=9|9"),
  ("const u = new URL('http://a.example/p?x=1&y=2'); u.searchParams.append('z', '3 4'); return u.href;", "http://a.example/p?x=1&y=2&z=3+4"),
  ("const u = new URL('http://a.example/p?x=1&y=2'); u.searchParams.delete('x'); return u.href;", "http://a.example/p?y=2"),
  ("const u = new URL('http://a.example/p?x=1'); u.searchParams.set('x', 'new'); u.searchParams.set('q', 'added'); return u.href;", "http://a.example/p?x=new&q=added"),
  ("const u = new URL('http://a.example/p?b=2&a=1&c=3'); u.searchParams.sort(); return u.search;", "?a=1&b=2&c=3"),
  ("const u = new URL('http://a.example/?a=1'); u.searchParams.delete('a'); return JSON.stringify([u.href, u.search]);", "[\"http://a.example/\",\"\"]"),
  ("const p = new URLSearchParams('a=1&b=2&a=3'); return JSON.stringify([p.getAll('a'), p.get('b'), p.has('a'), p.has('a', '3'), p.size, p.toString()]);", "[[\"1\",\"3\"],\"2\",true,true,3,\"a=1&b=2&a=3\"]"),
  ("const p = new URLSearchParams({ x: '1', y: 'two words' }); return p.toString();", "x=1&y=two+words"),
  ("const p = new URLSearchParams([['k', 'v'], ['k', 'w']]); return JSON.stringify([[...p.keys()], [...p.values()], [...p].map(e => e.join(':'))]);", "[[\"k\",\"k\"],[\"v\",\"w\"],[\"k:v\",\"k:w\"]]"),
  ("const p = new URLSearchParams('?a=%E2%82%AC&b=a+b&c'); return JSON.stringify([p.get('a'), p.get('b'), p.get('c')]);", "[\"\u20ac\",\"a b\",\"\"]"),
  ("const p = new URLSearchParams('a=1'); const seen = []; p.forEach((v, k) => seen.push(k + '=' + v)); return seen.join(',');", "a=1"),
  ("return JSON.stringify([URL.canParse('http://x.test'), URL.canParse('nope'), URL.parse('nope'), String(URL.parse('http://x.test'))]);", "[true,false,null,\"http://x.test/\"]"),
  ("return new URL('http://a.example/p').toJSON();", "http://a.example/p"),
  ("const u = new URL('http://a.example/p'); return JSON.stringify(u);", "\"http://a.example/p\""),
];

void main() {
  late QuickJsRuntime2 js;

  setUp(() {
    js = QuickJsRuntime2(timeout: 5000, webApis: const JsWebApis.standard());
  });
  tearDown(() => js.dispose());

  test('parsing matches Node field by field', () {
    final inputs = jsonEncode([
      for (final testCase in _parseCases) [testCase.$1, testCase.$2],
    ]);
    const script = r"""
      (function (cases) {
        return cases.map(function (entry) {
          try {
            const url = entry[1] === null ? new URL(entry[0]) : new URL(entry[0], entry[1]);
            return [url.href, url.protocol, url.username, url.password, url.host,
              url.hostname, url.port, url.pathname, url.search, url.hash, url.origin,
              url.searchParams.toString()];
          } catch (e) {
            return null;
          }
        });
      })""";
    final actual = js.evaluateJson('$script($inputs)') as List;

    final failures = <String>[];
    for (var i = 0; i < _parseCases.length; i++) {
      final (input, base, expected) = _parseCases[i];
      final got = actual[i] == null
          ? null
          : (actual[i] as List).map((v) => v as String).toList();
      if (expected == null ? got != null : !_listEquals(expected, got)) {
        failures.add('input=$input base=$base\n  node: $expected\n  qjs : $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('setters and URLSearchParams match Node', () {
    final failures = <String>[];
    for (final (body, expected) in _opCases) {
      final result = js.evaluate('(function () { $body })()');
      final got = result.isError
          ? 'THROWS:${_errorName(result.stringResult)}'
          : '${result.rawResult}';
      if (got != expected) {
        failures.add('$body\n  node: $expected\n  qjs : $got');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('URL objects are not structured-cloneable', () {
    final result = js.evaluate(
      r"""
      (() => { try { structuredClone(new URL('http://x.test')); return 'cloned'; }
        catch (e) { return e.name; } })()
      """,
    );
    expect(result.rawResult, 'DataCloneError');
  });
}

bool _listEquals(List<String> a, List<String>? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _errorName(String message) {
  final index = message.indexOf(':');
  return index < 0 ? message : message.substring(0, index);
}
