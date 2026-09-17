import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_qjs_next/javascript_runtime.dart';
import 'package:flutter_qjs_next/js_eval_result.dart';
import 'package:flutter_qjs_next/quickjs/quickjs_runtime2.dart';
import 'package:flutter_qjs_next/web/web_apis.dart' show JsWebApis;

/// A set of ES modules compiled to QuickJS bytecode ahead of time.
///
/// Loading modules from source makes QuickJS call the module loader for every
/// `import`, which is synchronous in the engine. A bundle resolves the whole
/// import graph once, at build time: [install] registers every module in the
/// context first, so evaluating the entry links against modules that are
/// already there and the loader is never called.
///
/// ```dart
/// final bundle = JsModuleBundle.compileSources(
///   entry: 'main.js',
///   sources: {
///     'main.js': "import {greet} from './greet.js'; globalThis.out = greet();",
///     'greet.js': "export const greet = () => 'hi';",
///   },
/// );
/// final runtime = getJavascriptRuntime();
/// final result = bundle.evaluate(runtime);
/// ```
///
/// Module names are the specifiers `import` resolves to. QuickJS normalizes
/// only a leading `./` / `../` against the importing module's name, so keys
/// should be paths relative to one common root (`'main.js'`, `'lib/util.js'`).
///
/// Bytecode is tied to the QuickJS build shipped with this package. Compile in
/// the same process (or the same app version) that evaluates it; see
/// `doc/wiki/api/bytecode.md`.
class JsModuleBundle {
  const JsModuleBundle({required this.entry, required this.modules});

  /// Module name of the entry point; must be a key of [modules].
  final String entry;

  /// Module name to compiled bytecode, including [entry].
  final Map<String, Uint8List> modules;

  static const _magic = 0x514a5342; // 'QJSB'
  static const _formatVersion = 1;

  /// Compile [sources] (module name → source text) into a bundle.
  ///
  /// Compilation runs in a scratch engine so the peak parser cost is not
  /// charged to the engine that later runs the code. When [verify] is set the
  /// import graph is linked (but not executed) and a missing module fails here
  /// instead of at the first `import` at runtime.
  ///
  /// [stripSource] drops function source text, which shrinks both the bytecode
  /// and the runtime heap at the cost of `Function.prototype.toString`.
  static JsModuleBundle compileSources({
    required String entry,
    required Map<String, String> sources,
    bool stripSource = true,
    bool verify = true,
  }) {
    if (!sources.containsKey(entry)) {
      throw ArgumentError.value(
        entry,
        'entry',
        'entry module is not present in sources',
      );
    }
    final modules = <String, Uint8List>{};
    final missing = <String>{};
    // QuickJS resolves a module's imports while compiling it, so the scratch
    // engine has to be able to reach every dependency. Serving them from
    // [sources] is also what turns an incomplete graph into an error here
    // instead of at the first import at runtime.
    final scratch = QuickJsRuntime2(
      memoryLimit: 0,
      webApis: const JsWebApis.none(),
      moduleHandler: (name) {
        final source = sources[name];
        if (source == null) {
          missing.add(name);
          throw JSError('module "$name" is not in sources');
        }
        return source;
      },
    );
    try {
      sources.forEach((name, source) {
        missing.clear();
        try {
          modules[name] = scratch.compile(
            source,
            name,
            stripSource: stripSource,
            asModule: true,
          );
        } on JSError catch (error) {
          if (missing.isEmpty) rethrow;
          throw JSError(
            '$name imports ${missing.join(', ')}, which '
            '${missing.length == 1 ? 'is' : 'are'} not in sources',
            error.stack,
          );
        }
      });
    } finally {
      scratch.dispose();
    }
    final bundle = JsModuleBundle(entry: entry, modules: modules);
    if (verify) bundle.verify();
    return bundle;
  }

  /// Link the import graph in a scratch engine without executing any module.
  /// Throws a [JSError] naming the specifiers that are not part of the bundle.
  void verify() {
    final missing = <String>[];
    final scratch = QuickJsRuntime2(
      memoryLimit: 0,
      webApis: const JsWebApis.none(),
      moduleHandler: (name) {
        missing.add(name);
        throw JSError('module "$name" is not part of the bundle');
      },
    );
    try {
      install(scratch, resolveEntry: true);
    } on JSError catch (error) {
      if (missing.isEmpty) rethrow;
      throw JSError(
        'JsModuleBundle("$entry") is incomplete: missing '
        '${missing.toSet().join(', ')}',
        error.stack,
      );
    } finally {
      scratch.dispose();
    }
  }

