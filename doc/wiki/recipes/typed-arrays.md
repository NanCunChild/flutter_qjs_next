# Recipe: TypedArrays

## Goal

Move binary data without per-element marshalling.

## JS → Dart

```dart
final r = js.evaluate('new Uint8Array([1, 2, 255, 0])');
final bytes = r.rawResult as Uint8List;
// [1, 2, 255, 0]
```

## Dart → JS

```dart
import 'dart:typed_data';

final data = Uint8List.fromList([9, 8, 7]);
final lenFn = js.evaluate('(v) => v.length').rawResult as JSInvokable;
final n = lenFn.invoke([data]);
lenFn.free();
// n == 3
```

## Tests

```bash
cd example
flutter test test/typed_array_test.dart
```

See [Types & marshalling](../api/types-and-marshalling.md).
