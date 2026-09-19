# Memory & lifecycle

## Memory limits

Default: **`kDefaultJsMemoryLimit` = 64 MiB** per QuickJS engine.

```dart
getJavascriptRuntime(memoryLimit: 32 * 1024 * 1024);
getJavascriptRuntime(memoryLimit: 0); // unlimited — avoid for multi-engine / untrusted
```

`memoryLimit` applies to the QuickJS heap of one runtime. `0` means unlimited;
`null` and negative values use the 64 MiB default. It is not a process-level
memory cap. Dart objects, Flutter memory, all native/plugin allocations and
process RSS are outside this limit. Oversized single `TypedData` and
`ByteBuffer` bridge payloads are rejected, but cumulative bridge allocations
and Dart-side result allocations are not fully accounted for.

`getMemoryUsage()` returns a snapshot (`JsMemoryUsage`) when the engine is live; `null` if disposed / not ready.

```dart
js.runGC(); // force QuickJS GC
```

Process RSS includes Dart, Flutter, native and plugin heaps. Monitor it
separately; a QuickJS heap limit alone cannot enforce a process RSS ceiling.

Soak evidence (RSS climb vs flat QJS / balanced bridge): see
[Soak RSS analysis](soak-rss-analysis.md).

### Native (C) heap

`getMemoryUsage()` covers one engine's QuickJS heap. For the whole process's C
allocator — every engine, the bridge buffers, the allocator's free lists — use
`readNativeHeapUsage()`:

```dart
final heap = readNativeHeapUsage();
if (heap.isSupported) {
  print('arena ${heap.arenaBytes >> 20} MiB, in use ${heap.inUseBytes >> 20} MiB, '
      'free ${heap.freeBytes >> 20} MiB');
}
if (trimNativeHeap()) {
  // the allocator returned free pages to the OS
}
```

- A growing `arenaBytes` with flat `inUseBytes` is pages the allocator keeps
  for reuse, not a leak. A growing `inUseBytes` is live C memory.
- If RSS grows while `arenaBytes` stays flat, the growth is outside the C heap
  (usually the Dart heap); look there instead.
- `trimNativeHeap()` asks the allocator to return free pages to the OS.
  Call it after churning many engines (`dispose()`, hard resets), not per
  operation. It uses `malloc_trim` (glibc), `mallopt(M_PURGE)` (Android) or
  `malloc_zone_pressure_relief` (Apple), and returns `false` when nothing was
  released or on other platforms (Windows).
- Only glibc ≥ 2.33 (Linux) reports usage numbers; elsewhere every field is 0
  and `isSupported` is `false`.

## Runtime lifecycle

```text
create → evaluate… → (optional close / reinitialize) → dispose
```

| Call | Effect |
|------|--------|
| `close()` | Free native rt/ctx; caches released; may recreate on next evaluate |
| `softReset()` | Clear globals / channels / timers; keep native heap + engine id |
| `reinitialize()` | close + clear maps + new id + init (pool `hard` reset) |
| `dispose()` | Final: no reopen; port closed; channels removed |

## Common leak / RSS patterns

1. Never calling **`dispose()`** on owned runtimes  
2. Creating engines in a loop without a pool cap (`getJavascriptRuntime` per request)  
3. Holding **`JSInvokable`** without **`free()`**  
4. Registering many unique channel names without dispose/reinitialize  
5. `resetMode: none` (the default) with dirty globals between tenants  
6. Using **`hard` / `resetOnRelease: true` hoping to “free memory”** under multi-tenant load — it does not lower process RSS and costs throughput; prefer **`soft`** first  
7. Watching only QJS `getMemoryUsage()` while **process RSS** climbs (Dart + Flutter + FFI + OS heaps are outside `memoryLimit`)
8. Staying on a version before **1.5.0** with long-lived engines that call into JS: every `JSInvokable.invoke` / `evaluateJson` queued a message on the engine's event-loop port, at least 32 B per call that was never released (more while a synchronous loop keeps the isolate busy)

## Pool

- `maxSize` caps concurrent engines.  
- Each engine has its own heap limit; the pool's aggregate QuickJS usage can be
  roughly `maxSize * memoryLimit`, before Dart and native overhead.
- Default **`resetMode: none`** reuses warm engines (better process RSS under
  churn). For tenants use **`soft`** first; **`hard`** / `resetOnRelease: true`
  only when you need a full native rebuild.
- Integration checklist: [Production integration checklist](production-checklist.md).

## Stress testing

```bash
cd example
flutter test test/leak_and_stress_test.dart
flutter test test/soak_stress_test.dart
```

See [Testing & benchmarks](../testing-and-benchmarks.md).
