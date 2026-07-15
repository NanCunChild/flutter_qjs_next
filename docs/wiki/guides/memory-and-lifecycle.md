# Memory & lifecycle

## Heap limit

Default: **`kDefaultJsMemoryLimit` = 64 MiB** per engine.

```dart
getJavascriptRuntime(memoryLimit: 32 * 1024 * 1024);
getJavascriptRuntime(memoryLimit: 0); // unlimited — avoid for multi-engine / untrusted
```

`getMemoryUsage()` returns a snapshot (`JsMemoryUsage`) when the engine is live; `null` if disposed / not ready.

```dart
js.runGC(); // force QuickJS GC
```

Process RSS includes Dart, Flutter, and native heaps — JS limit is only the QuickJS side.

## Runtime lifecycle

```text
create → evaluate… → (optional close / reinitialize) → dispose
```

| Call | Effect |
|------|--------|
| `close()` | Free native rt/ctx; caches released; may recreate on next evaluate |
| `reinitialize()` | close + clear maps + new id + init (pool uses this) |
| `dispose()` | Final: no reopen; port closed; channels removed |

## Common leak patterns

1. Never calling **`dispose()`** on owned runtimes  
2. Creating engines in a loop without a pool cap  
3. Holding **`JSInvokable`** without **`free()`**  
4. Registering many unique channel names without dispose/reinitialize  
5. `resetOnRelease: false` with dirty globals between tenants  

## Pool

- `maxSize` caps concurrent engines.  
- Default reset on release avoids cross-tenant memory retention of JS objects (native heap still recycled via reinitialize/close).  

## Stress testing

```bash
cd example
flutter test test/leak_and_stress_test.dart
flutter test test/soak_stress_test.dart
```

See [Testing & benchmarks](../testing-and-benchmarks.md).
