# ES modules

Module loading is available on **`QuickJsRuntime2`** via `moduleHandler`.

```dart
final js = QuickJsRuntime2(
  moduleHandler: (name) {
    // Return full JS source for the requested module name.
    // This string is converted to native UTF-8; ownership is taken by the
    // native module loader (freed there).
    if (name == 'util') {
      return 'export const answer = 42;';
    }
    throw StateError('Unknown module: $name');
  },
  timeout: 3000,
);
```

`getJavascriptRuntime` does **not** pass a module handler. Construct `QuickJsRuntime2` yourself when you need modules. Call `js.enableHandlePromises()` if you want the same promise helper setup as the factory.

## Precompiled bundles (preferred for a known graph)

QuickJS resolves imports **synchronously, while compiling**, so every module a
handler serves blocks the engine. `JsModuleBundle` moves that work to build
time: compile the graph once, register the bytecode in the context, and the
loader is never called.

```dart
final bundle = JsModuleBundle.compileSources(
  entry: 'main.js',
  sources: {
    'main.js': "import {answer} from './util.js'; globalThis.out = answer;",
    'util.js': 'export const answer = 42;',
  },
);

final js = getJavascriptRuntime();
await js.handlePromise(bundle.evaluate(js));      // registers + runs the entry
```

Keys are the specifiers `import` resolves to (QuickJS normalizes a leading
`./` / `../` against the importing module's name). `compileSources` reports the
importing module and the missing specifiers if the graph is incomplete.

`install(runtime)` registers into the **current context**: after `softReset()`
or `reinitialize()` the modules are gone, so install again. `toBytes()` /
`JsModuleBundle.fromBytes()` serialize the bundle. Details and caveats:
[Bytecode](../api/bytecode.md).

## Modules on `IsolateQjs`

An async `moduleHandler` on `IsolateQjs` runs on the **spawning** isolate while
the worker is blocked inside QuickJS, so the worker parks in 1 ms `sleep` steps
until the answer arrives — once per module, with platform-dependent latency.
Two ways to avoid that entirely:

```dart
// Precompiled: nothing is parsed or resolved at runtime.
final qjs = IsolateQjs(bundle: bundle);
await qjs.evaluateBundleEntry();

// Sources only: the worker resolves them itself, still no round trip.
final qjs = IsolateQjs(moduleSources: {'util.js': 'export const answer = 42;'});
await qjs.evaluate("import {answer} from './util.js'; globalThis.out = answer;",
    name: 'main.js', evalFlags: JSEvalFlag.MODULE);
```

Keep `moduleHandler` for specifiers that genuinely cannot be known up front; it
is consulted only when `moduleSources` has no entry for the name.

## Behavior notes

- Missing handler → module load fails (`No ModuleHandler`).  
- Handler errors are logged; native side may return null.  
- There is **no** Node/npm resolution — you map names to source (assets, network, embed).  
- Prefer loading known module graphs you control.

## Security

Module names come from JS `import`. Do not map arbitrary names to filesystem paths without allowlists.
