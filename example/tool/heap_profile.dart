// Connects to a paused `flutter test --start-paused` VM service, resumes it and
// prints the Dart classes whose retained bytes grow while the soak runs.
import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(args[0]);
  final ws = uri.replace(
    scheme: 'ws',
    path: uri.path.endsWith('/') ? '${uri.path}ws' : '${uri.path}/ws',
  );
  final service = await vmServiceConnectUri(ws.toString());
  final vm = await service.getVM();
  for (final isolate in vm.isolates ?? const <IsolateRef>[]) {
    try {
      await service.resume(isolate.id!);
    } catch (_) {}
  }
  final baseline = <String, int>{};
  final rounds = int.parse(args.length > 1 ? args[1] : '8');
  for (var round = 0; round < rounds; round++) {
    await Future<void>.delayed(const Duration(seconds: 20));
    final current = await service.getVM();
    for (final isolate in current.isolates ?? const <IsolateRef>[]) {
      final AllocationProfile profile;
      try {
        profile = await service.getAllocationProfile(isolate.id!, gc: true);
      } catch (e) {
        continue;
      }
      final rows = <MapEntry<String, int>>[];
      for (final member in profile.members ?? const <ClassHeapStats>[]) {
        final name = '${isolate.name}:${member.classRef?.name ?? '?'}';
        final bytes = member.bytesCurrent ?? 0;
        final base = baseline[name];
        if (round == 0) {
          baseline[name] = bytes;
        } else if (base != null) {
          rows.add(MapEntry('$name (n=${member.instancesCurrent})', bytes - base));
        }
      }
      if (rows.isEmpty) continue;
      rows.sort((a, b) => b.value.compareTo(a.value));
      stdout.writeln('--- round $round isolate=${isolate.name} '
          'heapUsage=${(profile.memoryUsage?.heapUsage ?? 0) ~/ 1000000}MB '
          'external=${(profile.memoryUsage?.externalUsage ?? 0) ~/ 1000000}MB');
      for (final row in rows.take(12)) {
        stdout.writeln('    ${row.key.padRight(48)} ${row.value ~/ 1000} kB');
      }
    }
  }
  await service.dispose();
  exit(0);
}
