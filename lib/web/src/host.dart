part of '../web_apis.dart';

/// Web API state of one JS context: retained JS function handles, Dart timers
/// and in-flight host work. Created by [JavascriptRuntime.init] and released
/// by [JavascriptRuntime.releaseHostCaches] before the context is freed.
class WebApiHost {
  WebApiHost._(this._runtime, this.config);

  final JavascriptRuntime _runtime;
  final JsWebApis config;
  final List<JSRef> _refs = [];
  final Map<int, Timer> _timers = {};
  JSInvokable? _fireTimer;
  _FetchHost? _fetch;
  bool _disposed = false;

  /// Module bytecode, compiled once per process and shared by all engines.
  static final Map<String, Uint8List> _bytecode = {};
  static final Random _random = Random.secure();

  /// Install the configured modules into [runtime]'s current context.
  /// Takes ownership of [natives].
  static WebApiHost install(
    JavascriptRuntime runtime,
    JsWebApis config,
    Object? natives,
  ) {
    final host = WebApiHost._(runtime, config);
    try {
      host._install(natives);
    } catch (_) {
      host.dispose();
      rethrow;
    } finally {
      if (natives is JSRef) natives.free();
    }
    return host;
  }

  void _install(Object? natives) {
    final order = config.resolvedModules;
    if (order.isEmpty) return;

    // Every module requires `core`, so the closure puts it first.
    final core = _load(JsWebModule.core);
    final Map<String, JSInvokable> exports;
    try {
      exports = _retain(core.invoke([natives, _coreHost()]));
    } finally {
      core.free();
    }
    _fireTimer = exports['fire'];
    final install = exports['install']!;

    for (final module in order.skip(1)) {
      _installModule(install, module);
    }
  }

  /// Host functions a module needs, and the wiring for modules that own host
  /// state. Pure modules get an empty object.
  Map<String, JSInvokable> _installModule(
    JSInvokable install,
    JsWebModule module,
  ) {
    if (identical(module, JsWebModule.crypto)) {
      return _invokeModule(install, module, {'digest': _digest, 'hmac': _hmac});
    }
    if (identical(module, JsWebModule.navigator)) {
      return _invokeModule(install, module, {
        'userAgent': () => config.userAgent,
      });
    }
    if (identical(module, JsWebModule.fetch)) {
      final options = config.fetch;
      if (options == null) {
        throw ArgumentError.value(
          module,
          'modules',
          'JsWebModule.fetch needs ${module.hostConfig}; '
              'pass JsWebApis(fetch: ...)',
        );
      }
      final fetchHost = _FetchHost(this, options, config.userAgent);
      _fetch = fetchHost;
      final exports = _invokeModule(install, module, fetchHost.hostFunctions());
      fetchHost.bind(exports);
      return exports;
    }
    return _invokeModule(install, module, const {});
  }

  Map<String, JSInvokable> _invokeModule(
    JSInvokable install,
    JsWebModule module,
    Map<String, Function> moduleHost,
  ) {
    final source = _load(module);
    try {
      return _retain(install.invoke([module.name, source, moduleHost]));
    } finally {
      source.free();
    }
  }

  JSInvokable _load(JsWebModule module) {
    final bytecode = _bytecode[module.name] ??= _compile(
      module.name,
      module._source,
    );
    final result = _runtime.evaluateBytecode(bytecode);
    if (result.isError) throw result.rawResult as Object;
    return result.rawResult as JSInvokable;
  }

  /// Compile a module in a scratch engine so that the peak cost of parsing is
  /// not charged to the target runtime's memory limit. Line info is kept for
  /// stack traces; source text is not.
  static Uint8List _compile(String name, String source) {
    final scratch = QuickJsRuntime2(
      memoryLimit: 0,
      webApis: const JsWebApis.none(),
    );
    try {
      return scratch.compile(source, 'web:$name', stripSource: true);
    } finally {
      scratch.dispose();
    }
  }

  /// Take ownership of the JS functions in a module's exports object.
  Map<String, JSInvokable> _retain(dynamic exports) {
    final retained = <String, JSInvokable>{};
    if (exports is Map) {
      exports.forEach((key, value) {
        if (value is JSInvokable) {
          _refs.add(value);
          retained['$key'] = value;
        } else {
          JSRef.freeRecursive(value);
        }
      });
    }
    return retained;
  }

  /// Run one host task (timer, network event): call into JS, then perform the
  /// microtask checkpoint unless the runtime leaves job draining to the caller.
  void _runTask(JSInvokable? callback, List args) {
    if (_disposed || callback == null) return;
    try {
      callback.invoke(args);
    } catch (e) {
      FlutterQjsLogger.error('Web API host task failed', e);
    }
    final runtime = _runtime;
    if (_disposed ||
        (runtime is QuickJsRuntime2 && !runtime.autoExecutePendingJobs)) {
      return;
    }
    try {
      runtime.executePendingJobs();
    } catch (_) {}
  }

  Map<String, Function> _coreHost() => {
    'log': _log,
    'schedule': _schedule,
    'cancel': _cancel,
    'randomBytes': _randomBytes,
  };

  static void _log(String level, String message) {
    switch (level) {
      case 'error':
        FlutterQjsLogger.error(message);
      case 'warn':
        FlutterQjsLogger.warning(message);
      case 'debug':
      case 'trace':
        FlutterQjsLogger.debug(message);
      default:
        FlutterQjsLogger.info(message);
    }
  }

  void _schedule(int id, num delay, bool repeat) {
    if (_disposed) return;
    _timers.remove(id)?.cancel();
    final duration = Duration(microseconds: (delay * 1000).round());
    if (repeat) {
      _timers[id] = Timer.periodic(
        duration < const Duration(milliseconds: 1)
            ? const Duration(milliseconds: 1)
            : duration,
        (_) => _runTask(_fireTimer, [id]),
      );
    } else {
      _timers[id] = Timer(duration, () {
        _timers.remove(id);
        _runTask(_fireTimer, [id]);
      });
    }
  }

  void _cancel(int id) {
    _timers.remove(id)?.cancel();
  }

  static Uint8List _digest(String algorithm, Uint8List data) =>
      _Sha.digest(algorithm, data);

  static Uint8List _hmac(String algorithm, Uint8List key, Uint8List data) =>
      _Sha.hmac(algorithm, key, data);

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    var i = 0;
    for (; i + 4 <= length; i += 4) {
      final value = _random.nextInt(0x100000000);
      bytes[i] = value;
      bytes[i + 1] = value >> 8;
      bytes[i + 2] = value >> 16;
      bytes[i + 3] = value >> 24;
    }
    for (; i < length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// Cancel host work and release JS handles. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _fireTimer = null;
    _fetch?.dispose();
    _fetch = null;
    for (final ref in _refs) {
      try {
        ref.free();
      } catch (_) {}
    }
    _refs.clear();
  }
}
