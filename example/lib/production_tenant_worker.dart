// Reference production posture for multi-tenant / high-churn scripts.
// See doc/wiki/guides/production-checklist.md and
// doc/wiki/recipes/multi-tenant-pool.md.
//
// Patterns:
// - JsEnginePool with modest maxSize
// - EngineResetMode.soft between tenants (prefer over hard)
// - evaluateJson for data-only results; evaluate for mixed/callable
// - TypedArray / Uint8List for binary (not number[])
// - Cache JSInvokable across calls within a lease; free() when done
// - Cap large Dart→JS buffer size / frequency
// - dispose the pool at feature/app teardown
// - do not call getJavascriptRuntime() per request

import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';

/// Snapshot of engine + bridge counters for host metrics (pair with process RSS).
class TenantWorkerDiagnostics {
  TenantWorkerDiagnostics({
    required this.poolSize,
    required this.idleCount,
    required this.inUseCount,
    required this.poolResetCount,
    required this.memoryUsage,
    required this.bridgeStats,
  });

  final int poolSize;
  final int idleCount;
  final int inUseCount;
  final int poolResetCount;
  final JsMemoryUsage? memoryUsage;
  final Map<String, int> bridgeStats;

  @override
  String toString() =>
      'TenantWorkerDiagnostics(pool=$poolSize idle=$idleCount inUse=$inUseCount '
      'resets=$poolResetCount mem=$memoryUsage bridge=$bridgeStats)';
}

/// Limits for hot-path Dart → JS bulk copies (bridge is copy-based, not zero-copy).
class TenantPayloadBudget {
  const TenantPayloadBudget({
    this.maxDartToJsBytes = 4 * 1024 * 1024,
    this.maxEvaluateJsonChars = 8 * 1024 * 1024,
  });

  /// Reject [ProductionTenantWorker.pushBytes] above this size.
  final int maxDartToJsBytes;

  /// Soft guard for source length on [asJson] evaluate paths (0 = off).
  final int maxEvaluateJsonChars;
}

/// Bounded multi-tenant worker. Own and [dispose] at shutdown.
///
/// Prefer this over `getJavascriptRuntime()` per request. Multi-tenant default
/// is [EngineResetMode.soft]; use [ProductionTenantWorker.warmReuse] when the
/// same trusted globals may stay warm across leases.
class ProductionTenantWorker {
  ProductionTenantWorker({
    int maxSize = 4,
    int timeoutMs = 2000,
    int memoryLimit = 32 * 1024 * 1024,
    EngineResetMode resetMode = EngineResetMode.soft,
    this.payloadBudget = const TenantPayloadBudget(),
  }) : _pool = JsEnginePool(
          maxSize: maxSize,
          config: JsEnginePoolConfig(
            timeout: timeoutMs,
            memoryLimit: memoryLimit,
            resetMode: resetMode,
          ),
        );

  /// Same-tenant / trusted warm reuse (best RSS; no global wipe between leases).
  factory ProductionTenantWorker.warmReuse({
    int maxSize = 4,
    int timeoutMs = 3000,
    int memoryLimit = 64 * 1024 * 1024,
    TenantPayloadBudget payloadBudget = const TenantPayloadBudget(),
  }) {
    return ProductionTenantWorker(
      maxSize: maxSize,
      timeoutMs: timeoutMs,
      memoryLimit: memoryLimit,
      resetMode: EngineResetMode.none,
      payloadBudget: payloadBudget,
    );
  }

  final JsEnginePool _pool;
  final TenantPayloadBudget payloadBudget;
  bool _disposed = false;

  int get idleCount => _pool.idleCount;
  int get inUseCount => _pool.inUseCount;
  int get size => _pool.size;
  int get resetCount => _pool.resetCount;

  /// Run a script with isolation policy from pool [EngineResetMode].
  ///
  /// [asJson] uses [JavascriptRuntime.evaluateJson] (throws on error; no
  /// functions/Promises in the result tree).
  /// Otherwise uses [JavascriptRuntime.evaluate] and throws if [JsEvalResult.isError].
  ///
  /// Re-register host bridges in [setup] when using soft/hard reset.
  Future<Object?> run(
    String source, {
    bool asJson = false,
    void Function(JavascriptRuntime js)? setup,
  }) {
    _ensureOpen();
    if (asJson &&
        payloadBudget.maxEvaluateJsonChars > 0 &&
        source.length > payloadBudget.maxEvaluateJsonChars) {
      throw ArgumentError.value(
        source.length,
        'source.length',
        'exceeds maxEvaluateJsonChars=${payloadBudget.maxEvaluateJsonChars}',
      );
    }
    return _pool.withEngine((js) async {
      setup?.call(js);
      if (asJson) {
        return js.evaluateJson(source);
      }
      final r = js.evaluate(source);
      if (r.isError) {
        throw StateError(r.stringResult);
      }
      return r.rawResult;
    });
  }

