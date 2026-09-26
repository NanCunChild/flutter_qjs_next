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

## Windows: the MSVC compatibility layer

Upstream QuickJS is written for GCC and Clang, and Flutter builds Windows plugins with MSVC. Everything that bridges the two lives in **`cxx/quickjs/msvc-compat.h`**, which `cutils.h` includes and which expands to nothing off MSVC: the GCC builtins (`__builtin_expect`, `__builtin_clz*`, `__builtin_ctz*`, `__builtin_frame_address`), `__attribute__` as a no-op, `gettimeofday` / `clock_gettime`, the `pthread_mutex_t` / `pthread_cond_t` subset that `Atomics.wait` and `JS_NewClassID` use (SRW locks and condition variables), and `alloca`, which quickjs.c calls but only declares on Linux and the BSDs.

The upstream files themselves carry only small marked changes. `grep -n '_MSC_VER\|JS_VALUE_UNCONST\|JS_VALUE_CONST\|JS_FLOAT64_INF' cxx/quickjs/*.c cxx/quickjs/*.h` lists all of them:

| Where | Why |
|-------|-----|
| `quickjs.c`, `dtoa.c` | `<sys/time.h>` and `<pthread.h>` do not exist on MSVC; `msvc-compat.h` supplies what they provide |
| `quickjs.c` `DIRECT_DISPATCH` | MSVC has no computed goto, so the interpreter uses the `switch` dispatch |
| `quickjs.c` `JS_FLOAT64_INF` | MSVC rejects the constant `1.0 / 0.0` as a division by zero |
| `quickjs.h` `JS_VALUE_UNCONST` / `JS_VALUE_CONST` | MSVC's C compiler rejects a cast between two struct types even when they are the same type |
| `cutils.h` `#pragma pack` | `__attribute__((packed))` is gone with `__attribute__`; these three structs read unaligned integers out of byte buffers |
| `quickjs.c` `JSClosureVar.closure_type` | **Not a style fix.** MSVC gives an enum bitfield a *signed* underlying type, so this 3-bit field read `JS_CLOSURE_GLOBAL` (5) back as `-3`, no case of the switch in `js_closure2()` matched, and the first global variable reference in any script took the process down. The other enum bitfields in the file are 8 bits wide, so they still hold every value their enums define. |

Build flags (`cxx/quickjs.cmake`, `windows/CMakeLists.txt`): the QuickJS C library needs `/std:c11 /experimental:c11atomics` for `<stdatomic.h>` behind `Atomics.*`, and the plugin needs C++20, because `quickjs.h` builds JSValues with compound literals that MSVC's C++ front end only accepts from C++20 on.

A QuickJS upgrade overwrites these files. Re-apply the marked changes and check that `flutter build windows --debug` still runs a script, not only that it links — a Windows build that compiles can still fail on the first line of JavaScript, which is how this went unnoticed before (see `doc/review/2026-09-22-code-review.md`, S3).

Windows threads get a 1 MiB stack, against 8 MiB on Linux and Apple, so [`kDefaultJsStackSize`](../../../lib/javascript_runtime.dart) is 256 KiB there: QuickJS has to reach *its* limit while real stack is left, or a deeply nested value takes the process down instead of raising `InternalError: stack overflow`. Converting a value to Dart recurses once per level in `_jsToDart`, and that recursion has no such guard — around 20 000 levels exhausts the stack of a Windows test isolate.

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
