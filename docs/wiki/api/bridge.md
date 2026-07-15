# Dart ↔ JS bridge

## Register a Dart handler

```dart
js.onMessage('log', (args) {
  print(args); // often List/Map after JSON decode
});

// equivalent:
js.setupBridge('log', (args) { ... });
```

- `setupBridge` returns `false` if the channel name is **already** registered for this engine id.  
- Registrations live in a static map keyed by `getEngineInstanceId()`.  
- `dispose()` / `disposeChannelFunctions()` / `reinitialize()` clear or replace that entry.

## Call from JavaScript

```js
sendMessage('log', JSON.stringify([1, 2, 3]));
// or a non-JSON string; Dart keeps the raw string if decode fails
```

`sendMessage` is installed on the JS global during `initChannelFunctions`.

## Handler signature and return values

```dart
void Function(dynamic args) // setupBridge
// onMessage accepts dynamic Function(dynamic args) — may be async
```

If the Dart function **returns a value**, it is marshalled back to the JS `sendMessage` call site (including `Future` → Promise when the marshalling path supports it). The example app uses async handlers that return data or `Future.error` for rejection.

See recipe: [Async bridge + Promise](../recipes/async-bridge.md).

## Deprecated: Dart → JS `sendMessage`

```dart
@Deprecated('Prefer JS-side sendMessage bridges; string eval is unsafe')
js.sendMessage(channelName: 'x', args: ['a', 'b']);
```

This builds a string and `evaluate`s it. Prefer registering a bridge and invoking from JS, or evaluate your own carefully escaped script.

## Host context maps

```dart
js.localContext; // Map — used by the package (e.g. setTimeout runner cache)
js.dartContext;  // Map — free for app data; cleared on reinitialize()
```

Do not put undisposed native handles only in these maps without cleanup.

## Security notes

- Channel names and payloads from user scripts are **untrusted**.  
- Do not expose privileged host APIs on open channel names.  
- Prefer structured validation of `args` before use.  

More: [Security](../guides/security.md).
