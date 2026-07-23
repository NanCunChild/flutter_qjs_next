# Runtime API

## `getJavascriptRuntime`

```dart
JavascriptRuntime getJavascriptRuntime({
  bool forceJavascriptCoreOnAndroid = false, // ignored
  bool xhr = true,                           // ignored
  Map<String, dynamic>? extraArgs = const {},
  int stackSize = 1024 * 1024,
  int? timeout,
  int? memoryLimit = kDefaultJsMemoryLimit, // 64 MiB; 0 = unlimited
});
```

`extraArgs` may override: `stackSize`, `timeout`, `memoryLimit` (same keys as named parameters).

Creates a `QuickJsRuntime2`, then `enableHandlePromises()`.

## `QuickJsRuntime2` constructor

```dart
QuickJsRuntime2({
  String Function(String name)? moduleHandler,
  int stackSize = 1024 * 1024,
  int? timeout,
  int? memoryLimit = kDefaultJsMemoryLimit,
  void Function(dynamic reason)? hostPromiseRejectionHandler,
  bool autoExecutePendingJobs = true,
});
```

Calls `init()` (channels, console, setTimeout).

### Memory-limit semantics

`memoryLimit` is a **per-runtime QuickJS heap limit**, not a limit for the
whole Flutter process. The contract is:

| Value | Meaning |
|-------|---------|
| positive integer | QuickJS heap limit in bytes |
| `0` | Unlimited QuickJS heap (not recommended for untrusted code) |
| `null` or negative | Falls back to `kDefaultJsMemoryLimit` (64 MiB) |

The limit does not include the Dart heap, Flutter allocations, process RSS, or
all native/plugin allocations. A single `TypedData` or `ByteBuffer` bridge
payload larger than the runtime limit is rejected, but this is not a complete
process-memory quota. Use `getMemoryUsage()` for QuickJS metrics and bound pool
size when multiple runtimes are live.

## Evaluate

```dart
JsEvalResult evaluate(String code, {String? sourceUrl});
// QuickJsRuntime2 also: name, evalFlags

Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl});
// Currently: Future.value(evaluate(...))

dynamic evaluateJson(String code, {String? sourceUrl});
```

### `evaluateJson`

Runs the script, then `JSON.stringify` in-engine and `jsonDecode` in Dart.

- **Fast** for large arrays/objects  
- Result must be JSON-serializable (functions, Promises, cycles dropped / `null` as with `JSON.stringify`)  
- Throws on JS exception (unlike `evaluate`, which returns `isError: true`)

## Jobs / GC / metrics

```dart
int executePendingJob();                 // one job; ≤0 if none / error
int executePendingJobs({int maxJobs = 10000});
bool hasPendingJobs;                     // QuickJsRuntime2
bool autoExecutePendingJobs;             // QuickJsRuntime2, default true

void runGC();
JsMemoryUsage? getMemoryUsage();
```

`JsMemoryUsage` exposes QuickJS `JS_ComputeMemoryUsage` style fields (malloc / JS heap sizes). See `lib/quickjs/ffi.dart`.

## Lifecycle

| Method | Meaning |
|--------|---------|
| `close()` | Free native runtime/context; next evaluate may recreate (unless disposed) |
| `dispose()` | Idempotent: mark disposed, close port, free native, drop channels; **cannot reopen** |
| `softReset()` | Clear globals / channels / timers; keep native heap + engine id (pool `soft`) |
| `reinitialize()` | `close` + clear contexts + new engine id + `init()` again (pool `hard`) |

Always call **`dispose()`** when you own a runtime and are done.

```dart
String getEngineInstanceId();
void setInspectable(bool inspectable); // no-op today
```

## Call / convert / stringify

```dart
JsEvalResult callFunction(Pointer fn, Pointer obj);
T? convertValue<T>(JsEvalResult jsValue);
String jsonStringify(JsEvalResult jsValue); // jsonEncode(rawResult)
```

`callFunction` is low-level FFI; most apps use `evaluate` or `JSInvokable.invoke`.

## Dispatch loop

```dart
// QuickJsRuntime2
Future<void> dispatch() async {
  await for (final _ in port) {
    _executePendingJob();
  }
}
```

Listen on the engine’s `ReceivePort` and drain jobs. Closing the port (via `dispose`) ends the loop.

## Related

- [Promises & event loop](promises-and-event-loop.md)  
- [Bytecode](bytecode.md)  
- [Engine pool](engine-pool.md)  
