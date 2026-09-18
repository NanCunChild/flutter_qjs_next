/// Web platform APIs (a WinterTC subset) for QuickJS runtimes.
///
/// Design notes: `doc/design/2026-09-13-web-apis.md`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../flutter_qjs_logger.dart';
import '../javascript_runtime.dart';
import '../quickjs/quickjs_runtime2.dart';

part 'src/fetch_host.dart';
part 'src/host.dart';
part 'src/js_blob.dart';
part 'src/js_core.dart';
part 'src/js_crypto.dart';
part 'src/js_fetch.dart';
part 'src/js_encoding.dart';
part 'src/js_events.dart';
part 'src/js_http.dart';
part 'src/js_navigator.dart';
part 'src/js_streams.dart';
part 'src/js_url.dart';
part 'src/sha.dart';

/// One independently installable unit of the Web platform API.
///
/// Modules are a **functional** split: they exist so a context only pays, in
/// heap and install time, for the APIs it uses. They are **not** a permission
/// or security boundary. Leaving a module out does not sandbox a script, and
/// several modules reach the host (`core` has timers, `console` and the system
/// random source; `navigator` reports the configured user agent). What a
/// script may do outside the heap is decided by the host objects you pass in,
/// such as [JsFetchOptions.allowUrl], and by the runtime's `memoryLimit` and
/// `timeout`. See `doc/wiki/guides/security.md`.
///
/// Modules declare what they need in [requires]; [JsWebApis] installs the
/// dependency closure of whatever you ask for, in dependency order. Depending
/// on another module is an implementation detail of the module, not something
/// callers have to model.
///
/// A module can also list [optional] modules: they are never pulled in, but
/// when they are installed anyway they come first, and the module enables the
/// features that need them (for example `TextEncoderStream` in [streams] needs
/// [encoding]).
class JsWebModule {
  const JsWebModule._(
    this.name,
    this.requires,
    this._source, {
    this.optional = const [],
    this.hostConfig,
  });

  /// Stable identifier, also the bytecode cache key and the script name that
  /// appears in stack traces (`web:<name>`).
  final String name;

  /// Modules that must be installed before this one.
  final List<JsWebModule> requires;

  /// Modules this one uses when present. Not installed on its behalf.
  final List<JsWebModule> optional;

  /// Name of the host configuration object this module cannot be installed
  /// without, or `null` if it needs none. Today only [fetch] has one
  /// ([JsFetchOptions]).
  final String? hostConfig;

  final String _source;

  /// Timers, `queueMicrotask`, `reportError`, `console`, `performance`,
  /// `structuredClone`, `atob` / `btoa`, `DOMException`,
  /// `crypto.getRandomValues` / `crypto.randomUUID`.
  ///
  /// Every other module builds on this one. Roughly 80 KiB of JS heap.
  static const core = JsWebModule._('core', [], _jsCore);

  /// `Event`, `CustomEvent`, `EventTarget`, `AbortController`, `AbortSignal`.
  static const events = JsWebModule._('events', [core], _jsEvents);

  /// `TextEncoder` and `TextDecoder` (UTF-8 only).
  static const encoding = JsWebModule._('encoding', [core], _jsEncoding);

  /// `URL` and `URLSearchParams` (WHATWG parser).
  static const url = JsWebModule._('url', [core], _jsUrl);

  /// `crypto.subtle`: `digest` and HMAC.
  static const crypto = JsWebModule._('crypto', [core], _jsCrypto);

  /// `Navigator` and the `navigator` global, including `navigator.userAgent`.
  static const navigator = JsWebModule._('navigator', [core], _jsNavigator);

  /// `ReadableStream` / `WritableStream` / `TransformStream` and the queuing
  /// strategies. `TextEncoderStream` / `TextDecoderStream` need [encoding].
  static const streams = JsWebModule._(
    'streams',
    [core, events],
    _jsStreams,
    optional: [encoding],
  );

  /// `Blob`, `File`, `FormData`. `Blob.prototype.stream` needs [streams].
  static const blob = JsWebModule._(
    'blob',
    [core],
    _jsBlob,
    optional: [streams],
  );

