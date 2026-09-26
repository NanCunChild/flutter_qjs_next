# flutter_qjs_next 代码审查记录（2026-09-22）

审查基线：`e8ee062`（QuickJS `2026-06-04`）。

本次审查的范围是最近几次提交，以及下游报告的「长字符串拼接结果到 Dart 变成 `null`」。
编号接续 [2026-09-13 的审查](2026-09-13-code-review.md)：R8、R9 已修复；T1–T7 为待办；S1、S2 为结构性问题。

2026-09-26 补充：三端实测（本机 Linux、远程 Windows、远程 macOS）发现 Windows 构建自 QuickJS 升级起就是坏的，见 S3；R10、R11 是在那次实测中发现并修复的运行期缺陷。macOS 侧同日完成两项收尾复验：Dart 测试套件 243 通过 / 1 跳过，CocoaPods 构建路径成功，见 S2 与 S3-1。

---

## 一、已实测确认并修复的逻辑错误

实测方式与上次相同：在 `example/` 下用 `flutter test` 加载 Linux debug 构建运行探针用例。

| # | 问题 | 位置 | 修复前实测 | 状态 |
|---|---|---|---|---|
| R8 | `+` 右操作数超过 `JS_STRING_ROPE_SHORT_LEN`（512）时，QuickJS 返回 `JS_TAG_STRING_ROPE`；`_jsToDart` 只处理 `JSTag.STRING`，rope 落入 `default` 返回 `null` | `lib/quickjs/wrapper.dart` `_jsToDart` | `evaluate("'a' + 'b'.repeat(600)")` 的 `rawResult` 为 `null`、`stringResult` 为 `"null"`；在对象/数组中、作为宿主函数参数同样为 `null` | 已修复 |
| R9 | 对象转换调用 `jsGetOwnPropertyNames(..., -1)`，flags 含 `JS_GPN_SYMBOL_MASK`；Symbol 键经 `_jsToDart` 变成 `null`，多个 Symbol 键互相覆盖 | `lib/quickjs/wrapper.dart` `_jsToDart` | `({[Symbol('a')]: 1, [Symbol('b')]: 2, x: 3})` → `{x: 3, null: 2}` | 已修复 |

### 修复记录

- **R8**：`case JSTag.STRING_ROPE` 与 `STRING` 共用分支。`JS_ToCStringLen2` 对非 `JS_TAG_STRING` 的值先 `JS_ToString`，会展平 rope，因此 native 无需改动。`evaluateJson` 的结果 tag 检查同样接受 rope。回归用例：`example/test/string_rope_test.dart`。
- **R9**：flags 改为 `JSGPN.STRING_MASK | JSGPN.ENUM_ONLY`（新增 `JSGPN` 常量类），语义与 `Object.keys` 一致。原来的 `-1` 也包含 `ENUM_ONLY`，因此只去掉了 Symbol（及 private）键，不可枚举属性的行为不变。回归用例：`example/test/object_keys_test.dart`。
- 删除死代码 `lib/quickjs/qjs_typedefs.dart`（tag 值来自旧版 QuickJS）及仅被它引用的 `lib/quickjs/utf8_null_terminated.dart`。
- 验证：`example/test/` 全部用例通过（243 个，1 个 skip），`flutter analyze` 无问题。

最近提交本身：`e8ee062` 的 `mallopt` 改为 `dlsym` 运行时解析，符合 bionic 的 API 级别（`mallopt` 自 API 26 起提供，`M_PURGE` 自 API 28 起生效），没有问题。

---

## 二、待办

### 逻辑

- [ ] **T1** `_toEvalResult` 把 `null` 结果的 `stringResult` 设为字符串 `"null"`（`lib/quickjs/quickjs_runtime2.dart` `_toEvalResult`），R8 因此长期未被发现。需要决定：保持 flutter_js 兼容，或者让未识别的 tag 在 debug 下断言或记录日志，使同类问题能暴露出来。
- [ ] **T2** `_DartFunction._passThis` 用正则 `{.*thisVal.*}` 匹配 `runtimeType.toString()`（`lib/quickjs/object.dart`）。名为 `thisValue` 的参数、回调参数自带的 `thisVal` 都会误判；`--obfuscate` 构建下类型字符串可能变化（未实测）。
- [ ] **T3** 超过 63 位的 BigInt 通过 `jsEval('BigInt("...")')` 构造（`lib/quickjs/wrapper.dart` `_dartToJs`），依赖全局 `BigInt` 未被改写；不受信任的脚本可以替换它，截获宿主传入的值。
- [ ] **T4** `IsolateFunction` 用 `identityHashCode` 作 handler id（`lib/quickjs/object.dart`），该值不保证唯一，碰撞时调用会路由到错误的 handler。继承自上游 ekibun 实现。
- [ ] **T5** `dispose()` 用 `e.message.contains('reference leak')` 决定是否 rethrow（`lib/quickjs/quickjs_runtime2.dart`），改为专用异常类型。