  /// Evaluate once to a [JSInvokable], invoke many times, then free.
  ///
  /// Prefer this over re-evaluating the same function expression each call.
  Future<List<Object?>> mapWithCachedFunction(
    String functionSource,
    List<List<Object?>> callArgs, {
    void Function(JavascriptRuntime js)? setup,
  }) {
    _ensureOpen();
    return _pool.withEngine((js) async {
      setup?.call(js);
      final r = js.evaluate(functionSource);
      if (r.isError) {
        throw StateError(r.stringResult);
      }
      final fn = r.rawResult;
      if (fn is! JSInvokable) {
        throw StateError(
          'Expected JSInvokable from functionSource, got ${fn.runtimeType}',
        );
      }
      try {
        final out = <Object?>[];
        for (final args in callArgs) {
          out.add(fn.invoke(args));
        }
        return out;
      } finally {
        fn.free();
      }
    });
  }

  /// Push binary as TypedArray (preferred over `number[]`).
  ///
  /// Uses a normal [Uint8List] copy path by default. For native-owned handoff
  /// (optional zero-copy into QuickJS ownership), set [preferTransfer].
  Future<int> pushBytes(
    Uint8List bytes, {
    String globalName = '__payload',
    bool preferTransfer = false,
    void Function(JavascriptRuntime js)? setup,
  }) {
    _ensureOpen();
    if (bytes.lengthInBytes > payloadBudget.maxDartToJsBytes) {
      throw ArgumentError.value(
        bytes.lengthInBytes,
        'bytes.lengthInBytes',
        'exceeds maxDartToJsBytes=${payloadBudget.maxDartToJsBytes}',
      );
    }
    return _pool.withEngine((js) async {
      setup?.call(js);
      final setGlobal =
          js.evaluate('(k,v)=>{globalThis[k]=v;}').rawResult as JSInvokable;
      try {
        if (preferTransfer) {
          final xfer = JsTypedArrayTransfer.allocate(
            byteLength: bytes.lengthInBytes,
            type: JSTypedArrayType.UINT8,
          );
          xfer.bytes.setAll(0, bytes);
          setGlobal.invoke([globalName, xfer]);
        } else {
          setGlobal.invoke([globalName, bytes]);
        }
      } finally {
        setGlobal.free();
      }
      final len = js.evaluate(
        'globalThis.$globalName.byteLength',
      );
      if (len.isError) {
        throw StateError(len.stringResult);
      }
      final n = len.rawResult;
      if (n is int) return n;
      if (n is num) return n.toInt();
      throw StateError('byteLength not numeric: $n');
    });
  }

  /// Pull binary from JS as [Uint8List] (TypedArray path).
  Future<Uint8List> pullBytes(
    String expression, {
    void Function(JavascriptRuntime js)? setup,
  }) {
    _ensureOpen();
    return _pool.withEngine((js) async {
      setup?.call(js);
      final r = js.evaluate(expression);
      if (r.isError) {
        throw StateError(r.stringResult);
      }
      final v = r.rawResult;
      if (v is Uint8List) return v;
      if (v is TypedData) {
        return Uint8List.view(
          v.buffer,
          v.offsetInBytes,
          v.lengthInBytes,
        );
      }
      throw StateError(
        'Expected TypedArray/Uint8List from expression, got ${v.runtimeType}',
      );
    });
  }

  /// Optional GC + usage snapshot on an idle engine (does not reclaim all RSS).
  Future<TenantWorkerDiagnostics> diagnostics({bool runGc = false}) {
    _ensureOpen();
    return _pool.withEngine((js) async {
      if (runGc) {
        js.runGC();
      }
      return TenantWorkerDiagnostics(
        poolSize: _pool.size,
        idleCount: _pool.idleCount,
        inUseCount: _pool.inUseCount,
        poolResetCount: _pool.resetCount,
        memoryUsage: js.getMemoryUsage(),
        bridgeStats: readBridgeStats(),
      );
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pool.dispose();
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('ProductionTenantWorker is disposed');
    }
  }
}
