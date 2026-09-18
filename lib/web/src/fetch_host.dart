part of '../web_apis.dart';

/// One HTTP exchange requested by JS `fetch`.
///
/// A [JsFetchHandler] must perform exactly this request and **must not follow
/// redirects**: redirect policy, the URL allow-list and the redirect limit are
/// applied by the runtime between hops so that every hop is checked.
class JsFetchRequest {
  const JsFetchRequest({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
    required this.onAbort,
  });

  final Uri url;
  final String method;
  final List<MapEntry<String, String>> headers;

  /// Request body, already fully buffered, or `null`.
  final Uint8List? body;

  /// Completes when JS aborts the request or the engine is reset.
  final Future<void> onAbort;
}

/// Result of a [JsFetchHandler] call.
class JsFetchResponse {
  const JsFetchResponse({
    required this.status,
    required this.body,
    this.statusText = '',
    this.headers = const [],
  });

  final int status;
  final String statusText;
  final List<MapEntry<String, String>> headers;

  /// Response body. Back-pressure follows JS reads: the runtime pauses this
  /// subscription until the script asks for the next chunk.
  final Stream<List<int>> body;
}

/// Performs a single HTTP exchange for JS `fetch`.
typedef JsFetchHandler = Future<JsFetchResponse> Function(JsFetchRequest request);

/// Network access for JS `fetch`. Passing this to [JsWebApis] enables the
/// global `fetch` and installs the modules it requires. This object, not the
/// module set, is the network policy: see [allowUrl].
class JsFetchOptions {
  const JsFetchOptions({
    this.allowUrl,
    this.handler,
    this.maxResponseBytes = kDefaultJsMemoryLimit,
    this.maxRedirects = 20,
    this.connectionTimeout,
  });

  /// Called for the request URL and for every redirect hop. Returning false
  /// fails the fetch with a `TypeError`. `null` allows every `http:`/`https:`
  /// URL, which is rarely what untrusted scripts should get.
  final bool Function(Uri url)? allowUrl;

  /// Network implementation. `null` uses a [HttpClient] owned by the runtime
  /// and closed when the engine is disposed or reset.
  final JsFetchHandler? handler;

  /// Maximum response body bytes; the body stream errors past it. 0 = unlimited.
  final int maxResponseBytes;

  final int maxRedirects;
  final Duration? connectionTimeout;
}

/// Default [JsFetchHandler]: one `dart:io` [HttpClient] request, no redirects.
class _HttpClientFetchHandler {
  _HttpClientFetchHandler(this._options, this._userAgent);

  final JsFetchOptions _options;
  final String _userAgent;
  HttpClient? _client;

  static const _skippedRequestHeaders = {'content-length', 'host'};

  HttpClient get _http {
    final existing = _client;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = _options.connectionTimeout
      ..userAgent = _userAgent;
    _client = client;
    return client;
  }

