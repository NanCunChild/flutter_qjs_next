# Web API soak 实验设计

日期：2026-09-16
被测对象：`doc/design/2026-09-13-web-apis.md` 引入的 Web API 模块。
术语说明：本文写于模块制改造（2026-09-17）之前，表格里的 L0 / L0+L1 分别对应今天的
`JsWebApis()`（只装 `core`）与 `JsWebApis.standard()`；`SOAK_WEB=web` 已更名为 `standard`。
承载框架：`example/lib/soak_stress_runner.dart`（复用池压力、指标采样、失败 dump、A/B 脚本）。

## 1. 为什么单独设计一次

现有 soak 覆盖的是桥接与编解码路径（evaluate、invoke、TypedArray、evaluateJson）。新增代码引入了三类
**旧 soak 完全不会触碰**的资源：

1. **跨 JS/Dart 的长生命周期句柄**：每个上下文常驻 `fire`、fetch 的 4 个回调；定时器表；fetch 的
   operation 表。引擎重置/销毁时必须全部释放。
2. **宿主侧操作系统资源**：`HttpClient` 的 socket、`StreamSubscription`。这类泄漏不会体现在 QuickJS 堆上，
   RSS 也可能长时间看不出来，但会耗尽文件描述符。
3. **新的原生 C 代码**：`utf8Encode` / `utf8EncodeInto` / `utf8Decode` 处理任意字节和孤立代理项，属于
   内存安全敏感路径，需要长时间、随机输入的持续冲击。

这三类问题的共同特点是：单元测试跑几百次不会暴露，需要**持续负载 + 反复重置 + 并发**才会显形。

## 2. 假设（每条都对应可证伪的指标）

| # | 假设 | 证伪信号 |
|---|---|---|
| H1 | 引擎重置/销毁后不残留 JS 句柄 | 空闲引擎 `debugReferenceCount` 随时间单调上升 |
| H2 | 定时器不会在重置后继续触发，也不会堆积 Dart `Timer` | 重置后仍有回调输出；RSS 持续上升且与定时器 op 相关 |
| H3 | fetch 的 socket 与 subscription 全部回收（含中止、丢弃、重置进行中请求） | `/proc/<pid>/fd` 数量持续上升 |
| H4 | Web API 的每次操作不在 JS 堆留下残留 | 空闲引擎 GC 后 `memoryUsedSize` / `atomCount` 持续上升 |
| H5 | 原生 UTF-8 代码在任意字节输入下不崩溃、不越界 | 进程崩溃；解码结果与往返不一致 |
| H6 | 启用 Web API 后进程 RSS 仍然收敛 | RSS 超过 baseline × factor |

## 3. 负载族（profile）

每个族都能单独跑，以便把增长归因到具体子系统。新增 profile 不改动既有的
`all` / `tiny` / `no_typed_array` / `dart_to_js` / `js_to_dart` / `typed_array`，避免影响已有基线对比。

| profile | 内容 | 主要压迫点 |
|---|---|---|
| `web_core` | 定时器建立/取消/interval、`structuredClone` 循环图、`console` 格式化、`crypto` 随机数 | H1 H2 H4 |
| `web_url` | URL 解析 + setter + `searchParams` 改写，逐条比对 href | atom / 字符串churn（H4） |
| `web_encoding` | 随机 Unicode 往返、随机字节解码、随机切分的流式解码、孤立代理项 | H5 |
| `web_blob` | Blob/File/FormData 构造、slice、multipart 序列化与回解析 | 大字节缓冲 churn（H4 H6） |
| `web_streams` | ReadableStream 分块 + TransformStream + 编解码流 + tee + 提前 cancel | 流内部队列、Promise 链（H1 H4） |
| `web_crypto` | `subtle.digest` 确定性与已知向量、HMAC 签名/验签 | Dart↔JS 拷贝（H6） |
| `web_fetch` | GET/JSON/分块读取/上传/重定向链/中止/丢弃请求 | H3 H1 |
| `web_all` | 上述全部按权重混合 | 综合 |
| `mixed_all` | `all`（旧负载）+ `web_all` | 回归：新旧路径互不干扰 |

所有 fetch 负载打到**进程内的本地 `HttpServer`**（loopback，随机端口），不依赖外网：实验可重复，
且把被测对象限定在本包的 fetch 实现而不是网络质量。端点包括固定小响应、JSON、分块响应、
慢响应（用于中止）、回显上传、可配置跳数的重定向链、404。

## 4. 两个对照开关

RSS 在持续负载下只涨不退（Dart 堆页不归还 OS），所以运行期的 RSS 曲线无法区分"泄漏"和"高水位"。
实验因此包含两个控制手段：

- **冷却阶段**（`SOAK_COOLDOWN_SEC`）：worker 停止后空转并制造分配压力促使 Dart GC 运行，再采一次 RSS。
  没有回落的部分才算保留，运行结束时会打印 `retained` / `retainedPerOp` / `retainedPerReset`。
