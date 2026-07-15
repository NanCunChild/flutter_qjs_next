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

Installed on init:

```js
console.log(...);
console.warn(...);
console.error(...);
console.info(...);
```

Forwarded on channel `ConsoleLog` to the logger (`error` / `warning` / `info`).

## When the package logs

Examples: unhandled promise rejection (if no custom handler), pending job failures, module handler errors, dispose failures, missing channel warnings.
