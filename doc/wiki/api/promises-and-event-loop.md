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

## Timers

`setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` are backed by
Dart `Timer`s (see [Web APIs](web-apis.md)):

1. JS stores the callback and calls a host function.
2. Dart starts a `Timer` (`Timer.periodic` for intervals).
3. On fire, Dart invokes a cached JS dispatcher, then runs the **microtask
   checkpoint** — promises resolved inside the callback continue without a
   manual pump (unless `autoExecutePendingJobs` is `false`).

`clearTimeout` / `clearInterval` cancel the Dart `Timer` itself. Callback
exceptions go to `reportError` (logged at error level), not silence.

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
