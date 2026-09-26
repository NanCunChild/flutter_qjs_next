import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'js_eval_result.dart';
import 'quickjs/ffi.dart' show JsMemoryUsage;
import 'web/web_apis.dart';

export 'quickjs/ffi.dart' show JsMemoryUsage;

/// Default QuickJS heap limit for all runtime construction paths.
const int kDefaultJsMemoryLimit = 64 * 1024 * 1024;

/// Default QuickJS C-stack limit for all runtime construction paths.
///
/// It has to stay well below the OS thread stack, or the thread runs out of
/// stack before QuickJS reaches its own limit and can raise `InternalError:
/// stack overflow`. Windows threads get 1 MiB by default, where a 1 MiB limit
/// never triggers and a deeply nested value (`JSON.stringify` on 20 000 levels,
/// for instance) takes the process down; Linux and Apple threads start at
/// 8 MiB.
final int kDefaultJsStackSize = Platform.isWindows
    ? 256 * 1024
    : 1024 * 1024;

/// Resolves the public memory-limit contract: zero is unlimited, while null
/// and negative values fall back to the safe default.
int normalizeJsMemoryLimit(int? value) {
  if (value == 0) return 0;
  if (value == null || value < 0) return kDefaultJsMemoryLimit;
  return value;
}

class FlutterJsPlatformEmpty extends JavascriptRuntime {
  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) {
    throw UnimplementedError();
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    throw UnimplementedError();
  }

  @override
  void dispose() {}

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    throw UnimplementedError();
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    throw UnimplementedError();
  }

  @override
  int executePendingJob() {
    throw UnimplementedError();
  }

  @override
  String getEngineInstanceId() {
    throw UnimplementedError();
  }

  @override
  void initChannelFunctions() {
    throw UnimplementedError();
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    throw UnimplementedError();
  }

  @override
  dynamic evaluateJson(String code, {String? sourceUrl}) {
    throw UnimplementedError();
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic args) fn) {
    throw UnimplementedError();
  }

  @override
  void setInspectable(bool inspectable) {
    throw UnimplementedError();
  }
}

abstract class JavascriptRuntime {
  static bool debugEnabled = false;

  @protected
  JavascriptRuntime init() {
    initChannelFunctions();
    _webApiHost = WebApiHost.install(this, webApis, createWebNatives());
    return this;
  }

  /// Web platform APIs installed by [init] and reinstalled after resets.
  JsWebApis get webApis => const JsWebApis();

  /// Engine-specific native helpers handed to the Web API layer, or `null`.
  @protected
  Object? createWebNatives() => null;

  WebApiHost? _webApiHost;

  Map<String, dynamic> localContext = {};

  Map<String, dynamic> dartContext = {};

  void dispose();

  static final Map<String, Map<String, Function(dynamic arg)>>
  _channelFunctionsRegistered = {};

  static Map<String, Map<String, Function(dynamic arg)>>
  get channelFunctionsRegistered => _channelFunctionsRegistered;

  JsEvalResult evaluate(String code, {String? sourceUrl});

  /// Compile [code] to bytecode. [stripSource] drops function source text:
  /// a smaller heap, but `Function.prototype.toString` no longer shows it.
  ///
  /// With [asModule], [code] is compiled as an ES module and [fileName] becomes
  /// the name its importers resolve to. QuickJS resolves the module's imports
  /// while compiling it, so the engine's module handler must be able to reach
  /// every dependency, and compiling registers the module in the engine's
  /// current context — compile in a scratch engine rather than repeatedly in a
  /// long-lived one. [JsModuleBundle] does both for a whole import graph.
  Uint8List compile(
    String code,
    String fileName, {
    bool stripSource = false,
    bool asModule = false,
  }) {
    throw UnimplementedError();
  }

  /// Register module [bytecode] in the current context without running it, so
  /// that `import` of its name resolves from the context instead of calling the
  /// module loader. With [resolve], the module's own imports are linked now
  /// (every dependency must already be registered).
  ///
  /// Registration belongs to one context: after [softReset] / [reinitialize]
  /// the modules are gone and have to be registered again.
  void registerModuleBytecode(Uint8List bytecode, {bool resolve = false}) {
    throw UnimplementedError();
  }

