# Web APIs (WinterTC subset)

`flutter_qjs_next` installs a subset of the Web platform APIs into every JS
context. It is **not** a WinterTC-conformant runtime: QuickJS has no
`WebAssembly`, which the Minimum Common API requires.

Design notes: `doc/design/2026-09-13-web-apis.md`.

## Modules

Web APIs are installed per module. You name the modules you want and the runtime
installs their **dependency closure**, in dependency order. What a module needs
from another module is the module's business, not yours.

| Module | Requires | Globals |
|---|---|---|
| `core` | — | `setTimeout` / `clearTimeout` / `setInterval` / `clearInterval`, `queueMicrotask`, `reportError`, `console`, `performance`, `structuredClone`, `atob` / `btoa`, `DOMException`, `crypto.getRandomValues` / `crypto.randomUUID` |
| `events` | `core` | `Event`, `CustomEvent`, `EventTarget`, `AbortController`, `AbortSignal` |
| `encoding` | `core` | `TextEncoder`, `TextDecoder` |
| `url` | `core` | `URL`, `URLSearchParams` |
| `crypto` | `core` | `crypto.subtle`, `SubtleCrypto`, `CryptoKey` |
| `navigator` | `core` | `Navigator`, `navigator` |
| `streams` | `core`, `events`, `encoding` | `ReadableStream`, `WritableStream`, `TransformStream`, the queuing strategies, `TextEncoderStream`, `TextDecoderStream` |
| `blob` | `core`, `streams` | `Blob`, `File`, `FormData` |
| `http` | `core`, `url`, `events`, `streams`, `blob` | `Headers`, `Request`, `Response` |
| `fetch` | `core`, `http`, `streams` | `fetch` — **needs a capability**, see below |

```dart
// Presets.
const JsWebApis.none();       // nothing at all: plain ECMAScript
const JsWebApis();            // core only (the default)
const JsWebApis.standard();   // every pure-computation module
JsWebApis.standard(fetch: JsFetchOptions(...));

// Or name what you need; dependencies come along.
const JsWebApis(modules: {JsWebModule.url});   // core + url, 224 KiB
const JsWebApis(modules: {JsWebModule.http});  // pulls url, events, encoding,
                                               // streams and blob with it
```

`getJavascriptRuntime(webApis: ...)` and `JsEnginePoolConfig(webApis: ...)` take
the same object. `JsWebApis.resolvedModules` returns the ordered closure and
`installs(module)` answers whether a module ends up in it.

### Capabilities

`fetch` is the only module that reaches outside the JS context, so it is the
only one that cannot be switched on by itself: it is installed when — and only
when — you pass the policy object that grants it.

```dart
JsWebApis(modules: {JsWebModule.fetch})              // ArgumentError
JsWebApis(fetch: JsFetchOptions(...))                // fetch + its closure
JsWebApis.standard(fetch: JsFetchOptions(...))       // everything
```

Every other module is pure computation over values already in the heap. Without
`JsFetchOptions` the engine has no network at all. See
[Security](../guides/security.md).

## Cost per module

Measured on Linux x64 (debug build), per engine: `heap` is
`getMemoryUsage().memoryUsedSize` after construction, `own` is what the module
itself adds on top of its dependencies, and `create` is engine construction
including the install.

| Modules installed | own | heap | create |
|---|---|---|---|
| *(`JsWebApis.none()`)* | — | 77 KiB | 0.22 ms |
| `core` | 82 KiB | 160 KiB | 0.90 ms |
| `+ navigator` | 3 KiB | 163 KiB | 0.84 ms |
| `+ encoding` | 7 KiB | 167 KiB | 0.89 ms |
| `+ crypto` | 22 KiB | 181 KiB | 0.95 ms |
| `+ events` | 30 KiB | 190 KiB | 1.04 ms |
| `+ url` | 64 KiB | 224 KiB | 1.09 ms |
| `+ events, encoding, streams` | 89 KiB | 286 KiB | 1.45 ms |
| `+ …, blob` | 23 KiB | 310 KiB | 1.53 ms |
| `+ …, url, http` | 51 KiB | 425 KiB | 2.10 ms |
| `JsWebApis.standard()` | — | 451 KiB | 2.28 ms |
| `JsWebApis.standard(fetch: …)` | 8 KiB | 459 KiB | 2.35 ms |

A context needs roughly **320 KiB** of `memoryLimit` to install `core` and about
**1 MiB** for the full `standard()` set; below that, construction fails with
`InternalError: out of memory`. Selecting fewer modules lowers both numbers — a
URL-only engine is under half the size of a `standard()` one.

Module sources are compiled to bytecode **once per process** (in a scratch
engine, so the compile peak is not charged to your `memoryLimit`) and then
evaluated per context. A module you never select is never compiled, and its
source is a `const String` the AOT compiler can drop from the binary.

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
- **`IsolateQjs`** installs `core` only.

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
