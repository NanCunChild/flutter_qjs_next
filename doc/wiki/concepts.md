# Concepts

Mental model for **flutter_qjs_next**. Read this after [Getting Started](getting-started.md).

## One runtime = one QuickJS engine

`getJavascriptRuntime()` (or `QuickJsRuntime2(...)`) creates:

- A native `JSRuntime` + `JSContext` (QuickJS heap)
- Dart channel maps keyed by a **unique engine instance id**
- A `ReceivePort` used for the JS job / event loop side

Engines do **not** share `globalThis`. Create many only when you need isolation; otherwise reuse one runtime or use [`JsEnginePool`](api/engine-pool.md).

Engine ids look like:

```text
qjs-<isolateHash>-<serial>-<microseconds>
```

so parallel isolates do not collide in the static channel registry.

## Layering

```text
Your Flutter / Dart app
        │
        ▼
lib/  (JavascriptRuntime, QuickJsRuntime2, pool, marshalling)
        │  dart:ffi
        ▼
cxx/ffi.cpp   stable C ABI (heap-allocated JSValue*)
        │
        ▼
cxx/quickjs/  embedded QuickJS 2026-06-04
```

You almost always stay on the Dart API. Freeing raw `JSValue*` yourself is undefined; use package wrappers (`JSInvokable.free()`, `dispose()`, etc.).

## Built-ins on `init()`

When a runtime is constructed, `JavascriptRuntime.init()` installs:

| Feature | Role |
|---------|------|
| `console.log/warn/error/info` | Forward to `FlutterQjsLogger` via channel `ConsoleLog` |
| `setTimeout` / `clearTimeout` | Schedule Dart `Timer`s; callbacks run through a **cached** invokable runner |
| `sendMessage(channel, payload)` | Call Dart handlers registered with `onMessage` / `setupBridge` |

These are reinstalled after [`reinitialize()`](api/runtime.md) (pool reset).

## Evaluating code

| API | Use when |
|-----|----------|
| `evaluate` | Normal path; full JS→Dart conversion of the result |
| `evaluateAsync` | Same work, returned as `Future` (implementation is still sync evaluate) |
| `evaluateJson` | Result is a JSON-serializable tree; **much faster** for large arrays/objects |
| `compile` + `evaluateBytecode` | Precompile once, run bytecode many times |

Results are wrapped in [`JsEvalResult`](api/overview.md): `stringResult`, `rawResult`, `isError`, `isPromise`.

## Jobs, Promises, and the host loop

QuickJS Promise reactions and other microtasks sit on a **job queue**.

- By default **`autoExecutePendingJobs` is `true`**: after `evaluate` / `evaluateJson` / `evaluateBytecode` / `callFunction`, the runtime drains pending jobs.
- You can also call `executePendingJob()` / `executePendingJobs()` yourself.
- Long-lived async (`setTimeout`, host Futures resolved back into JS) may need `dispatch()` and/or [`handlePromise`](api/promises-and-event-loop.md).

Disabling auto-drain is useful when you want explicit control or minimal post-call work.

## Dart ↔ JS values

Marshalling converts:

- Primitives, lists, maps  
- Errors → `JSError`  
- Functions → `JSInvokable` (call with `invoke`, then **`free()`** when done)  
- `TypedData` ↔ TypedArray (bulk copy fast path)  
- `ByteBuffer` ↔ `ArrayBuffer`  

Deep object graphs via full `jsToDart` are convenient but slower; prefer `evaluateJson` when you only need data.

Details: [Types & marshalling](api/types-and-marshalling.md).

## Bridges (host functions)

JS calls Dart:

```js
sendMessage('myChannel', JSON.stringify({ a: 1 }));
```

Dart registers:

```dart
js.onMessage('myChannel', (args) { /* args often a List/Map from JSON */ });
```

Treat channel names and payloads as **untrusted** if scripts are untrusted. Prefer bridges over string-building eval for host entry points.

## Isolation strategies

| Approach | When |
|----------|------|
| Single long-lived runtime | One app feature, trusted or carefully gated scripts |
| Multiple runtimes | Hard isolation between features/tenants |
| [`JsEnginePool`](api/engine-pool.md) | Bounded concurrency; default **`resetOnRelease`** reinitializes between tenants |

## Compatibility knobs

`getJavascriptRuntime(forceJavascriptCoreOnAndroid: …, xhr: …)` accepts flutter_js-style arguments but:

- Always uses QuickJS  
- Does **not** install a built-in XHR/fetch polyfill  

See [Migration](guides/migration-from-flutter-js.md).

## Next

- [API overview](api/overview.md)  
- [Security](guides/security.md)  
- [Recipes](recipes/hello-evaluate.md)  