  JsEvalResult evaluateBytecode(Uint8List bytecode) {
    throw UnimplementedError();
  }

  Future<JsEvalResult> evaluateAsyncBytecode(Uint8List bytecode) {
    throw UnimplementedError();
  }

  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl});

  dynamic evaluateJson(String code, {String? sourceUrl});

  /// Evaluate multiple JavaScript expressions and decode the results through
  /// one JSON round-trip. Expressions must be JSON-serializable and are
  /// evaluated in order in the same runtime.
  List<dynamic> evaluateJsonBatch(
    Iterable<String> expressions, {
    String? sourceUrl,
  }) {
    final items = expressions.toList(growable: false);
    if (items.isEmpty) return const [];
    final code = '[${items.map((expression) => '($expression)').join(',')}]';
    final result = evaluateJson(code, sourceUrl: sourceUrl);
    return (result as List<dynamic>?) ?? const [];
  }

  JsEvalResult callFunction(Pointer fn, Pointer obj);

  T? convertValue<T>(JsEvalResult jsValue);

  String jsonStringify(JsEvalResult jsValue);

  @protected
  void initChannelFunctions();

  int executePendingJob();

  /// Drain the QuickJS job queue until empty or [maxJobs] jobs run.
  /// Returns the number of jobs executed, or stops early on error (`-1` job).
  int executePendingJobs({int maxJobs = 10000}) {
    var n = 0;
    while (n < maxJobs) {
      final r = executePendingJob();
      if (r <= 0) break;
      n++;
    }
    return n;
  }

  /// Force a QuickJS GC pass. No-op if the engine is not ready / disposed.
  void runGC() {}

  /// QuickJS heap usage snapshot, or `null` if unavailable.
  JsMemoryUsage? getMemoryUsage() => null;

  /// Drop native heap and re-run channel / Web API setup.
  /// Used by [JsEnginePool] when resetting a leased engine. Default is no-op.
  void reinitialize() {}

  /// Clear tenant state without destroying the native QuickJS engine.
  ///
  /// Cancels pending timers and host work, wipes user globals (including global
  /// `var` / `let` / `const` bindings) and host maps, drops custom channels,
  /// then reinstalls the Web APIs. Prefer this over
  /// [reinitialize] when isolation is needed but process RSS under churn matters.
  /// Default is no-op; [QuickJsRuntime2] implements a real wipe.
  void softReset() {}

  /// Free Dart-side JS refs that must not outlive [close]; call before native free.
  /// Cancels Web API timers and host work installed by [init].
  @protected
  void releaseHostCaches() {
    final host = _webApiHost;
    _webApiHost = null;
    host?.dispose();
  }

  /// Dart → JS message helper. Prefer not to inject untrusted strings into
  /// [evaluate]; use registered bridges + `sendMessage` from JS instead.
  @Deprecated('Prefer JS-side sendMessage bridges; string eval is unsafe')
  void sendMessage({
    required String channelName,
    required List<String> args,
    String? uuid,
  }) {
    final safeChannel = jsonEncode(channelName);
    final safeArgs = jsonEncode(args);
    if (uuid != null) {
      final safeUuid = jsonEncode(uuid);
      evaluate(
        "DART_TO_QUICKJS_CHANNEL_sendMessage($safeChannel, $safeArgs, $safeUuid);",
      );
    } else {
      evaluate(
        "DART_TO_QUICKJS_CHANNEL_sendMessage($safeChannel, $safeArgs);",
      );
    }
  }

  void onMessage(String channelName, dynamic Function(dynamic args) fn) {
    setupBridge(channelName, fn);
  }

  bool setupBridge(String channelName, void Function(dynamic args) fn);

  String getEngineInstanceId();

  void setInspectable(bool inspectable);

  /// Removes channel registrations for this engine (call from [dispose]).
  void disposeChannelFunctions() {
    _channelFunctionsRegistered.remove(getEngineInstanceId());
  }
}
