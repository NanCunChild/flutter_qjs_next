# flutter_qjs_next

Flutter / Dart bindings for [QuickJS](https://github.com/bellard/quickjs) via `dart:ffi`.

- Embedded QuickJS **2025-09-13** (ES2023-era language features)
- Platforms: **Android, iOS, macOS, Linux, Windows** (no Web — native FFI only)
- API style compatible with [flutter_js](https://github.com/abner/flutter_js) (`JavascriptRuntime`, `getJavascriptRuntime()`)

## Install

```yaml
dependencies:
  flutter_qjs_next: ^0.0.1
```

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';
```

## Quick start

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';

void main() {
  final js = getJavascriptRuntime(
    timeout: 5000, // ms of JS work before interrupt; null/0 = off
    memoryLimit: 32 * 1024 * 1024,
  );

  final r = js.evaluate('Math.trunc(Math.random() * 100).toString()');
  print(r.stringResult);

  // Promise / setTimeout need the host event loop:
  // either call js.dispatch() after async work, or use evaluateAsync + handlePromises.
  js.dispose();
}
```

### Limits

| Parameter | Meaning |
|-----------|---------|
| `stackSize` | JS stack size in bytes (default 1 MiB) |
| `timeout` | Interrupt after this many **ms** of JS execution (`clock()`-based today) |
| `memoryLimit` | Heap limit in bytes |

`forceJavascriptCoreOnAndroid` and `xhr` are accepted for API compatibility with flutter_js but **are not implemented** (always QuickJS; no built-in XHR/fetch polyfill).

### Dart ↔ JS bridge

```dart
js.onMessage('log', (args) {
  print(args); // typically a List from JSON
});
```

```js
sendMessage('log', JSON.stringify([1, 2, 3]));
```

Prefer `setupBridge` / newer channel APIs when available; channel names and payloads should be treated as untrusted if they come from user scripts.

### TypedArray / binary

`TypedData` (e.g. `Uint8List`) maps to JS TypedArrays via a bulk buffer path.  
`ByteBuffer` maps to `ArrayBuffer`.  
Use `evaluateJson` when you only need a Dart JSON-like tree (often faster for large objects).

### Event loop / Promises

QuickJS jobs and `setTimeout` are drained through the runtime’s `ReceivePort`. After scheduling async JS, call `dispatch()` (or rely on paths that already pump the port, e.g. promise helpers in `handle_promises.dart`).

### Logging

```dart
FlutterQjsLogger.level = FlutterQjsLogLevel.debug;
FlutterQjsLogger.handler = (level, message, error) { /* ... */ };
```

## Example app

See `example/` for a full Flutter demo (AJV, typed arrays, etc.).

```bash
cd example && flutter run
```

## Benchmark

**Use Flutter’s test harness** (loads the plugin native library correctly).
Do **not** use bare `dart run` on this package: on recent Dart SDKs, standalone
compilation of `dart:ffi` callbacks (`Pointer.fromFunction`) can crash the
compiler before any code runs.

```bash
cd example
flutter test test/benchmark_test.dart
```

Results are printed to the test console (µs/op for evaluate, evaluateJson, and
TypedArray marshalling). Shared logic lives in `example/lib/benchmark_runner.dart`.

Interactive option:

```bash
cd example && flutter run
# tap "Run Benchmarks" on the home screen
```

`benchmark/flutter_qjs_benchmark.dart` only prints these instructions if invoked
with `dart run` by mistake.

## Architecture (short)

- `lib/quickjs/*` — Dart FFI bindings and marshalling  
- `cxx/ffi.cpp` — stable C ABI around QuickJS (`JSValue*` on the heap)  
- `cxx/quickjs/` — embedded engine (same tree used on Windows via `cxx-windows/`)

## Limitations / security

- Scripts run with full engine capability; do not eval untrusted code without your own sandbox policy.
- No Web platform; no shipping XHR implementation in this package.
- Dispose runtimes you create (`dispose()`) to free native resources.

## References

- [bellard/quickjs](https://github.com/bellard/quickjs)
- [ekibun/flutter_qjs](https://github.com/ekibun/flutter_qjs)
- [abner/flutter_js](https://github.com/abner/flutter_js)
- [kodjodevf/flutter_qjs](https://github.com/kodjodevf/flutter_qjs)
