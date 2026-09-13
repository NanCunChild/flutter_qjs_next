## 1.2.2

* **Fix:** `compile()` crashed (`free(): invalid pointer`) — bytecode buffer is now released with `js_free`.
* **Fix:** Dart→JS conversion read freed memory when the same `List` / `Map` appeared more than once (non-cyclic shared references).
* **Fix (behavior):** `softReset()` now replaces the `JSContext` on the same `JSRuntime`. Global `var` / `let` / `const` / `class` bindings and builtin prototype changes no longer survive, and builtins such as `AggregateError`, `Iterator`, `Float16Array` are no longer deleted. Native heap and engine instance id are kept.
* **Fix (behavior):** `timeout` now also covers JS run while converting results (getters, Proxy traps). A throwing or interrupted getter makes the whole result an error (`evaluate` → `isError`, `JSInvokable.invoke` → throws `JSError`) instead of silently becoming `null`.
* **Fix:** strings containing U+0000 are no longer truncated in either direction (native `jsNewString` / `jsToCString` take explicit lengths).
* **Fix:** a Dart host function that throws no longer leaks its `JSRef` arguments.
* **Fix:** the `DartObject` class id is allocated once per process instead of per context, removing per-engine `class_array` growth and the ~65k engine-creation limit.
* **Native:** new exports `jsBeginCall` / `jsEndCall`; `jsNewString` and `jsToCString` signatures changed (all platform copies synchronized).
* **Tests / docs:** `example/test/review_regression_test.dart`; review notes in `doc/review/2026-09-13-code-review.md`.

## 1.2.1

* **Lint:** add missing type annotations on `JSError` constructor parameters (`lib/quickjs/object.dart`).
* **macOS/iOS build:** avoid ObjC `BOOL` clash with QuickJS `cutils.h` (`#if !defined(__OBJC__)`).
* **Apple plugins:** pure Objective-C registration (drop Swift) so SPM can compile C/C++ + ObjC in one target.
* **SPM:** depend on Flutter’s `FlutterFramework`; public headers only under `Sources/.../include/`.
* **CocoaPods:** public headers limited to `Classes/`; QuickJS headers private; header search path for `cxx/`.
* **macOS SPM:** rename QuickJS `VERSION` → `VERSION.txt` (APFS case-insensitive clash with C++ `#include <version>`).

## 1.2.0

* **Pool default:** `JsEnginePoolConfig.resetOnRelease` is now **`false`** (warm reuse; better process RSS under churn). Multi-tenant: prefer `resetMode: soft` (not hard as an RSS fix).
* **Soft wipe:** `JavascriptRuntime.softReset()` + `EngineResetMode` (`none` / `soft` / `hard`) on `JsEnginePoolConfig.resetMode`. Prefer `soft` for multi-tenant isolation without full native rebuild; `resetOnRelease: true` still maps to `hard`.
* Document soak RSS analysis: process RSS growth is dominated by hard reinitialize churn, not QJS heap / bridge counters.
* **Docs:** production integration checklist (`doc/wiki/guides/production-checklist.md`), multi-tenant recipe updates, and example `ProductionTenantWorker` + tests.

## 1.1.1

* Fix `QuickJsRuntime2.close` reference leak: release runtime refs via `jsReleaseRuntimeRefs` before freeing the `JSContext`.

## 1.1.0

* **Perf:** `JsTypedArrayTransfer` and native owned-buffer paths for TypedArray / ArrayBuffer bridging.
* **Perf:** `evaluateJsonBatch` for bulk JSON evaluate and bulk result copy.
* Optimize object reference tables on the FFI boundary.
* Fix `Uint8ClampedArray` double-copy path; expand TypedArray benchmarks (sizes, element types, non-zero offset, both directions).
* **Feat:** native bridge allocation / copy counters (`readBridgeStats` / `jsBridgeStats*`) on all platforms.
* Expand micro-benchmarks, soak/stress coverage, and performance wiki docs (measured results, standard `benchmark_results/` layout).

## 1.0.2

* Add a complete Flutter example application and include it in the published package.
* Improve the GitHub Actions pub.dev publishing workflow for version tags.
* Expand example-based test and stress-test coverage for package validation.
* Add static analysis configuration and update development dependencies.
* Bump embedded QuickJS to **2026-06-04** (all platforms: `cxx/`, `cxx-windows/`, iOS/macOS SPM trees).

## 1.0.1
* Publish automatically from Github Action
* Fix Non Linux and Windows head file problem

## 1.0.0

* Package name: `flutter_qjs_next` (QuickJS engine bindings for Flutter).
* QuickJS **2025-09-13** on all platforms; Windows tree aligned with Unix (`dtoa`, same sources).
* TypedArray detection no longer depends on hard-coded `JS_CLASS_*` numeric IDs (constructor name + element size).
* `dart:ffi` bindings for Android, iOS, macOS, Linux, Windows.
* Array / TypedArray marshalling fast paths, `evaluateJson`, timeout/memory/stack limits, console logger, safer `setTimeout` channel (cached invokable runner).
* Default `memoryLimit` **64 MiB** (`kDefaultJsMemoryLimit`); pass `0` for unlimited.
* Multi-engine: `JsEnginePool` / `JsEnginePoolConfig` with **`resetOnRelease`** via `JavascriptRuntime.reinitialize()`.
* Unique engine instance ids: `qjs-<isolateHash>-<serial>-<us>` (not `identityHashCode`).
* `QuickJsRuntime2.autoExecutePendingJobs` (default true) drains Promise jobs after evaluate / call / bytecode / evaluateJson; documented in README.
* Isolate module load: 1ms wait on `IntPtr` slot instead of 1µs pointer spin.
* Dispose hardening: idempotent `dispose`, `runtimeOpaques` entry removed on free, disposed engines refuse re-init.
* Rename residues: `FLUTTER_QJS_NEXT_LIBRARY` (legacy `FLUTTER_QJS_ES2023_LIBRARY` still accepted).
