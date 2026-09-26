## 1.5.2

* **Breaking:** the minimum Flutter version is now `3.44.0` (was `3.0.0`), matching the Swift Package Manager path, which is the primary iOS/macOS build. CocoaPods remains supported as a secondary path: both podspecs ship with the package, their `s.version` tracks `pubspec.yaml` (`scripts/check-package-metadata.sh` checks it in CI), and CocoaPods 1.17.0 was verified to build the example and to run the podspecs' `prepare_command`.
* **Fix:** strings built by concatenation (a right operand longer than 512 characters makes QuickJS return a rope, `JS_TAG_STRING_ROPE`) no longer arrive in Dart as `null` — as an `evaluate` result, inside objects and arrays, or as a host function argument. `evaluateJson` accepts a rope result as well.
* **Fix (behavior):** JS → Dart object conversion keeps enumerable string keys only, like `Object.keys`. Symbol keys used to become Dart `null` keys and overwrite each other; they are now skipped.
* **Fix (Android):** `trimNativeHeap()` resolves `mallopt` through `dlsym` instead of referencing it directly. bionic only provides `mallopt` from API 26 (`M_PURGE` from API 28), so the direct reference did not belong in a `minSdk 21` library; devices without the symbol now report "no trim" and API 28+ devices keep the purge.
* **Fix (Windows):** Windows builds again, and now runs. The QuickJS upgrade to `2026-06-04` had overwritten `cxx-windows/` — which was a *patched* older QuickJS, not a copy — with the unpatched upstream sources, so the plugin had not compiled since. Beyond the compile errors, two defects made a Windows build useless even once it linked: `JSClosureVar.closure_type` is an enum bitfield, which MSVC makes **signed**, so a 3-bit field read `JS_CLOSURE_GLOBAL` back as `-3` and the first global variable reference in any script (`globalThis`, `String(1)`, …) killed the process; and the default 1 MiB JS stack limit equals a Windows thread's whole stack, so a deeply nested value overflowed the real stack instead of raising `InternalError: stack overflow`.
* **Fix:** `kDefaultJsStackSize` — the default QuickJS C-stack limit is now 256 KiB on Windows and stays 1 MiB elsewhere. `stackSize` is nullable everywhere it is accepted (`getJavascriptRuntime`, `QuickJsRuntime2`, `JsEnginePoolConfig`, `IsolateQjs`); passing a value still overrides it.
* **Build:** Windows builds QuickJS and the FFI bridge from `cxx/`, like Android and Linux; the `cxx-windows/` copy is gone. `cxx/` is the only place to edit native code: `scripts/sync-native.sh` regenerates the iOS/macOS Swift Package Manager trees from it, and CI (`scripts/check-native-sync.sh`) fails when they differ. MSVC support lives in `cxx/quickjs/msvc-compat.h` plus a handful of marked `#ifdef _MSC_VER` lines in the upstream files; `doc/wiki/guides/platforms.md` lists every one of them and what to re-apply after a QuickJS upgrade.
* **Removed:** the unused `lib/quickjs/qjs_typedefs.dart` (tag values from an older QuickJS, e.g. `JS_TAG_FLOAT64 = 7`) and `lib/quickjs/utf8_null_terminated.dart`, which only it imported.

## 1.5.1

* **Docs:** Web API guidance reworked — new `doc/wiki/recipes/choosing-web-apis.md`, refreshed API pages, and a clearer statement that a module's optional modules (`blob`, `encoding`) are never installed on its behalf and that modules are a functional split, not a sandbox. The README and getting-started guide link the recipe.
* **Docs:** performance and risk sections synced — `doc/wiki/guides/performance.md` documents the 1.5.0 call-cost win (`invoke` 2.2× faster; ~4× over millions of calls) with the new `benchmark_results/87a7363/` artifacts, `soak-rss-analysis.md` corrects the non-fetch RSS peak, and the production checklist states the real network contract (`fetch` is opt-in through `JsFetchOptions`; no Flutter Web target, no XHR).
* **Example:** the demo restricts `fetch` to `raw.githubusercontent.com` through `JsFetchOptions(allowUrl: ...)`.
* **Chore:** explicit `dynamic` parameter types in `lib/quickjs/object.dart`; benchmark artifacts for `87a7363` added under `benchmark_results/`.

## 1.5.0

