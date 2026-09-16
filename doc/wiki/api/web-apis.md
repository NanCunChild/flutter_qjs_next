# Web APIs (WinterTC subset)

`flutter_qjs_next` installs a subset of the Web platform APIs into every JS
context. It is **not** a WinterTC-conformant runtime: QuickJS has no
`WebAssembly`, which the Minimum Common API requires.

Design notes: `doc/design/2026-09-13-web-apis.md`.

## Levels

| Level | Default | What is installed |
|-------|---------|-------------------|
| **L0 core** | on | `setTimeout` / `clearTimeout` / `setInterval` / `clearInterval`, `queueMicrotask`, `reportError`, `console`, `performance`, `structuredClone`, `atob` / `btoa`, `DOMException`, `crypto.getRandomValues` / `crypto.randomUUID` |
| **L1 standard library** | off | `Event` / `CustomEvent` / `EventTarget`, `AbortController` / `AbortSignal`, `TextEncoder` / `TextDecoder`, `URL` / `URLSearchParams`, `Blob` / `File` / `FormData`, `ReadableStream` / `WritableStream` / `TransformStream` + queuing strategies + `TextEncoderStream` / `TextDecoderStream`, `Headers` / `Request` / `Response`, `crypto.subtle`, `navigator` |
| **L2 network** | off | `fetch` (implies L1) |

```dart
final js = QuickJsRuntime2(
  webApis: JsWebApis(
    web: true,                       // L1
    fetch: JsFetchOptions(           // L2 (implies L1)
      allowUrl: (url) => url.host == 'api.example.com',
      maxResponseBytes: 16 * 1024 * 1024,
    ),
    userAgent: 'my-app/1.0',
  ),
);
```

`getJavascriptRuntime(webApis: ...)` and `JsEnginePoolConfig(webApis: ...)` take
the same object. `JsWebApis(core: false)` installs **nothing** (no `console`, no
timers) for engines that need the smallest possible context.

## Cost per level

Measured on Linux x64 (debug build), per engine:

| Level | Engine creation | `softReset()` | JS heap |
|-------|-----------------|---------------|---------|
| `core: false` | 0.31 ms | 0.27 ms | 78 KiB |
| L0 (default) | 1.06 ms | 0.92 ms | 160 KiB |
| L0 + L1 | 2.97 ms | 2.58 ms | 453 KiB |
| L0 + L1 + fetch | 2.94 ms | 2.66 ms | 461 KiB |

Module sources are compiled to bytecode **once per process** (in a scratch
engine, so the compile peak is not charged to your `memoryLimit`) and then
evaluated per context. A context with the Web APIs needs roughly **320 KiB** of
`memoryLimit` for L0 and about **1 MiB** for L1; below that, construction fails
with `InternalError: out of memory`.

## Event loop

Timer callbacks and `fetch` data are host tasks: the runtime calls into JS and
then performs the microtask checkpoint, so a promise resolved inside a timer
callback continues without a manual pump.

```js
setTimeout(() => { Promise.resolve().then(() => { done = true; }); }, 5);
```

When `QuickJsRuntime2.autoExecutePendingJobs` is `false` the checkpoint is left
to you, as with `evaluate`.

`clearTimeout` / `clearInterval` cancel the Dart `Timer`. An exception thrown by
a timer callback, a `queueMicrotask` callback or an event listener is reported
through `reportError`, which logs at error level via `FlutterQjsLogger`.

## `fetch`

```dart
JsFetchOptions(
  allowUrl: (url) => url.scheme == 'https' && url.host.endsWith('.example.com'),
  handler: myHandler,           // optional: replace the network implementation
  maxResponseBytes: 64 << 20,   // 0 = unlimited
  maxRedirects: 20,
  connectionTimeout: Duration(seconds: 10),
)
```

- `allowUrl` is checked for the initial URL **and every redirect hop**.
- Only `http:` and `https:` are supported.
- Response bodies stream: the Dart subscription stays paused until the script
  reads the next chunk, so back-pressure reaches the socket.
- Redirects are followed by the runtime, not by the handler: `303`, and
  `301`/`302` on `POST`, become a bodyless `GET`, and `Authorization` is dropped
  when the origin changes.
- A custom `handler` performs exactly one exchange and must not follow
  redirects. Use it to plug in your own HTTP stack or a test stub:

```dart
JsFetchOptions(handler: (request) async => JsFetchResponse(
  status: 200,
  headers: const [MapEntry('content-type', 'application/json')],
  body: Stream.value(utf8.encode('{"stub":true}')),
));
```

Without `JsFetchOptions`, `fetch` is not defined at all — the engine has no
network. See [Security](../guides/security.md).

## Deviations

- **URL**: no full UTS #46 / IDNA mapping. Non-ASCII hosts go through NFC,
  lowercase and Punycode.
- **Streams**: byte streams (`type: 'bytes'`) and BYOB readers throw
  `TypeError`. Pull scheduling can differ from other engines by one microtask.
- **`TextDecoder`**: UTF-8 only; other labels throw `RangeError`.
- **`crypto.subtle`**: `digest` (SHA-1/256/384/512) and HMAC
  (`generateKey` / `importKey` / `exportKey` / `sign` / `verify`) only.
  Everything else rejects with `NotSupportedError`.
- **`fetch`**: no cookie store, no CORS, no cache. A `ReadableStream` request
  body is buffered before sending. `redirect: 'manual'` returns the real 3xx
  response rather than an opaque one.
- **Not implemented**: `WebAssembly`, `CompressionStream` / `DecompressionStream`,
  `URLPattern`, `XMLHttpRequest`, `WebSocket`.
- **`IsolateQjs`** installs L0 only.

Behaviour is verified against Node.js 24 by the differential tests in
`example/test/web_apis_*_test.dart`. Where Node itself deviates from the spec
(`webkitRelativePath`, `endings: 'native'` with a lone `CR`, cloning
`FormData`), this package follows the spec and the tests say so.

## Compatibility notes

The previous `console` / `setTimeout` implementation used the internal channels
`ConsoleLog` and `SetTimeout` and the globals `__NATIVE_FLUTTER_JS__*`. Both are
gone: `console` now formats like `util.format` / `util.inspect` (`%s`, `%d`,
`%o`, BigInt, cycles, `Error` stacks) and calls the logger directly, and global
Web API properties are non-enumerable, as in a browser.
