# Security

QuickJS is a full language runtime. **flutter_qjs_next is not a complete sandbox.** You are responsible for capability control, resource limits, and what host APIs you expose.

## Threat model (typical)

| Asset | Risk if untrusted JS runs |
|-------|---------------------------|
| CPU / UI jank | Infinite loops, heavy allocation |
| Memory | Large heaps, many runtimes |
| Host secrets | Bridged channels that return tokens, files, network |
| Other tenants | Shared `globalThis` if you reuse engines without reset |

## Recommended defaults for untrusted scripts

```dart
final js = getJavascriptRuntime(
  timeout: 2000,              // wall-clock interrupt (ms); null/0 = off
  memoryLimit: 64 * 1024 * 1024, // default already 64 MiB; avoid 0 (unlimited)
  stackSize: 1024 * 1024,
);
```

- Prefer a **positive `timeout`** for third-party or user-edited scripts.  
- Keep the **default `memoryLimit`** unless you have a measured reason to raise it.  
- Treat `memoryLimit` as a per-runtime QuickJS heap budget, not a process RSS
  limit. For multiple engines, account for the aggregate budget and pool
  overhead separately.
- Prefer **`JsEnginePool` with `resetMode: soft` (or `hard` / `resetOnRelease: true`)**
  between tenants — pool default is warm reuse (`none`), which is not multi-tenant safe.

## Capability control

- **Do not** register bridges that expose privileged host operations under names scripts can guess.  
- Validate and authorize every `onMessage` payload.  
- There is **no built-in network**: any `fetch`/HTTP requires **your** polyfill or bridge. That is a feature for lockdown — only add what you intend.  
- Module loading (`moduleHandler`) returns source you supply; treat requested module names as untrusted input.

## What limits do *not* provide

| Control | Does **not** mean |
|---------|-------------------|
| `timeout` | Full fairness under all native callbacks |
| `memoryLimit` | A cap on Dart heap, Flutter memory, process RSS, or all bridge allocations |
| Bytecode | Integrity or authenticity of code |
| Separate runtimes | Isolation of host process or OS credentials |

## Lifecycle hygiene

- Always `dispose()` runtimes you own.  
- Free `JSInvokable` handles you create.  
- Do not keep using an engine after `pool.release`.  
- After `reinitialize`, re-register any app channels you still need.

## Eval safety

Avoid building JS source from untrusted strings when a bridge can pass data instead. The Dart-side `sendMessage(... evaluate ...)` helper is **deprecated** for this reason.

For a hard process-level memory boundary, an in-process runtime or Dart
isolate is insufficient: use a separately managed helper process with an
OS-level memory policy. This is substantially more complex and is not provided
by `memoryLimit`.

## Report issues

Security-sensitive bugs: open a private report or GitHub issue at the project repository if no dedicated policy is published yet.
