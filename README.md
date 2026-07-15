# flutter_qjs_next

Flutter / Dart bindings for [QuickJS](https://github.com/bellard/quickjs) via `dart:ffi`.

- Embedded QuickJS **2026-06-04**
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
final pool = JsEnginePool(
  maxSize: 4,
  config: JsEnginePoolConfig(
    timeout: 3000,
    // default: resetOnRelease true → reinitialize() between tenants
  ),
);
final out = await pool.withEngine((js) async {
  return js.evaluate('1 + 1').stringResult;
});
pool.dispose();
```

Engine ids include the isolate hash (`qjs-<isolate>-<serial>-<us>`) so parallel isolates do not collide in channel maps.

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

#### `autoExecutePendingJobs` (QuickJsRuntime2)

Default is **`true`**: after `evaluate`, `evaluateJson`, `evaluateBytecode`, and `callFunction`, the runtime automatically drains the QuickJS job queue via `executePendingJobs()` (Promise reactions / microtasks).

Implications:

- Synchronous scripts that schedule Promises often settle without an extra manual drain.
- Call order / timing can differ from engines that only run jobs when you call `dispatch()` / `executePendingJobs()` yourself.
- There is a small cost after each of those entry points when jobs are pending.

Disable when you need explicit control or minimal post-call work:

```dart
final js = QuickJsRuntime2(autoExecutePendingJobs: false);
// or:
(js as QuickJsRuntime2).autoExecutePendingJobs = false;
```

With `autoExecutePendingJobs: false`, drain jobs yourself (`executePendingJobs()`, `dispatch()`, or `handlePromises`) after async JS.

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

## Documentation

Full package wiki: **[docs/wiki/](docs/wiki/README.md)**

| | |
|--|--|
| Start here | [Getting started](docs/wiki/getting-started.md) · [Concepts](docs/wiki/concepts.md) |
| API | [API reference](docs/wiki/api/overview.md) · [Runtime](docs/wiki/api/runtime.md) · [Bridge](docs/wiki/api/bridge.md) |
| Guides | [Security](docs/wiki/guides/security.md) · [Performance](docs/wiki/guides/performance.md) · [Migration](docs/wiki/guides/migration-from-flutter-js.md) |
| Recipes | [Hello evaluate](docs/wiki/recipes/hello-evaluate.md) · [Async bridge](docs/wiki/recipes/async-bridge.md) · [Pool](docs/wiki/recipes/multi-tenant-pool.md) |
| Ops | [FAQ](docs/wiki/faq.md) · [Troubleshooting](docs/wiki/troubleshooting.md) · [Testing](docs/wiki/testing-and-benchmarks.md) |

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

### Performance vs pre-optimization baseline

Compared **`main`** to git commit **`3261eb4`** (pre bulk-buffer / marshalling work)
on the same machine, same seeds, **`BENCH_RUNS=32`**, via
`flutter test test/benchmark_test.dart`.

| Scenario | Baseline (us/op) | main (us/op) | Speedup |
|----------|-----------------:|-------------:|--------:|
| evaluate tiny (`1+1`) | 4.7 | 3.6 | **1.3×** |
| host invoke `(a,b)=>a+b` | 3.0 | 2.1 | **1.4×** |
| string Dart→JS→Dart | 9.2 | 2.7 | **3.4×** |
| small Map Dart→JS→Dart | 23.5 | 16.9 | **1.4×** |
| Dart `Uint8List`→JS (1 MiB) | 110 | 36 | **3.1×** |
| Dart `Float64List`→JS (10k) | 1567 | 4.0 | **~392×** |
| evaluate large array (full jsToDart) | 2571 | 1648 | **1.6×** |
| evaluate large object (full jsToDart) | 4983 | 4431 | **1.1×** |
| JS `Uint8Array`→Dart (1 KiB) | 568 | 38 | **15×** |
| JS `Uint8Array`→Dart (64 KiB) | 43341 | 1467 | **30×** |
| JS `Uint8Array`→Dart (1 MiB) | 931803 | 25239 | **37×** |
| JS `Float64Array`→Dart (10k) | 6779 | 712 | **9.5×** |

Approximate throughput on the same run:

| Path | Baseline | main |
|------|---------:|-----:|
| Dart `Uint8List`→JS 1 MiB | ~9 GiB/s | ~27 GiB/s |
| Dart `Float64List`→JS 10k | ~49 MiB/s | ~19 GiB/s |
| JS `Uint8Array`→Dart 1 MiB | ~1.1 MiB/s | ~40 MiB/s |
| JS `Float64Array`→Dart 10k | ~11 MiB/s | ~107 MiB/s |

**What improved most**

- **TypedArray / buffer paths** — bulk copy instead of per-element marshalling
  (largest wins on JS→Dart and non-byte TypedArrays Dart→JS).
- **String / host invoke** — leaner FFI and value conversion.
- **Large array `evaluate`** — faster recursive jsToDart; use **`evaluateJson`**
  when you only need a JSON-like tree (avoids deep object graph conversion).

Raw logs (full suite output + aggregated means):  
`benchmark_results/baseline_3261eb4_BENCH_RUNS32.txt`,  
`benchmark_results/main_BENCH_RUNS32.txt`.

Numbers are single-host microbenchmarks (Linux `flutter_tester`); treat them as
relative, not absolute product SLOs.

### Soak / stress (long-haul)

Separate from micro-benchmarks: high-concurrency burn-in, RSS/metrics, fail-fast
dump (not us/op). Shared logic: `example/lib/soak_stress_runner.dart`.

```bash
cd example
# short smoke (default ~30s)
flutter test test/soak_stress_test.dart

# ≥1h burn-in example
flutter test test/soak_stress_test.dart \
  --dart-define=SOAK_DURATION_SEC=3600 \
  --dart-define=SOAK_POOL_SIZE=8 \
  --dart-define=SOAK_WORKERS=32
```

On failure, a dump is written under `soak_dumps/` (config, pool stats, RSS,
recent ops, sample `getMemoryUsage`). Native core dump is optional/external
(`gcore` / `ulimit -c`).

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
