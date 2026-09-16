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
part 'src/js_streams.dart';
part 'src/js_url.dart';
part 'src/sha.dart';

/// Web platform APIs a runtime installs into each JS context.
class JsWebApis {
  /// L0 core primitives: timers, `queueMicrotask`, `reportError`, `console`,
  /// `performance`, `structuredClone`, `atob` / `btoa`, `DOMException` and
  /// `crypto` random values. Costs roughly 80 KiB of JS heap per context;
  /// set to `false` for a bare engine (no `console`, no timers).
  final bool core;

  /// L1 standard library: `Event` / `EventTarget` / `AbortController`,
  /// `TextEncoder` / `TextDecoder`, `URL` / `URLSearchParams`,
  /// `Blob` / `File` / `FormData`, streams, `Headers` / `Request` / `Response`,
  /// `crypto.subtle` and `navigator`. Off by default.
  final bool web;

  /// L2 network access: a non-null value installs the global `fetch` and
  /// implies [web]. `null` means the engine has no network at all.
  final JsFetchOptions? fetch;

  /// Value reported by `navigator.userAgent` and used as the default
  /// `User-Agent` by the built-in fetch handler.
  final String userAgent;

  const JsWebApis({
    this.core = true,
    this.web = false,
    this.fetch,
    this.userAgent = 'flutter_qjs_next',
  });

  /// Whether the L1 standard library is installed.
  bool get installsWeb => web || fetch != null;
}