- **fetch 桩**（`SOAK_FETCH_STUB=1`）：用进程内桩 handler 替换真实网络，JS 侧工作量不变但不碰 socket 与
  `HttpClient`。与真实运行对比即可把宿主侧增长归因到网络栈还是本包的请求记账。

## 5. 不变量与阈值

除既有的 RSS 上限外，新增三条在采样时检查、超限即 fail-fast 并写 dump：

| 定义 | 默认阈值 | 对应假设 |
|---|---|---|
| `SOAK_MAX_FD_GROWTH` | baseline + max(128, workers × 8) | H3 |
| `SOAK_MAX_DART_REFS` | 每个空闲引擎 512 | H1 |
| `SOAK_MAX_ENGINE_HEAP_MB` | 每个空闲引擎 GC 后 16 MiB | H2 H4 |

阈值先用短程运行标定（见第 6 节），取实测稳态值的若干倍留出余量：既要能抓住线性增长，也不能
因为正常抖动误报。每次操作自身还要**校验结果正确性**（URL href 逐字段、摘要向量、往返字节、响应体内容），
所以本实验同时是一个长时间运行的一致性测试，而不只是内存观察。

## 6. 采样指标

在既有采样（RSS、`/proc/smaps_rollup`、池状态、每引擎 QuickJS 内存与 `debugReferenceCount`、桥接计数器、
op 计数）之上新增：

- `fds`：`/proc/<pid>/fd` 数量（Linux）。
- `web.fetchOps` / `web.fetchBytes`：完成的请求数与读取字节数。
- `web.level` / `web.stub`：本次运行安装的 API 层级、是否用桩替换网络。
- 冷却后的 `retained` / `retainedPerOp` / `retainedPerReset`（仅在设置 `SOAK_COOLDOWN_SEC` 时）。
- 池被占满时，采样会临时借一个引擎，保证每次采样都有 per-engine 数据。

全部写入 `soak_metrics.jsonl`，可直接复用 `scripts/plot-soak-metrics.py` 出图。

## 7. 运行矩阵

```bash
# 冒烟（默认 30s）
cd example && flutter test test/soak_stress_test.dart \
  --dart-define=SOAK_PROFILE=web_all --dart-define=SOAK_WEB=fetch

# 带冷却的判读运行（推荐：任何怀疑内存的场合都加 cooldown）
flutter test test/soak_stress_test.dart --timeout none \
  --dart-define=SOAK_PROFILE=web_all --dart-define=SOAK_DURATION_SEC=300 \
  --dart-define=SOAK_COOLDOWN_SEC=90

# 单族归因（各 10 分钟）
for p in web_core web_url web_encoding web_blob web_streams web_crypto web_fetch; do
  flutter test test/soak_stress_test.dart --timeout none \
    --dart-define=SOAK_PROFILE=$p --dart-define=SOAK_DURATION_SEC=600
done

# 长程 burn-in + 重置 A/B + 出图
scripts/run-soak-ab.sh --full-test --duration 3600 \
  --profiles web_core,web_url,web_encoding,web_blob,web_streams,web_crypto,web_fetch,web_all,mixed_all
```

A/B 的两侧是 `resetOnRelease` 开/关：关表示引擎长期复用（句柄和定时器有更长的累积窗口），
开表示每次租借后 `reinitialize`（重装 Web API 的路径被反复走）。两条曲线都应收敛。

## 8. 试点结果（2026-09-16，Linux x64，debug 构建）

pool=6、workers=24、`resetOnRelease=true`，冷却 90s：

| 负载 | 操作数 | 峰值 RSS | 冷却后 | 保留 | 每次操作 |
|---|---|---|---|---|---|
| `all`（旧负载，对照） | 1,088,264 | 246 MB | 227 MB | 98 MB | 90 B |
| `web_url`（纯同步 web 操作） | 192,336 | 204 MB | 204 MB | 74 MB | 385 B |
| `web_crypto`（异步） | 126,000 | 245 MB | 239 MB | 110 MB | 870 B |
| `web_all` | 178,640 | 448 MB | 432 MB | 302 MB | 1690 B |

**所有 QuickJS 侧计数器在整个 10 分钟运行中逐字节恒定**：`atomCount` 1779、`strCount` 467、
`mallocSize` 649 KiB、`memoryUsedSize` 458 KiB、`objCount` 840；`debugReferenceCount` 恒为 18；
fd 在负载中随并发起伏、结束后回到基线。也就是说 H1、H3、H4、H5 全部未被证伪，
JS 堆、Dart 句柄表、文件描述符都没有泄漏。

网络栈不是主因。`mixed_all` 在相同参数下跑真实 loopback 与桩 handler（`SOAK_FETCH_STUB=1`，
完全不建 socket）：

