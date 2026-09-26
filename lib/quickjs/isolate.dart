/*
 * @Description: isolate
 * @Author: ekibun
 * @Date: 2020-10-02 13:49:03
 * @LastEditors: ekibun
 * @LastEditTime: 2020-10-03 22:21:31
 */
part of 'quickjs_runtime2.dart';

typedef _Decode = dynamic Function(Map obj);
List<_Decode> _decoders = [JSError._decode, IsolateFunction._decode];

abstract class _IsolateEncodable {
  Map _encode();
}

dynamic _encodeData(dynamic data, {Map<dynamic, dynamic>? cache}) {
  if (cache == null) cache = Map();
  if (cache.containsKey(data)) return cache[data];
  if (data is Error || data is Exception) {
    return _encodeData(JSError(data), cache: cache);
  }
  if (data is _IsolateEncodable) return data._encode();
  if (data is List) {
    final ret = [];
    cache[data] = ret;
    for (int i = 0; i < data.length; ++i) {
      ret.add(_encodeData(data[i], cache: cache));
    }
    return ret;
  }
  if (data is Map) {
    final ret = {};
    cache[data] = ret;
    for (final entry in data.entries) {
      ret[_encodeData(entry.key, cache: cache)] = _encodeData(
        entry.value,
        cache: cache,
      );
    }
    return ret;
  }
  if (data is Future) {
    final futurePort = ReceivePort();
    data.then(
      (value) {
        futurePort.first.then((port) {
          futurePort.close();
          (port as SendPort).send(_encodeData(value));
        });
      },
      onError: (e) {
        futurePort.first.then((port) {
          futurePort.close();
          (port as SendPort).send({#error: _encodeData(e)});
        });
      },
    );
    return {#jsFuturePort: futurePort.sendPort};
  }
  return data;
}

dynamic _decodeData(dynamic data, {Map<dynamic, dynamic>? cache}) {
  if (cache == null) cache = Map();
  if (cache.containsKey(data)) return cache[data];
  if (data is List) {
    final ret = [];
    cache[data] = ret;
    for (int i = 0; i < data.length; ++i) {
      ret.add(_decodeData(data[i], cache: cache));
    }
    return ret;
  }
  if (data is Map) {
    for (final decoder in _decoders) {
      final decodeObj = decoder(data);
      if (decodeObj != null) return decodeObj;
    }
    if (data.containsKey(#jsFuturePort)) {
      SendPort port = data[#jsFuturePort];
      final futurePort = ReceivePort();
      port.send(futurePort.sendPort);
      final futureCompleter = Completer();
      futureCompleter.future.catchError((e) {});
      futurePort.first.then((value) {
        futurePort.close();
        if (value is Map && value.containsKey(#error)) {
          futureCompleter.completeError(_decodeData(value[#error]));
        } else {
          futureCompleter.complete(_decodeData(value));
        }
      });
      return futureCompleter.future;
    }
    final ret = {};
    cache[data] = ret;
    for (final entry in data.entries) {
      ret[_decodeData(entry.key, cache: cache)] = _decodeData(
        entry.value,
        cache: cache,
      );
    }
    return ret;
  }
  return data;
}

void _runJsIsolate(Map spawnMessage) async {
  SendPort sendPort = spawnMessage[#port];
  ReceivePort port = ReceivePort();
  sendPort.send(port.sendPort);
  // Sources the worker can resolve on its own. Anything found here costs no
  // isolate round trip, which is the whole point of [IsolateQjs.moduleSources]
  // and [IsolateQjs.bundle].
  final Map<String, String> localSources =
      (spawnMessage[#moduleSources] as Map?)?.cast<String, String>() ??
      const {};
  final bundleBytes = spawnMessage[#bundle] as Uint8List?;
  final hasRemoteHandler = spawnMessage[#hasModuleHandler] == true;
  final qjs = QuickJsRuntime2(
    stackSize: spawnMessage[#stackSize],
    timeout: spawnMessage[#timeout],
    memoryLimit: spawnMessage[#memoryLimit],
    hostPromiseRejectionHandler: (reason) {
      sendPort.send({
        #type: #hostPromiseRejection,
        #reason: _encodeData(reason),
      });
    },
    moduleHandler: (name) {
      final local = localSources[name];
      if (local != null) return local;
      if (!hasRemoteHandler) throw JSError('Module Not found: $name');
      // Fallback: QuickJS's module loader is synchronous, but host resolution
      // lives on another isolate. The reply is a native source string pointer
      // written into [slot] (0 = pending, -1 = error) and the worker parks with
      // 1ms sleeps. Every module costs at least one such round trip, so prefer
      // [IsolateQjs.bundle] / [IsolateQjs.moduleSources] for known graphs.
      final slot = calloc<IntPtr>();
      slot.value = 0;
      sendPort.send({#type: #module, #name: name, #slot: slot.address});
      while (slot.value == 0) {
        sleep(const Duration(milliseconds: 1));
      }
      final addr = slot.value;
      calloc.free(slot);
      if (addr == -1) throw JSError('Module Not found: $name');
      final ret = Pointer<Utf8>.fromAddress(addr);
      final retString = ret.toDartString();
      malloc.free(ret);
      return retString;
    },
  );
  // Registering the bundle up front means every `import` in it resolves inside
  // the worker's own context; the module loader above is never reached.
  final bundle = bundleBytes == null
      ? null
      : JsModuleBundle.fromBytes(bundleBytes);
  bundle?.install(qjs);
  port.listen((msg) async {
    dynamic data;
    SendPort? msgPort = msg[#port];
    try {
      // Host function channel: bind provided Dart closures onto globalThis
      // before evaluating. Each is an IsolateFunction routed back to the
      // spawning isolate; returning a Future yields a JS Promise (via
      // _dartToJs). Inject-once semantics: only the message that carries
      // #functions binds them; persists across later evaluates on the same
      // engine.
      final encodedFns = msg[#functions];
      if (encodedFns != null) {
        final fns = _decodeData(encodedFns) as Map;
        final setter = qjs.evaluate('(k,v)=>{globalThis[k]=v;}').rawResult;
        try {
          fns.forEach((k, v) => (setter as JSInvokable).invoke([k, v]));
        } finally {
          if (setter is JSRef) setter.free();
        }
      }
      switch (msg[#type]) {
        case #evaluate:
          // QuickJsRuntime2.evaluate wraps the result in a JsEvalResult and
          // reports errors via isError instead of throwing. Unwrap here so the
          // error travels back through the #error channel and Promises resolve
          // to their settled value.
          final r = qjs.evaluate(
            msg[#command],
            name: msg[#name],
            evalFlags: msg[#flag],
          );
          if (r.isError) throw r.rawResult;
          data = await r.rawResult;
          break;
        case #evaluateBundleEntry:
          if (bundle == null) throw JSError('IsolateQjs has no module bundle');
          final r = qjs.evaluateBytecode(bundle.modules[bundle.entry]!);
          if (r.isError) throw r.rawResult;
          data = await r.rawResult;
          break;
        case #close:
          data = false;
          qjs.port.close();
          qjs.close();
          port.close();
          data = true;
          break;
      }
      if (msgPort != null) msgPort.send(_encodeData(data));
    } catch (e) {
      if (msgPort != null) msgPort.send({#error: _encodeData(e)});
    }
  });
  await qjs.dispatch();
}

typedef _JsAsyncModuleHandler = Future<String> Function(String name);

class IsolateQjs {
  Future<SendPort>? _sendPort;

  /// Max stack size for quickjs.
  final int? stackSize;

  /// Max stack size for quickjs.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Asynchronously handler to manage js module.
  ///
  /// QuickJS resolves imports synchronously, so every module this handler
  /// serves costs a round trip to the spawning isolate while the worker is
  /// parked. Prefer [bundle] (or [moduleSources]) whenever the import graph is
  /// known up front; keep this handler for genuinely dynamic resolution.
  final _JsAsyncModuleHandler? moduleHandler;

  /// Modules compiled to bytecode ahead of time. They are registered in the
  /// worker's context before the first [evaluate], so imports of their names
  /// resolve locally: no [moduleHandler] round trip, no parked worker, and no
  /// per-module parse cost at runtime.
  final JsModuleBundle? bundle;

  /// Module sources the worker resolves on its own, as a fallback for graphs
  /// that are known but not precompiled. Cheaper than [moduleHandler] (no round
  /// trip) but still parses on every load; [bundle] is the faster option.
  final Map<String, String>? moduleSources;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  /// Host functions to expose on `globalThis`, wrapped as cross-isolate
  /// [IsolateFunction]s. Bound onto the worker's globalThis on the first
  /// [evaluate] (inject-once); invoking from JS routes back to this isolate,
  /// and a returned Future becomes a JS Promise.
  final Map<String, IsolateFunction> _hostFunctions = {};
  bool _hostFunctionsBound = false;

  /// Quickjs engine runing on isolate thread.
  ///
  /// Pass handlers to implement js-dart interaction and resolving modules. The `methodHandler` is
  /// used in isolate, so **the handler function must be a top-level function or a static method**.
  IsolateQjs({
    this.moduleHandler,
    this.bundle,
    this.moduleSources,
    this.stackSize,
    this.timeout,
    this.memoryLimit,
    this.hostPromiseRejectionHandler,
  });

  /// Register host functions callable from JS as `globalThis[name](...)`.
  ///
  /// Each value is a Dart closure (may return a Future → JS Promise). The
  /// closure runs on **this** (spawning) isolate, not the worker — args are
  /// marshalled in, the return value (or resolved Future) marshalled back; the
  /// worker/JS never sees Dart closure internals. **Inject-once**: must be
  /// called before the first [evaluate]; runtime mutation is rejected.
  void setHostFunctions(Map<String, Function> functions) {
    if (_hostFunctionsBound) {
      throw StateError(
        'host functions must be registered before evaluate (inject-once)',
      );
    }
    functions.forEach((k, v) {
      // Dispose any prior registration for this key so repeated/accumulating
      // pre-evaluate calls don't leak IsolateFunction handlers.
      _hostFunctions[k]?.destroy();
      _hostFunctions[k] = IsolateFunction(v);
    });
  }

  void _ensureEngine() {
    if (_sendPort != null) return;
    ReceivePort port = ReceivePort();
    Isolate.spawn(_runJsIsolate, {
      #port: port.sendPort,
      #stackSize: stackSize,
      #timeout: timeout,
      #memoryLimit: memoryLimit,
      #bundle: bundle?.toBytes(),
      #moduleSources: moduleSources,
      #hasModuleHandler: moduleHandler != null,
    }, errorsAreFatal: true);
    final completer = Completer<SendPort>();
    port.listen(
      (msg) async {
        if (msg is SendPort && !completer.isCompleted) {
          completer.complete(msg);
          return;
        }
        switch (msg[#type]) {
          case #hostPromiseRejection:
            try {
              final err = _decodeData(msg[#reason]);
              if (hostPromiseRejectionHandler != null) {
                hostPromiseRejectionHandler!(err);
              } else {
                FlutterQjsLogger.warning('Unhandled promise rejection', err);
              }
            } catch (e) {
              FlutterQjsLogger.error('Host promise rejection handler error', e);
            }
            break;
          case #module:
            final slot = Pointer<IntPtr>.fromAddress(msg[#slot] as int);
            try {
              if (moduleHandler == null) {
                slot.value = -1;
              } else {
                final source = await moduleHandler!(msg[#name] as String);
                slot.value = source.toNativeUtf8().address;
              }
            } catch (e) {
              slot.value = -1;
            }
            break;
        }
      },
      onDone: () {
        close();
        if (!completer.isCompleted) {
          completer.completeError(JSError('isolate close'));
        }
      },
    );
    _sendPort = completer.future;
  }

  /// Free Runtime and close isolate thread that can be recreate when evaluate again.
  Future<dynamic>? close() {
    // Host-function handlers are reclaimed by the existing IsolateFunction
    // refcount path: when the worker frees its runtime on #close, the bound
    // globalThis functions are GC'd, and their cross-isolate #free messages
    // remove the handlers registered here. Manually destroying them up-front
    // races those late messages ("handler released"), so we don't.
    _hostFunctions.clear();
    _hostFunctionsBound = false;
    final sendPort = _sendPort;
    _sendPort = null;
    if (sendPort == null) return null;
    final ret = sendPort.then((sendPort) async {
      final closePort = ReceivePort();
      sendPort.send({#type: #close, #port: closePort.sendPort});
      final result = await closePort.first;
      closePort.close();
      if (result is Map && result.containsKey(#error)) {
        throw _decodeData(result[#error]);
      }
      return _decodeData(result);
    });
    return ret;
  }

  /// Evaluate js script.
  Future<dynamic> evaluate(
    String command, {
    String? name,
    int? evalFlags,
  }) async {
    _ensureEngine();
    final evaluatePort = ReceivePort();
    final sendPort = await _sendPort!;
    final msg = {
      #type: #evaluate,
      #command: command,
      #name: name,
      #flag: evalFlags,
      #port: evaluatePort.sendPort,
    };
    // Inject host functions once, on the first evaluate that follows
    // setHostFunctions. Encoded as IsolateFunction refs (id + handle port).
    if (_hostFunctions.isNotEmpty && !_hostFunctionsBound) {
      msg[#functions] = _encodeData(_hostFunctions);
      _hostFunctionsBound = true;
    }
    sendPort.send(msg);
    final result = await evaluatePort.first;
    evaluatePort.close();
    if (result is Map && result.containsKey(#error)) {
      throw _decodeData(result[#error]);
    }
    return _decodeData(result);
  }

  /// Evaluate the entry module of [bundle] in the worker.
  ///
  /// The whole graph is already compiled and registered, so this runs the entry
  /// without parsing anything and without a single module round trip. Throws a
  /// [JSError] when the instance was built without a bundle.
  Future<dynamic> evaluateBundleEntry() async {
    if (bundle == null) {
      throw JSError('IsolateQjs was created without a module bundle');
    }
    _ensureEngine();
    final evaluatePort = ReceivePort();
    final sendPort = await _sendPort!;
    final msg = {
      #type: #evaluateBundleEntry,
      #port: evaluatePort.sendPort,
    };
    if (_hostFunctions.isNotEmpty && !_hostFunctionsBound) {
      msg[#functions] = _encodeData(_hostFunctions);
      _hostFunctionsBound = true;
    }
    sendPort.send(msg);
    final result = await evaluatePort.first;
    evaluatePort.close();
    if (result is Map && result.containsKey(#error)) {
      throw _decodeData(result[#error]);
    }
    return _decodeData(result);
  }
}