### 冗余与风格

- [ ] **T6** `reinitialize()` 在 `close()` 之后重复执行 `localContext.clear()` / `dartContext.clear()`。
- [ ] **T7** 风格不一致：`jsToCString` 失败时抛 `Exception`，其余路径抛 `JSError`；`object.dart`、`isolate.dart`、`wrapper.dart` 保留 2020 年 ekibun 的文件头，以及 `Map()` / `Set()` 等旧写法。

---

## 三、结构性问题

- **S1 原生源码的多份副本。** `ffi.cpp` / `ffi.h` / `quickjs/` / `quickjs.cmake` 原本在 `cxx/`、`cxx-windows/`、iOS SPM、macOS SPM 下各有一份，逐字节一致，平台差异全部写在 `#if` 与各平台构建文件里。原有的 `scripts/check-native-ffi-sync.sh` 只比对 `ffi.*`，且没有接入 CI。

  决定：以 `cxx/` 为唯一源码。平台差异继续用 `#if` 和构建参数表达，不允许副本内容分叉。分三步：

  - [x] **S1-1 CI 检测。** 新增 `.github/workflows/ci.yml`：原生副本一致性、`flutter analyze`、Linux 构建与全部测试、Windows 构建、iOS/macOS SPM 构建。检查脚本改名为 `scripts/check-native-sync.sh`，范围扩大到整个 `quickjs/` 目录（含多出或缺失的文件），以及 `Package.swift` 中的 `CONFIG_VERSION` 与 `VERSION.txt` 是否一致；新增 `scripts/sync-native.sh`，从 `cxx/` 重新生成 Apple 副本。
  - [x] **S1-2 删除 `cxx-windows/`。** `windows/CMakeLists.txt` 改为与 Linux 一样 include `../cxx/quickjs.cmake`（两份 cmake 原本逐字节一致，MSVC 分支已在其中）。`cxx-windows/prebuild.sh` 没有任何调用方，一并删除。Windows 构建已在 Windows 机器上实测通过，但需要先修好 MSVC 兼容层，见 S3。
  - [ ] **S1-3 Apple 改为转发源文件。** 用几行 `#include "../../…/cxx/…"` 的转发文件替换 SPM 目录里的副本。SwiftPM 只编译包目录内的源文件，需要先在 Mac 上（或借 CI 的 `apple-spm` job）验证；验证不通过则保留由 `sync-native.sh` 生成的副本。
- **S2 CocoaPods 路径（已决定：SPM 为主，CocoaPods 适度支持）。** 原问题：podspec 被 `.pubignore` 排除；`prepare_command` 不会对 `:path` 引入的 pod 执行，`cxx/` 不会被生成；`pubspec.yaml` 允许 Flutter 3.0，而 SPM 路径需要 3.44+；podspec 版本号仍为 `0.0.1`。

  **2026-09-26 实机复验（macOS 14.8.9 / Xcode 16.2 / Flutter 3.47.5 / CocoaPods 1.17.0，x86_64）：** `flutter config --no-enable-swift-package-manager` 后 `flutter build macos --debug` 构建成功（`✓ Built …/flutter_qjs_example.app`）；删除 `example/macos/Pods` 与 `Podfile.lock` 后重跑仍成功。`pod install` 期间 podspec 的 `prepare_command` **确实执行了**：`macos/cxx/` 由 `cxx/prebuild.sh` 生成（`quickjs.c` 开头为 `CONFIG_VERSION "2026-06-04"` 与 `DUMP_LEAKS`，`VERSION.txt` 已移除），Xcode 编译的正是这份源码（CocoaPods 1.17.0 的 `PodSourcePreparer#run_prepare_command` 没有针对 `:path` 的分支）。因此「`prepare_command` 对 Flutter 的 `:path` pod 不执行」在 1.17.0 上不成立，CI 的 `apple-cocoapods` job（不阻塞）预期可以通过。当时仍成立的三点（podspec 被 `.pubignore` 排除、Flutter 最低版本与 SPM 要求的矛盾、podspec 版本号 `0.0.1`）已在同日按下文决定处理。复验还观察到 Flutter 3.47.5 首次构建会一次性升级示例工程（`analysis_options.yaml` 排除 build/平台目录、macOS 部署目标 10.15→12.0 反映在 `Podfile` 与 `project.pbxproj`、`pubspec.lock` 依赖小版本变动），属工具迁移而非本包改动，已还原未提交。

  **决定（2026-09-26）：全面拥抱 SPM，适度支持 CocoaPods。** Flutter 下限提高到 `>=3.44.0`，与 SPM 看齐；两个 podspec 从 `.pubignore` 移出、随包发布，`s.version` 与 `pubspec.yaml` 同步，并由新增的 `scripts/check-package-metadata.sh` 在 CI 校验；podspec 保留 `prepare_command`（实测可执行），把 `source_files` 改指向 SPM `Sources/` 树留到 S1-3 的转发源文件之后。
