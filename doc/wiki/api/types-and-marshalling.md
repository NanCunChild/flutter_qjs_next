# Types & marshalling

Conversion lives mainly in `lib/quickjs/wrapper.dart` (`_dartToJs` / `_jsToDart`).

## Primitives & collections

| JS | Dart (typical) |
|----|----------------|
| `null` / `undefined` | `null` |
| boolean / number / string | `bool` / `int`/`double` / `String` |
| Array | `List` |
| plain Object | `Map` |
| Error | `JSError` |
| Promise | `Future` (thenable path) |
| Function | `JSInvokable` |

Exact numeric typing follows QuickJS tags and conversion helpers.

## Functions: `JSInvokable`

```dart
final fn = js.evaluate('(a, b) => a + b').rawResult as JSInvokable;
final sum = fn.invoke([2, 3]); // → 5
fn.free(); // required when you keep a handle
```

- Cache invokables for hot paths (benchmarks do this).  
- Always **`free()`** when finished; do not free the shared setTimeout runner (package-owned).  
- Host Dart functions can be passed into JS and become callable from JS (wrapped).

## TypedArray / ArrayBuffer (fast paths)

### Dart → JS

`TypedData` views map to matching TypedArrays via bulk buffer copy (`jsNewTypedArrayOwned`):

`Int8List`, `Uint8List`, `Uint8ClampedList`, `Int16List`, `Uint16List`, `Int32List`, `Uint32List`, `Float32List`, `Float64List`, and big-int variants where applicable.

`ByteBuffer` → JS `ArrayBuffer`.

### JS → Dart

TypedArrays convert to the matching Dart typed lists; `ArrayBuffer` often surfaces as `Uint8List` of the buffer bytes.

Detection does **not** rely on hard-coded QuickJS class numeric IDs (constructor name + element size).

## Performance implications

| Path | Notes |
|------|--------|
| Full `evaluate` + deep `jsToDart` | Correct for graphs with functions / nested objects; cost grows with size |
| `evaluateJson` | One stringify + decode; best for pure data |
| TypedArray bulk | Orders-of-magnitude faster than per-element (see README bench table) |

Recipe: [TypedArrays](../recipes/typed-arrays.md), [evaluateJson](../recipes/evaluate-json.md).  
Guide: [Performance](../guides/performance.md).

## Errors

JS exceptions become `JsEvalResult(isError: true)` on `evaluate`, or thrown `JSError` on some paths (`evaluateJson`, compile failures).

```dart
final r = js.evaluate('throw new Error("nope")');
assert(r.isError);
```
