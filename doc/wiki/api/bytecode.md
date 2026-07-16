# Bytecode

QuickJS can compile source to bytecode and evaluate it later.

## Compile

```dart
Uint8List compile(String code, String fileName);
```

- Requires a live engine (`_ensureEngine`).  
- On failure, throws `JSError` (parsed from the context).  
- Returned bytes are a Dart copy of the native buffer.

## Evaluate bytecode

```dart
JsEvalResult evaluateBytecode(Uint8List bytecode);
Future<JsEvalResult> evaluateAsyncBytecode(Uint8List bytecode);
// async variant: Future.value(evaluateBytecode(...))
```

Same result wrapping as `evaluate` (including `autoExecutePendingJobs` drain).

## When to use

- Load/compile once at startup; evaluate many times  
- Ship precompiled blobs instead of large source strings (still not a security boundary)  
- Slightly faster load path for hot scripts (measure with your scripts)

## Caveats

- Bytecode is tied to the **QuickJS version** embedded in this package (2026-06-04). Rebuild if you change engines.  
- Not a sandbox: bytecode can do anything source could do.  
- Prefer `timeout` / `memoryLimit` for untrusted payloads the same as source.

## Example

```dart
final js = getJavascriptRuntime();
final bc = js.compile('function add(a,b){return a+b;} add(2,3);', 'add.js');
final r = js.evaluateBytecode(bc);
print(r.rawResult); // 5
js.dispose();
```
