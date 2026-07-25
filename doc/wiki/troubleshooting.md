# Troubleshooting

## Build / load

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Web compile fails / no `dart:ffi` | Web unsupported | Use Android/iOS/desktop |
| Native library not found | Not using Flutter plugin build | `flutter run` / `flutter test` under an app with the dependency |
| `dart run` **crashes the compiler** | Known FFI `fromFunction` toolchain crash | Use `flutter test` / `flutter run` instead |
| Plugin not registered | Wrong package or incomplete pub get | `flutter pub get`, clean rebuild `flutter clean && flutter pub get` |
| macOS/iOS: `typedef redefinition` of `BOOL` (`int` vs `_Bool`) | QuickJS `cutils.h` vs Apple ObjC | Ensure `cutils.h` uses `#if !defined(__OBJC__)`; `flutter clean` + rebuild so CocoaPods re-runs `prebuild.sh` |
| SPM: missing Flutter / Swift+C same target | Old `Package.swift` or Swift plugin sources | Keep pure ObjC plugin + `FlutterFramework` dep; see [Platforms](guides/platforms.md) |
| Flutter warns plugin lacks SPM | Missing/invalid `ios\|macos/<pkg>/Package.swift` | Restore package layout; do not delete `Package.swift` long-term (required on Flutter 3.44+) |

## Runtime

| Symptom | Fix |
|---------|-----|
| Evaluate after dispose | Create a new runtime; `dispose` is final |
| `TimeoutException` from pool | Increase `maxSize`, shorten work, or longer `acquire` timeout |
| Cross-tenant pollution | Set `resetMode: soft` or `hard` (default is warm reuse); re-register bridges after reset |
| Channel “already exists” | `setupBridge` returns false if name taken; dispose/reinit or pick a new name |

## Promises / timers

| Symptom | Fix |
|---------|-----|
| Promise never completes | `executePendingJob` / leave auto drain on; `await handlePromise`; ensure Dart event loop runs |
| `setTimeout` never fires | Flutter isolate must process timers (normal UI isolate); don’t block the isolate forever |
| Unhandled rejection logs | Provide `hostPromiseRejectionHandler` or fix JS |

## Memory / perf

| Symptom | Fix |
|---------|-----|
| OOM / allocate failures | Lower JS/payload size; raise per-runtime `memoryLimit` carefully; run `runGC`; use fewer engines |
| Slow large objects | Use `evaluateJson` or TypedArray |
| Growing RSS over time | `memoryLimit` does not cap RSS; check dispose/free, pool max, bridge payloads and native/Dart allocations; use leak tests |

## Modules

| Symptom | Fix |
|---------|-----|
| `No ModuleHandler` | Pass `moduleHandler` to `QuickJsRuntime2` |
| Module not found | Handler must return source for that name |

## Still stuck

1. Minimal reproduce with `getJavascriptRuntime` + one `evaluate`.  
2. Run `example/test/typed_array_test.dart`.  
3. Open an issue with platform, Flutter version, and snippet.  

See [FAQ](faq.md).
