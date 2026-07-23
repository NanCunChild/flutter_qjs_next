# flutter_qjs_next documentation

Flutter / Dart bindings for [QuickJS](https://github.com/bellard/quickjs) via `dart:ffi`.

| | |
|--|--|
| **Engine** | QuickJS **2026-06-04** (embedded) |
| **Platforms** | Android, iOS, macOS, Linux, Windows |
| **Not supported** | Web (native FFI only) |
| **API style** | Compatible with [flutter_js](https://github.com/abner/flutter_js) (`JavascriptRuntime`, `getJavascriptRuntime()`) |
| **Package** | `flutter_qjs_next` |

This tree under `docs/wiki/` is the **source of truth** for the project wiki.  
On push to `main`/`master` (paths under `docs/wiki/**`), CI runs `scripts/sync-wiki.sh` and mirrors pages to the [GitHub Wiki](https://github.com/NanCunChild/flutter_qjs_next/wiki) (`README.md` → `Home.md`).

**One-time setup:** enable **Wikis** in repo settings, create any first page in the Wiki UI (creates `*.wiki.git`), and allow Actions **read/write** contents. Local dry-run: `WIKI_DRY_RUN=1 bash scripts/sync-wiki.sh`.

## Start here

1. **[Getting Started](getting-started.md)** — install, integrate, Flutter commands, minimal test  
2. **[Concepts](concepts.md)** — one runtime, jobs, bridges, isolation  
3. **[Security](guides/security.md)** — defaults for untrusted scripts  

## Documentation map

### API

- [Overview](api/overview.md)
- [Runtime](api/runtime.md)
- [Dart ↔ JS bridge](api/bridge.md)
- [Types & marshalling](api/types-and-marshalling.md)
- [Promises & event loop](api/promises-and-event-loop.md)
- [Bytecode](api/bytecode.md)
- [Engine pool](api/engine-pool.md)
- [Logging](api/logging.md)

### Guides

- [Security](guides/security.md)
- [Performance](guides/performance.md)
- [Memory & lifecycle](guides/memory-and-lifecycle.md)
- [Soak RSS analysis](guides/soak-rss-analysis.md)
- [ES modules](guides/modules.md)
- [Migration (flutter_js / older flutter_qjs)](guides/migration-from-flutter-js.md)
- [Platforms](guides/platforms.md)

### Recipes

- [Hello evaluate](recipes/hello-evaluate.md)
- [Async bridge + Promise](recipes/async-bridge.md)
- [TypedArrays](recipes/typed-arrays.md)
- [evaluateJson](recipes/evaluate-json.md)
- [Multi-tenant pool](recipes/multi-tenant-pool.md)
- [AJV validation](recipes/ajv-validation.md)

### Other

- [Architecture](architecture/overview.md)
- [Testing & benchmarks](testing-and-benchmarks.md)
- [Troubleshooting](troubleshooting.md)
- [FAQ](faq.md)
- [Changelog](../../CHANGELOG.md) (repo root)

## What this package is not

- A browser or full Web API surface  
- JavaScriptCore on Android (always QuickJS)  
- A built-in `fetch` / XHR implementation (`xhr: true` is accepted for API compatibility but ignored)  
- A security sandbox by itself — you must set limits and control bridges  

## Links

- Repository: https://github.com/NanCunChild/flutter_qjs_next  
- Issues: https://github.com/NanCunChild/flutter_qjs_next/issues  
- Example app: `example/`  