- **S3 Windows 构建自 QuickJS 升级起就是坏的（已修复）。** 2026-09-26 在 Windows 机器（VS 2022 BuildTools 17.14、Flutter 3.47.0）上实测。

  起因：`cxx-windows/` 最初不是副本。它在 `f1e4993` 引入时是一份**为 MSVC 打过补丁的旧版 QuickJS**（2024-02-14，`quickjs.c` 有 4 处 `_MSC_VER`、`cutils.h` 有 8 处），而 `cxx/` 当时是 2025-09-13。`9e6589f`（升级到 2026-06-04）把 `cxx-windows/` 覆盖成了与 `cxx/` 相同的上游源码，补丁全部丢失。此后 Windows 无法编译，没有 CI 也没有 Windows 机器，因此一直没被发现——S1 里「四份副本逐字节一致、没有平台差异」描述的其实是补丁丢失之后的状态。

  两类问题，编译期的在 `doc/wiki/guides/platforms.md` 的「Windows: the MSVC compatibility layer」中列全；运行期的只有一个，但足以致命：

  | # | 问题 | 实测 |
  |---|---|---|
  | R10 | `JSClosureVar.closure_type` 是**枚举类型的位域**。MSVC 给枚举位域选有符号底层类型，3 位字段把 `JS_CLOSURE_GLOBAL`（5）读回 `-3`，`js_closure2()` 的 switch 无分支匹配 | 任何脚本里第一次引用全局变量即进程终止（`String(1)`、`globalThis` 都会）。修复后 `closure_type` 改为 `uint8_t : 3` |
  | R11 | 默认 JS 栈上限 1 MiB 等于 Windows 线程栈总量，QuickJS 的检查永远先于真实栈耗尽触发不了 | `JSON.stringify` 20000 层嵌套对象 → `0xC00000FD`（栈溢出）而非 `InternalError: stack overflow`。新增 `kDefaultJsStackSize`，Windows 取 256 KiB，实测改为抛出可捕获的异常 |

  验证方式：`cxx/` 直接用 `cl` 编成独立 exe / DLL 跑探针，绕开 Flutter 逐步二分。因为 `flutter_tester` **无法加载插件 DLL**（进程里已经有一个 Flutter 引擎），Windows 上跑 `example/test` 需要一份不链接 Flutter 的独立 DLL，`ffi.dart` 目前只为 Linux 准备了测试期查找路径。

  - [ ] **S3-1** `ffi.dart` 的 `FLUTTER_TEST` 分支只覆盖 Linux。若要让 CI 在 Windows/macOS 上跑测试套件，需要一个不链接 Flutter 的测试库产物和对应的查找路径。

    2026-09-26 macOS 实机：手工把 `cxx/ffi.cpp` + `cxx/quickjs/*.c` 编成不链接 Flutter 的 dylib，用现成的 `FLUTTER_QJS_NEXT_LIBRARY` 指向它后，`flutter test` 全套 **243 通过 / 1 跳过**（36 s），与 Linux 完全一致。构建命令（注意 QuickJS 的 `asm volatile` 在严格 `-std=c11` 下编不过，用 clang 默认的 `gnu11`）：

    ```sh
    clang -O2 -w -fPIC -std=gnu11 -DCONFIG_VERSION='"2026-06-04"' -I cxx/quickjs \
      -c cxx/quickjs/{cutils,libregexp,libunicode,quickjs,dtoa}.c
    clang++ -O2 -w -fPIC -std=c++17 -I cxx -I cxx/quickjs -c cxx/ffi.cpp
    clang++ -shared -o libflutter_qjs_next_plugin.dylib *.o
    cd example && FLUTTER_QJS_NEXT_LIBRARY=$PWD/../libflutter_qjs_next_plugin.dylib flutter test
    ```

    所以 macOS 半边不需要改 `ffi.dart`，`FLUTTER_QJS_NEXT_LIBRARY` 已经够用；剩余工作是把测试库的构建做成可重复的脚本（Windows 与 macOS 共用，Windows 只有 `cl` 探针的手工步骤），并决定是否让 CI 接入。
  - [ ] **S3-2** `_jsToDart` 按层递归，没有深度上限；Windows 测试 isolate 上约 20000 层耗尽栈（纯 Dart 递归同样深度也会失败，与本包无关）。考虑改为迭代或设上限。
