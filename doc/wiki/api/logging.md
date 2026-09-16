# Logging

## `FlutterQjsLogger`

```dart
enum FlutterQjsLogLevel { debug, info, warning, error }

FlutterQjsLogger.enabled = true;
FlutterQjsLogger.level = FlutterQjsLogLevel.debug;

FlutterQjsLogger.handler = (level, message, error) {
  // custom sink
};

FlutterQjsLogger.info('hello');
FlutterQjsLogger.error('failed', exception);
```

Default sink: `dart:developer` `log` with name `flutter_qjs_next`.

Messages below `level` are dropped. Set `enabled = false` to silence all.

## JS `console`

Installed on init (see [Web APIs](web-apis.md)):

```js
console.log('%s scored %d', name, score);   // util.format-style substitution
console.info(obj);                          // util.inspect-style formatting
console.warn(...); console.error(...); console.debug(...); console.trace(...);
console.group(...); console.groupEnd();
console.count(label); console.time(label); console.timeEnd(label);
console.assert(condition, ...); console.dir(value); console.table(value);
```

Values are formatted in JS (BigInt, `Map` / `Set`, TypedArrays, cycles, getters
and `Error` stacks) and handed to the logger directly:

| Method | Level |
|--------|-------|
| `error`, `assert` failure | `error` |
| `warn` | `warning` |
| `debug`, `trace` | `debug` |
| everything else | `info` |

The old `ConsoleLog` channel is gone; nothing needs to be registered.

## When the package logs

Examples: unhandled promise rejection (if no custom handler), pending job failures, module handler errors, dispose failures, missing channel warnings.
