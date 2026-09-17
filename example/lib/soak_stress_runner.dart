import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';

// =============================================================================
// Soak / stress runner (long-haul, high-concurrency)
//
// Purpose
// -------
// Complement micro-benchmarks (`benchmark_runner.dart`) and short leak tests
// (`leak_and_stress_test.dart`). This suite is for multi-hour burn-in under
// extreme concurrent load, not for us/op comparison.
//
// Coverage (concrete work items)
// ------------------------------
// 1. Pool lease pressure
//    - Many concurrent [JsEnginePool.withEngine] / acquire-release cycles.
//    - Waiters when pool is saturated (bounded maxSize).
//    - Optional resetOnRelease reinitialize churn between tenants.
//
// 2. Hot evaluate / host invoke
//    - Tiny `evaluate` (`1+1`, small expressions).
//    - Cached [JSInvokable.invoke] with free() discipline (no handle leaks).
//
// 3. Marshalling paths
//    - String and small Map Dart↔JS identity round-trips.
//    - Owned TypedArray Dart→JS (Uint8List size ladder).
//    - JS→Dart TypedArray via evaluate (`new Uint8Array(n)`).
//
// 4. evaluateJson vs full evaluate
//    - Larger array payloads (JSON-ish tree vs deep jsToDart).
//
// 5. Promise job queue
//    - Microtask scheduling; manual drain via executePendingJobs.
//
// 6. Engine lifecycle
//    - Short-lived create/dispose engines outside the pool (native teardown).
//    - Periodic [JavascriptRuntime.runGC] on leased engines.
//
// 7. Web platform APIs (see doc/design/2026-09-16-web-apis-soak.md)
//    - L0: timer create/cancel/interval churn, structuredClone graphs, console
//      formatting, crypto random values.
//    - L1: URL parse/mutate, TextEncoder/TextDecoder fuzz (random bytes, split
//      streaming, lone surrogates), Blob/File/FormData + multipart round trip,
//      streams (transform, tee, early cancel), subtle digest / HMAC.
//    - L2: fetch against an in-process HTTP server — GET, JSON, chunked read,
//      upload, redirect chain, abort mid-flight, and requests abandoned across
//      an engine reset.
//
// 8. Memory observation
//    - Periodic process RSS ([ProcessInfo.currentRss]) + pool stats.
//    - Open file descriptors (fetch socket / subscription leaks).
//    - Per idle engine: QuickJS heap after GC and Dart handle count.
//    - Optional soft ceilings: RSS factor, fd growth, dart refs, engine heap.
//
// 9. Failure stop + dump
//    - First error: write dump under [SoakStressConfig.dumpDir] (config, RSS,
//      pool stats, sample getMemoryUsage, last N ops, stack). Then rethrow.
//    - Native core: not produced here — see [SoakStressConfig.coreDumpHint].
//
// Non-goals
// ---------
// - Replacing micro-benchmark timing tables.
// - Multi-isolate JS engines (single isolate + pool skeleton first).
// - Full native heap dump from pure Dart (use gcore/gdb after dump file).
//
// Entry
// -----
// Prefer Flutter test harness (loads plugin native lib):
//
//   cd example
//   flutter test test/soak_stress_test.dart
//
// Duration / load (dart-define):
//
//   --dart-define=SOAK_DURATION_SEC=3600
//   --dart-define=SOAK_POOL_SIZE=8
//   --dart-define=SOAK_WORKERS=32
//   --dart-define=SOAK_DUMP_DIR=soak_dumps
//   --dart-define=SOAK_SEED=1
//   --dart-define=SOAK_PROFILE=all
//   --dart-define=SOAK_WEB=core|none|standard|fetch
//   --dart-define=SOAK_MAX_FD_GROWTH=128
//   --dart-define=SOAK_MAX_DART_REFS=512
//   --dart-define=SOAK_MAX_ENGINE_HEAP_MB=16
//
// Defaults are a short smoke (~30s). Full burn-in: SOAK_DURATION_SEC=3600.
//
// Matrix + charts (repo root):
//   scripts/run-soak-ab.sh --full-test --duration 3600
//   scripts/run-soak-ab.sh --plot-only soak_profiles
//   python3 scripts/plot-soak-metrics.py --root <dump-root> -o report/
// =============================================================================

/// Resolved soak parameters (CLI dart-define or programmatic).
class SoakStressConfig {
  SoakStressConfig({
    this.duration = const Duration(seconds: 30),
    this.poolSize = 4,
    this.workers = 16,
    this.opsPerBurst = 8,
    this.metricsInterval = const Duration(seconds: 5),
    this.seed = 1,
    this.dumpDir = 'soak_dumps',
    this.resetOnRelease = true,
    this.memoryLimitBytes = kDefaultJsMemoryLimit,
    this.timeoutMs = 5000,
    this.failOnFirstError = true,
    this.maxRssGrowthFactor = 0,
    this.maxLogLines = 200,
    this.workloadProfile = 'all',
    this.webApiLevel = 'core',
    this.maxFdGrowth = 128,
    this.maxDartRefs = 512,
    this.maxEngineHeapBytes = 16 * 1024 * 1024,
    this.fetchStub = false,
    this.cooldown = Duration.zero,
  });

  /// Wall-clock run length (target ≥ 1h for real burn-in).
  final Duration duration;

  /// [JsEnginePool.maxSize] — concurrent engines.
  final int poolSize;

  /// Parallel async workers issuing bursts against the pool.
  final int workers;

  /// Operations per worker iteration (mixed workload).
  final int opsPerBurst;

  /// How often to sample RSS / pool stats.
  final Duration metricsInterval;

  final int seed;
  final String dumpDir;
  final bool resetOnRelease;
  final int memoryLimitBytes;
  final int timeoutMs;
  final bool failOnFirstError;

  /// If > 0, fail when RSS exceeds baseline * this factor (0 = disabled).
  final double maxRssGrowthFactor;

  final int maxLogLines;

  /// Workload selector used to isolate memory-heavy operation families.
  /// Legacy: all, tiny, no_typed_array, dart_to_js, js_to_dart, typed_array.
  /// Web APIs: web_core, web_url, web_encoding, web_blob, web_streams,
  /// web_crypto, web_fetch, web_all, mixed_all.
  final String workloadProfile;

  /// Web API level installed in pooled engines: none, core, web, fetch.
  final String webApiLevel;

  /// Fail when open file descriptors exceed baseline + this (0 = disabled).
  /// Catches fetch sockets or stream subscriptions that are never released.
  final int maxFdGrowth;

  /// Fail when an idle engine holds more than this many Dart-side JS handles
  /// (0 = disabled). Catches JSInvokable / JSRef leaks across resets.
  final int maxDartRefs;

  /// Fail when an idle engine's QuickJS heap stays above this after GC
  /// (0 = disabled). Catches per-operation JS heap growth.
  final int maxEngineHeapBytes;

  /// Serve fetch from an in-process stub instead of the network (control
  /// variant for attributing host-side memory growth).
  final bool fetchStub;

  /// Quiet phase after the workers stop: idle plus allocation churn so the Dart
  /// GC runs, then sample RSS again. Under sustained load the heap only ever
  /// grows, so RSS during a run cannot distinguish a leak from a high-water
  /// mark; the drop during cooldown can.
  final Duration cooldown;

  JsWebApis get webApis => switch (webApiLevel) {
    'none' => const JsWebApis.none(),
    'core' => const JsWebApis(),
    'standard' => const JsWebApis.standard(),
    'fetch' => JsWebApis.standard(
      fetch: fetchStub
          ? JsFetchOptions(handler: _stubFetch)
          : const JsFetchOptions(),
    ),
    _ => throw ArgumentError.value(
      webApiLevel,
      'SOAK_WEB',
      'expected none, core, standard, or fetch',
    ),
  };

