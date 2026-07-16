# Engine pool

`JsEnginePool` bounds how many `JavascriptRuntime` instances exist and hands them out for short jobs.

## Config

```dart
class JsEnginePoolConfig {
  final int stackSize;      // default 1 MiB
  final int? timeout;
  final int? memoryLimit;   // default kDefaultJsMemoryLimit
  final bool resetOnRelease; // default true
}
```

When **`resetOnRelease`** is true, `release` calls `reinitialize()` so the next tenant does not see prior `globalThis` / channel state. On reinitialize failure the engine is destroyed.

`memoryLimit` is per engine, not a pool-wide or process-wide limit. With
`maxSize: 4` and a 64 MiB limit, the pool may reserve up to roughly 256 MiB of
QuickJS heap before Dart, Flutter and native overhead. Use a conservative
`maxSize`; the pool currently does not enforce an aggregate RSS budget.

## Usage

```dart
final pool = JsEnginePool(
  maxSize: 4,
  config: JsEnginePoolConfig(timeout: 3000),
);

final out = await pool.withEngine((js) async {
  return js.evaluate('1 + 1').stringResult;
});

// or:
final eng = await pool.acquire(timeout: Duration(seconds: 5));
try {
  // ...
} finally {
  pool.release(eng); // do not use eng after release
}

pool.dispose();
```

### API surface

| Member | Meaning |
|--------|---------|
| `maxSize` | Cap on live engines |
| `size` / `idleCount` / `inUseCount` | Stats |
| `acquire` | Borrow; waits if all busy; optional timeout → `TimeoutException` |
| `release` | Return (+ optional reset) |
| `withEngine` | acquire → fn → release |
| `dispose` | Fail waiters; dispose all engines |

### Custom factory

```dart
JsEnginePool(
  maxSize: 2,
  factory: () => QuickJsRuntime2(timeout: 1000).. /* optional */,
);
```

If you skip `getJavascriptRuntime`, call `enableHandlePromises()` yourself when you need `handlePromise`.

## Guidance

- Prefer the pool for **multi-tenant** or high-churn script execution.  
- Keep `resetOnRelease: true` unless you fully wipe state yourself.  
- Still dispose the **pool** at shutdown.  

Recipe: [Multi-tenant pool](../recipes/multi-tenant-pool.md).  
Soak patterns: `example/lib/soak_stress_runner.dart`.
