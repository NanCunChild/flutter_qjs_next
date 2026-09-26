# 1.5.2 发版检查（2026-09-26）

检查范围：`v1.5.1..a7ad944`，以及本次工作区修复。初始工作区干净。
环境：Linux x64，`fvm flutter`，Flutter 3.44.1 / Dart 3.12.1。

本机全量测试、补充压力测试、Linux Debug/Release 构建、Android Debug APK 构建均通过。
独立文件快照的发布预检查通过，0 警告。本轮没有 Windows/macOS/iOS 实机环境，不能将本机结果视为所有平台的完整验证。

## 发现与修复

1. **发版阻塞：Apple podspec 版本未同步。** `pubspec.yaml` 为 1.5.2，而两个 podspec 仍为 1.5.1；`scripts/check-package-metadata.sh` 返回失败。已同步为 1.5.2，复验通过。
2. **发布预检查警告：已跟踪锁文件同时被 git 忽略。** 从 `.gitignore` 移除 `pubspec.lock`，改在 `.pubignore` 排除；保留仓库中可复现依赖的锁文件，不随包发布。

审阅了 rope 字符串转换、可枚举字符串属性筛选、平台默认栈大小及其传递路径、Android `mallopt` 动态解析、Windows 原生源码统一与 MSVC 兼容改动。本轮未确认新的运行期回归。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `sh scripts/check-native-sync.sh` | 通过，Apple 原生副本与 cxx 一致 |
| `sh scripts/check-package-metadata.sh` | 修复后通过 |
| `fvm flutter analyze` | 通过，无问题 |
| example：`fvm flutter build linux --debug` | 通过，重新构建测试使用的动态库 |
| example：`fvm flutter test --reporter expanded` | 243 通过，1 默认跳过；约 31 秒，默认 8 轮基准测试也执行 |
| 默认压力测试（包含在全量套件中） | 30 秒，89,448 次操作，0 错误 |
| HTTP 对照实验，`CONTROL_SEC=10` | 补跑默认跳过项，1 通过，15,104 次操作，结束时 liveHandlers=0 |
| mixed_all 压力测试，60 秒 + 30 秒冷却 | 1 通过，44,656 次操作，5,133 次 fetch，0 错误 |
| example：`fvm flutter build linux --release` | 通过 |
| example：`fvm flutter build apk --debug` | 通过，产物 example/build/app/outputs/flutter-apk/app-debug.apk |
| Android 打包插件 ELF 检查 | arm64-v8a、armeabi-v7a、x86、x86_64 均无直接 mallopt 符号依赖，存在 dlsym 引用；LOAD 段对齐均为 0x4000 |
| 工作区 `fvm flutter pub publish --dry-run` | 剩余 1 项警告：两个 podspec 修改尚未提交；退出码 65 |
| 独立文件快照 `fvm flutter pub publish --dry-run` | 退出码 0，0 警告，压缩包约 2 MB |
| `git diff --check` | 通过 |

独立快照复制 `git ls-files` 列出的文件当前内容到 `/tmp/flutter-qjs-release-ydfse5dr`，不复制 `.git`，不执行发布。本报告在快照验证后添加。

混合压力测试的 RSS：基线 130,441,216 B，峰值 234,434,560 B，冷却后 222,822,400 B。桥接 alloc/free 计数均为 23,780，最终文件描述符为 12（基线 13）。短期测试满足既有断言，但 RSS 没有回到基线，不据此断言长期无泄漏；本轮未执行小时级压力矩阵。

补充测试命令（在 example 下执行）：

```sh
fvm flutter test test/http_control_test.dart --reporter expanded --dart-define=CONTROL_SEC=10
fvm flutter test test/soak_stress_test.dart --reporter expanded \
  --dart-define=SOAK_PROFILE=mixed_all \
  --dart-define=SOAK_DURATION_SEC=60 \
  --dart-define=SOAK_COOLDOWN_SEC=30 \
  --dart-define=SOAK_DUMP_DIR=/tmp/flutter_qjs_next-mixed-soak
```

## 发版边界

- 本轮 Windows、macOS、iOS 未重新构建或运行；仓库旧审查记录中的实测结果不计入本轮结果。Android 本轮验证编译、打包和插件 ELF，未做设备运行测试。
- 现有 CI 覆盖 Linux 测试及 Windows/Apple 构建，没有 Android job；Windows/Apple job 未运行全量 Dart 测试，CocoaPods job 为非阻塞。
- 发布 workflow 在推送版本标签时直接运行 `dart pub publish --force`，没有依赖测试 job。发版前应核对目标提交的 CI 结果。
- 当前本地 `v1.5.2` 标签指向 `a7ad944`，不含本次修复。修复未提交，也未改动标签或执行发布。
- Android 构建有 Gradle/AGP/Kotlin 未来支持变更提示，本轮构建成功；未扩展修改工具链版本。

原始日志保留在 `/tmp/flutter_qjs_next-tests.log`、`/tmp/flutter_qjs_next-http-control.log`、`/tmp/flutter_qjs_next-mixed-soak.log`、`/tmp/flutter_qjs_next-linux-release.log`、`/tmp/flutter_qjs_next-android-build.log`、`/tmp/flutter_qjs_next-publish-dry-run.log`、`/tmp/flutter_qjs_next-publish-snapshot.log`。全量测试改写的历史 `example/soak_dumps/soak_metrics.jsonl` 已恢复，生成内容另存于 `/tmp/flutter_qjs_next-default-soak.jsonl`。
