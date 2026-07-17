/* START PARTS IMPORT QJS ENGINE */
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_qjs_next/flutter_qjs_logger.dart';
import 'package:flutter_qjs_next/javascript_runtime.dart';
import 'package:flutter_qjs_next/js_eval_result.dart';

import 'ffi.dart';

export 'ffi.dart'
    show JSEvalFlag, JSRef, JSTypedArrayType, JsTypedArrayTransfer;

part 'isolate.dart';
part 'object.dart';
part 'wrapper.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

int _nextEngineSerial = 0;

String _newEngineInstanceId() =>
    'qjs-${Isolate.current.hashCode}-${_nextEngineSerial++}-'
    '${DateTime.now().microsecondsSinceEpoch}';

/// Quickjs engine for flutter.
class QuickJsRuntime2 extends JavascriptRuntime {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;
  Pointer<JSValue>? _jsonStringifyFn;

  /// Stable unique id for channel maps (not [identityHashCode]).
  late String _engineInstanceId = _newEngineInstanceId();

  bool _disposed = false;
  bool _needsInitialization = false;

  /// When true (default), [evaluate] / [evaluateJson] / [callFunction] drain
  /// Promise microtasks via [executePendingJobs] after the call.
  bool autoExecutePendingJobs;

  /// Max stack size for quickjs.
  int stackSize;

  /// Interrupt after this many ms of wall-clock JS work (`null`/`0` = off).
  final int? timeout;

  /// Heap limit bytes (`null`/`0` = unlimited).
  final int? memoryLimit;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  QuickJsRuntime2({
    this.moduleHandler,
    this.stackSize = 1024 * 1024,
    this.timeout,
    int? memoryLimit = kDefaultJsMemoryLimit,
    this.hostPromiseRejectionHandler,
    this.autoExecutePendingJobs = true,
  }) : memoryLimit = normalizeJsMemoryLimit(memoryLimit) {
    this.init();
  }

  void _ensureEngine() {
    if (_disposed) {
      throw StateError('QuickJsRuntime2 is disposed');
    }
    if (_rt != null) return;
    final resolvedMemoryLimit = this.memoryLimit ?? 0;
    final rt = jsNewRuntime(
      (ctx, type, ptr) {
        try {
          switch (type) {
            case JSChannelType.METHON:
              final pdata = ptr.cast<Pointer<JSValue>>();
              final argc = (pdata + 1).value.cast<Int32>().value;
              final pargs = [];
              for (var i = 0; i < argc; ++i) {
                pargs.add(
                  _jsToDart(
                    ctx,
                    Pointer.fromAddress(
                      (pdata + 2).value.address + sizeOfJSValue * i,
                    ),
                  ),
                );
              }
              final JSInvokable func = _jsToDart(ctx, (pdata + 3).value);
              return _dartToJs(
                ctx,
                func.invoke(pargs, _jsToDart(ctx, (pdata + 0).value)),
              );
            case JSChannelType.MODULE:
              if (moduleHandler == null) throw JSError('No ModuleHandler');
              // Ownership transferred to native js_module_loader (free(str)).
              final ret = moduleHandler!(
                ptr.cast<Utf8>().toDartString(),
              ).toNativeUtf8();
              return ret.cast();
            case JSChannelType.PROMISE_TRACK:
              final err = _parseJSException(ctx, ptr);
              if (hostPromiseRejectionHandler != null) {
                hostPromiseRejectionHandler!(err);
              } else {
                FlutterQjsLogger.warning('Unhandled promise rejection', err);
              }
              return nullptr;
            case JSChannelType.FREE_OBJECT:
              final rt = ctx.cast<JSRuntime>();
              _DartObject.fromAddress(rt, ptr.address)?.free();
              return nullptr;
          }
          throw JSError('call channel with wrong type');
        } catch (e) {
          if (type == JSChannelType.FREE_OBJECT) {
            FlutterQjsLogger.error('DartObject release error', e);
            return nullptr;
          }
          if (type == JSChannelType.MODULE) {
            FlutterQjsLogger.error('Module handler error', e);
            return nullptr;
          }
          final throwObj = _dartToJs(ctx, e);
          final err = jsThrow(ctx, throwObj);
          jsFreeValue(ctx, throwObj);
          return err;
        }
      },
      timeout ?? 0,
      port,
      memoryLimit: resolvedMemoryLimit,
    );
    final stackSize = this.stackSize;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    if (resolvedMemoryLimit > 0) {
      jsSetMemoryLimit(rt, resolvedMemoryLimit);
    }
    _rt = rt;
    _ctx = jsNewContext(rt);
    if (_needsInitialization) {
      _needsInitialization = false;
      init();
    }
  }

