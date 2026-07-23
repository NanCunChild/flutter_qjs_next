# Recipe: Multi-tenant pool

## Goal

Run many short scripts with a hard cap on engines and a clean global between tenants — without paying hard-reinitialize RSS cost unless you need it.

## Recommended (production)

```dart
final pool = JsEnginePool(
  maxSize: 4, // match real concurrency; each engine has its own memoryLimit
  config: const JsEnginePoolConfig(
    timeout: 2000, // ms wall-clock JS work; set for untrusted scripts
    memoryLimit: 32 * 1024 * 1024,
    resetMode: EngineResetMode.soft, // clear globals/channels/timers; keep native heap
  ),
);

Future<String> runTenant(String code) {
  return pool.withEngine((js) async {
    // Re-register bridges every lease when using soft/hard reset.
    // js.onMessage('log', ...);

    // Data-only results: prefer evaluateJson over evaluate.
    final r = js.evaluate(code);
    if (r.isError) throw StateError(r.stringResult);
    return r.stringResult;
  });
}

// await runTenant('1+1');
// ...
// pool.dispose();
```

### When to use which `resetMode`

| Mode | Isolation | Process RSS under churn | Use |
|------|-----------|-------------------------|-----|
| `none` (default) | None | Best | Same tenant / trusted warm reuse |
| **`soft`** | Globals, channels, timers | Good | **Multi-tenant default** |
| `hard` / `resetOnRelease: true` | Full native rebuild | Often worse | Only if soft is not enough |

Do **not** use `hard` as a generic “lower memory” switch. Soak analysis shows hard reinitialize churn can dominate process RSS growth while QuickJS heap counters stay flat. See [Soak RSS analysis](../guides/soak-rss-analysis.md).

## Notes

- Do not use a runtime after `release` / after `withEngine` returns.  
- Re-register channels inside `withEngine` after soft/hard reset.  
- Cap `maxSize`: aggregate QuickJS heap ≈ `maxSize × memoryLimit`, plus Dart/native RSS outside the limit.  
- Prefer `evaluateJson` for large JSON-like results; TypedArray for binary.  
- Keep heavy work off the UI isolate when latency matters.  

Full checklist: [Production integration checklist](../guides/production-checklist.md).  
Reference class: `example/lib/production_tenant_worker.dart`.  
Soak: `example/test/soak_stress_test.dart`.
