# flutter_qjs_next 代码审查记录（2026-09-22）

审查基线：`e8ee062`（QuickJS `2026-06-04`）。

本次审查的范围是最近几次提交，以及下游报告的「长字符串拼接结果到 Dart 变成 `null`」。
编号接续 [2026-09-13 的审查](2026-09-13-code-review.md)：R8、R9 已修复；T1–T7 为待办；S1、S2 为结构性问题。

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

- **S1 原生源码的多份副本。** `ffi.cpp` / `ffi.h` / `quickjs/` / `quickjs.cmake` 在 `cxx/`、`cxx-windows/`、iOS SPM、macOS SPM 下各有一份，逐字节一致，平台差异全部写在 `#if` 与各平台构建文件里。`scripts/check-native-ffi-sync.sh` 只比对 `ffi.*`，且没有接入 CI（CI 只有 publish）。

  决定：以 `cxx/` 为唯一源码。平台差异继续用 `#if` 和构建参数表达，不允许副本内容分叉。分三步：

  - [ ] **S1-1 CI 检测。** 在 CI 中检查原生副本一致性，并运行 analyze、测试和各平台构建。
  - [ ] **S1-2 删除 `cxx-windows/`。** Windows 与 Linux 一样直接使用 `cxx/quickjs.cmake`。
  - [ ] **S1-3 Apple 改为转发源文件。** 需要先在 Mac 上验证 SwiftPM 能否编译包目录外的源文件。
- **S2 CocoaPods 路径（未解决）。** podspec 被 `.pubignore` 排除；`prepare_command` 不会对 `:path` 引入的 pod 执行，`cxx/` 不会被生成；`pubspec.yaml` 允许 Flutter 3.0，而 SPM 路径需要 3.44+；podspec 版本号仍为 `0.0.1`。以上均未在 Mac 上复现。待决定：放弃 CocoaPods 并提高 Flutter 下限，或者修复 podspec，让它直接使用 SPM 源码目录。
