# Getting Started

Integrate **flutter_qjs_next** into a Flutter app, run a one-liner evaluate, then verify with a minimal widget test.

**Requirements**

- Dart SDK `^3.10.0`
- Flutter `>=3.0.0`
- A **native** target: Android, iOS, macOS, Linux, or Windows (not Web)

---

## 1. Add the dependency

### From pub.dev

```bash
flutter pub add flutter_qjs_next
```

### From a local path (development)

```yaml
dependencies:
  flutter_qjs_next:
    path: ../flutter_qjs_next   # path to this repo
```

### From Git

```yaml
dependencies:
  flutter_qjs_next:
    git:
      url: https://github.com/NanCunChild/flutter_qjs_next.git
      ref: main
```

Fetch packages:

```bash
flutter pub get
```

---

## 2. Import

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';
```

That export gives you:

- `getJavascriptRuntime`
- `JavascriptRuntime` / `QuickJsRuntime2`
- `JsEvalResult`, `JsEnginePool`, `FlutterQjsLogger`
- Promise helpers (`handlePromise`, …)

---

## 3. Minimal integration (sync evaluate)

```dart
import 'package:flutter_qjs_next/flutter_qjs.dart';

void runOnce() {
  final js = getJavascriptRuntime(
    timeout: 5000, // ms; recommended for untrusted scripts; null/0 = off
    // per-runtime QuickJS heap limit; null/negative -> 64 MiB, 0 -> unlimited
  );

  final r = js.evaluate('Math.trunc(Math.random() * 100).toString()');
  print(r.stringResult); // e.g. "42"
  print(r.isError);      // false on success

  js.dispose(); // always dispose — frees native heap + channel maps
}
```

### Limits (defaults)

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `stackSize` | JS stack size (bytes) | 1 MiB |
| `timeout` | Interrupt after this many **ms** of wall-clock JS work (`null`/`0` = off) | off |
| `memoryLimit` | Per-runtime QuickJS heap limit; `0` = unlimited; null/negative use default | **64 MiB** |

Each call to `getJavascriptRuntime()` creates a **separate** QuickJS engine (own heap, channels, `ReceivePort`). Prefer one long-lived runtime or a [pool](api/engine-pool.md) over create-per-call.

The heap limit is not a cap on the Flutter process or its RSS. Dart, Flutter,
plugin/native allocations and all runtime overhead remain outside it. For
untrusted inputs, also use a positive timeout, validate bridge payload sizes,
and limit the number of live engines.

---

## 4. Wire into a Flutter widget (sketch)

```dart
class _HomeState extends State<Home> {
  late final JavascriptRuntime _js;

  @override
  void initState() {
    super.initState();
    _js = getJavascriptRuntime(timeout: 5000);
  }

  @override
  void dispose() {
    _js.dispose();
    super.dispose();
  }

  void _onPressed() {
    final r = _js.evaluate('1 + 1');
    setState(() { /* use r.stringResult / r.rawResult */ });
  }

  // ...
}
```

**Rules of thumb**

1. Create the runtime once (e.g. in `initState` or a service), not on every button press.  
2. Call `dispose()` when the owner is disposed.  
3. For Promises / `setTimeout`, see [Promises & event loop](api/promises-and-event-loop.md).  
4. For Dart ↔ JS messages, see [Bridge](api/bridge.md).

Full demo: `example/lib/main.dart` (async bridge, AJV screen, benchmarks button).

---

## 5. Flutter commands you’ll use

Assume the **plugin repo** root is `flutter_qjs_next/` and the sample app is `example/`.

### Check environment

```bash
flutter doctor
flutter --version
```

### Get dependencies (plugin and example)

```bash
# plugin package
flutter pub get

# example app (has its own pubspec that depends on the plugin via path)
cd example
flutter pub get
```

### Run the example app

```bash
cd example

# list devices
flutter devices

# desktop (Linux example)
flutter run -d linux

# or pick interactively
flutter run
```

Other targets (when SDKs are installed):

```bash
flutter run -d windows
flutter run -d macos
flutter run -d chrome   # Web is NOT supported by this plugin — expect build/runtime failure
flutter run -d <android-device-id>
flutter run -d <ios-simulator-or-device>
```

### Hot reload / restart

While `flutter run` is attached:

- `r` — hot reload  
- `R` — hot restart  
- `q` — quit  

Native FFI / plugin registration changes usually need a **full restart** or re-run, not hot reload alone.

### Analyze / format

```bash
# from example/ or package root
flutter analyze
dart format .
```

---

## 6. Minimal test (recommended path)

The native QuickJS library is loaded through the **Flutter plugin**. Prefer **`flutter test`** under `example/` (or any Flutter app that depends on the plugin).

### Why not bare `dart run`?

On recent Dart SDKs, compiling standalone programs that use `dart:ffi` callbacks (`Pointer.fromFunction` / similar) can **crash the compiler** before any code runs. Use the Flutter test harness so the plugin’s native library is linked correctly.

### Option A — run the package’s TypedArray tests (smoke)

From the **example** directory:

```bash
cd example
flutter test test/typed_array_test.dart
```

You should see tests pass for `Uint8Array` → `Uint8List` and related paths. That confirms:

- native library loads  
- evaluate works  
- marshalling works  

Other useful tests:

```bash
cd example

# Promise job queue / pool / dispose stress
flutter test test/leak_and_stress_test.dart

# micro-benchmarks (slower; default 8 seeds)
flutter test test/benchmark_test.dart
flutter test test/benchmark_test.dart --dart-define=BENCH_RUNS=1

# short soak smoke (~30s)
flutter test test/soak_stress_test.dart
```

### Option B — add a minimal test in *your* app

In your app’s `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
```

Create `test/qjs_smoke_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';

void main() {
  test('evaluate 1+1', () {
    final js = getJavascriptRuntime(timeout: 3000);
    addTearDown(js.dispose);

    final r = js.evaluate('1 + 1');
    expect(r.isError, isFalse);
    expect(r.rawResult, 2);
    expect(r.stringResult, '2');
  });
}
```

Run:

```bash
flutter test test/qjs_smoke_test.dart
```

Use a **Flutter** project (not a pure Dart package without the Flutter plugin tooling) so the native build runs.

---

## 7. What to try next

| Goal | Doc |
|------|-----|
| Understand engine / jobs / isolation | [Concepts](concepts.md) |
| Channel `sendMessage` / Dart handlers | [Bridge](api/bridge.md) |
| Promises, `setTimeout`, `handlePromise` | [Promises & event loop](api/promises-and-event-loop.md) |
| Untrusted scripts | [Security](guides/security.md) |
| Copy-paste snippets | [Recipes](recipes/hello-evaluate.md) |
| Example UI | `cd example && flutter run` |

---

## 8. Common first-run issues

| Symptom | What to do |
|---------|------------|
| Web build / `dart:ffi` missing | Use a mobile/desktop device; Web is unsupported |
| Tests fail to load native library | Run under `example/` with `flutter test`, not `dart test` alone on the plugin root without Flutter |
| Compiler crash with `dart run …` | Switch to `flutter test` / `flutter run` |
| Forgot `dispose()` | Leak of native heap and channel map entries — always dispose |
| Promise never finishes | See [Troubleshooting](troubleshooting.md) and [Promises](api/promises-and-event-loop.md) |

More: [Troubleshooting](troubleshooting.md), [FAQ](faq.md).