  bool get webEnabled =>
      webApiLevel == 'standard' || webApiLevel == 'fetch';
  bool get fetchEnabled => webApiLevel == 'fetch';

  /// Hint printed in dumps for operators (not executed).
  String get coreDumpHint =>
      'Linux: gcore <pid> or ulimit -c unlimited before re-run; '
      'gdb -p <pid> if process still alive after dump.';

  static SoakStressConfig fromEnvironment() {
    // String.fromEnvironment only sees --dart-define when the name is a
    // compile-time constant literal (not a runtime [key] parameter).
    int parseInt(String s, int fallback) => s.isEmpty ? fallback : int.parse(s);

    final sec = parseInt(const String.fromEnvironment('SOAK_DURATION_SEC'), 30);
    final metricsSec =
        parseInt(const String.fromEnvironment('SOAK_METRICS_SEC'), 5);
    final growth = const String.fromEnvironment('SOAK_MAX_RSS_GROWTH');
    final profile = const String.fromEnvironment(
      'SOAK_PROFILE',
      defaultValue: 'all',
    );
    final dumpDir = const String.fromEnvironment(
      'SOAK_DUMP_DIR',
      defaultValue: 'soak_dumps',
    );
    final web = const String.fromEnvironment('SOAK_WEB');
    final workers = parseInt(const String.fromEnvironment('SOAK_WORKERS'), 16);
    // In-flight fetch sockets scale with concurrency, so the default ceiling
    // does too; it is a leak detector, not a concurrency limit.
    final fdGrowth = workers * 8 < 128 ? 128 : workers * 8;
    return SoakStressConfig(
      duration: Duration(seconds: sec),
      poolSize: parseInt(const String.fromEnvironment('SOAK_POOL_SIZE'), 4),
      workers: workers,
      opsPerBurst:
          parseInt(const String.fromEnvironment('SOAK_OPS_PER_BURST'), 8),
      metricsInterval: Duration(seconds: metricsSec),
      seed: parseInt(const String.fromEnvironment('SOAK_SEED'), 1),
      dumpDir: dumpDir.isEmpty ? 'soak_dumps' : dumpDir,
      resetOnRelease:
          parseInt(const String.fromEnvironment('SOAK_RESET_ON_RELEASE'), 1) !=
              0,
      memoryLimitBytes:
          parseInt(const String.fromEnvironment('SOAK_MEMORY_LIMIT_MB'), 64) *
              1024 *
              1024,
      timeoutMs:
          parseInt(const String.fromEnvironment('SOAK_TIMEOUT_MS'), 5000),
      failOnFirstError:
          parseInt(const String.fromEnvironment('SOAK_FAIL_FAST'), 1) != 0,
      maxRssGrowthFactor: growth.isEmpty ? 0.0 : double.parse(growth),
      workloadProfile: profile,
      webApiLevel: _resolveWebLevel(web, profile),
      maxFdGrowth:
          parseInt(const String.fromEnvironment('SOAK_MAX_FD_GROWTH'), fdGrowth),
      maxDartRefs:
          parseInt(const String.fromEnvironment('SOAK_MAX_DART_REFS'), 512),
      maxEngineHeapBytes:
          parseInt(const String.fromEnvironment('SOAK_MAX_ENGINE_HEAP_MB'), 16) *
              1024 *
              1024,
      fetchStub:
          parseInt(const String.fromEnvironment('SOAK_FETCH_STUB'), 0) != 0,
      cooldown: Duration(
        seconds: parseInt(const String.fromEnvironment('SOAK_COOLDOWN_SEC'), 0),
      ),
    );
  }

  /// Web profiles imply the level they need unless SOAK_WEB says otherwise.
  static String _resolveWebLevel(String explicit, String profile) {
    if (explicit.isNotEmpty) return explicit;
    if (_fetchProfiles.contains(profile)) return 'fetch';
    if (profile.startsWith('web_')) return 'standard';
    if (profile.startsWith(_singleOpPrefix)) {
      final kind = _singleOp(profile);
      if (_fetchOps.contains(kind)) return 'fetch';
      if (_webCoreOps.contains(kind) || kind.name.startsWith('web')) {
        return 'standard';
      }
    }
    return 'core';
  }

  /// `SOAK_PROFILE=op:<name>` pins the workload to one [_OpKind], which is how
  /// a profile-level regression gets narrowed to a single operation.
  static const _singleOpPrefix = 'op:';

  static _OpKind _singleOp(String profile) {
    final name = profile.substring(_singleOpPrefix.length);
    for (final kind in _OpKind.values) {
      if (kind.name == name) return kind;
    }
    throw ArgumentError.value(
      profile,
      'SOAK_PROFILE',
      'unknown op name "$name"; expected one of '
          '${_OpKind.values.map((k) => k.name).join(', ')}',
    );
  }

  static const _fetchProfiles = {'web_fetch', 'web_all', 'mixed_all'};

  @override
  String toString() =>
      'SoakStressConfig(duration=$duration poolSize=$poolSize workers=$workers '
      'opsPerBurst=$opsPerBurst seed=$seed dumpDir=$dumpDir '
      'resetOnRelease=$resetOnRelease memoryLimit=$memoryLimitBytes '
      'timeoutMs=$timeoutMs failFast=$failOnFirstError '
      'maxRssGrowth=$maxRssGrowthFactor profile=$workloadProfile '
      'web=$webApiLevel fetchStub=$fetchStub cooldown=$cooldown '
      'maxFdGrowth=$maxFdGrowth '
      'maxDartRefs=$maxDartRefs '
      'maxEngineHeapMB=${maxEngineHeapBytes ~/ (1024 * 1024)})';
}

/// Outcome of a completed (or aborted) soak run.
class SoakStressResult {
  SoakStressResult({
    required this.config,
    required this.wallElapsed,
    required this.totalOps,
    required this.errors,
    required this.dumpPath,
    required this.baselineRss,
    required this.peakRss,
    required this.rssAfterCooldown,
    required this.aborted,
  });

  final SoakStressConfig config;
  final Duration wallElapsed;
  final int totalOps;
  final int errors;
  final String? dumpPath;
  final int baselineRss;
  final int peakRss;

  /// RSS after the cooldown phase, or null when no cooldown ran. Compare with
  /// [baselineRss]: what does not come back is retained.
  final int? rssAfterCooldown;
  final bool aborted;

  bool get ok => !aborted && errors == 0;

  @override
  String toString() =>
      'SoakStressResult(ok=$ok elapsed=$wallElapsed ops=$totalOps errors=$errors '
      'rss baseline=$baselineRss peak=$peakRss '
      'afterCooldown=$rssAfterCooldown dump=$dumpPath)';
}

/// Ring buffer of recent op lines for crash dumps.
class _OpLog {
  _OpLog(this.capacity);
  final int capacity;
  final List<String> _lines = <String>[];

  void add(String line) {
    _lines.add('${DateTime.now().toIso8601String()} $line');
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
  }

  String dump() => _lines.join('\n');
}

/// Mixed op kinds — each worker picks randomly (weighted).
enum _OpKind {
  evaluateTiny,
  invokeCached,
  stringRoundTrip,
  mapRoundTrip,
  dartUint8ToJs,
  jsUint8ToDart,
  evaluateJsonArray,
  evaluateFullArray,
  promiseMicrotask,
  createDisposeEngine,
  runGcSample,
  // Web APIs (L0)
  webTimers,
  webStructuredClone,
  webConsole,
  webRandom,
  // Web APIs (L1)
  webUrl,
  webEncoding,
  webBlobFormData,
  webStreams,
  webCrypto,
  // Web APIs (L2)
  fetchGet,
  fetchJson,
  fetchStream,
  fetchUpload,
  fetchRedirect,
  fetchAbort,
  fetchAbandoned,
  createDisposeWebEngine,
}

