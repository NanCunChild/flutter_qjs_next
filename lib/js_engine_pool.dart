import 'dart:async';
import 'dart:collection';

import 'package:flutter_qjs_next/flutter_qjs.dart';

/// Configuration for engines created by [JsEnginePool].
class JsEnginePoolConfig {
  final int stackSize;
  final int? timeout;
  final int? memoryLimit;

  /// When true (default), [JsEnginePool.release] calls [JavascriptRuntime.reinitialize]
  /// so the next tenant does not see prior `globalThis` / channel state.
  final bool resetOnRelease;

  const JsEnginePoolConfig({
    this.stackSize = 1024 * 1024,
    this.timeout,
    this.memoryLimit = kDefaultJsMemoryLimit,
    this.resetOnRelease = true,
  });
}

/// Bounded pool of [JavascriptRuntime] instances for multi-engine workloads.
///
/// Engines are created lazily up to [maxSize]. Call [acquire] / [release], or
/// use [withEngine]. Always [dispose] the pool when finished.
///
/// By default [JsEnginePoolConfig.resetOnRelease] reinitializes engines on
/// return so scripts do not share dirty globals. Set `resetOnRelease: false`
/// only when callers guarantee cleanup.
class JsEnginePool {
  final int maxSize;
  final JsEnginePoolConfig config;
  final JavascriptRuntime Function()? _factory;

  final ListQueue<JavascriptRuntime> _idle = ListQueue();
  final Set<JavascriptRuntime> _all = {};
  final Set<JavascriptRuntime> _leased = {};
  final ListQueue<Completer<JavascriptRuntime>> _waiters = ListQueue();
  bool _disposed = false;

  JsEnginePool({
    this.maxSize = 4,
    this.config = const JsEnginePoolConfig(),
    JavascriptRuntime Function()? factory,
  })  : assert(maxSize > 0),
        _factory = factory;

  int get size => _all.length;
  int get idleCount => _idle.length;
  int get inUseCount => _leased.length;

  JavascriptRuntime _create() {
    if (_factory != null) return _factory();
    return getJavascriptRuntime(
      stackSize: config.stackSize,
      timeout: config.timeout,
      memoryLimit: config.memoryLimit,
    );
  }

  /// Borrow an engine. Blocks (async) if all engines are in use until one is
  /// [release]d, unless [timeout] elapses.
  Future<JavascriptRuntime> acquire({Duration? timeout}) async {
    if (_disposed) throw StateError('JsEnginePool is disposed');

    if (_idle.isNotEmpty) {
      final engine = _idle.removeFirst();
      _leased.add(engine);
      return engine;
    }
    if (_all.length < maxSize) {
      final eng = _create();
      _all.add(eng);
      _leased.add(eng);
      return eng;
    }

    final c = Completer<JavascriptRuntime>();
    _waiters.add(c);
    if (timeout != null) {
      return c.future.timeout(timeout, onTimeout: () {
        _waiters.remove(c);
        throw TimeoutException('JsEnginePool.acquire', timeout);
      });
    }
    return c.future;
  }

  void _prepareForReuse(JavascriptRuntime engine) {
    if (!config.resetOnRelease) return;
    try {
      engine.reinitialize();
    } catch (_) {
      _destroy(engine);
    }
  }

  /// Return an engine to the pool. Do not use [engine] after this call.
  void release(JavascriptRuntime engine) {
    if (_disposed) {
      _destroy(engine);
      return;
    }
    if (!_all.contains(engine)) {
      throw ArgumentError('Engine not owned by this pool');
    }
    if (!_leased.remove(engine)) {
      throw StateError('Engine is not currently leased');
    }
    _prepareForReuse(engine);
    if (!_all.contains(engine)) {
      // reinitialize failed and engine was destroyed; try to fill a waiter with a new one
      if (_waiters.isNotEmpty && _all.length < maxSize) {
        final eng = _create();
        _all.add(eng);
        _leased.add(eng);
        final w = _waiters.removeFirst();
        if (!w.isCompleted) {
          w.complete(eng);
          return;
        }
        _idle.addLast(eng);
      }
      return;
    }
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeFirst();
      if (!w.isCompleted) {
        _leased.add(engine);
        w.complete(engine);
        return;
      }
    }
    _idle.addLast(engine);
  }

  /// Run [fn] with a borrowed engine, always releasing afterward.
  Future<T> withEngine<T>(
    FutureOr<T> Function(JavascriptRuntime runtime) fn, {
    Duration? acquireTimeout,
  }) async {
    final eng = await acquire(timeout: acquireTimeout);
    try {
      return await fn(eng);
    } finally {
      release(eng);
    }
  }

  void _destroy(JavascriptRuntime eng) {
    _all.remove(eng);
    _idle.remove(eng);
    try {
      eng.dispose();
    } catch (_) {}
  }

  /// Dispose all engines and fail any pending [acquire] waiters.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeFirst();
      if (!w.isCompleted) {
        w.completeError(StateError('JsEnginePool is disposed'));
      }
    }
    final engines = List<JavascriptRuntime>.from(_all);
    _idle.clear();
    _all.clear();
    _leased.clear();
    for (final e in engines) {
      try {
        e.dispose();
      } catch (_) {}
    }
  }
}
