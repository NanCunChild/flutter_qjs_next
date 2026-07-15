# Troubleshooting

## Build / load

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Web compile fails / no `dart:ffi` | Web unsupported | Use Android/iOS/desktop |
| Native library not found | Not using Flutter plugin build | `flutter run` / `flutter test` under an app with the dependency |
| `dart run` **crashes the compiler** | Known FFI `fromFunction` toolchain crash | Use `flutter test` / `flutter run` instead |
| Plugin not registered | Wrong package or incomplete pub get | `flutter pub get`, clean rebuild `flutter clean && flutter pub get` |

## Runtime

| Symptom | Fix |
|---------|-----|
| Evaluate after dispose | Create a new runtime; `dispose` is final |
| `TimeoutException` from pool | Increase `maxSize`, shorten work, or longer `acquire` timeout |
| Cross-tenant pollution | Keep `resetOnRelease: true`; re-register bridges after reset |
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
| OOM / allocate failures | Lower script size; raise `memoryLimit` carefully; `runGC`; fewer engines |
| Slow large objects | Use `evaluateJson` or TypedArray |
| Growing RSS over time | Check dispose/free; pool max; leak tests |

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