/// Run long-haul stress. Rethrows first failure when
/// [SoakStressConfig.failOnFirstError] is true (after writing dump).
Future<SoakStressResult> runSoakStress({
  SoakStressConfig? config,
  void Function(String line)? log,
}) async {
  final cfg = config ?? SoakStressConfig.fromEnvironment();
  void emit(String line) {
    log?.call(line);
    FlutterQjsLogger.info(line);
  }

  final started = DateTime.now();
  emit('soak start: $cfg');
  emit(
    'soak env: os=${Platform.operatingSystem} '
    'processors=${Platform.numberOfProcessors} '
    'pid=$pid executable=${Platform.resolvedExecutable}',
  );
  emit('core dump hint: ${cfg.coreDumpHint}');

  final rng = Random(cfg.seed);
  final opLog = _OpLog(cfg.maxLogLines);
  final pool = JsEnginePool(
    maxSize: cfg.poolSize,
    config: JsEnginePoolConfig(
      timeout: cfg.timeoutMs,
      memoryLimit: cfg.memoryLimitBytes,
      resetOnRelease: cfg.resetOnRelease,
      webApis: cfg.webApis,
    ),
  );

  // Web API workloads need the level they exercise; fail before burning an hour.
  if (cfg.workloadProfile.startsWith('web_') && !cfg.webEnabled) {
    throw ArgumentError.value(
      cfg.webApiLevel,
      'SOAK_WEB',
      'profile ${cfg.workloadProfile} needs SOAK_WEB=standard or fetch',
    );
  }
  if (cfg.workloadProfile.startsWith(SoakStressConfig._singleOpPrefix)) {
    // Validates the name and, with it, the level implied above.
    SoakStressConfig._singleOp(cfg.workloadProfile);
  }
  if (SoakStressConfig._fetchProfiles.contains(cfg.workloadProfile) &&
      !cfg.fetchEnabled) {
    throw ArgumentError.value(
      cfg.webApiLevel,
      'SOAK_WEB',
      'profile ${cfg.workloadProfile} needs SOAK_WEB=fetch',
    );
  }
  final server = cfg.fetchEnabled && !cfg.fetchStub
      ? await _startSoakServer()
      : null;
  final env = _WebEnv(config: cfg, server: server);
  if (server != null) emit('soak http server: ${env.baseUrl}');
  // console.* ops would otherwise flood the log; warnings and errors stay on.
  final previousLogLevel = FlutterQjsLogger.level;
  FlutterQjsLogger.level = FlutterQjsLogLevel.warning;

  var totalOps = 0;
  var errors = 0;
  var peakRss = _rss();
  final baselineRss = peakRss;
  final baselineFds = _openFds();
  String? dumpPath;
  var aborted = false;
  final opCounts = <String, int>{
    for (final k in _OpKind.values) k.name: 0,
  };
  final metricsFile = File('${cfg.dumpDir}/soak_metrics.jsonl');
  metricsFile.parent.createSync(recursive: true);
  final metricsSink = metricsFile.openWrite(mode: FileMode.append);
  emit('soak diagnostics: ${metricsFile.path} (JSONL)');
  Object? firstError;
  StackTrace? firstStack;

  final stopAt = started.add(cfg.duration);
  var metricsInFlight = false;
  Future<void> emitMetrics() async {
    if (metricsInFlight) return;
    metricsInFlight = true;
    final rss = _rss();
    if (rss > peakRss) peakRss = rss;
    try {
      Map<String, dynamic> sampleEngine(JavascriptRuntime js) {
        js.runGC();
        final qjs = js.getMemoryUsage();
        return <String, dynamic>{
          'id': js.getEngineInstanceId(),
          'qjs': qjs == null ? null : _memoryUsageJson(qjs),
          'pendingJobs': js is QuickJsRuntime2 && js.hasPendingJobs,
          'dartRefs': js is QuickJsRuntime2 ? js.debugReferenceCount : null,
        };
      }

      final engines = <Map<String, dynamic>>[];
      for (final js in pool.idleEngines) {
        engines.add(sampleEngine(js));
      }
      if (engines.isEmpty) {
        // Pool saturated: borrow one engine so handle / heap growth is still
        // observed under sustained load, not only when workers drain.
        try {
          await pool.withEngine(
            (js) async => engines.add(sampleEngine(js)),
            acquireTimeout: const Duration(seconds: 2),
          );
        } catch (e) {
          opLog.add('metrics engine sample skipped: $e');
        }
      }
      final fds = _openFds();
      final sample = <String, dynamic>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'fds': fds,
        'web': env.toJson(),
        'elapsedSec': DateTime.now().difference(started).inMilliseconds / 1000,
        'opsTotal': totalOps,
        'errors': errors,
        'rss': rss,
        'rssDelta': rss - baselineRss,
        'peakRss': peakRss,
        'baselineRss': baselineRss,
        'procMemory': _procMemory(),
        // Splits process RSS into the C heap and everything else (the Dart
        // heap). A flat arena with climbing RSS means the growth is Dart-side,
        // not QuickJS and not allocator fragmentation.
        'nativeHeap': readNativeHeapUsage().toJson(),
        'pool': <String, dynamic>{
          'size': pool.size,
          'idle': pool.idleCount,
          'inUse': pool.inUseCount,
          'resetCount': pool.resetCount,
          'disposeCount': pool.disposeCount,
        },
        'engines': engines,
        'bridge': readBridgeStats(),
        'opCounts': Map<String, int>.from(opCounts),
        'profile': cfg.workloadProfile,
        'resetOnRelease': cfg.resetOnRelease,
      };
      metricsSink.writeln(jsonEncode(sample));
      await metricsSink.flush();
      emit(
        'metrics: ops=$totalOps errors=$errors pool size=${pool.size} '
        'idle=${pool.idleCount} inUse=${pool.inUseCount} rss=$rss '
        'peakRss=$peakRss baselineRss=$baselineRss fds=$fds '
        'web=${env.toJson()} nativeHeap=${readNativeHeapUsage()} '
        'engines=${engines.length} bridge=${readBridgeStats()}',
      );
      // Resource ceilings: each one maps to a hypothesis in
      // doc/design/2026-09-16-web-apis-soak.md.
      if (cfg.maxFdGrowth > 0 &&
          baselineFds > 0 &&
          fds > baselineFds + cfg.maxFdGrowth) {
        firstError ??= StateError(
          'open file descriptors grew: fds=$fds baseline=$baselineFds '
          'limit=+${cfg.maxFdGrowth} (leaked fetch sockets?)',
        );
        aborted = true;
      }
      for (final engine in engines) {
        final refs = engine['dartRefs'] as int?;
        if (cfg.maxDartRefs > 0 && refs != null && refs > cfg.maxDartRefs) {
          firstError ??= StateError(
            'idle engine holds $refs Dart JS handles (limit ${cfg.maxDartRefs}): '
            '${engine['id']}',
          );
          aborted = true;
        }
        final qjs = engine['qjs'] as Map<String, int>?;
        final used = qjs == null ? null : qjs['memoryUsedSize'];
        if (cfg.maxEngineHeapBytes > 0 &&
            used != null &&
            used > cfg.maxEngineHeapBytes) {
          firstError ??= StateError(
            'idle engine JS heap after GC is $used bytes '
            '(limit ${cfg.maxEngineHeapBytes}): ${engine['id']}',
          );
          aborted = true;
        }
      }
      if (cfg.maxRssGrowthFactor > 0 &&
          baselineRss > 0 &&
          rss > baselineRss * cfg.maxRssGrowthFactor) {
        firstError ??= StateError(
          'RSS growth exceeded: rss=$rss baseline=$baselineRss '
          'factor=${cfg.maxRssGrowthFactor}',
        );
        aborted = true;
      }
    } finally {
      metricsInFlight = false;
    }
  }

  final metricsTimer = Timer.periodic(
    cfg.metricsInterval,
    (_) => unawaited(emitMetrics()),
  );

  Future<void> fail(Object e, StackTrace st, String where) async {
    errors++;
    firstError ??= e;
    firstStack ??= st;
    opLog.add('FAIL at $where: $e');
    emit('soak error at $where: $e');
    dumpPath = await _writeDump(
      cfg: cfg,
      pool: pool,
      opLog: opLog,
      totalOps: totalOps,
      errors: errors,
      baselineRss: baselineRss,
      peakRss: peakRss,
      error: e,
      stack: st,
      where: where,
    );
    emit('soak dump written: $dumpPath');
    if (cfg.failOnFirstError) {
      aborted = true;
    }
  }

  Future<void> worker(int id) async {
    while (!aborted && DateTime.now().isBefore(stopAt)) {
      try {
        await pool.withEngine((js) async {
          for (var i = 0; i < cfg.opsPerBurst; i++) {
            if (aborted) return;
            final kind = _pickOp(rng, cfg.workloadProfile);
            final tag = 'w$id/${kind.name}';
            opLog.add(tag);
            await _runOp(js, kind, rng, tag, env);
            totalOps++;
            opCounts[kind.name] = (opCounts[kind.name] ?? 0) + 1;
          }
        }, acquireTimeout: const Duration(seconds: 30));
      } catch (e, st) {
        await fail(e, st, 'worker-$id');
        if (cfg.failOnFirstError) return;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  int? rssAfterCooldown;
  try {
    await Future.wait(List.generate(cfg.workers, worker));

    if (!aborted && cfg.cooldown > Duration.zero) {
      emit('soak cooldown: ${cfg.cooldown}');
      final cooldownEnd = DateTime.now().add(cfg.cooldown);
      while (DateTime.now().isBefore(cooldownEnd)) {
        // Allocation churn gives the Dart GC a reason to run; the delay lets
        // timers and sockets finish unwinding.
        final junk = <Uint8List>[];
        for (var i = 0; i < 16; i++) {
          junk.add(Uint8List(256 * 1024));
        }
        junk.clear();
        for (final js in pool.idleEngines) {
          js.runGC();
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      rssAfterCooldown = _rss();
      final retained = rssAfterCooldown - baselineRss;
      emit(
        'soak cooldown done: rss=$rssAfterCooldown baseline=$baselineRss '
        'peak=$peakRss retained=$retained '
        'retainedPerOp=${totalOps == 0 ? 0 : retained ~/ totalOps}B '
        'retainedPerReset=${pool.resetCount == 0 ? 0 : retained ~/ pool.resetCount}B '
        'fds=${_openFds()}',
      );
    }

    if (aborted && firstError != null && dumpPath == null) {
      dumpPath = await _writeDump(
        cfg: cfg,
        pool: pool,
        opLog: opLog,
        totalOps: totalOps,
        errors: errors,
        baselineRss: baselineRss,
        peakRss: peakRss,
        error: firstError!,
        stack: firstStack ?? StackTrace.current,
        where: 'abort',
      );
    }
  } finally {
    metricsTimer.cancel();
    // Wait for any in-flight metrics write before closing the sink
    // (avoids "StreamSink is bound to a stream" on concurrent flush/close).
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (metricsInFlight && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      await emitMetrics();
    } catch (e) {
      emit('final metrics emit failed: $e');
    }
    while (metricsInFlight && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      await metricsSink.flush();
      await metricsSink.close();
    } catch (e) {
      emit('metricsSink close: $e');
    }
    try {
      pool.dispose();
    } catch (e, st) {
      emit('pool.dispose error: $e\n$st');
    }
    FlutterQjsLogger.level = previousLogLevel;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (e) {
        emit('soak http server close: $e');
      }
    }
  }

  final result = SoakStressResult(
    config: cfg,
    wallElapsed: DateTime.now().difference(started),
    totalOps: totalOps,
    errors: errors,
    dumpPath: dumpPath,
    baselineRss: baselineRss,
    peakRss: peakRss,
    rssAfterCooldown: rssAfterCooldown,
    aborted: aborted,
  );
  emit('soak done: $result');
  emit(
    'soak web: level=${cfg.webApiLevel} fetchOps=${env.fetchOps} '
    'fetchBytes=${env.fetchBytes} fds=${_openFds()} baselineFds=$baselineFds',
  );
  if (aborted && firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack ?? StackTrace.current);
  }
  return result;
}

Map<String, int> _memoryUsageJson(JsMemoryUsage value) => <String, int>{
      'mallocSize': value.mallocSize,
      'mallocLimit': value.mallocLimit,
      'memoryUsedSize': value.memoryUsedSize,
      'mallocCount': value.mallocCount,
      'memoryUsedCount': value.memoryUsedCount,
      'atomCount': value.atomCount,
      'atomSize': value.atomSize,
      'strCount': value.strCount,
      'strSize': value.strSize,
      'objCount': value.objCount,
      'objSize': value.objSize,
      'propCount': value.propCount,
      'propSize': value.propSize,
    };

Map<String, int> _procMemory() {
  if (!Platform.isLinux) return <String, int>{};
  try {
    final values = <String, int>{};
    for (final line in File('/proc/$pid/smaps_rollup').readAsLinesSync()) {
      final match = RegExp(r'^(Rss|Pss|Private_Dirty|Anonymous):\s+(\d+) kB$')
          .firstMatch(line);
      if (match != null) {
        values[match.group(1)!] = int.parse(match.group(2)!) * 1024;
      }
    }
    return values;
  } catch (_) {
    return <String, int>{};
  }
}

int _rss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}

_OpKind _pickOp(Random rng, String profile) {
  if (profile.startsWith(SoakStressConfig._singleOpPrefix)) {
    return SoakStressConfig._singleOp(profile);
  }
  switch (profile) {
    case 'tiny':
      return _OpKind.evaluateTiny;
    case 'dart_to_js':
      return _OpKind.dartUint8ToJs;
    case 'js_to_dart':
      return _OpKind.jsUint8ToDart;
    case 'typed_array':
      return rng.nextBool() ? _OpKind.dartUint8ToJs : _OpKind.jsUint8ToDart;
    case 'no_typed_array':
      const nonTyped = <_OpKind>[
        _OpKind.evaluateTiny,
        _OpKind.invokeCached,
        _OpKind.stringRoundTrip,
        _OpKind.mapRoundTrip,
        _OpKind.evaluateJsonArray,
        _OpKind.evaluateFullArray,
        _OpKind.promiseMicrotask,
        _OpKind.createDisposeEngine,
        _OpKind.runGcSample,
      ];
      return nonTyped[rng.nextInt(nonTyped.length)];
    case 'all':
      break;
    case 'web_core':
      return _webCoreOps[rng.nextInt(_webCoreOps.length)];
    case 'web_url':
      return _OpKind.webUrl;
    case 'web_encoding':
      return _OpKind.webEncoding;
    case 'web_blob':
      return _OpKind.webBlobFormData;
    case 'web_streams':
      return _OpKind.webStreams;
    case 'web_crypto':
      return _OpKind.webCrypto;
    case 'web_fetch':
      return _fetchOps[rng.nextInt(_fetchOps.length)];
    case 'web_all':
      return _pickWebOp(rng);
    case 'mixed_all':
      return rng.nextBool() ? _pickOp(rng, 'all') : _pickWebOp(rng);
    default:
      throw ArgumentError.value(
        profile,
        'SOAK_PROFILE',
        'expected all, tiny, no_typed_array, dart_to_js, js_to_dart, '
            'typed_array, web_core, web_url, web_encoding, web_blob, '
            'web_streams, web_crypto, web_fetch, web_all, mixed_all, '
            'or op:<opName>',
      );
  }
  final r = rng.nextInt(100);
  if (r < 20) return _OpKind.evaluateTiny;
  if (r < 35) return _OpKind.invokeCached;
  if (r < 45) return _OpKind.stringRoundTrip;
  if (r < 52) return _OpKind.mapRoundTrip;
  if (r < 65) return _OpKind.dartUint8ToJs;
  if (r < 75) return _OpKind.jsUint8ToDart;
  if (r < 82) return _OpKind.evaluateJsonArray;
  if (r < 88) return _OpKind.evaluateFullArray;
  if (r < 93) return _OpKind.promiseMicrotask;
  if (r < 97) return _OpKind.createDisposeEngine;
  return _OpKind.runGcSample;
}

const _webCoreOps = <_OpKind>[
  _OpKind.webTimers,
  _OpKind.webStructuredClone,
  _OpKind.webConsole,
  _OpKind.webRandom,
];

const _fetchOps = <_OpKind>[
  _OpKind.fetchGet,
  _OpKind.fetchJson,
  _OpKind.fetchStream,
  _OpKind.fetchUpload,
  _OpKind.fetchRedirect,
  _OpKind.fetchAbort,
  _OpKind.fetchAbandoned,
];

_OpKind _pickWebOp(Random rng) {
  final r = rng.nextInt(100);
  if (r < 15) return _webCoreOps[rng.nextInt(_webCoreOps.length)];
  if (r < 30) return _OpKind.webUrl;
  if (r < 45) return _OpKind.webEncoding;
  if (r < 55) return _OpKind.webBlobFormData;
  if (r < 65) return _OpKind.webStreams;
  if (r < 73) return _OpKind.webCrypto;
  if (r < 96) return _fetchOps[rng.nextInt(_fetchOps.length)];
  return _OpKind.createDisposeWebEngine;
}

Future<void> _runOp(
  JavascriptRuntime js,
  _OpKind kind,
  Random rng,
  String tag,
  _WebEnv env,
) async {
  switch (kind) {
    case _OpKind.evaluateTiny:
      final r = js.evaluate('1+1');
      if (r.isError || r.rawResult != 2) {
        throw StateError('$tag evaluateTiny failed: ${r.stringResult}');
      }
    case _OpKind.invokeCached:
      final fn = js.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
      try {
        final out = fn.invoke([3, 4]);
        if (out != 7) throw StateError('$tag invoke expected 7 got $out');
      } finally {
        fn.free();
      }
    case _OpKind.stringRoundTrip:
      final fn = js.evaluate('(x)=>x').rawResult as JSInvokable;
      try {
        const s = 'soak-string-payload-0123456789';
        final out = fn.invoke([s]);
        if (out != s) throw StateError('$tag string round-trip mismatch');
      } finally {
        fn.free();
      }
    case _OpKind.mapRoundTrip:
      final fn = js.evaluate('(x)=>x').rawResult as JSInvokable;
      try {
        final m = <String, dynamic>{'a': 1, 'b': 'two', 'c': true};
        final out = fn.invoke([m]);
        if (out is! Map) throw StateError('$tag map not Map: $out');
      } finally {
        fn.free();
      }
    case _OpKind.dartUint8ToJs:
      final size = const [1024, 64 * 1024, 256 * 1024][rng.nextInt(3)];
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i += 64) {
        bytes[i] = i & 0xff;
      }
      final fn = js.evaluate('(v)=>v.length').rawResult as JSInvokable;
      try {
        final len = fn.invoke([bytes]);
        if (len != size) {
          throw StateError('$tag dartUint8 len $len != $size');
        }
      } finally {
        fn.free();
      }
    case _OpKind.jsUint8ToDart:
      final size = const [1024, 64 * 1024][rng.nextInt(2)];
      final r = js.evaluate('new Uint8Array($size)');
      if (r.isError) throw StateError('$tag jsUint8: ${r.stringResult}');
      final v = r.rawResult;
      if (v is! Uint8List || v.length != size) {
        throw StateError('$tag jsUint8 type/len: $v');
      }
    case _OpKind.evaluateJsonArray:
      final n = 50 + rng.nextInt(200);
      final v = js.evaluateJson('Array.from({length:$n},(_,i)=>i)');
      if (v is! List || v.length != n) {
        throw StateError('$tag evaluateJsonArray: $v');
      }
    case _OpKind.evaluateFullArray:
      final n = 20 + rng.nextInt(80);
      final r = js.evaluate('Array.from({length:$n},(_,i)=>i)');
      if (r.isError) throw StateError('$tag evaluateFull: ${r.stringResult}');
      final v = r.rawResult;
      if (v is! List || v.length != n) {
        throw StateError('$tag evaluateFull type/len: $v');
      }
    case _OpKind.promiseMicrotask:
      if (js is QuickJsRuntime2) {
        final prev = js.autoExecutePendingJobs;
        js.autoExecutePendingJobs = false;
        try {
          js.evaluate(
            'globalThis.__soak_p = 0; '
            'Promise.resolve().then(()=>{globalThis.__soak_p=1})',
          );
          js.executePendingJobs();
          final r = js.evaluate('globalThis.__soak_p');
          if (r.rawResult != 1) {
            throw StateError('$tag promise not drained: ${r.rawResult}');
          }
        } finally {
          js.autoExecutePendingJobs = prev;
        }
      } else {
        js.evaluate('Promise.resolve().then(()=>{})');
        js.executePendingJobs();
      }
    case _OpKind.createDisposeEngine:
      final eng = getJavascriptRuntime(
        timeout: 2000,
        memoryLimit: kDefaultJsMemoryLimit,
      );
      try {
        final r = eng.evaluate('2*21');
        if (r.rawResult != 42) {
          throw StateError('$tag createDispose: ${r.stringResult}');
        }
      } finally {
        eng.dispose();
      }
    case _OpKind.runGcSample:
      js.runGC();
      final m = js.getMemoryUsage();
      if (m != null && m.memoryUsedSize < 0) {
        throw StateError('$tag memoryUsage negative');
      }
    case _OpKind.webTimers:
    case _OpKind.webStructuredClone:
    case _OpKind.webConsole:
    case _OpKind.webRandom:
    case _OpKind.webUrl:
    case _OpKind.webEncoding:
    case _OpKind.webBlobFormData:
    case _OpKind.webStreams:
    case _OpKind.webCrypto:
    case _OpKind.fetchGet:
    case _OpKind.fetchJson:
    case _OpKind.fetchStream:
    case _OpKind.fetchUpload:
    case _OpKind.fetchRedirect:
    case _OpKind.fetchAbort:
    case _OpKind.fetchAbandoned:
    case _OpKind.createDisposeWebEngine:
      await _runWebOp(js, kind, rng, tag, env);
  }
}

