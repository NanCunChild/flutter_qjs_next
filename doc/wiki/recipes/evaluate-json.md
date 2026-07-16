# Recipe: evaluateJson

## Goal

Pull a large JSON-serializable structure out of JS without deep FFI graph walks.

```dart
final js = getJavascriptRuntime();

final list = js.evaluateJson(
  'Array.from({length: 1000}, (_, i) => ({ i: i, v: i * i }))',
);
// list is List<dynamic> of Map-like entries

final obj = js.evaluateJson('{ a: 1, b: [true, null, "x"] }');

js.dispose();
```

## Rules

- No functions / Promises in the result tree (same as `JSON.stringify`).  
- On exception, **throws** (unlike `evaluate` → `isError`).  
- Use for analytics blobs, schema data, AJV-like output, etc.

Compare speed: [Performance](../guides/performance.md).
