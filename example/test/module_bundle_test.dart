import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

const _sources = <String, String>{
  'main.js': '''
    import { greet } from './lib/greet.js';
    import { VERSION } from './lib/meta.js';
    globalThis.result = greet('world') + '@' + VERSION;
  ''',
  'lib/greet.js': '''
    import { VERSION } from './meta.js';
    export const greet = (who) => 'hello ' + who + ' v' + VERSION;
  ''',
  'lib/meta.js': "export const VERSION = '1';",
};

void main() {
  test('bundle resolves the import graph without a module handler', () async {
    final bundle = JsModuleBundle.compileSources(
      entry: 'main.js',
      sources: _sources,
    );
    expect(bundle.modules.keys, containsAll(_sources.keys));

    final js = getJavascriptRuntime();
    try {
      final started = bundle.evaluate(js);
      expect(started.isError, isFalse, reason: started.stringResult);
      await js.handlePromise(started, timeout: const Duration(seconds: 10));
      expect(js.evaluate('globalThis.result').stringResult, 'hello world v1@1');
    } finally {
      js.dispose();
    }
  });

  test('registered modules are importable from evaluated module source', () async {
    final bundle = JsModuleBundle.compileSources(
      entry: 'lib/meta.js',
      sources: {'lib/meta.js': _sources['lib/meta.js']!},
    );
    final js = getJavascriptRuntime() as QuickJsRuntime2;
    try {
      bundle.install(js);
      final started = js.evaluate(
        "import { VERSION } from './lib/meta.js'; globalThis.v = VERSION;",
        name: 'entry.js',
        evalFlags: JSEvalFlag.MODULE,
      );
      expect(started.isError, isFalse, reason: started.stringResult);
      await js.handlePromise(started, timeout: const Duration(seconds: 10));
      expect(js.evaluate('globalThis.v').stringResult, '1');
    } finally {
      js.dispose();
    }
  });

  test('verify reports modules that are missing from the bundle', () {
    expect(
      () => JsModuleBundle.compileSources(
        entry: 'main.js',
        sources: {'main.js': _sources['main.js']!},
      ),
      throwsA(
        isA<JSError>().having(
          (e) => e.message,
          'message',
          allOf(contains('not in sources'), contains('lib/greet.js')),
        ),
      ),
    );
  });

  test('bundle survives a toBytes / fromBytes round trip', () async {
    final bundle = JsModuleBundle.compileSources(
      entry: 'main.js',
      sources: _sources,
    );
    final restored = JsModuleBundle.fromBytes(bundle.toBytes());
    expect(restored.entry, bundle.entry);
    expect(restored.modules.keys, bundle.modules.keys);
    for (final name in bundle.modules.keys) {
      expect(restored.modules[name], bundle.modules[name], reason: name);
    }

    final js = getJavascriptRuntime();
    try {
      await js.handlePromise(
        restored.evaluate(js),
        timeout: const Duration(seconds: 10),
      );
      expect(js.evaluate('globalThis.result').stringResult, 'hello world v1@1');
    } finally {
      js.dispose();
    }
  });

  test('fromBytes rejects a corrupt blob', () {
    expect(
      () => JsModuleBundle.fromBytes(Uint8List.fromList([1, 2, 3, 4, 5, 6])),
      throwsA(isA<FormatException>()),
    );
  });

  test('IsolateQjs evaluates a bundle without any module round trip', () async {
    final bundle = JsModuleBundle.compileSources(
      entry: 'main.js',
      sources: _sources,
    );
    final qjs = IsolateQjs(bundle: bundle);
    try {
      await qjs.evaluateBundleEntry();
      expect(await qjs.evaluate('globalThis.result'), 'hello world v1@1');
    } finally {
      await qjs.close();
    }
  });

  test('IsolateQjs resolves moduleSources locally', () async {
    final qjs = IsolateQjs(moduleSources: _sources);
    try {
      expect(
        await qjs.evaluate(
          "import { greet } from './lib/greet.js'; globalThis.r = greet('a');",
          name: 'entry.js',
          evalFlags: JSEvalFlag.MODULE,
        ),
        isNull,
      );
      expect(await qjs.evaluate('globalThis.r'), 'hello a v1');
    } finally {
      await qjs.close();
    }
  });

  test('IsolateQjs without any module source reports the missing name',
      () async {
    final qjs = IsolateQjs();
    try {
      await expectLater(
        qjs.evaluate(
          "import './nope.js';",
          name: 'entry.js',
          evalFlags: JSEvalFlag.MODULE,
        ),
        throwsA(isA<JSError>()),
      );
    } finally {
      await qjs.close();
    }
  });
}