// =============================================================================
// Web API workloads (doc/design/2026-09-16-web-apis-soak.md)
// =============================================================================

/// Fixed payload sizes the in-process server serves, so ops can assert exactly.
const int _soakSmallBodyLength = 512;
const int _soakChunkedChunks = 8;
const int _soakChunkSize = 4096;

/// Local server + counters shared by the Web API workloads.
class _WebEnv {
  _WebEnv({required this.config, required this.server});

  final SoakStressConfig config;
  final HttpServer? server;
  int fetchOps = 0;
  int fetchBytes = 0;

  bool get hasWeb => config.webEnabled;
  bool get hasFetch => config.fetchEnabled && (server != null || config.fetchStub);

  String get baseUrl {
    final running = server;
    if (running != null) return 'http://${running.address.address}:${running.port}';
    if (config.fetchStub) return 'http://stub.invalid';
    throw StateError('soak HTTP server is not running');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'level': config.webApiLevel,
        'stub': config.fetchStub,
        'fetchOps': fetchOps,
        'fetchBytes': fetchBytes,
      };
}

/// Deterministic in-process endpoints: the experiment never leaves loopback.
/// Control variant: same JS-side fetch work, no sockets and no [HttpClient].
///
/// Enabled with `--dart-define=SOAK_FETCH_STUB=1`. Comparing a stubbed run
/// against the real one attributes host-side growth to either the network stack
/// or this package's own request bookkeeping.
Future<JsFetchResponse> _stubFetch(JsFetchRequest request) async {
  final segments = request.url.pathSegments;
  final first = segments.isEmpty ? '' : segments.first;
  switch (first) {
    case 'json':
      return JsFetchResponse(
        status: 200,
        headers: const [MapEntry('content-type', 'application/json')],
        body: Stream.value(
          utf8.encode(jsonEncode({'ok': true, 'n': _soakSmallBodyLength})),
        ),
      );
    case 'chunked':
      return JsFetchResponse(
        status: 200,
        headers: const [MapEntry('content-type', 'application/octet-stream')],
        body: Stream.fromIterable([
          for (var i = 0; i < _soakChunkedChunks; i++)
            Uint8List(_soakChunkSize)..fillRange(0, _soakChunkSize, i),
        ]),
      );
    case 'slow':
      return JsFetchResponse(
        status: 200,
        headers: const [MapEntry('content-type', 'text/plain')],
        body: Stream.periodic(
          const Duration(milliseconds: 25),
          (_) => utf8.encode('tick;'),
        ).take(20),
      );
    case 'echo':
      final body = request.body;
      return JsFetchResponse(
        status: 200,
        headers: const [MapEntry('content-type', 'application/json')],
        body: Stream.value(
          utf8.encode(
            jsonEncode({
              'method': request.method,
              'length': body == null ? 0 : body.length,
              'contentType': _requestHeader(request, 'content-type'),
            }),
          ),
        ),
      );
    case 'redirect':
      final hops = segments.length > 1 ? int.tryParse(segments[1]) ?? 1 : 1;
      return JsFetchResponse(
        status: 302,
        headers: [
          MapEntry('location', hops <= 1 ? '/small' : '/redirect/${hops - 1}'),
        ],
        body: const Stream.empty(),
      );
    case 'small':
      return JsFetchResponse(
        status: 200,
        headers: const [MapEntry('content-type', 'text/plain')],
        body: Stream.value(utf8.encode('x' * _soakSmallBodyLength)),
      );
    default:
      return JsFetchResponse(
        status: 404,
        headers: const [MapEntry('content-type', 'text/plain')],
        body: Stream.value(utf8.encode('nope')),
      );
  }
}