* **Breaking (Web APIs):** optional module dependencies. A module's `optional` modules are never installed on its behalf; when they are installed anyway they come first and enable extra features. `streams` no longer pulls in `encoding` (`TextEncoderStream` / `TextDecoderStream` appear only with `encoding`), `blob` no longer pulls in `streams` (`Blob.prototype.stream` only with `streams`), and `http` no longer pulls in `blob` (`blob()` / `formData()` and Blob/FormData bodies only with `blob`). So `JsWebApis(modules: {JsWebModule.http})` no longer defines `Blob`, and `JsWebApis(fetch: ...)` alone has no `response.blob()`; add `JsWebModule.blob` or use `JsWebApis.standard(...)`, which is unchanged. `fetch` now declares its direct dependency on `events`.
* **Breaking (Web APIs):** `JsWebModule.capability` is renamed `hostConfig` (value `'JsFetchOptions'`). Modules are documented as a functional split, not a permission model: leaving a module out does not sandbox a script; host access is governed by `JsFetchOptions`, bridges, `memoryLimit` and `timeout`.
* **Internal:** `core` exposes `has(name)` and default `isAbortSignal` / `isBlob` / `isFormData` brand checks that `events` / `blob` replace. Modules read `internal` only through one leading destructuring; `example/test/web_apis_internal_names_test.dart` checks that every name read comes from a declared dependency and that optional ones are guarded by `has()`.
* **Fix:** `jsCall` no longer posts a wake-up message to the event-loop port when no `dispatch()` loop is running, so the port no longer buffers one message per call for the life of the runtime.

## 1.4.0

* **Feat:** `JsModuleBundle` — compile an ES module graph to bytecode once and register it in a context, so imports resolve locally instead of through the module loader. `IsolateQjs(bundle: ...)` ships the bundle with the spawn message and `evaluateBundleEntry()` runs it, which removes the per-module cross-isolate round trip (the worker used to park in 1 ms `sleep` steps while the spawning isolate resolved each module) and the per-load parse. `IsolateQjs(moduleSources: {...})` is the same round-trip-free path without precompiling.
* **Feat:** `JavascriptRuntime.compile(..., asModule: true)` and `registerModuleBytecode(bytecode, resolve: false)`.
* **Feat:** `readNativeHeapUsage()` / `trimNativeHeap()` — C heap accounting (arena / in use / free / mmapped) and a request to return free pages to the OS. These tell allocator residency apart from a real leak; see `doc/wiki/guides/soak-rss-analysis.md`.
* **Fix:** every call from JS into a Dart host function leaked the 16-byte `JSValue` box holding the return value (`js_channel` never freed the pointer the host handed back).
* **Fix:** the `ArrayBuffer` / `TypedArray` probes in `_jsToDart` left a pending `TypeError` ("not an ArrayBuffer" / "not a TypedArray") on the context for every plain object converted. The next unrelated exception check reported it instead of the real failure.
* **Fix:** a module that cannot be loaded now throws `ReferenceError: could not load module '<name>'` instead of failing with no exception, and `_parseJSException` never returns `null`.
* **Native:** new exports `jsCompile`, `jsReadModuleBytecode`, `jsTrimNativeHeap`, `jsNativeHeapUsage`; `EvaluateBytecode` resolves a module's imports before evaluating it (all platform copies synchronized).
* **Tests:** `SOAK_PROFILE=op:<opName>` pins the soak to a single operation, and `soak_metrics.jsonl` records `nativeHeap` (C heap arena / in use / free / mmapped) next to `rss`. Together they identify what grows without guessing: process RSS under `web_fetch` is the **Dart** heap (C arena flat at ~30 MB, `malloc_trim` recovers ~24 MB of 540), and inside `web_fetch` it is `fetchAbort` alone — 5.1 MB/s against ≤0.26 MB/s for every other fetch operation. `example/test/http_control_test.dart` reproduces it with no QuickJS in the process (`CONTROL_MODE=abort`: 150 → 1206 MB over 30 k requests; `read` / `cancel` / `cancelpaused` all plateau), so the retention is in `dart:io`'s aborted-request path, not in this package. Findings and how to re-run: `doc/wiki/guides/soak-rss-analysis.md`.
* **Tests:** the soak's `/slow` endpoint no longer parks a server handler forever when the client aborts (it watches `response.done` and bounds `flush`/`close`); 6682 handlers were stuck after 10 k aborted requests.
* **Fix:** `initChannelFunctions` reports the engine's own message when bridge setup fails instead of an opaque cast error, and frees the setter even if installing the bridge throws.
* **Build:** opening a native library older than the Dart code now fails with the missing symbol and how to rebuild, instead of surfacing much later as a masked `JSError` during value conversion.

