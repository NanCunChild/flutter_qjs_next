// Blob / File / FormData differential tests against Node.js 24.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

/// (async JS body, JSON.stringify of the result in Node).
const _cases = <(String, String)>[
  ("const blob = new Blob(['hello ', new Uint8Array([226, 130, 172]), new Blob(['!'])], { type: 'TEXT/Plain' });\n   return [blob.size, blob.type, await blob.text(), [...new Uint8Array(await blob.arrayBuffer())].length, [...(await blob.bytes())].slice(0, 3)];", "[10,\"text/plain\",\"hello \u20ac!\",10,[104,101,108]]"),
  ("const blob = new Blob(['0123456789']);\n   return [await blob.slice(2, 5).text(), await blob.slice(-3).text(), await blob.slice(5, 2).text(),\n     await blob.slice().text(), blob.slice(0, 4, 'text/plain').type];", "[\"234\",\"789\",\"\",\"0123456789\",\"text/plain\"]"),
  ("return [new Blob([], { type: 'a\\u0001b' }).type, new Blob([]).type, new Blob(['x'], { type: 'Text/HTML' }).type];", "[\"\",\"\",\"text/html\"]"),
  ("const blob = new Blob(['a\\r\\nb'], { endings: 'native' });\n   const raw = new Blob(['a\\r\\nb']);\n   return [await blob.text(), await raw.text()];", "[\"a\\nb\",\"a\\r\\nb\"]"),
  ("const blob = new Blob(['chunky']);\n   const chunks = [];\n   for await (const chunk of blob.stream()) chunks.push([...chunk]);\n   return chunks;", "[[99,104,117,110,107,121]]"),
  ("const file = new File(['data'], 'note.txt', { type: 'text/plain', lastModified: 1700000000000 });\n   return [file.name, file.size, file.type, file.lastModified, file instanceof Blob, await file.text()];", "[\"note.txt\",4,\"text/plain\",1700000000000,true,\"data\"]"),
  ("const fd = new FormData();\n   fd.append('a', '1');\n   fd.append('a', '2');\n   fd.append('file', new Blob(['xyz'], { type: 'text/plain' }), 'up.txt');\n   fd.set('b', '3');\n   fd.set('a', 'only');\n   const file = fd.get('file');\n   return [fd.getAll('a'), fd.get('b'), fd.has('missing'), [...fd.keys()],\n     file.name, file.type, await file.text(), file instanceof File];", "[[\"only\"],\"3\",false,[\"a\",\"file\",\"b\"],\"up.txt\",\"text/plain\",\"xyz\",true]"),
  ("const fd = new FormData();\n   fd.append('x', '1');\n   fd.delete('x');\n   const seen = [];\n   fd.append('k', 'v');\n   fd.forEach((value, key) => seen.push(key + '=' + value));\n   return [fd.get('x'), seen, [...fd].map((e) => e.join(':')), [...fd.values()]];", "[null,[\"k=v\"],[\"k:v\"],[\"v\"]]"),
  ("let error;\n   try { new FormData().append('name', 'value', 'file.txt'); } catch (e) { error = e.constructor.name; }\n   return [error];", "[\"TypeError\"]"),
  ("const blob = new Blob(['clone me'], { type: 'text/plain' });\n   const file = new File(['f'], 'f.txt', { lastModified: 5 });\n   const clonedBlob = structuredClone(blob);\n   const clonedFile = structuredClone(file);\n   return [await clonedBlob.text(), clonedBlob.type, clonedBlob !== blob,\n     clonedFile.name, clonedFile.lastModified, await clonedFile.text(), clonedFile instanceof File];", "[\"clone me\",\"text/plain\",true,\"f.txt\",5,\"f\",true]"),
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

  test('Blob, File and FormData behave like Node', () async {
    final failures = <String>[];
    for (final (body, expected) in _cases) {
      final actual = await run(body);
      if (actual != expected) {
        failures.add('$body\n  node: $expected\n  qjs : $actual');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });

  test('spec behaviours where Node differs', () async {
    // File API: webkitRelativePath exists (Node leaves it undefined).
    expect(js.evaluate(r"new File(['x'], 'n.txt').webkitRelativePath").rawResult, '');
    // endings 'native' also converts a lone CR (Node converts only CRLF).
    expect(
      await run(r"return await new Blob(['a\rb'], { endings: 'native' }).text();"),
      '"a\\nb"',
    );
    // FormData is serializable (Node throws DataCloneError).
    expect(
      await run(r"""
        const fd = new FormData();
        fd.append('k', new File(['f'], 'f.txt', { lastModified: 5 }));
        fd.append('plain', 'v');
        const copy = structuredClone(fd);
        return [copy.get('k').name, await copy.get('k').text(), copy.get('plain'), copy !== fd];
      """),
      '["f.txt","f","v",true]',
    );
  });
}
