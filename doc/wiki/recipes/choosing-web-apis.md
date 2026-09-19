# Recipe: choosing Web APIs

## Goal

Give a context the Web APIs its scripts use and nothing else. Reference
(module table, `fetch` options, deviations): [Web APIs](../api/web-apis.md).

Modules are a functional split: leaving one out makes the context smaller, it
does not sandbox the script. Limits come from `JsFetchOptions`, your bridges,
`memoryLimit` and `timeout` — see [Security](../guides/security.md).

## Pick a starting point

| Scripts need | `webApis:` | Installed |
|---|---|---|
| Plain ECMAScript, no `console`, no timers | `const JsWebApis.none()` | nothing |
| `console`, timers, `structuredClone`, `atob` … | `const JsWebApis()` (default) | `core` |
| `URL` only | `const JsWebApis(modules: {JsWebModule.url})` | `core`, `url` |
| `Headers` / `Request` / `Response` | `const JsWebApis(modules: {JsWebModule.http})` | `core`, `url`, `events`, `streams`, `http` |
| the same, with `blob()` / `formData()` | `const JsWebApis(modules: {JsWebModule.http, JsWebModule.blob})` | … + `blob` |
| `fetch` | `JsWebApis(fetch: JsFetchOptions(...))` | `http` closure + `fetch` |
| everything | `JsWebApis.standard(fetch: JsFetchOptions(...))` | every module |

The same object goes to every constructor:

```dart
final js = getJavascriptRuntime(webApis: const JsWebApis(modules: {JsWebModule.url}));

final pool = JsEnginePool(
  maxSize: 4,
  config: const JsEnginePoolConfig(webApis: JsWebApis(modules: {JsWebModule.url})),
);
```

## `fetch` with a policy

`fetch` exists only when you pass `JsFetchOptions`. Its `allowUrl` is checked
for the request and every redirect hop:

```dart
final js = getJavascriptRuntime(
  webApis: JsWebApis(
    modules: {JsWebModule.blob}, // for response.blob() / formData()
    fetch: JsFetchOptions(
      allowUrl: (url) => url.scheme == 'https' && url.host == 'api.example.com',
      maxResponseBytes: 8 << 20,
      connectionTimeout: const Duration(seconds: 10),
    ),
  ),
  timeout: 5000,
);

final r = await js.handlePromise(js.evaluate('''
  fetch('https://api.example.com/v1/items').then((res) => res.json())
'''));
```

In tests, replace the network with a `handler` (one exchange, no redirects):

```dart
JsFetchOptions(handler: (request) async => JsFetchResponse(
  status: 200,
  headers: const [MapEntry('content-type', 'application/json')],
  body: Stream.value(utf8.encode('{"stub":true}')),
))
```

## Optional features

Some modules add features when another module is also installed, but never
install it for you:

| Installed | Also installed | Adds |
|---|---|---|
| `streams` | `encoding` | `TextEncoderStream`, `TextDecoderStream` |
| `blob` | `streams` | `Blob.prototype.stream()` |
| `http` (and so `fetch`) | `blob` | `blob()` / `formData()` on `Request` / `Response`; `Blob` and `FormData` bodies |

When a script's `response.blob()` throws a `TypeError` because `blob` is
`undefined`, add `JsWebModule.blob`.

## Check what a context gets

From Dart, before creating anything:

```dart
const apis = JsWebApis(modules: {JsWebModule.http});
apis.resolvedModules.map((m) => m.name); // (core, url, events, streams, http)
apis.installs(JsWebModule.blob);         // false
JsWebModule.http.requires;               // [core, url, events, streams]
JsWebModule.http.optional;               // [blob]
JsWebModule.fetch.hostConfig;            // 'JsFetchOptions'
```

From a script, feature-test as in a browser:

```js
if (typeof Response.prototype.blob === 'function') { /* blob installed */ }
```

## Upgrading from 1.4

| 1.4 | 1.5 |
|---|---|
| `JsWebApis(modules: {JsWebModule.http})` also installed `blob` | add `JsWebModule.blob` for `Blob`, `FormData`, `blob()` / `formData()` |
| `JsWebApis(fetch: ...)` had `response.blob()` | add `JsWebModule.blob`, or use `JsWebApis.standard(fetch: ...)` |
| `{JsWebModule.streams}` also installed `encoding` | add `JsWebModule.encoding` for `TextEncoderStream` / `TextDecoderStream` |
| `{JsWebModule.blob}` also installed `streams` | add `JsWebModule.streams` for `Blob.prototype.stream()` |
| `JsWebModule.capability` | `JsWebModule.hostConfig` |

`JsWebApis()` and `JsWebApis.standard(...)` install the same modules as before.
