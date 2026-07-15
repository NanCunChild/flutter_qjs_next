# Recipe: Async bridge + Promise

## Goal

JS calls Dart via `sendMessage`, Dart returns async data, JS `await`s a Promise, Dart awaits the final value with `handlePromise`.

Pattern from `example/lib/main.dart`.

```dart
final js = getJavascriptRuntime(timeout: 10000);

js.onMessage('getDataAsync', (args) async {
  await Future.delayed(const Duration(milliseconds: 50));
  final count = args is Map ? (args['count'] as num?)?.toInt() ?? 0 : 0;
  return List.generate(count, (i) => {'key$i': i});
});

js.onMessage('asyncWithError', (_) async {
  await Future.delayed(const Duration(milliseconds: 10));
  return Future.error('Some error');
});

Future<String> run() async {
  final pending = await js.evaluateAsync('''
    async function test() {
      var asyncResult = await sendMessage(
        "getDataAsync",
        JSON.stringify({"count": 3})
      );
      var err;
      try {
        await sendMessage("asyncWithError", "{}");
      } catch (e) {
        err = e.message || e;
      }
      return { asyncResult: asyncResult, expectedError: err };
    }
    test();
  ''');
  js.executePendingJob();
  final done = await js.handlePromise(pending);
  return done.stringResult;
}

// later:
// js.dispose();
```

## Notes

- Prefer JSON strings for structured args (auto-decoded in the bridge).  
- Pump jobs if needed (`executePendingJob` / auto drain).  
- Use `handlePromise` timeout for safety: `handlePromise(r, timeout: Duration(seconds: 5))`.  
