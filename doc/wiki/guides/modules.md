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

## Behavior notes

- Missing handler → module load fails (`No ModuleHandler`).  
- Handler errors are logged; native side may return null.  
- There is **no** Node/npm resolution — you map names to source (assets, network, embed).  
- Prefer loading known module graphs you control.

## Security

Module names come from JS `import`. Do not map arbitrary names to filesystem paths without allowlists.
