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

## Apple (iOS / macOS) source layout

| Path | Role |
|------|------|
| `cxx/` | **Source of truth** for `ffi.*` + `quickjs/` |
| `cxx/prebuild.sh` | CocoaPods `prepare_command`: copies `cxx/` → `ios/cxx` or `macos/cxx` (flattened headers) |
| `ios/Classes`, `macos/Classes` | CocoaPods plugin entry (ObjC only) |
| `ios/flutter_qjs_next/`, `macos/flutter_qjs_next/` | Swift Package Manager trees (`Package.swift` + `Sources/…`) |
| `ios/.../Sources/.../quickjs`, `macos/.../quickjs` | SPM copies of QuickJS (keep in sync with `cxx/quickjs/`) |

Plugin registration is pure **Objective-C** so SPM can mix ObjC + C/C++ in one target (Swift + C/C++ in the same SPM target is rejected).

`Package.swift` depends on Flutter’s generated `FlutterFramework` package (Flutter 3.44+ SPM path). CocoaPods still works via the podspecs.

On Apple, QuickJS `cutils.h` must not redefine `BOOL` under Objective-C (`#if !defined(__OBJC__)`).

QuickJS version string lives in `VERSION.txt` (not `VERSION`): macOS/iOS APFS is often **case-insensitive**, so a file named `VERSION` is treated as the C++ standard header `<version>` and breaks libc++ (`ptrdiff_t` cascade).

## Not supported

- **Web** — `dart:ffi` and native shared libraries are required.  
- Pure Dart VM without the Flutter plugin registration path may fail to locate the library; use Flutter apps / `flutter test`.

## Tooling requirements

- Dart `^3.10.0`, Flutter `>=3.0.0`  
- Platform SDKs as required by Flutter for your target  
- iOS/macOS: Xcode + CocoaPods and/or Swift Package Manager (Flutter 3.44+)

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
