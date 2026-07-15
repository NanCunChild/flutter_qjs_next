# Recipe: AJV validation

## Goal

Load a large JS library (AJV) into a runtime and validate form-like data.

Reference implementation: `example/lib/ajv_example.dart` + `example/assets/js/ajv.js`.

## Steps (summary)

1. Create or reuse a `JavascriptRuntime`.  
2. Ensure globals expected by the bundle (`window` / `global` / `globalThis` as needed).  
3. `rootBundle.loadString('assets/js/ajv.js')` then `evaluate` the source once.  
4. Construct `Ajv`, `addSchema`, call `validate`.  
5. Prefer **`evaluateJson`** for large validation result trees when applicable.  
6. Keep the same runtime for the session so AJV loads once.

```dart
// Sketch — see example for full UI wiring
js.evaluate('var window = global = globalThis;');
js.evaluate(ajvSource);
js.evaluate('''
  var ajv = new global.Ajv({ allErrors: true, coerceTypes: true });
  // addSchema(...); validate(...)
''');
```

## Run the demo

```bash
cd example
flutter pub get
flutter run
# open "See Ajv Example"
```

## Tips

- One-time load: gate on `typeof ajv === 'undefined'`.  
- Memory: large validators + schemas benefit from the default heap limit and a single engine.  
