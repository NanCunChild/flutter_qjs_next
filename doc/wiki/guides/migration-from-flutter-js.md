# Migration from flutter_js / older flutter_qjs

## Package

| Before | After |
|--------|--------|
| `flutter_js` | `flutter_qjs_next` |
| Older `flutter_qjs` forks | `package:flutter_qjs_next/flutter_qjs.dart` |

```bash
flutter pub add flutter_qjs_next
```

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';
```

## Same-shaped APIs

Still work in the common case:

- `getJavascriptRuntime(...)`
- `JavascriptRuntime.evaluate` / `evaluateAsync`
- `onMessage` / `setupBridge`
- `JsEvalResult`
- `handlePromise` extension
- `dispose()`

## Behavioral differences

| Topic | flutter_qjs_next |
|-------|------------------|
| Engine on Android | **Always QuickJS** (`forceJavascriptCoreOnAndroid` ignored) |
| XHR / fetch | No XHR ever. `fetch` is available by opting in: `webApis: JsWebApis(fetch: JsFetchOptions(...))` |
| Default QuickJS heap | **64 MiB per runtime** unless you set `memoryLimit` |
| Promise jobs | `autoExecutePendingJobs: true` by default |
| Promise helper | Lightweight `handlePromise` (no 20 ms query poll registry) |
| Multi-engine | `JsEnginePool`; for tenants `resetMode: EngineResetMode.soft` |
| Logging | `FlutterQjsLogger` (not only `print`) |

## Fetch

flutter_js shipped an XHR-based `fetch`. Here `fetch` is native to the package
but off unless you pass a policy; the demo button in `example/lib/main.dart`
uses `JsWebApis.standard(fetch: JsFetchOptions(allowUrl: ...))`, which
allows only the host it reads. `response.blob()` / `formData()` also need
`JsWebModule.blob` (included in `standard`). See
[Choosing Web APIs](../recipes/choosing-web-apis.md).

## Native library env (advanced)

Set `FLUTTER_QJS_NEXT_LIBRARY` to the path of a native library build to load it
instead of the one bundled with the app, e.g. in tooling or when running tests
against a specific build. A library older than the Dart code fails at load with
the missing symbol and how to rebuild.

## Checklist

1. Change dependency + imports.  
2. Remove assumptions about JSC-only APIs.  
3. Add `timeout` / keep default `memoryLimit` for untrusted scripts.  
4. Re-test Promise and bridge flows with `handlePromise`.  
5. Replace any XHR-dependent scripts with host bridges or an explicit polyfill.  

The default heap limit is not a process-memory limit. If the migrated app uses
large Dart buffers, many runtimes, or untrusted bridge payloads, add explicit
payload validation and keep the pool size bounded.
