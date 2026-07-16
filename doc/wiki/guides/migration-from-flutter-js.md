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
| XHR / fetch | **Not** installed (`xhr` ignored). Polyfill or bridge yourself |
| Default QuickJS heap | **64 MiB per runtime** unless you set `memoryLimit` |
| Promise jobs | `autoExecutePendingJobs: true` by default |
| Promise helper | Lightweight `handlePromise` (no 20 ms query poll registry) |
| Multi-engine | Prefer `JsEnginePool` + `reinitialize` |
| Logging | `FlutterQjsLogger` (not only `print`) |

## Fetch in the example app

`example/lib/main.dart` may call `fetch(...)` in a demo button. That relies on you providing a polyfill (e.g. assets) or will fail in a clean runtime. Do not assume network exists.

## Native library env (advanced)

If you load a custom dynamic library path for tooling, see package FFI loader / `FLUTTER_QJS_NEXT_LIBRARY` if documented in code comments for your platform.

## Checklist

1. Change dependency + imports.  
2. Remove assumptions about JSC-only APIs.  
3. Add `timeout` / keep default `memoryLimit` for untrusted scripts.  
4. Re-test Promise and bridge flows with `handlePromise`.  
5. Replace any XHR-dependent scripts with host bridges or an explicit polyfill.  

The default heap limit is not a process-memory limit. If the migrated app uses
large Dart buffers, many runtimes, or untrusted bridge payloads, add explicit
payload validation and keep the pool size bounded.