String? _requestHeader(JsFetchRequest request, String name) {
  for (final header in request.headers) {
    if (header.key.toLowerCase() == name) return header.value;
  }
  return null;
}

Future<HttpServer> _startSoakServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final small = 'x' * _soakSmallBodyLength;
  server.listen((request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      switch (segments.isEmpty ? '' : segments.first) {
        case 'small':
          response.headers.contentType = ContentType.text;
          response.write(small);
        case 'json':
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'ok': true, 'n': _soakSmallBodyLength}));
        case 'chunked':
          for (var i = 0; i < _soakChunkedChunks; i++) {
            response.add(
              Uint8List(_soakChunkSize)..fillRange(0, _soakChunkSize, i),
            );
            await response.flush();
          }
        case 'slow':
          // fetchAbort / fetchAbandoned cut this response off on purpose.
          // Writing to a peer that went away neither fails nor completes, so
          // without watching `done` (and bounding `flush`) every aborted
          // request leaves a handler parked here for the rest of the run —
          // which is what made web_fetch look like an engine leak.
          var connected = true;
          unawaited(
            response.done.then(
              (_) => connected = false,
              onError: (Object _) => connected = false,
            ),
          );
          for (var i = 0; i < 20 && connected; i++) {
            response.write('tick;');
            final flushed = await response
                .flush()
                .timeout(const Duration(milliseconds: 500))
                .then((_) => true, onError: (Object _) => false);
            if (!flushed) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        case 'echo':
          final body = await request.fold<List<int>>(
            <int>[],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'method': request.method,
              'length': body.length,
              'contentType': request.headers.value('content-type'),
            }),
          );
        case 'redirect':
          final hops = segments.length > 1
              ? int.tryParse(segments[1]) ?? 1
              : 1;
          response.statusCode = 302;
          response.headers.set(
            'location',
            hops <= 1 ? '/small' : '/redirect/${hops - 1}',
          );
        default:
          response.statusCode = 404;
          response.write('nope');
      }
    } catch (_) {
      // Client aborted mid-response; the JS side asserts its own outcome.
    } finally {
      try {
        await response.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  });
  return server;
}

