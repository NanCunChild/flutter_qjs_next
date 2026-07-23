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
}
