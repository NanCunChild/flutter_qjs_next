## 0.0.1

* Package name: `flutter_qjs_next` (QuickJS ES2023-era engine bindings for Flutter).
* QuickJS **2025-09-13** on all platforms; Windows tree aligned with Unix (`dtoa`, same sources).
* TypedArray detection no longer depends on hard-coded `JS_CLASS_*` numeric IDs (constructor name + element size).
* `dart:ffi` bindings for Android, iOS, macOS, Linux, Windows.
* Array / TypedArray marshalling fast paths, `evaluateJson`, timeout/memory/stack limits, console logger, safer `setTimeout` channel.
* Default `memoryLimit` **64 MiB** (`kDefaultJsMemoryLimit`); pass `0` for unlimited.
* Multi-engine: `JsEnginePool` / `JsEnginePoolConfig`; unique engine instance ids (not `identityHashCode`).
* Dispose hardening: idempotent `dispose`, `runtimeOpaques` entry removed on free, disposed engines refuse re-init.
