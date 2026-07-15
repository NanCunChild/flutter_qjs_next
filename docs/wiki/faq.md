# FAQ

### Does this support Flutter Web?

No. It uses `dart:ffi` and a native QuickJS library.

### Is this the same as flutter_js?

It aims for a **compatible** API surface (`getJavascriptRuntime`, bridges, `JsEvalResult`) but always uses QuickJS and does not ship XHR. See [Migration](guides/migration-from-flutter-js.md).

### Why is my `fetch` failing?

There is no built-in network stack. Provide a polyfill or a Dart bridge.

### What is the default memory limit?

**64 MiB** (`kDefaultJsMemoryLimit`). Pass `memoryLimit: 0` for unlimited (not recommended for untrusted multi-engine use).

### Should I create a runtime per call?

No — reuse one runtime or use `JsEnginePool`.

### Why `evaluateJson`?

Deep JS→Dart conversion is expensive for large pure data. JSON round-trip in-engine is much faster.

### Do I need to free functions returned from JS?

Yes — cast to `JSInvokable` and call **`free()`** when you own them (not the package’s setTimeout runner).

### Can I run untrusted user scripts safely?

Only with careful limits and **no privileged bridges**. See [Security](guides/security.md). This is not a multi-tenant OS sandbox.

### Why does `dart run` crash?

Recent Dart compilers can crash when compiling some FFI callback patterns. Prefer **`flutter test`** / **`flutter run`**.

### How do I load ES modules?

Use `QuickJsRuntime2(moduleHandler: ...)` — not exposed on `getJavascriptRuntime` today.

### Where is the changelog?

[CHANGELOG.md](../../CHANGELOG.md) at the repository root.
