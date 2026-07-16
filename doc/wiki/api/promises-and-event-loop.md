# Promises & event loop

## Job queue

QuickJS schedules Promise reactions and similar work as **jobs**.

### Auto drain (default)

`QuickJsRuntime2.autoExecutePendingJobs` defaults to **`true`**.

After `evaluate`, `evaluateJson`, `evaluateBytecode`, and `callFunction`, the runtime calls `executePendingJobs()`.

Implications:

- Sync scripts that only schedule microtasks often settle without an extra manual drain.  
- Ordering can differ from engines that only run jobs when you pump explicitly.  
- Small cost when jobs are pending.

Disable for explicit control:

```dart
final js = QuickJsRuntime2(autoExecutePendingJobs: false);
// or:
(js as QuickJsRuntime2).autoExecutePendingJobs = false;
```

### Manual drain

```dart
js.executePendingJob();           // one
js.executePendingJobs();          // up to maxJobs (default 10000)
(js as QuickJsRuntime2).hasPendingJobs;
```

## `handlePromise`

Extension on `JavascriptRuntime` (`lib/extensions/handle_promises.dart`):

```dart
final r = js.evaluate('Promise.resolve(1)');
final done = await js.handlePromise(r, timeout: Duration(seconds: 5));
```

If `rawResult` is a Dart `Future` (Promise marshalled), it awaits that Future while periodically calling `executePendingJob()` (every ~4 ms).

`getJavascriptRuntime` calls `enableHandlePromises()` (marks a flag; no 20 ms poll registry).

## `setTimeout`

Implemented in Dart:

1. JS stores the callback and `sendMessage('SetTimeout', { timeoutIndex, timeout })`.  
2. Dart starts a `Timer`.  
3. On fire, invokes a **cached** JS runner invokable (not free’d per shot).

`clearTimeout` only deletes the JS-side callback entry.

Host wall-clock timers still require the Dart event loop to run (normal in Flutter).

## `dispatch()`

```dart
// QuickJsRuntime2 — long-lived pump
unawaited((js as QuickJsRuntime2).dispatch());
```

Consumes the runtime `ReceivePort` until closed (`dispose`). Use when native/async paths notify the port and you need continuous job execution.

## Typical async evaluate pattern

```dart
final pending = await js.evaluateAsync('fetchLike().then(x => x)');
js.executePendingJob(); // if auto drain off or still pending
final result = await js.handlePromise(pending);
```

See [Async bridge recipe](../recipes/async-bridge.md) and `example/lib/main.dart`.

## Unhandled rejections

Optional `hostPromiseRejectionHandler` on `QuickJsRuntime2`. Default: log a warning via `FlutterQjsLogger`.