| 变体 | 操作数 | 保留 | 每次操作 | 每次重置 |
|---|---|---|---|---|
| 桩（无 socket） | 42,856 | 73 MB | 1.7 KB | 13.7 KB |
| 真实网络 | 35,912 | 98 MB | 2.7 KB | 21.9 KB |

去掉整个网络栈后仍保留 73 MB，说明主要成分在引擎与上下文的生命周期上，网络只贡献增量。
定点探针（每项 2000 次，冷却后测量）：

| 生命周期操作 | 每次保留 |
|---|---|
| 创建+销毁（`JsWebApis.none()`，完全不装 Web API） | 1.9 KB |
| 创建+销毁（L0） | 2.6 KB |
| 创建+销毁（L0+L1） | 4.6 KB |
| `reinitialize`（L0） | 1.0 KB |
| `reinitialize`（L0+L1） | 2.6 KB |
| `softReset`（L0） | ≈ 0 |
| `softReset`（L0+L1） | 1.2 KB |

结论：

0. 增长有两个成分：**主要成分按引擎生命周期次数累积**（创建/销毁、`reinitialize`），
   次要成分随每次操作搬运的字节数增长（fetch 响应体、Blob、摘要输入）。
1. 这是**已存在的现象**，不是 Web API 引入的：不装任何 Web API 的引擎每次创建/销毁同样保留 1.9 KB，
   与 `doc/wiki/guides/soak-rss-analysis.md` 中"RSS 增长由 hard reinitialize churn 主导"的结论一致。
2. Web API 把每个上下文的 JS 堆从 78 KiB 放大到约 460 KiB，保留量按大致相同的比例（约堆大小的 1%）
   放大。保留量与堆大小成正比而不是与某个具体对象数成正比，更像 glibc 分配器碎片，而非漏掉某次 free。
3. 纯 Dart 对照（20 万次、每次约 1.5 KB 字符串 + Future）只保留 27 B/次，排除了"测试框架或 Dart 堆
   本身如此"的解释。
4. **运维含义**：启用 Web API 后，引擎池应优先 `resetMode: soft` 或保持温复用（`none`），避免
   `hard`/`resetOnRelease`；后者在本实验的参数下每次重置多保留约 2.6 KB。

## 9. 判读方式

- **线性增长**：任一指标随时间近似线性上升 → 泄漏。先看是哪个 profile 单独复现，再看是 JS 堆
  （`memoryUsedSize` / `atomCount`）、Dart 句柄（`dartRefs`）还是宿主资源（`fds` / RSS）。
- **阶梯状**：只在重置时抬升 → 重装路径没释放旧上下文的东西。
- **锯齿收敛**：正常（GC 与 arena 缓存）。
- 失败时 dump 包含配置、最近 N 条 op、池状态、引擎内存快照与堆栈，可直接定位到 op 族。

## 10. 本次实验尚未覆盖

- 第 8 节第 2 条的碎片假设未做直接验证（需要 `malloc_trim` 或换分配器做对照实验）。
- 多 isolate 并发（沿用现有 soak 的限制）。
- 真实网络与 TLS（本地 server 是明文 HTTP）。
- `IsolateQjs`（只装 `core`，不在本实验范围）。

## 11. 后续修正（2026-09-17）

第 8 节第 2 条的"碎片假设"已做对照实验，**结论被推翻**：

- `readNativeHeapUsage()`（glibc `mallinfo2`，现已写入 `soak_metrics.jsonl` 的
  `nativeHeap`）显示 C 堆 arena 在整段 `web_fetch` 负载中稳定在 ~30 MB、
  in-use ~26 MB，而进程 RSS 从 151 MB 涨到 691 MB；`malloc_trim(0)` 只收回
  24 MB。增长全部在 **Dart 堆**，不是分配器碎片。
- 按 profile 定位：`web_fetch` 3.04 MB/s，其余 profile ≤ 0.23 MB/s。
- 用新的 `SOAK_PROFILE=op:<opName>` 逐个 op 定位：**只有 `fetchAbort` 泄漏**
  （5.12 MB/s），其余 fetch op 都 ≤ 0.26 MB/s。
- `example/test/http_control_test.dart` 在**完全不启动 QuickJS** 的情况下复现：
  `CONTROL_MODE=abort` 30k 次请求 150 → 1206 MB，而 `read` / `cancel` /
  `cancelpaused` 都收敛。即保留发生在 `dart:io` 中止请求的路径上，与本包的
  fetch 桥接和引擎生命周期无关。
- 另外修掉了 harness 自身的问题：`/slow` 端点在客户端中止后会永远停在
  `flush()`，10k 次请求后有 6682 个 handler 卡住。

详见 `doc/wiki/guides/soak-rss-analysis.md` 的 "Update 2026-09-17"。
