# Recipe: Multi-tenant pool

## Goal

Run many short scripts with a hard cap on engines and a clean global between tenants.

```dart
final pool = JsEnginePool(
  maxSize: 4,
  config: const JsEnginePoolConfig(
    timeout: 2000,
    memoryLimit: 64 * 1024 * 1024,
    resetOnRelease: true, // default
  ),
);

Future<String> runTenant(String code) {
  return pool.withEngine((js) async {
    // Optional: register bridges for this lease only; reinitialize clears them
    final r = js.evaluate(code);
    if (r.isError) throw StateError(r.stringResult);
    return r.stringResult;
  });
}

// await runTenant('1+1');
// ...
// pool.dispose();
```

## Notes

- Do not use a runtime after `release` / after `withEngine` returns.  
- Re-register channels inside `withEngine` if needed each time.  
- Soak: `example/test/soak_stress_test.dart`.  
