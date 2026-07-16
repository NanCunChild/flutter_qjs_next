# API overview

Import:

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';
```

## Entry points

| Symbol | Role |
|--------|------|
| `getJavascriptRuntime(...)` | Create a configured `JavascriptRuntime` (QuickJS) + enable promise helpers |
| `kDefaultJsMemoryLimit` | Default per-runtime QuickJS heap cap: **64 MiB**; not a process RSS cap |
| `QuickJsRuntime2` | Concrete engine (cast when you need QuickJS-only APIs) |
| `JavascriptRuntime` | Abstract API shared with flutter_js-style call sites |
| `JsEvalResult` | Evaluate result wrapper |
| `JsEnginePool` / `JsEnginePoolConfig` | Bounded multi-engine pool |
| `FlutterQjsLogger` | Logging for native/bridge diagnostics and JS `console` |
| `HandlePromises` extension | `enableHandlePromises`, `handlePromise` |

## `JsEvalResult`

```dart
class JsEvalResult {
  final String stringResult;
  final dynamic rawResult;
  final bool isPromise;
  final bool isError;
}
```

- Prefer **`rawResult`** for typed use (`int`, `Map`, `Uint8List`, `JSInvokable`, `Future`, …).  
- **`stringResult`** is a display/debug string (`toString()` of the value or error).  
- **`isError`**: JS threw or result is a `JSError`.  
- **`isPromise`**: result was detected as a Promise-like / Dart `Future` from marshalling.

## Compatibility shims

| Argument | Behavior in flutter_qjs_next |
|----------|------------------------------|
| `forceJavascriptCoreOnAndroid` | Ignored — always QuickJS |
| `xhr` | Ignored — no built-in XHR/fetch |

## QuickJS-only features

Cast when needed:

```dart
final qjs = js as QuickJsRuntime2;
qjs.autoExecutePendingJobs = false;
qjs.hasPendingJobs;
qjs.dispatch();
// moduleHandler / hostPromiseRejectionHandler via QuickJsRuntime2 constructor
```

`getJavascriptRuntime` does not currently forward `moduleHandler`; construct `QuickJsRuntime2` yourself if you need modules, then call `enableHandlePromises()` if desired.

## Subpages

1. [Runtime](runtime.md)  
2. [Bridge](bridge.md)  
3. [Types & marshalling](types-and-marshalling.md)  
4. [Promises & event loop](promises-and-event-loop.md)  
5. [Bytecode](bytecode.md)  
6. [Engine pool](engine-pool.md)  
7. [Logging](logging.md)  