  /// `Headers`, `Request`, `Response` and the body mixin. `blob()` and
  /// `formData()`, and `Blob` / `FormData` request bodies, need [blob].
  static const http = JsWebModule._(
    'http',
    [core, url, events, streams],
    _jsHttp,
    optional: [blob],
  );

  /// The global `fetch`. Needs [JsFetchOptions], which carries the network
  /// policy; see [hostConfig].
  static const fetch = JsWebModule._(
    'fetch',
    [core, http, events, streams],
    _jsFetch,
    hostConfig: 'JsFetchOptions',
  );

  /// Every module that needs no host configuration, i.e. all of them except
  /// [fetch].
  static const standard = {
    core,
    events,
    encoding,
    url,
    crypto,
    navigator,
    streams,
    blob,
    http,
  };

  @override
  String toString() => 'JsWebModule($name)';
}

/// Web platform APIs a runtime installs into each JS context.
///
/// Pick a preset, or name the modules you want and let the dependency closure
/// take care of the rest:
///
/// ```dart
/// const JsWebApis.none();                        // pure QuickJS
/// const JsWebApis();                             // core only (the default)
/// const JsWebApis(modules: {JsWebModule.url});   // core + url
/// JsWebApis.standard(fetch: JsFetchOptions());   // everything, with network
/// ```
class JsWebApis {
  /// Installs [modules] and everything they require.
  ///
  /// Defaults to [JsWebModule.core] alone. A non-null [fetch] additionally
  /// installs [JsWebModule.fetch], so `JsWebApis(fetch: ...)` gives you a
  /// context with `fetch` and the types it needs.
  const JsWebApis({
    this.modules = const {JsWebModule.core},
    this.fetch,
    this.userAgent = _defaultUserAgent,
  });

  /// Installs nothing at all: no `console`, no timers, plain ECMAScript.
  ///
  /// For engines on a very small `memoryLimit`, and for the scratch engine the
  /// module compiler runs in.
  const JsWebApis.none() : this(modules: const {});

  /// Installs every module that needs no host configuration
  /// ([JsWebModule.standard]), plus `fetch` when [fetch] is given.
  const JsWebApis.standard({
    JsFetchOptions? fetch,
    String userAgent = _defaultUserAgent,
  }) : this(modules: JsWebModule.standard, fetch: fetch, userAgent: userAgent);

  static const _defaultUserAgent = 'flutter_qjs_next';

  /// Modules explicitly requested. Their dependencies are installed too; see
  /// [resolvedModules].
  final Set<JsWebModule> modules;

  /// Network policy for [JsWebModule.fetch]. `null` means the context has no
  /// network at all and no global `fetch`.
  final JsFetchOptions? fetch;

  /// Value reported by `navigator.userAgent` and used as the default
  /// `User-Agent` by the built-in fetch handler.
  final String userAgent;

  /// The dependency closure of [modules] (plus [JsWebModule.fetch] when
  /// [fetch] is set), ordered so that every module comes after everything it
  /// requires and after every installed module it lists as optional.
  List<JsWebModule> get resolvedModules {
    final requested = fetch == null
        ? modules
        : <JsWebModule>{...modules, JsWebModule.fetch};

    // Only hard requirements decide what gets installed.
    final closure = <String>{};
    void collect(JsWebModule module) {
      if (!closure.add(module.name)) return;
      module.requires.forEach(collect);
    }

    requested.forEach(collect);

    // Optional edges only affect order, and only between installed modules.
    final order = <JsWebModule>[];
    final seen = <String>{};
    void visit(JsWebModule module) {
      if (!seen.add(module.name)) return;
      for (final dependency in module.requires) {
        visit(dependency);
      }
      for (final dependency in module.optional) {
        if (closure.contains(dependency.name)) visit(dependency);
      }
      order.add(module);
    }

    for (final module in requested) {
      visit(module);
    }
    return order;
  }

  /// Whether [module] ends up installed, directly or as a dependency.
  bool installs(JsWebModule module) =>
      resolvedModules.any((m) => m.name == module.name);
}
