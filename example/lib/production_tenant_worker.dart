// Reference production posture for multi-tenant / high-churn scripts.
// See doc/wiki/guides/production-checklist.md and
// doc/wiki/recipes/multi-tenant-pool.md.
//
// Patterns:
// - JsEnginePool with modest maxSize
// - EngineResetMode.soft between tenants (prefer over hard)
// - evaluateJson for data-only results; evaluate for mixed/callable
// - dispose the pool at feature/app teardown
// - do not call getJavascriptRuntime() per request

import 'package:flutter_qjs_next/flutter_qjs.dart';

/// Bounded multi-tenant worker. Own and [dispose] at shutdown.
class ProductionTenantWorker {
  ProductionTenantWorker({
    int maxSize = 4,
    int timeoutMs = 2000,
    int memoryLimit = 32 * 1024 * 1024,
  }) : _pool = JsEnginePool(
          maxSize: maxSize,
          config: JsEnginePoolConfig(
            timeout: timeoutMs,
            memoryLimit: memoryLimit,
            resetMode: EngineResetMode.soft,
          ),
        );

  final JsEnginePool _pool;
  bool _disposed = false;

  int get idleCount => _pool.idleCount;
  int get inUseCount => _pool.inUseCount;
  int get size => _pool.size;

  /// Run a script with a clean global between tenants.
  ///
  /// [asJson] uses [JavascriptRuntime.evaluateJson] (throws on error).
  /// Otherwise uses [JavascriptRuntime.evaluate] and throws if [JsEvalResult.isError].
  Future<Object?> run(
    String source, {
    bool asJson = false,
    void Function(JavascriptRuntime js)? setup,
  }) {
    if (_disposed) {
      throw StateError('ProductionTenantWorker is disposed');
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pool.dispose();
  }
}
