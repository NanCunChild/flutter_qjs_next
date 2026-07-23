# Production integration checklist

Use this before shipping multi-tenant or high-churn QuickJS work. Library micro-benchmarks are already strong; **production pain is usually process RSS, UI jank, and misuse** — not us/op on tiny expressions.

See also: [Performance](performance.md) · [Memory & lifecycle](memory-and-lifecycle.md) · [Soak RSS analysis](soak-rss-analysis.md) · [Multi-tenant pool](../recipes/multi-tenant-pool.md)

---

## Decision tree

| Workload | Prefer |
|----------|--------|
| Long-lived single feature (same globals OK) | **One** reused `JavascriptRuntime` |
| Many short / concurrent / multi-tenant scripts | **`JsEnginePool`** with modest `maxSize` |
| Untrusted or isolation-required tenants | Pool + **`resetMode: soft`** (or `hard` only if soft is insufficient) |
| Large JSON-like results | **`evaluateJson`** (not deep `evaluate` / `jsToDart`) |
| Binary / buffers | **TypedArray / `Uint8List`**, not `number[]` |
| Same script many times | `compile` once + **`evaluateBytecode`** |
| Heavy sync work | **Non-UI isolate** (or short scripts only on UI isolate) |

**Anti-patterns (avoid in hot paths)**

1. `getJavascriptRuntime()` **per request** / per frame  
2. Pool **`hard` / `resetOnRelease: true` as a “memory fix”** (often **worse** process RSS under churn)  
3. Large objects via `evaluate` instead of `evaluateJson`  
4. Binary as nested JS number arrays  
5. Creating a new function value every call without caching `JSInvokable`  
6. Ignoring **process RSS**; only watching QJS `getMemoryUsage()`  
7. Blocking the **UI isolate** with multi‑ms / multi‑MiB evaluate  

---

## 1. Engine ownership

- [ ] Own runtimes are **`dispose()`d** exactly once at shutdown (or never leaked in a loop).  
- [ ] Hot path uses **one runtime** or a **pool**, not create/destroy per call.  
- [ ] Pool **`maxSize`** matches real concurrency (not “as large as possible”).  
- [ ] Budget: rough QuickJS heap upper bound ≈ **`maxSize × memoryLimit`**, plus Dart / Flutter / FFI overhead and process RSS outside `memoryLimit`.

```dart
// Trusted same-tenant warm reuse (default)
final pool = JsEnginePool(
  maxSize: 4,
  config: const JsEnginePoolConfig(
    timeout: 3000,
    memoryLimit: 64 * 1024 * 1024,
    // resetMode: EngineResetMode.none  // default
  ),
);

// Multi-tenant: soft wipe between leases (prefer over hard)
final tenantPool = JsEnginePool(
  maxSize: 4,
  config: const JsEnginePoolConfig(
    timeout: 2000,
    memoryLimit: 32 * 1024 * 1024,
    resetMode: EngineResetMode.soft,
  ),
);
```

| `resetMode` | Isolation | RSS under churn | When |
|-------------|-----------|-----------------|------|
| `none` (default) | No | Best | Same tenant / trusted reuse |
| `soft` | Clears globals / channels / timers | Good | Multi-tenant default |
| `hard` | Full native rebuild | Often **worse** | Only when soft is not enough |

Re-register bridges **inside** each `withEngine` lease when using soft/hard.

---

## 2. Evaluate paths

- [ ] Pure data out of JS → **`evaluateJson`** (throws on error; no functions/Promises in tree).  
- [ ] Binary → **TypedArray / `TypedData`** both directions.  
- [ ] Small mixed results / callables → `evaluate` is fine.  
- [ ] Hot functions: cache **`JSInvokable`**, call many times, then **`free()`**.

```dart
// JSON-like tree (prefer)
final data = js.evaluateJson('buildReport()');

// Binary (prefer)
final bytes = js.evaluate('new Uint8Array(buf)').rawResult as Uint8List;

// Callable cache
final fn = js.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
try {
  for (final x in inputs) {
    fn.invoke([x, 1]);
  }
} finally {
  fn.free();
}
```

