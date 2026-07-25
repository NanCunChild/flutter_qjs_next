import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_qjs_example/production_tenant_worker.dart';

void main() {
  test('soft reset clears tenant global between leases', () async {
    final worker = ProductionTenantWorker(maxSize: 1, timeoutMs: 3000);
    addTearDown(worker.dispose);

    await worker.run('globalThis.__tenant = 1');
    final after = await worker.run(
      'typeof globalThis.__tenant === "undefined" ? "clean" : String(globalThis.__tenant)',
    );
    expect(after, 'clean');
  });

  test('warmReuse keeps global between leases', () async {
    final worker = ProductionTenantWorker.warmReuse(maxSize: 1);
    addTearDown(worker.dispose);

    await worker.run('globalThis.__warm = 42');
    final after = await worker.run('globalThis.__warm');
    expect(after, 42);
  });

  test('evaluateJson path returns Dart structure', () async {
    final worker = ProductionTenantWorker(maxSize: 1);
    addTearDown(worker.dispose);

    final data = await worker.run(
      '({ a: 1, b: [true, null, "x"] })',
      asJson: true,
    );
    expect(data, isA<Map>());
    final map = data as Map;
    expect(map['a'], 1);
    expect(map['b'], [true, null, 'x']);
  });

  test('evaluate error becomes StateError', () async {
    final worker = ProductionTenantWorker(maxSize: 1, timeoutMs: 1000);
    addTearDown(worker.dispose);

    await expectLater(
      worker.run('throw new Error("boom")'),
      throwsA(isA<StateError>()),
    );
  });

  test('mapWithCachedFunction reuses JSInvokable', () async {
    final worker = ProductionTenantWorker(maxSize: 1);
    addTearDown(worker.dispose);

    final out = await worker.mapWithCachedFunction(
      '(a, b) => a + b',
      [
        [1, 2],
        [10, 5],
        [0, 0],
      ],
    );
    expect(out, [3, 15, 0]);
  });

  test('pushBytes / pullBytes TypedArray path', () async {
    final worker = ProductionTenantWorker(maxSize: 1);
    addTearDown(worker.dispose);

    final n = await worker.pushBytes(Uint8List.fromList([1, 2, 3, 255]));
    expect(n, 4);

    final back = await worker.pullBytes(
      'new Uint8Array([9, 8, 7])',
    );
    expect(back, equals([9, 8, 7]));
  });

  test('payload budget rejects oversized Dart→JS', () async {
    final worker = ProductionTenantWorker(
      maxSize: 1,
      payloadBudget: const TenantPayloadBudget(maxDartToJsBytes: 8),
    );
    addTearDown(worker.dispose);

    expect(
      () => worker.pushBytes(Uint8List(16)),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('diagnostics returns memory and bridge stats', () async {
    final worker = ProductionTenantWorker(maxSize: 1);
    addTearDown(worker.dispose);

    await worker.run('1+1');
    final d = await worker.diagnostics(runGc: true);
    expect(d.poolSize, greaterThanOrEqualTo(1));
    expect(d.bridgeStats, contains('copyBytes'));
    // QuickJS heap counters should be available on real engines.
    expect(d.memoryUsage, isNotNull);
  });
}