/// Evaluate a synchronous JS body and return its value.
dynamic _evalSync(JavascriptRuntime js, String body, String tag) {
  final result = js.evaluate('(() => { $body })()');
  if (result.isError) throw StateError('$tag: ${result.stringResult}');
  return result.rawResult;
}

/// Evaluate an async JS body, pumping the job queue until it settles.
Future<dynamic> _evalAsync(
  JavascriptRuntime js,
  String body,
  String tag, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final started = js.evaluate('(async () => { $body })()');
  if (started.isError) throw StateError('$tag: ${started.stringResult}');
  final settled = await js.handlePromise(started, timeout: timeout);
  if (settled.isError) throw StateError('$tag: ${settled.stringResult}');
  return settled.rawResult;
}

Future<void> _runWebOp(
  JavascriptRuntime js,
  _OpKind kind,
  Random rng,
  String tag,
  _WebEnv env,
) async {
  final seed = rng.nextInt(1 << 30);
  switch (kind) {
    case _OpKind.webTimers:
      await _evalAsync(js, r'''
        const seen = [];
        await new Promise((resolve, reject) => {
          const guard = setTimeout(
            () => reject(new Error('timers stalled: ' + seen.join(','))), 10000);
          const cancelled = setTimeout(() => seen.push('cancelled'), 1);
          clearTimeout(cancelled);
          setTimeout((a, b) => seen.push(a + b), 1, 'ti', 'mer');
          let ticks = 0;
          const interval = setInterval(() => {
            if (++ticks < 2) return;
            clearInterval(interval);
            // The host runs a microtask checkpoint after each timer callback.
            Promise.resolve().then(() => {
              seen.push('micro');
              clearTimeout(guard);
              resolve();
            });
          }, 1);
        });
        if (seen.includes('cancelled')) throw new Error('cleared timer fired');
        if (!seen.includes('timer')) throw new Error('timer args lost: ' + seen.join(','));
        if (!seen.includes('micro')) throw new Error('microtask checkpoint missing');
        return seen.length;
      ''', tag);

    case _OpKind.webStructuredClone:
      _evalSync(js, r'''
        const bytes = new Uint8Array(256);
        for (let i = 0; i < bytes.length; i++) bytes[i] = i & 0xff;
        const src = {
          n: 1, s: 'soak', d: new Date(1700000000000), re: /a+/g, big: 123n,
          map: new Map([['k', { deep: [1, 2, 3] }]]), set: new Set([1, 2]),
          bytes, view: new DataView(bytes.buffer), err: new RangeError('r'),
        };
        src.self = src;
        const copy = structuredClone(src);
        if (copy.self !== copy) throw new Error('cycle lost');
        if (copy.map.get('k').deep[2] !== 3) throw new Error('map lost');
        if (copy.bytes.buffer === src.bytes.buffer) throw new Error('buffer shared');
        if (copy.view.buffer !== copy.bytes.buffer) throw new Error('view split from buffer');
        if (copy.d.getTime() !== 1700000000000 || copy.re.source !== 'a+' || copy.big !== 123n) {
          throw new Error('builtin lost');
        }
        if (!(copy.err instanceof RangeError)) throw new Error('error lost');
        return copy.set.size;
      ''', tag);

    case _OpKind.webConsole:
      _evalSync(js, '''
        const cyclic = { name: 'soak-$seed' };
        cyclic.self = cyclic;
        console.log('soak %s %d %o', 'x', $seed, { a: [1, 2, { b: 3n }] });
        console.debug(cyclic, new Map([['k', new Uint8Array(4)]]), new RangeError('inspect'));
        console.count('soak');
        console.time('soak-timer');
        console.timeEnd('soak-timer');
        return 1;
      ''', tag);

    case _OpKind.webRandom:
      _evalSync(js, '''
        const buf = new Uint8Array(32 + ($seed % 97));
        crypto.getRandomValues(buf);
        if (buf.every((b) => b === 0)) throw new Error('random buffer all zero');
        const id = crypto.randomUUID();
        if (id.length !== 36 || id[14] !== '4') throw new Error('bad uuid ' + id);
        return buf.length;
      ''', tag);

    case _OpKind.webUrl:
      _evalSync(js, '''
        const bases = ['http://a.example/p/q?x=1#f',
          'https://user:pw@b.example:8443/a/b/c', 'file:///tmp/x/y'];
        const base = bases[$seed % bases.length];
        const url = new URL('../rel/../z?q=' + $seed + '#frag', base);
        url.searchParams.append('k', 'v ' + $seed);
        url.searchParams.sort();
        url.hash = 'h$seed';
        const reparsed = new URL(url.href);
        if (reparsed.href !== url.href) {
          throw new Error('reparse mismatch ' + reparsed.href + ' vs ' + url.href);
        }
        if (reparsed.searchParams.get('k') !== 'v ' + $seed) throw new Error('param lost');
        if (reparsed.hash !== '#h$seed') throw new Error('hash lost ' + reparsed.hash);
        return url.href.length;
      ''', tag);

    case _OpKind.webEncoding:
      _evalSync(js, '''
        let state = $seed >>> 0;
        const rand = () => (state = (state * 1103515245 + 12345) >>> 0) / 4294967296;
        let text = '';
        for (let i = 0; i < 96; i++) {
          const r = rand();
          text += r < 0.5 ? String.fromCharCode(32 + Math.floor(rand() * 95))
            : r < 0.8 ? String.fromCharCode(0x80 + Math.floor(rand() * 0x2000))
              : String.fromCodePoint(0x10000 + Math.floor(rand() * 0xffff));
        }
        const encoder = new TextEncoder();
        const bytes = encoder.encode(text);
        if (new TextDecoder().decode(bytes) !== text) throw new Error('utf8 round trip mismatch');

        // Random (mostly invalid) bytes must decode to replacements, never throw.
        const noise = new Uint8Array(160);
        for (let i = 0; i < noise.length; i++) noise[i] = Math.floor(rand() * 256);
        const decodedNoise = new TextDecoder().decode(noise);
        if (typeof decodedNoise !== 'string') throw new Error('noise decode type');
        let fatalThrew = false;
        try {
          new TextDecoder('utf-8', { fatal: true }).decode(noise);
        } catch (error) {
          fatalThrew = true;
        }

        // Streaming decode split at random boundaries must equal the whole.
        const decoder = new TextDecoder();
        let streamed = '';
        let offset = 0;
        while (offset < bytes.length) {
          const size = 1 + Math.floor(rand() * 7);
          streamed += decoder.decode(
            bytes.subarray(offset, Math.min(offset + size, bytes.length)), { stream: true });
          offset += size;
        }
        streamed += decoder.decode();
        if (streamed !== text) throw new Error('streaming decode mismatch');

        // Lone surrogates become U+FFFD.
        const lone = encoder.encode('a\\ud800b');
        if (lone.length !== 5 || lone[1] !== 0xef || lone[2] !== 0xbf || lone[3] !== 0xbd) {
          throw new Error('lone surrogate not replaced: ' + lone.join(','));
        }
        const into = new Uint8Array(4);
        if (encoder.encodeInto(text, into).written > 4) throw new Error('encodeInto overflow');
        return [bytes.length, decodedNoise.length, fatalThrew];
      ''', tag);

    case _OpKind.webBlobFormData:
      await _evalAsync(js, '''
        const size = 1024 + ($seed % 4096);
        const bytes = new Uint8Array(size);
        for (let i = 0; i < size; i += 7) bytes[i] = i & 0xff;
        const blob = new Blob(['head-', bytes, new Blob(['-tail'])],
          { type: 'application/octet-stream' });
        if (blob.size !== size + 10) throw new Error('blob size ' + blob.size);
        const sliced = await blob.slice(5, 5 + size).arrayBuffer();
        if (sliced.byteLength !== size) throw new Error('slice length ' + sliced.byteLength);
        if (new Uint8Array(sliced)[7] !== 7) throw new Error('slice content');

        const form = new FormData();
        form.append('text', 'value-$seed');
        form.append('file', new File([bytes], 'f.bin', { type: 'application/octet-stream' }));
        const round = await new Response(form).formData();
        if (round.get('text') !== 'value-$seed') throw new Error('form text lost');
        const file = round.get('file');
        if (file.name !== 'f.bin' || file.size !== size) {
          throw new Error('form file ' + file.name + ' ' + file.size);
        }
        return blob.size;
      ''', tag);

    case _OpKind.webStreams:
      await _evalAsync(js, '''
        const total = 8 + ($seed % 8);
        let produced = 0;
        const source = new ReadableStream({
          pull(controller) {
            if (produced >= total) { controller.close(); return; }
            controller.enqueue('chunk-' + (produced++) + ';');
          },
        }, { highWaterMark: 2 });
        const upper = new TransformStream({
          transform(chunk, controller) { controller.enqueue(chunk.toUpperCase()); },
        });
        const [left, right] = source.pipeThrough(upper).tee();
        const drain = async (stream) => {
          let out = '';
          for await (const value of stream) out += value;
          return out;
        };
        const [a, b] = await Promise.all([drain(left), drain(right)]);
        if (a !== b) throw new Error('tee branches differ');
        if (a.split(';').length - 1 !== total) throw new Error('chunk count ' + a);

        let decoded = '';
        for await (const part of new Blob([a]).stream().pipeThrough(new TextDecoderStream())) {
          decoded += part;
        }
        if (decoded !== a) throw new Error('encoding stream mismatch');

        // Abandon a stream after one read: controller and queue must be dropped.
        const endless = new ReadableStream({
          pull(controller) { controller.enqueue(new Uint8Array(4096)); },
        });
        const reader = endless.getReader();
        await reader.read();
        await reader.cancel('soak');
        return total;
      ''', tag);

    case _OpKind.webCrypto:
      await _evalAsync(js, '''
        const size = 64 + ($seed % 4096);
        const data = new Uint8Array(size);
        for (let i = 0; i < size; i++) data[i] = (i * 31 + $seed) & 0xff;
        const hex = (buffer) =>
          [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, '0')).join('');
        const first = hex(await crypto.subtle.digest('SHA-256', data));
        const second = hex(await crypto.subtle.digest('SHA-256', data));
        if (first !== second) throw new Error('digest not deterministic');
        const known = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc')));
        if (known !== 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') {
          throw new Error('SHA-256 vector mismatch: ' + known);
        }
        const key = await crypto.subtle.importKey('raw', data.subarray(0, 32),
          { name: 'HMAC', hash: 'SHA-512' }, true, ['sign', 'verify']);
        const signature = await crypto.subtle.sign('HMAC', key, data);
        if (!(await crypto.subtle.verify('HMAC', key, signature, data))) {
          throw new Error('HMAC verify failed');
        }
        return signature.byteLength;
      ''', tag);

    case _OpKind.fetchGet:
      if (!env.hasFetch) return;
      final length = await _evalAsync(js, '''
        const response = await fetch('${env.baseUrl}/small');
        if (!response.ok || response.status !== 200) throw new Error('status ' + response.status);
        const text = await response.text();
        if (text.length !== $_soakSmallBodyLength) throw new Error('body length ' + text.length);
        return text.length;
      ''', tag);
      env.fetchOps++;
      env.fetchBytes += length as int;

    case _OpKind.fetchJson:
      if (!env.hasFetch) return;
      await _evalAsync(js, '''
        const response = await fetch('${env.baseUrl}/json');
        const body = await response.json();
        if (body.ok !== true || body.n !== $_soakSmallBodyLength) {
          throw new Error('json body ' + JSON.stringify(body));
        }
        if (response.headers.get('content-type') === null) throw new Error('missing content-type');
        return body.n;
      ''', tag);
      env.fetchOps++;

    case _OpKind.fetchStream:
      if (!env.hasFetch) return;
      final streamed = await _evalAsync(js, '''
        const response = await fetch('${env.baseUrl}/chunked');
        const reader = response.body.getReader();
        let total = 0;
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          total += value.length;
        }
        const expected = ${_soakChunkedChunks * _soakChunkSize};
        if (total !== expected) throw new Error('streamed ' + total + ' of ' + expected);
        return total;
      ''', tag);
      env.fetchOps++;
      env.fetchBytes += streamed as int;

    case _OpKind.fetchUpload:
      if (!env.hasFetch) return;
      await _evalAsync(js, '''
        const size = 256 + ($seed % 2048);
        const payload = new Uint8Array(size);
        const useForm = ($seed % 2) === 0;
        const body = useForm ? new FormData() : payload;
        if (useForm) body.append('f', new File([payload], 'up.bin'));
        const response = await fetch('${env.baseUrl}/echo', { method: 'POST', body });
        const echoed = await response.json();
        if (echoed.method !== 'POST') throw new Error('method ' + echoed.method);
        if (useForm) {
          if (!echoed.contentType.startsWith('multipart/form-data')) {
            throw new Error('content-type ' + echoed.contentType);
          }
          if (echoed.length <= size) throw new Error('multipart too short ' + echoed.length);
        } else if (echoed.length !== size) {
          throw new Error('echo length ' + echoed.length + ' != ' + size);
        }
        return echoed.length;
      ''', tag);
      env.fetchOps++;

    case _OpKind.fetchRedirect:
      if (!env.hasFetch) return;
      await _evalAsync(js, '''
        const response = await fetch('${env.baseUrl}/redirect/3');
        if (!response.redirected) throw new Error('redirected flag not set');
        if (!response.url.endsWith('/small')) throw new Error('final url ' + response.url);
        const text = await response.text();
        if (text.length !== $_soakSmallBodyLength) throw new Error('redirect body ' + text.length);
        const manual = await fetch('${env.baseUrl}/redirect/1', { redirect: 'manual' });
        if (manual.status !== 302) throw new Error('manual status ' + manual.status);
        return text.length;
      ''', tag);
      env.fetchOps++;

    case _OpKind.fetchAbort:
      if (!env.hasFetch) return;
      final outcome = await _evalAsync(js, '''
        const controller = new AbortController();
        const pending = fetch('${env.baseUrl}/slow', { signal: controller.signal });
        setTimeout(() => controller.abort(), 5 + ($seed % 20));
        try {
          const response = await pending;
          await response.text();
          return 'completed';
        } catch (error) {
          if (error.name !== 'AbortError') throw error;
          return 'aborted';
        }
      ''', tag);
      if (outcome != 'aborted' && outcome != 'completed') {
        throw StateError('$tag unexpected abort outcome: $outcome');
      }
      env.fetchOps++;

    case _OpKind.fetchAbandoned:
      if (!env.hasFetch) return;
      // Started and never awaited: the engine is released (and usually reset)
      // with the request in flight, which must cancel it on the host side.
      final started = js.evaluate(
        "fetch('${env.baseUrl}/slow').then((r) => r.text()).catch(() => {}); 1",
      );
      if (started.isError) throw StateError('$tag: ${started.stringResult}');
      env.fetchOps++;

    case _OpKind.createDisposeWebEngine:
      final engine = getJavascriptRuntime(
        timeout: 5000,
        memoryLimit: kDefaultJsMemoryLimit,
        webApis: env.config.webApis,
      );
      try {
        if (env.hasWeb) {
          _evalSync(engine, r'''
            const url = new URL('https://example.test/a?b=1');
            const bytes = new TextEncoder().encode(url.href);
            if (new TextDecoder().decode(bytes) !== url.href) {
              throw new Error('fresh engine round trip');
            }
            return bytes.length;
          ''', tag);
        } else {
          _evalSync(engine, 'return structuredClone({ a: 1 }).a;', tag);
        }
      } finally {
        engine.dispose();
      }

    // Dispatched by _runOp.
    case _OpKind.evaluateTiny:
    case _OpKind.invokeCached:
    case _OpKind.stringRoundTrip:
    case _OpKind.mapRoundTrip:
    case _OpKind.dartUint8ToJs:
    case _OpKind.jsUint8ToDart:
    case _OpKind.evaluateJsonArray:
    case _OpKind.evaluateFullArray:
    case _OpKind.promiseMicrotask:
    case _OpKind.createDisposeEngine:
    case _OpKind.runGcSample:
      throw StateError('$tag is not a Web API op');
  }
}

