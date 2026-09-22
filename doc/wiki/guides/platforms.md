# Platforms

## Supported

| Platform | Plugin tree |
|----------|-------------|
| Android | `android/` |
| iOS | `ios/` |
| macOS | `macos/` |
| Linux | `linux/` |
| Windows | `windows/` |

Native code: C/C++ FFI bridge under `cxx/`, embedded QuickJS under `cxx/quickjs/`. `cxx/` is the only place to edit native code. Android, Linux and Windows build it directly through `cxx/quickjs.cmake`; platform differences live in `#if` blocks in `ffi.cpp` and in each platform's build file, never in a separate copy of the sources.

## Apple (iOS / macOS) source layout

| Path | Role |
|------|------|
| `cxx/` | **Source of truth** for `ffi.*` + `quickjs/` |
| `cxx/prebuild.sh` | CocoaPods `prepare_command`: copies `cxx/` → `ios/cxx` or `macos/cxx` (flattened headers). See [CocoaPods](#cocoapods-known-issue) |
| `ios/Classes`, `macos/Classes` | CocoaPods plugin entry (ObjC only) |
| `ios/flutter_qjs_next/`, `macos/flutter_qjs_next/` | Swift Package Manager trees (`Package.swift` + `Sources/…`) |
| `ios/.../Sources/.../{ffi.*,quickjs/}`, `macos/...` | SPM copies generated from `cxx/`: do not edit them by hand |

Plugin registration is pure **Objective-C** so SPM can mix ObjC + C/C++ in one target (Swift + C/C++ in the same SPM target is rejected).

`Package.swift` depends on Flutter’s generated `FlutterFramework` package (Flutter 3.44+ SPM path).

After changing anything under `cxx/` (including a QuickJS upgrade), regenerate the SPM trees and check them:

```bash
sh scripts/sync-native.sh      # copies cxx/ffi.* and cxx/quickjs/, sets CONFIG_VERSION in both Package.swift
sh scripts/check-native-sync.sh
```

CI (`.github/workflows/ci.yml`) runs the check and fails when the trees differ from `cxx/`. Replacing the copies with small forwarding sources that `#include` the files in `cxx/` is planned. It has to be verified on a Mac first, because SwiftPM only compiles sources inside the package directory.

On Apple, QuickJS `cutils.h` must not redefine `BOOL` under Objective-C (`#if !defined(__OBJC__)`).

QuickJS version string lives in `VERSION.txt` (not `VERSION`): macOS/iOS APFS is often **case-insensitive**, so a file named `VERSION` is treated as the C++ standard header `<version>` and breaks libc++ (`ptrdiff_t` cascade).

## CocoaPods: known issue

**Status: unresolved.** Treat Swift Package Manager (Flutter 3.44+) as the only supported Apple build path for now. The CocoaPods path is expected to fail, for the reasons below. None of them have been reproduced on a Mac yet. The non-blocking `apple-cocoapods` job in CI builds the example with SPM disabled and records the result. It builds from the repository, where the podspecs exist, so it covers point 2 but not point 1.

1. **The podspecs are not published.** `.pubignore` excludes `ios/flutter_qjs_next.podspec` and `macos/flutter_qjs_next.podspec`. An app that uses the package from pub.dev with SPM disabled has no podspec for this plugin.
2. **The native sources would not be generated.** The podspecs compile `cxx/**`, which `prepare_command` (`sh ../cxx/prebuild.sh`) creates by copying the repository's `cxx/`. CocoaPods does not run `prepare_command` for pods installed with `:path`, and Flutter installs every plugin pod that way. Nothing creates `ios/cxx` or `macos/cxx`.
3. **The version constraint does not match.** `pubspec.yaml` allows `flutter: ">=3.0.0"`, but the SPM path needs Flutter 3.44+. Below 3.44, Apple builds fall back to CocoaPods, which is affected by 1 and 2.
4. The podspecs still declare version `0.0.1`.

Options, to be decided:

- **Drop CocoaPods.** Remove the podspecs, `Classes/` and `cxx/prebuild.sh`. Raise the Flutter constraint to 3.44 and say that Apple builds need SPM.
- **Repair CocoaPods.** Publish the podspecs and point `source_files` at the SPM `Sources/` tree instead of running `prepare_command`. Once the planned forwarding sources exist, both paths share them.

## Not supported

- **Web** — `dart:ffi` and native shared libraries are required.  
- Pure Dart VM without the Flutter plugin registration path may fail to locate the library; use Flutter apps / `flutter test`.

## Tooling requirements

- Dart `^3.10.0`, Flutter `>=3.0.0`  
- Platform SDKs as required by Flutter for your target  
- iOS/macOS: Xcode + Swift Package Manager (Flutter 3.44+); see [CocoaPods](#cocoapods-known-issue)

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
