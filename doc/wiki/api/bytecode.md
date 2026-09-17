# Bytecode

QuickJS can compile source to bytecode and evaluate it later.

## Compile

```dart
Uint8List compile(String code, String fileName,
    {bool stripSource = false, bool asModule = false});
```

- Requires a live engine (`_ensureEngine`).  
- On failure, throws `JSError` (parsed from the context).  
- Returned bytes are a Dart copy of the native buffer.  
- `asModule: true` compiles an ES module; `fileName` becomes the name its
  importers resolve to. QuickJS resolves a module's imports **while compiling
  it**, so the engine's `moduleHandler` must be able to reach every dependency.
  Use `JsModuleBundle` instead of calling this directly for a graph.

## Evaluate bytecode

```dart
JsEvalResult evaluateBytecode(Uint8List bytecode);
Future<JsEvalResult> evaluateAsyncBytecode(Uint8List bytecode);
// async variant: Future.value(evaluateBytecode(...))
```

Same result wrapping as `evaluate` (including `autoExecutePendingJobs` drain).

## Module bundles

`JsModuleBundle` compiles a whole import graph once and loads it without ever
calling the module loader. That matters most for `IsolateQjs`: QuickJS resolves
imports synchronously, so a worker isolate that asks the spawning isolate for
each module parks (in 1 ms steps) once per module.

```dart
final bundle = JsModuleBundle.compileSources(
  entry: 'main.js',
  sources: {
    'main.js': "import {greet} from './lib/greet.js'; globalThis.out = greet();",
    'lib/greet.js': "export const greet = () => 'hi';",
  },
);

// In-process engine.
final js = getJavascriptRuntime();
await js.handlePromise(bundle.evaluate(js));

// Worker isolate: the bundle travels with the spawn message, so the worker
// resolves everything locally.
final qjs = IsolateQjs(bundle: bundle);
await qjs.evaluateBundleEntry();
```

- Keys are the specifiers `import` resolves to. QuickJS normalizes only a
  leading `./` / `../` against the importing module's name, so use paths
  relative to one common root (`'main.js'`, `'lib/util.js'`).
- `compileSources` fails with the importing module and the missing specifiers
  when the graph is incomplete; `verify()` re-checks the load path.
- `toBytes()` / `JsModuleBundle.fromBytes()` serialize the whole bundle, e.g.
  to ship it as an asset or cache it next to the app version that built it.
- `install(runtime)` registers the modules in the **current context**. After
  `softReset()` / `reinitialize()` they are gone; install again.
- `IsolateQjs(moduleSources: {...})` is the cheaper middle ground when the
  sources are known but not precompiled: the worker resolves them itself (no
  round trip) but still parses on every load.

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