/// Open file descriptors — leaked fetch sockets or stream subscriptions show up
/// here long before RSS moves.
int _openFds() {
  if (!Platform.isLinux) return 0;
  try {
    return Directory('/proc/$pid/fd').listSync().length;
  } catch (_) {
    return 0;
  }
}

Future<String> _writeDump({
  required SoakStressConfig cfg,
  required JsEnginePool pool,
  required _OpLog opLog,
  required int totalOps,
  required int errors,
  required int baselineRss,
  required int peakRss,
  required Object error,
  required StackTrace stack,
  required String where,
}) async {
  final dir = Directory(cfg.dumpDir);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final file = File('${dir.path}/soak_dump_$stamp.txt');

  final memLines = <String>[];
  try {
    if (pool.idleCount > 0 ||
        pool.size < pool.maxSize ||
        pool.inUseCount == 0) {
      await pool.withEngine((js) async {
        js.runGC();
        memLines.add('sample engine: ${js.getEngineInstanceId()}');
        memLines.add('  memoryUsage: ${js.getMemoryUsage()}');
      }, acquireTimeout: const Duration(seconds: 2));
    } else {
      memLines.add('skip memory sample: pool busy');
    }
  } catch (e) {
    memLines.add('memory sample failed: $e');
  }

  final buf = StringBuffer()
    ..writeln('flutter_qjs_next soak dump')
    ..writeln('when: ${DateTime.now().toIso8601String()}')
    ..writeln('where: $where')
    ..writeln('error: $error')
    ..writeln('stack:')
    ..writeln(stack)
    ..writeln()
    ..writeln('config: $cfg')
    ..writeln('ops: $totalOps errors: $errors')
    ..writeln('rss baseline=$baselineRss peak=$peakRss current=${_rss()}')
    ..writeln(
      'pool size=${pool.size} idle=${pool.idleCount} inUse=${pool.inUseCount}',
    )
    ..writeln('pid=$pid')
    ..writeln('core: ${cfg.coreDumpHint}')
    ..writeln()
    ..writeln('--- QJS sample ---')
    ..writeln(memLines.join('\n'))
    ..writeln()
    ..writeln('--- recent ops ---')
    ..writeln(opLog.dump());

  file.writeAsStringSync(buf.toString());
  return file.path;
}