  /// Register every module of the bundle in [runtime]'s current context
  /// without running it. Call once per context (after a reset, register again).
  ///
  /// With [resolveEntry] the entry's imports are linked immediately, which
  /// surfaces a missing or mismatched module before any code runs.
  void install(JavascriptRuntime runtime, {bool resolveEntry = false}) {
    final entryBytecode = modules[entry];
    if (entryBytecode == null) {
      throw ArgumentError.value(entry, 'entry', 'entry module is missing');
    }
    modules.forEach((name, bytecode) {
      if (name == entry) return;
      runtime.registerModuleBytecode(bytecode);
    });
    runtime.registerModuleBytecode(entryBytecode, resolve: resolveEntry);
  }

  /// [install] the bundle and evaluate its entry module.
  ///
  /// Module evaluation is asynchronous in QuickJS: the result wraps the
  /// module's evaluation promise, so `await`
  /// [HandlePromises.handlePromise] (or [JsEvalResult.rawResult] as a
  /// `Future`) to observe a top-level `await` or an import failure.
  JsEvalResult evaluate(JavascriptRuntime runtime) {
    install(runtime);
    return runtime.evaluateBytecode(modules[entry]!);
  }

  /// Serialize to a single blob (for an asset, a cache file, or a message to
  /// another isolate).
  Uint8List toBytes() {
    final entryBytes = utf8.encode(entry);
    var length = 4 + 4 + 4 + entryBytes.length + 4;
    final names = <List<int>>[];
    for (final name in modules.keys) {
      final nameBytes = utf8.encode(name);
      names.add(nameBytes);
      length += 4 + nameBytes.length + 4 + modules[name]!.length;
    }
    final out = Uint8List(length);
    final view = ByteData.view(out.buffer);
    var offset = 0;
    void putUint32(int value) {
      view.setUint32(offset, value, Endian.little);
      offset += 4;
    }

    void putBytes(List<int> bytes) {
      out.setRange(offset, offset + bytes.length, bytes);
      offset += bytes.length;
    }

    putUint32(_magic);
    putUint32(_formatVersion);
    putUint32(entryBytes.length);
    putBytes(entryBytes);
    putUint32(modules.length);
    var i = 0;
    for (final bytecode in modules.values) {
      putUint32(names[i].length);
      putBytes(names[i]);
      putUint32(bytecode.length);
      putBytes(bytecode);
      i++;
    }
    return out;
  }

  /// Inverse of [toBytes].
  factory JsModuleBundle.fromBytes(Uint8List bytes) {
    final view = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    var offset = 0;
    int takeUint32(String field) {
      if (offset + 4 > bytes.length) {
        throw FormatException('JsModuleBundle: truncated at $field');
      }
      final value = view.getUint32(offset, Endian.little);
      offset += 4;
      return value;
    }

    Uint8List takeBytes(int length, String field) {
      if (length < 0 || offset + length > bytes.length) {
        throw FormatException('JsModuleBundle: truncated at $field');
      }
      final value = Uint8List.sublistView(bytes, offset, offset + length);
      offset += length;
      return value;
    }

    if (takeUint32('magic') != _magic) {
      throw const FormatException('JsModuleBundle: bad magic');
    }
    final version = takeUint32('version');
    if (version != _formatVersion) {
      throw FormatException('JsModuleBundle: unsupported format v$version');
    }
    final entry = utf8.decode(takeBytes(takeUint32('entry length'), 'entry'));
    final count = takeUint32('module count');
    final modules = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final name = utf8.decode(takeBytes(takeUint32('name length'), 'name'));
      modules[name] = Uint8List.fromList(
        takeBytes(takeUint32('bytecode length'), 'bytecode'),
      );
    }
    return JsModuleBundle(entry: entry, modules: modules);
  }

  @override
  String toString() =>
      'JsModuleBundle(entry: $entry, modules: ${modules.length}, '
      'bytes: ${modules.values.fold<int>(0, (sum, b) => sum + b.length)})';
}