  /// Free Runtime and Context. After [dispose], the engine cannot be reopened.
  /// After [close] without [dispose], the next [evaluate] recreates the engine.
  void close() {
    try {
      releaseHostCaches();
    } catch (_) {}
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null) return;
    try {
      _executePendingJob();
    } catch (_) {}
    if (ctx != null) {
      final jsonStringifyFn = _jsonStringifyFn;
      _jsonStringifyFn = null;
      if (jsonStringifyFn != null) {
        try {
          jsFreeValue(ctx, jsonStringifyFn);
        } catch (_) {}
      }
      try {
        jsFreeContext(ctx);
      } catch (_) {}
    }
    _rt = null;
    _ctx = null;
    localContext.clear();
    dartContext.clear();
    _needsInitialization = true;
    try {
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  /// Drop native heap + channels and re-run [init] (console, setTimeout, bridges).
  /// Used by [JsEnginePool] when `resetOnRelease` is true.
  @override
  void reinitialize() {
    if (_disposed) {
      throw StateError('QuickJsRuntime2 is disposed');
    }
    try {
      close();
    } catch (_) {}
    try {
      disposeChannelFunctions();
    } catch (_) {}
    localContext.clear();
    dartContext.clear();
    _engineInstanceId = _newEngineInstanceId();
    _needsInitialization = false;
    init();
  }

  void _maybeDrainJobs() {
    if (!autoExecutePendingJobs || _rt == null || _disposed) return;
    try {
      executePendingJobs();
    } catch (_) {}
  }

  void _executePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return;
    while (true) {
      int err = jsExecutePendingJob(rt);
      if (err <= 0) {
        if (err < 0) {
          FlutterQjsLogger.error(
            'Pending JavaScript job failed',
            _parseJSException(ctx),
          );
        }
        break;
      }
    }
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    await for (final _ in port) {
      _executePendingJob();
    }
  }

  @override
  void runGC() {
    final rt = _rt;
    if (rt == null || _disposed) return;
    jsRunGC(rt);
  }

  @override
  JsMemoryUsage? getMemoryUsage() {
    final rt = _rt;
    if (rt == null || _disposed) return null;
    return jsComputeMemoryUsage(rt);
  }

  @override
  void setInspectable(bool inspectable) {
    // Nothing to do.
  }

