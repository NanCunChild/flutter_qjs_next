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
    timeout: 5000, // recommended for untrusted scripts; null/0 = off
    // memoryLimit defaults to 64 MiB; use 0 for unlimited
  );

  final r = js.evaluate('Math.trunc(Math.random() * 100).toString()');
  print(r.stringResult);

  // Promise / setTimeout need the host event loop:
  // either call js.dispatch() after async work, or use evaluateAsync + handlePromises.
  js.dispose(); // always dispose — free native heap + channel maps
}
```

### Limits

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `stackSize` | JS stack size in bytes | 1 MiB |
| `timeout` | Interrupt after this many **ms** of wall-clock JS work (`null`/`0` = off) | off |
| `memoryLimit` | Heap limit in bytes (`0` = unlimited) | **64 MiB** |

Each `getJavascriptRuntime()` is a **separate** QuickJS engine (own heap, channels, `ReceivePort`). Create many only when you need isolation; otherwise reuse one runtime or use a pool.

### Multi-engine pool

```dart
final pool = JsEnginePool(maxSize: 4, config: JsEnginePoolConfig(timeout: 3000));
final out = await pool.withEngine((js) async {
  return js.evaluate('1 + 1').stringResult;
});
pool.dispose();
```

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

```dart
// Drain Promise microtasks / jobs in a tight loop:
js.executePendingJobs(); // or executePendingJob() once per job

// QuickJsRuntime2 only:
// (js as QuickJsRuntime2).hasPendingJobs
```

### Memory / GC

```dart
js.runGC();
final m = js.getMemoryUsage(); // JsMemoryUsage? (malloc / JS heap sizes)
```

Default **heap limit is 64 MiB** (`memoryLimit: 0` for unlimited). Always call **`dispose()`** so native `JSRuntime` / `JSContext`, `ReceivePort`, and channel maps are released.

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
# default: 8 RNG seeds → mean ± σ (us/op; buffers also MiB/s)
flutter test test/benchmark_test.dart

# adjust repeats (1 = single seed, faster smoke)
flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=3
flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=1

# base seed (used when BENCH_RUNS=1, or to extend seeds when runs>8)
flutter test test/benchmark_test.dart --dart-define=BENCH_SEED=464037
```

Shared logic: `example/lib/benchmark_runner.dart`
(`runFlutterQjsBenchmarkSuite` / `runFlutterQjsBenchmarks`).

Coverage:

1. Hot path: tiny `evaluate` and cached `JSInvokable.invoke`
2. String / small `Map` Dart↔JS identity round-trips
3. Buffer size ladder (1 KiB / 64 KiB / 1 MiB) for owned TypedArray path
4. `evaluateJson` vs full `evaluate` (deep jsToDart) on array and object payloads
5. Multi-seed mean ± σ (`kBenchmarkDefaultSeeds`, default **8** runs) plus OS /
   CPU / executable banner for cross-commit comparison

Interactive option:

```bash
cd example && flutter run
# tap "Run Benchmarks" (same 8-run suite as the test default)
```

`benchmark/flutter_qjs_benchmark.dart` only prints these instructions if invoked
with `dart run` by mistake.

## Architecture (short)

- `lib/quickjs/*` — Dart FFI bindings and marshalling  
- `cxx/ffi.cpp` — stable C ABI around QuickJS (`JSValue*` on the heap)  
- `cxx/quickjs/` — embedded engine (same tree used on Windows via `cxx-windows/`)

## Limitations / security

- Scripts run with full engine capability; do not eval untrusted code without your own sandbox policy.
- Prefer **`timeout`** (wall-clock interrupt) and the default **`memoryLimit`** (64 MiB) for untrusted scripts.
- No Web platform; no shipping XHR implementation in this package.
- Dispose runtimes you create (`dispose()`) to free native resources.
- Module sources from `moduleHandler` are copied into QuickJS then **`free`’d in native** (no Dart microtask free race).
- `JSValue*` returned across the FFI boundary is heap-allocated; callers must free via the package APIs (`jsFreeValue` / Dart wrappers) — double-free of the same handle after dispose is undefined.

## References

- [bellard/quickjs](https://github.com/bellard/quickjs)
- [ekibun/flutter_qjs](https://github.com/ekibun/flutter_qjs)
- [abner/flutter_js](https://github.com/abner/flutter_js)
- [kodjodevf/flutter_qjs](https://github.com/kodjodevf/flutter_qjs)
