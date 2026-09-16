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
- The Web APIs need heap of their own: about **320 KiB** for the default `core`
  module and about **1 MiB** for `JsWebApis.standard()`. Install only the modules
  you need, or `JsWebApis.none()` for a bare engine.
- Prefer **`JsEnginePool` with `resetMode: soft` (or `hard` / `resetOnRelease: true`)**
  between tenants — pool default is warm reuse (`none`), which is not multi-tenant safe.

## Capability control

- **Do not** register bridges that expose privileged host operations under names scripts can guess.  
- Validate and authorize every `onMessage` payload.  
- **Network is off unless you ask for it.** `fetch` exists only when the runtime is built with
  `webApis: JsWebApis(fetch: JsFetchOptions(...))` — `fetch` is the only module that carries a
  capability, and it cannot be installed without that policy object. When you enable it, set `allowUrl` (checked for
  the first URL **and every redirect hop**), keep `maxResponseBytes` finite, and consider a custom
  `handler` that routes through your own HTTP stack. See [Web APIs](../api/web-apis.md).
- Every other Web API module is pure computation over values already in the heap: timers, `console`,
  encoding, `URL`, streams, `Blob` and `crypto.subtle` reach nothing outside the context.
  `JsWebApis.none()` removes even those.
- Module loading (`moduleHandler`) returns source you supply; treat requested module names as untrusted input.

## What limits do *not* provide

| Control | Does **not** mean |
|---------|-------------------|
| `allowUrl` | Protection against a malicious *handler*, DNS rebinding, or SSRF through hosts you allowed |
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
