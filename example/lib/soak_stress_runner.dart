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
// 7. Memory observation
//    - Periodic process RSS ([ProcessInfo.currentRss]) + pool stats.
//    - Optional soft ceiling: fail if RSS grows past threshold factor.
//
// 8. Failure stop + dump
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
  /// Supported values: all, tiny, no_typed_array, dart_to_js, js_to_dart,
  /// typed_array.
  final String workloadProfile;

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
    return SoakStressConfig(
      duration: Duration(seconds: sec),
      poolSize: parseInt(const String.fromEnvironment('SOAK_POOL_SIZE'), 4),
      workers: parseInt(const String.fromEnvironment('SOAK_WORKERS'), 16),
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
    );
  }

  @override
  String toString() =>
      'SoakStressConfig(duration=$duration poolSize=$poolSize workers=$workers '
      'opsPerBurst=$opsPerBurst seed=$seed dumpDir=$dumpDir '
      'resetOnRelease=$resetOnRelease memoryLimit=$memoryLimitBytes '
      'timeoutMs=$timeoutMs failFast=$failOnFirstError '
      'maxRssGrowth=$maxRssGrowthFactor profile=$workloadProfile)';
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
    required this.aborted,
  });

  final SoakStressConfig config;
  final Duration wallElapsed;
  final int totalOps;
  final int errors;
  final String? dumpPath;
  final int baselineRss;
  final int peakRss;
  final bool aborted;

  bool get ok => !aborted && errors == 0;

  @override
  String toString() =>
      'SoakStressResult(ok=$ok elapsed=$wallElapsed ops=$totalOps errors=$errors '
      'rss baseline=$baselineRss peak=$peakRss dump=$dumpPath)';
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
    ),
  );

  var totalOps = 0;
  var errors = 0;
  var peakRss = _rss();
  final baselineRss = peakRss;
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
      final engines = <Map<String, dynamic>>[];
      for (final js in pool.idleEngines) {
        js.runGC();
        final qjs = js.getMemoryUsage();
        engines.add(<String, dynamic>{
          'id': js.getEngineInstanceId(),
          'qjs': qjs == null ? null : _memoryUsageJson(qjs),
          'pendingJobs': js is QuickJsRuntime2 && js.hasPendingJobs,
          'dartRefs': js is QuickJsRuntime2 ? js.debugReferenceCount : null,
        });
      }
      final sample = <String, dynamic>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'elapsedSec': DateTime.now().difference(started).inMilliseconds / 1000,
        'opsTotal': totalOps,
        'errors': errors,
        'rss': rss,
        'rssDelta': rss - baselineRss,
        'peakRss': peakRss,
        'baselineRss': baselineRss,
        'procMemory': _procMemory(),
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
        'peakRss=$peakRss baselineRss=$baselineRss '
        'engines=${engines.length} bridge=${readBridgeStats()}',
      );
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
            await _runOp(js, kind, rng, tag);
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

  try {
    await Future.wait(List.generate(cfg.workers, worker));

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
  }

  final result = SoakStressResult(
    config: cfg,
    wallElapsed: DateTime.now().difference(started),
    totalOps: totalOps,
    errors: errors,
    dumpPath: dumpPath,
    baselineRss: baselineRss,
    peakRss: peakRss,
    aborted: aborted,
  );
  emit('soak done: $result');
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
    default:
      throw ArgumentError.value(
        profile,
        'SOAK_PROFILE',
        'expected all, tiny, no_typed_array, dart_to_js, js_to_dart, or typed_array',
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

Future<void> _runOp(
  JavascriptRuntime js,
  _OpKind kind,
  Random rng,
  String tag,
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
