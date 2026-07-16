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
* Multi-engine: `JsEnginePool` / `JsEnginePoolConfig` with **`resetOnRelease`** (default true) via `JavascriptRuntime.reinitialize()`.
* Unique engine instance ids: `qjs-<isolateHash>-<serial>-<us>` (not `identityHashCode`).
* `QuickJsRuntime2.autoExecutePendingJobs` (default true) drains Promise jobs after evaluate / call / bytecode / evaluateJson; documented in README.
* Isolate module load: 1ms wait on `IntPtr` slot instead of 1µs pointer spin.
* Dispose hardening: idempotent `dispose`, `runtimeOpaques` entry removed on free, disposed engines refuse re-init.
* Rename residues: `FLUTTER_QJS_NEXT_LIBRARY` (legacy `FLUTTER_QJS_ES2023_LIBRARY` still accepted).