  Future<JsFetchResponse> call(JsFetchRequest request) async {
    final httpRequest = await _http.openUrl(request.method, request.url);
    httpRequest.followRedirects = false;
    for (final header in request.headers) {
      if (_skippedRequestHeaders.contains(header.key.toLowerCase())) continue;
      httpRequest.headers.add(header.key, header.value, preserveHeaderCase: true);
    }
    final body = request.body;
    if (body != null) {
      httpRequest.contentLength = body.length;
      httpRequest.add(body);
    }
    unawaited(
      request.onAbort.then((_) {
        try {
          httpRequest.abort();
        } catch (_) {}
      }),
    );
    final response = await httpRequest.close();
    final headers = <MapEntry<String, String>>[];
    response.headers.forEach((name, values) {
      for (final value in values) {
        headers.add(MapEntry(name, value));
      }
    });
    return JsFetchResponse(
      status: response.statusCode,
      statusText: response.reasonPhrase,
      headers: headers,
      body: response,
    );
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

class _FetchOperation {
  _FetchOperation(this.id, this.url, this.method, this.headers, this.body, this.redirect);

  final int id;
  Uri url;
  String method;
  List<MapEntry<String, String>> headers;
  Uint8List? body;
  final String redirect;
  final Completer<void> abort = Completer<void>();
  StreamSubscription<List<int>>? subscription;
  bool redirected = false;
  bool responded = false;
  int received = 0;
}

/// Dart side of the JS `fetch` implementation.
class _FetchHost {
  _FetchHost(this._web, this._options, String userAgent)
    : _ownedHandler = _options.handler == null
          ? _HttpClientFetchHandler(_options, userAgent)
          : null;

  final WebApiHost _web;
  final JsFetchOptions _options;
  final _HttpClientFetchHandler? _ownedHandler;
  final Map<int, _FetchOperation> _operations = {};
  Map<String, JSInvokable> _exports = const {};
  bool _disposed = false;

  static const _redirectStatuses = {301, 302, 303, 307, 308};
  static const _bodyHeaders = {
    'content-encoding',
    'content-language',
    'content-location',
    'content-type',
  };

  Map<String, Function> hostFunctions() => {
    'start': _start,
    'pull': _pull,
    'cancel': _cancel,
    'abort': _abortRequest,
  };

  void bind(Map<String, JSInvokable> exports) {
    _exports = exports;
  }

  JsFetchHandler get _handler => _options.handler ?? _ownedHandler!.call;

  void _start(
    int id,
    String url,
    String method,
    List<dynamic> headers,
    dynamic body,
    String redirect,
  ) {
    if (_disposed) return;
    final parsed = Uri.tryParse(url);
    if (parsed == null) {
      _fail(id, 'invalid URL: $url');
      return;
    }
    final operation = _FetchOperation(
      id,
      parsed,
      method,
      [
        for (final header in headers)
          MapEntry('${(header as List)[0]}', '${header[1]}'),
      ],
      body is Uint8List
          ? body
          : body is List<int>
          ? Uint8List.fromList(body)
          : null,
      redirect,
    );
    _operations[id] = operation;
    unawaited(_run(operation));
  }

  Future<void> _run(_FetchOperation operation) async {
    try {
      var redirects = 0;
      while (true) {
        final scheme = operation.url.scheme;
        if (scheme != 'http' && scheme != 'https') {
          throw _FetchFailure('unsupported scheme: $scheme');
        }
        final allow = _options.allowUrl;
        if (allow != null && !allow(operation.url)) {
          throw _FetchFailure('${operation.url} is not allowed by the host policy');
        }
        final response = await _handler(
          JsFetchRequest(
            url: operation.url,
            method: operation.method,
            headers: operation.headers,
            body: operation.body,
            onAbort: operation.abort.future,
          ),
        );
        if (_disposed || !_operations.containsKey(operation.id)) {
          await response.body.drain<void>().catchError((_) {});
          return;
        }
        final location = _headerValue(response.headers, 'location');
        final isRedirect =
            _redirectStatuses.contains(response.status) && location != null;
        if (isRedirect && operation.redirect == 'error') {
          throw _FetchFailure('redirect received with redirect: error');
        }
        if (isRedirect && operation.redirect == 'follow') {
          if (++redirects > _options.maxRedirects) {
            throw _FetchFailure('too many redirects');
          }
          await response.body.drain<void>().catchError((_) {});
          _applyRedirect(operation, response.status, location);
          continue;
        }
        _deliverResponse(operation, response);
        return;
      }
    } catch (error) {
      _fail(operation.id, error is _FetchFailure ? error.message : '$error');
    }
  }

  void _applyRedirect(_FetchOperation operation, int status, String location) {
    final target = operation.url.resolve(location);
    // 303, and 301/302 on POST, become a bodyless GET (fetch spec).
    if (status == 303 ||
        ((status == 301 || status == 302) && operation.method == 'POST')) {
      operation.method = 'GET';
      operation.body = null;
      operation.headers = operation.headers
          .where((header) => !_bodyHeaders.contains(header.key.toLowerCase()))
          .toList();
    }
    if (target.origin != operation.url.origin) {
      operation.headers = operation.headers
          .where((header) => header.key.toLowerCase() != 'authorization')
          .toList();
    }
    operation.url = target;
    operation.redirected = true;
  }

  static String? _headerValue(
    List<MapEntry<String, String>> headers,
    String name,
  ) {
    for (final header in headers) {
      if (header.key.toLowerCase() == name) return header.value;
    }
    return null;
  }

  void _deliverResponse(_FetchOperation operation, JsFetchResponse response) {
    operation.responded = true;
    final subscription = response.body.listen(
      (chunk) {
        final active = _operations[operation.id];
        if (active == null) return;
        active.subscription?.pause();
        active.received += chunk.length;
        final limit = _options.maxResponseBytes;
        if (limit > 0 && active.received > limit) {
          _fail(operation.id, 'response body exceeds maxResponseBytes ($limit)');
          return;
        }
        _web._runTask(_exports['onChunk'], [
          operation.id,
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
        ]);
      },
      onDone: () {
        if (_operations.remove(operation.id) == null) return;
        _web._runTask(_exports['onEnd'], [operation.id]);
      },
      onError: (Object error) => _fail(operation.id, '$error'),
      cancelOnError: true,
    );
    subscription.pause();
    operation.subscription = subscription;
    _web._runTask(_exports['onResponse'], [
      operation.id,
      response.status,
      response.statusText,
      [
        for (final header in response.headers) [header.key, header.value],
      ],
      operation.url.toString(),
      operation.redirected,
    ]);
  }

  void _pull(int id) {
    _operations[id]?.subscription?.resume();
  }

  void _cancel(int id) {
    final operation = _operations.remove(id);
    if (operation == null) return;
    unawaited(operation.subscription?.cancel().catchError((_) {}));
  }

  void _abortRequest(int id) {
    final operation = _operations.remove(id);
    if (operation == null) return;
    if (!operation.abort.isCompleted) operation.abort.complete();
    unawaited(operation.subscription?.cancel().catchError((_) {}));
  }

  void _fail(int id, String message) {
    final operation = _operations.remove(id);
    if (operation != null) {
      unawaited(operation.subscription?.cancel().catchError((_) {}));
    }
    _web._runTask(_exports['onError'], [id, message]);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final operation in _operations.values.toList()) {
      if (!operation.abort.isCompleted) operation.abort.complete();
      unawaited(operation.subscription?.cancel().catchError((_) {}));
    }
    _operations.clear();
    _ownedHandler?.close();
    _exports = const {};
  }
}

class _FetchFailure implements Exception {
  const _FetchFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
