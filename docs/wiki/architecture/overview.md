# Architecture overview

## Stack

```text
┌─────────────────────────────────────┐
│  App / example (Flutter)            │
├─────────────────────────────────────┤
│  lib/flutter_qjs.dart               │  public export
│  lib/javascript_runtime.dart        │  abstract API + factory
│  lib/quickjs/quickjs_runtime2.dart  │  main engine
│  lib/quickjs/wrapper.dart           │  dartToJs / jsToDart
│  lib/quickjs/engine_pool.dart       │  JsEnginePool
│  lib/extensions/handle_promises.dart│
│  lib/js_eval_result.dart            │
├─────────────────────────────────────┤
│  dart:ffi                           │
├─────────────────────────────────────┤
│  cxx/ffi.cpp + headers              │  stable C ABI, heap JSValue*
│  cxx/quickjs/                       │  QuickJS 2026-06-04
├─────────────────────────────────────┤
│  Platform plugins (android, ios, …) │  package shared library
└─────────────────────────────────────┘
```

## Design goals

1. **flutter_js-compatible surface** where practical (`getJavascriptRuntime`, bridges, `JsEvalResult`).  
2. **Stable FFI ABI** — values often cross as heap-allocated `JSValue*` owned by the Dart wrappers.  
3. **Multi-engine safety** — unique engine ids; channel maps do not collide across isolates/engines.  
4. **Operational defaults** — 64 MiB heap, optional timeout, pool reset, structured logging.  
5. **Performance knobs** — `evaluateJson`, TypedArray bulk, invokable cache, bytecode.

## Ownership & free

- Runtime dispose closes native rt/ctx and the Dart `ReceivePort`.  
- `JSInvokable` / some wrappers must be `free()`’d by the caller when not package-owned.  
- Module handler strings: UTF-8 buffers freed on the native module path after load.

## Event loop touchpoints

| Piece | Role |
|-------|------|
| QuickJS job queue | Promise microtasks |
| `autoExecutePendingJobs` | Drain after sync host entry points |
| `setTimeout` | Dart `Timer` + cached invokable |
| `dispatch()` | Port-driven continuous drain |
| `handlePromise` | Await Future + periodic job pump |

## Testing surfaces

- Unit/integration: `example/test/*`  
- UI: `example/lib/main.dart`  
- Soak helpers: `example/lib/soak_stress_runner.dart`  

## Related docs

- [Concepts](../concepts.md)  
- [Runtime API](../api/runtime.md)  
- [Security](../guides/security.md)  