  /// Evaluate js script.
  JsEvalResult evaluate(
    String command, {
    String? name,
    int? evalFlags,
    String? sourceUrl,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      name ?? sourceUrl ?? '<eval>',
      evalFlags ?? JSEvalFlag.GLOBAL,
    );

    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      JSError exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }
    final result = _jsToDart(ctx, jsval);
    final isPromise = result is Future;
    jsFreeValue(ctx, jsval);
    _maybeDrainJobs();
    return JsEvalResult(
      result?.toString() ?? "null",
      result,
      isPromise: isPromise,
      isError: result is JSError,
    );
  }

  /// Evaluate js script and decode the result via a single `JSON.stringify`
  /// round-trip instead of recursive per-element FFI marshaling.
  ///
  /// This is dramatically faster for large arrays/objects, but the result must
  /// be JSON-serializable: functions, Promises and cyclic references are not
  /// supported (they decode to `null` / are dropped, as with `JSON.stringify`).
  @override
  dynamic evaluateJson(String command, {String? sourceUrl}) {
    _ensureEngine();
    final ctx = _ctx!;
    final jsval = jsEval(
      ctx,
      command,
      sourceUrl ?? '<eval>',
      JSEvalFlag.GLOBAL,
    );
    if (jsIsException(jsval) != 0) {
      jsFreeValue(ctx, jsval);
      throw _parseJSException(ctx);
    }
    final fnStringify = _jsonStringifyFn ??= jsEval(
      ctx,
      'JSON.stringify',
      '<json>',
      JSEvalFlag.GLOBAL,
    );
    final thisObj = jsUNDEFINED();
    final jsonVal = jsCall(ctx, fnStringify, thisObj, [jsval]);
    jsFreeValue(ctx, thisObj);
    jsFreeValue(ctx, jsval);
    if (jsIsException(jsonVal) != 0) {
      jsFreeValue(ctx, jsonVal);
      throw _parseJSException(ctx);
    }
    if (jsValueGetTag(jsonVal) != JSTag.STRING) {
      jsFreeValue(ctx, jsonVal);
      return null;
    }
    final jsonStr = jsToCString(ctx, jsonVal);
    jsFreeValue(ctx, jsonVal);
    _maybeDrainJobs();
    return jsonDecode(jsonStr);
  }

  JsEvalResult evaluateBytecode(Uint8List bytecode) {
    _ensureEngine();
    final ctx = _ctx!;
    final Pointer<Uint8> pointer = calloc<Uint8>(bytecode.length);
    pointer.asTypedList(bytecode.length).setAll(0, bytecode);

    final value = evaluateBytecodeFn(ctx, bytecode.length, pointer);

    calloc.free(pointer);

    if (value.address == 0 || jsIsException(value) != 0) {
      if (value.address != 0) jsFreeValue(ctx, value);
      JSError exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }

    final result = _jsToDart(ctx, value);
    jsFreeValue(ctx, value);
    _maybeDrainJobs();
    return JsEvalResult(
      result?.toString() ?? "null",
      result,
      isPromise: result is Future,
      isError: result is JSError,
    );
  }

  @override
  Uint8List compile(String script, String fileName) {
    _ensureEngine();
    final ctx = _ctx!;
    final scriptPtr = script.toNativeUtf8().cast<Char>();
    final fileNamePtr = fileName.toNativeUtf8().cast<Char>();
    final lengthPtr = calloc<IntPtr>();
    final value = compileFn(ctx, scriptPtr, fileNamePtr, lengthPtr);
    try {
      if (value.address == 0) {
        throw _parseJSException(ctx);
      }
      final length = lengthPtr.value;
      return Uint8List.fromList(value.asTypedList(length));
    } finally {
      if (value.address != 0) {
        calloc.free(value);
      }
      calloc.free(scriptPtr);
      calloc.free(fileNamePtr);
      calloc.free(lengthPtr);
    }
  }

  @override
  Future<JsEvalResult> evaluateAsyncBytecode(Uint8List bytecode) {
    return Future.value(evaluateBytecode(bytecode));
  }

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) {
    _ensureEngine();
    final ctx = _ctx!;
    final func = fn.cast<JSValue>();
    final thisObj = obj.cast<JSValue>();
    final jsRet = jsCall(ctx, func, thisObj, const []);
    if (jsIsException(jsRet) != 0) {
      jsFreeValue(ctx, jsRet);
      final exception = _parseJSException(ctx);
      return JsEvalResult(exception.toString(), exception, isError: true);
    }
    final result = _jsToDart(ctx, jsRet);
    jsFreeValue(ctx, jsRet);
    _maybeDrainJobs();
    return JsEvalResult(
      result?.toString() ?? 'null',
      result,
      isPromise: result is Future,
      isError: result is JSError,
    );
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    final raw = jsValue.rawResult;
    if (raw is T) return raw;
    return null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      disposeChannelFunctions();
    } catch (e) {
      FlutterQjsLogger.error('disposeChannelFunctions failed', e);
    }
    try {
      port.close();
    } catch (_) {}
    try {
      close();
    } on JSError catch (e) {
      // Surface unreclaimed JSRef (functions/objects) so callers can detect leaks.
      if (e.message.contains('reference leak')) rethrow;
      FlutterQjsLogger.error('QuickJS dispose failed', e);
    } catch (e) {
      FlutterQjsLogger.error('QuickJS dispose failed', e);
    }
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return Future.value(evaluate(code, sourceUrl: sourceUrl));
  }

  @override
  int executePendingJob() {
    final rt = _rt;
    if (rt == null) return 0;
    final err = jsExecutePendingJob(rt);
    if (err < 0 && _ctx != null) {
      FlutterQjsLogger.error(
        'Pending JavaScript job failed',
        _parseJSException(_ctx!),
      );
    }
    return err;
  }

  /// True if QuickJS has at least one pending job (Promise reactions, etc.).
  bool get hasPendingJobs {
    final rt = _rt;
    if (rt == null || _disposed) return false;
    return jsIsJobPending(rt) != 0;
  }

  @override
  String getEngineInstanceId() => _engineInstanceId;

  @override
  void initChannelFunctions() {
    JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()] = {};
    final setToGlobalObject = evaluate(
      "(key, val) => { this[key] = val; }",
    ).rawResult;
    (setToGlobalObject as JSInvokable).invoke([
      'sendMessage',
      (String channelName, dynamic message) {
        final channelFunctions = JavascriptRuntime
            .channelFunctionsRegistered[getEngineInstanceId()];

        if (channelFunctions == null ||
            !channelFunctions.containsKey(channelName)) {
          FlutterQjsLogger.warning('No channel $channelName registered');
          return null;
        }

        dynamic payload = message;
        if (message is String) {
          try {
            payload = jsonDecode(message);
          } catch (_) {
            payload = message;
          }
        }
        return channelFunctions[channelName]!.call(payload);
      },
    ]);
    (setToGlobalObject as JSRef).free();
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    return jsonEncode(jsValue.rawResult);
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic args) fn) {
    final channelFunctionCallbacks =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    if (channelFunctionCallbacks.keys.contains(channelName)) return false;

    channelFunctionCallbacks[channelName] = fn;

    return true;
  }
}