## 1.3.0

* **Feat:** Web platform APIs (a WinterTC subset), installed per module with their dependency closure — see `doc/wiki/api/web-apis.md`. Modules: `core` (default: timers, `queueMicrotask`, `reportError`, `console`, `performance`, `structuredClone`, `atob`/`btoa`, `DOMException`, `crypto.getRandomValues`/`randomUUID`), `events`, `encoding`, `url`, `crypto`, `navigator`, `streams`, `blob`, `http`, `fetch`. Presets: `JsWebApis.none()`, `JsWebApis()` (core only), `JsWebApis.standard()`, or `JsWebApis(modules: {JsWebModule.url})` to name your own — dependencies are resolved and ordered for you.
* **Feat:** `fetch` (`JsWebApis(fetch: JsFetchOptions(...))`, off by default). It is the only module that carries a capability, and it cannot be installed without that policy object — `JsWebApis(modules: {JsWebModule.fetch})` alone throws `ArgumentError`. Per-hop `allowUrl` policy, runtime-side redirect handling, `maxResponseBytes`, back-pressured response streaming, `AbortSignal`, and a replaceable `JsFetchHandler` (default: `dart:io` `HttpClient`, closed with the engine).
* **Feat:** `crypto.subtle` with SHA-1/256/384/512 `digest` and HMAC (`generateKey` / `importKey` / `exportKey` / `sign` / `verify`); other algorithms reject with `NotSupportedError`.
* **Feat (behavior):** `console` now formats like `util.format` / `util.inspect` (`%s`/`%d`/`%o`, BigInt, `Map`/`Set`, TypedArrays, cycles, getters, `Error` stacks) and adds `debug`, `trace`, `assert`, `dir`, `group`, `count`, `time`. It calls the logger directly: the internal `ConsoleLog` channel is gone.
* **Feat (behavior):** timers gained `setInterval` / `clearInterval` and extra callback arguments; `clearTimeout` / `clearInterval` now really cancel the Dart `Timer`; callback errors are reported through `reportError` instead of being swallowed; a timer callback is followed by a microtask checkpoint. The internal `SetTimeout` channel and the `__NATIVE_FLUTTER_JS__*` globals are gone, and Web API globals are non-enumerable.
* **Fix:** JS→Dart strings no longer lose a leading BOM (`Utf8Decoder` silently drops U+FEFF).
* **Behavior:** installing the `core` module needs roughly 320 KiB of `memoryLimit` (about 1 MiB for `JsWebApis.standard()`). Engines with a tighter budget can install fewer modules (`{JsWebModule.url}` is 224 KiB) or pass `JsWebApis.none()` for a bare context (no `console`, no timers).
* **API:** `JsWebApis` (`.none()` / `.standard()` / `modules:`, with `resolvedModules` and `installs()`), `JsWebModule`, `JsFetchOptions`, `JsFetchRequest`, `JsFetchResponse`, `JsFetchHandler`; `webApis` on `QuickJsRuntime2`, `getJavascriptRuntime` and `JsEnginePoolConfig`; `JavascriptRuntime.compile(..., stripSource: false)`.
* **Native:** new exports `jsNewWebNatives` (UTF-8 encode/decode, monotonic clock) and `jsSetStripInfo` / `jsGetStripInfo` (all platform copies synchronized).
* **Perf:** `_DartFunction` resolves its `thisVal` parameter once instead of running a regular expression on every host call.
* **Removed:** `assets/js/fetch.js` (an unused XHR-based polyfill) and the package `assets/` declaration.
* **Tests:** the soak runner gained Web API workloads (`web_core`, `web_url`, `web_encoding`, `web_blob`, `web_streams`, `web_crypto`, `web_fetch`, `web_all`, `mixed_all`) driven against an in-process HTTP server, plus open-file-descriptor / Dart-handle / engine-heap ceilings, an optional cooldown phase that makes RSS interpretable, and a stubbed-network control (`SOAK_FETCH_STUB`). Experiment design and pilot results: `doc/design/2026-09-16-web-apis-soak.md`.
* **Tests / docs:** `example/test/web_apis_*_test.dart` (module closure and capability enforcement, core, standard library, URL, streams, Blob/FormData, HTTP types, crypto, fetch), with expectations cross-checked against Node.js 24; new wiki page `doc/wiki/api/web-apis.md`; design notes in `doc/design/2026-09-13-web-apis.md`.

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
