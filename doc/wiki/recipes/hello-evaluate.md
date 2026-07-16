# Recipe: Hello evaluate

## Goal

Run one expression and read the result.

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';

void main() {
  final js = getJavascriptRuntime(timeout: 3000);
  final r = js.evaluate('Math.trunc(Math.random() * 100).toString()');
  print('ok=${!r.isError} value=${r.stringResult} raw=${r.rawResult}');
  js.dispose();
}
```

In Flutter, put create/dispose on a `State` or service (see [Getting Started](../getting-started.md)).

## Checklist

- [ ] Dependency added, `flutter pub get`  
- [ ] Import `flutter_qjs.dart`  
- [ ] `dispose()` called  
- [ ] Smoke test: `flutter test` with a tiny evaluate (under a Flutter app / `example/`)  