- [ ] Cap **Dart → JS** large buffer frequency and size (bridge copies; not zero-copy).  
- [ ] Prefer one bulk transfer over many tiny marshals when possible.

---

## 3. UI isolate / latency

- [ ] Default `evaluate` is **synchronous FFI on the calling isolate** — long work freezes UI.  
- [ ] Move multi‑ms scripts or multi‑MiB transfers off the UI isolate when jank matters.  
- [ ] Set a wall-clock **`timeout`** (ms) for untrusted or unbounded scripts.  
- [ ] Leave **`autoExecutePendingJobs: true`** (default) unless you intentionally pump jobs yourself.  
- [ ] Ensure the isolate runs Dart timers so **`setTimeout`** / Promises can complete.

---

## 4. Memory & monitoring

- [ ] Treat **`memoryLimit` as per-engine QuickJS heap**, not process RSS.  
- [ ] Monitor **process RSS** (and crash/OOM rate) in production; pair with `getMemoryUsage()` for JS heap.  
- [ ] Do **not** use hard reinitialize as the primary RSS control — see [Soak RSS analysis](soak-rss-analysis.md).  
- [ ] Free **`JSInvokable`**, dispose owned engines / pool, avoid unbounded channel name growth.  
- [ ] Optional idle **`runGC()`** after large one-shot jobs (does not reclaim all process RSS).

```dart
final m = js.getMemoryUsage();
// Log m alongside process RSS from your host metrics.
```

---

## 5. Security (untrusted scripts)

- [ ] Set **`timeout`** and a finite **`memoryLimit`**.  
- [ ] Do not expose privileged Dart bridges without auth/validation.  
- [ ] Treat channel names and payloads as untrusted.  
- [ ] Soft/hard reset between tenants so `globalThis` does not leak state.  

Details: [Security](security.md).

---

## 6. Shutdown

- [ ] `pool.dispose()` at app/feature teardown.  
- [ ] No use of engines after `release` / after `withEngine` returns.  
- [ ] Single owned runtime: always `dispose()` when done.

---

## Copy-paste: tenant worker

Runnable reference in the example app: `example/lib/production_tenant_worker.dart`
(tests: `example/test/production_tenant_worker_test.dart`).

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';

final JsEnginePool tenantPool = JsEnginePool(
  maxSize: 4,
  config: const JsEnginePoolConfig(
    timeout: 2000,
    memoryLimit: 32 * 1024 * 1024,
    resetMode: EngineResetMode.soft,
  ),
);

/// Run untrusted or per-tenant script; isolate globals between leases.
Future<Object?> runTenantScript(String source, {bool asJson = false}) {
  return tenantPool.withEngine((js) async {
    // Re-register any host bridges for this lease if needed.
    if (asJson) {
      return js.evaluateJson(source);
    }
    final r = js.evaluate(source);
    if (r.isError) {
      throw StateError(r.stringResult);
    }
    return r.rawResult;
  });
}

// App shutdown:
// tenantPool.dispose();
```

---

## Verify before release

```bash
cd example
flutter test test/production_tenant_worker_test.dart
flutter test test/leak_and_stress_test.dart
# Optional soak (long): see test/soak_stress_test.dart and guides/soak-rss-analysis.md
```

| Symptom | Check |
|---------|--------|
| RSS climbs under load | Pool reset mode? Per-request engines? Large Dart→JS copies? |
| UI jank | Sync evaluate on UI isolate? Script size? |
| Cross-tenant state | `resetMode` still `none`? Bridges re-registered? |
| Pool `TimeoutException` | `maxSize`, work duration, `acquire` timeout |
| Slow large results | Still using `evaluate` instead of `evaluateJson` / TypedArray? |

---

## What this checklist does **not** fix

Library-side allocation fragmentation, true zero-copy buffers, and pool-wide RSS budgets are **library work** (see performance / soak docs). This page is **integration posture** — the highest ROI before code changes in the binding layer.
