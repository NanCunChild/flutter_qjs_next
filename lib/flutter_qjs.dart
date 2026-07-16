import 'package:flutter_qjs_next/javascript_runtime.dart';
import './quickjs/quickjs_runtime2.dart';
import './extensions/handle_promises.dart';

export './extensions/handle_promises.dart';
export './quickjs/quickjs_runtime2.dart';
export 'flutter_qjs_logger.dart';
export 'javascript_runtime.dart';
export 'js_engine_pool.dart';
export 'js_eval_result.dart';

/// Creates a [JavascriptRuntime] backed by QuickJS.
///
/// **Limits** (also via [extraArgs] keys `stackSize`, `timeout`, `memoryLimit`):
/// - [stackSize]: JS stack bytes (default 1 MiB)
/// - [timeout]: interrupt after this many ms of wall-clock JS work
///   (`null` / `0` = off). Prefer a positive value for untrusted scripts.
/// - [memoryLimit]: heap limit bytes (default [kDefaultJsMemoryLimit];
///   `0` = unlimited; null and negative values use the default).
///
/// Each runtime is a separate QuickJS engine (own heap, channels, port).
/// Prefer [JsEnginePool] when many short-lived scripts run in parallel.
///
/// [forceJavascriptCoreOnAndroid] and [xhr] are kept for flutter_js-compatible
/// call sites but are ignored (always QuickJS; no built-in XHR).
JavascriptRuntime getJavascriptRuntime({
  bool forceJavascriptCoreOnAndroid = false,
  bool xhr = true,
  Map<String, dynamic>? extraArgs = const {},
  int stackSize = 1024 * 1024,
  int? timeout,
  int? memoryLimit = kDefaultJsMemoryLimit,
}) {
  final resolvedStack = (extraArgs?['stackSize'] as int?) ?? stackSize;
  final resolvedTimeout = (extraArgs?['timeout'] as int?) ?? timeout;
  final resolvedMemory = (extraArgs?['memoryLimit'] as int?) ?? memoryLimit;

  final runtime = QuickJsRuntime2(
    stackSize: resolvedStack,
    timeout: resolvedTimeout,
    memoryLimit: resolvedMemory,
  );
  runtime.enableHandlePromises();
  return runtime;
}
