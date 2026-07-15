# Platforms

## Supported

| Platform | Plugin tree |
|----------|-------------|
| Android | `android/` |
| iOS | `ios/` |
| macOS | `macos/` |
| Linux | `linux/` |
| Windows | `windows/` (+ `cxx-windows/` QuickJS sources) |

Native code: C/C++ FFI bridge under `cxx/`, embedded QuickJS under `cxx/quickjs/`.

## Not supported

- **Web** — `dart:ffi` and native shared libraries are required.  
- Pure Dart VM without the Flutter plugin registration path may fail to locate the library; use Flutter apps / `flutter test`.

## Tooling requirements

- Dart `^3.10.0`, Flutter `>=3.0.0`  
- Platform SDKs as required by Flutter for your target  

## Build notes

- Example and tests load the plugin through Flutter’s build system.  
- Prefer:

```bash
cd example
flutter run -d <device>
flutter test
```

over bare `dart run` for anything that touches FFI callbacks.

## Desktop

Linux/Windows/macOS are first-class for development and CI-style tests when the corresponding Flutter desktop embedding is enabled:

```bash
flutter config --enable-linux-desktop   # if needed
flutter devices
```
