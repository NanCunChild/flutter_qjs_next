// Connects to a paused `flutter test --start-paused` run, resumes it, waits,
// then takes a heap snapshot and prints which classes hold the heap.
import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _watch = [
  'QuickJsRuntime2', 'WebApiHost', '_FetchHost', '_FetchOperation',
  '_HttpClientFetchHandler', '_DartObject', '_JSObject', '_JSFunction',
  '_DartFunction', 'JsEnginePool', 'JSError', 'JsEvalResult',
  '_HttpClient', '_HttpClientConnection', '_HttpClientRequest',
  '_HttpClientResponse', '_HttpParser', '_HttpIncoming', '_HttpOutgoing',
  '_Socket', '_NativeSocket', '_RawSocket', 'HttpServer', '_HttpServer',
  '_HttpConnection', '_StreamController', '_ControllerSubscription',
  '_BufferingStreamSubscription', '_AsyncStreamController', 'Timer', '_Timer',
  'Completer', '_AsyncCompleter', '_PendingEvents', '_StreamImplEvents',
];

Future<void> main(List<String> args) async {
  final uri = Uri.parse(args[0]);
  final waitSec = int.parse(args.length > 1 ? args[1] : '90');
  final ws = uri.replace(
    scheme: 'ws',
    path: uri.path.endsWith('/') ? '${uri.path}ws' : '${uri.path}/ws',
  );
  final service = await vmServiceConnectUri(ws.toString());
  var vm = await service.getVM();
  for (final isolate in vm.isolates ?? const <IsolateRef>[]) {
    try {
      await service.resume(isolate.id!);
    } catch (_) {}
  }
  await Future<void>.delayed(Duration(seconds: waitSec));
  vm = await service.getVM();
  final main = (vm.isolates ?? const <IsolateRef>[]).firstWhere(
    (i) => i.name == 'main',
  );
  final graph = await HeapSnapshotGraph.getSnapshot(service, main);
  stdout.writeln(
    'objects=${graph.objects.length} capacity=${graph.capacity ~/ 1000000}MB',
  );

  final bytes = <String, int>{};
  final counts = <String, int>{};
  for (final object in graph.objects) {
    final name = object.klass.name;
    bytes[name] = (bytes[name] ?? 0) + object.shallowSize;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final top = bytes.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('== top classes by shallow bytes ==');
  for (final entry in top.take(20)) {
    stdout.writeln(
      '  ${entry.key.padRight(32)} '
      '${(entry.value / 1e6).toStringAsFixed(1)}MB n=${counts[entry.key]}',
    );
  }
  stdout.writeln('== watchlist ==');
  for (final name in _watch) {
    final n = counts[name];
    if (n != null) {
      stdout.writeln(
        '  ${name.padRight(32)} n=$n '
        '${((bytes[name] ?? 0) / 1e6).toStringAsFixed(2)}MB',
      );
    }
  }
  await service.dispose();
  exit(0);
}
