// jsCall / jsEval must only post to the event-loop port while dispatch() is
// running. Otherwise every call queues a message on a ReceivePort nobody
// listens to, and the port's buffer grows for the life of the runtime (pool
// engines are never disposed, so for the life of the process). Found by the
// 1 h `profile=all` soak: ~22 B/op of `_DelayedData` on the Dart heap.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const calls = 1000;

  /// Messages already waiting on [js]'s event-loop port.
  Future<int> backlog(QuickJsRuntime2 js) async {
    var count = 0;
    final subscription = js.port.listen((_) => count++);
    // Buffered messages are delivered on the next event-loop turns.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await subscription.cancel();
    return count;
  }

  test('JSInvokable.invoke without dispatch leaves nothing on the port',
      () async {
    final js = QuickJsRuntime2(webApis: const JsWebApis.none());
    addTearDown(js.dispose);
    final fn = js.evaluate('(x) => x + 1').rawResult as JSInvokable;
    addTearDown(fn.free);
    for (var i = 0; i < calls; i++) {
      expect(fn.invoke([i]), i + 1);
    }
    expect(await backlog(js), 0);
  });

  test('evaluateJson without dispatch leaves nothing', () async {
    final js = QuickJsRuntime2(webApis: const JsWebApis.none());
    addTearDown(js.dispose);
    for (var i = 0; i < calls; i++) {
      expect(js.evaluateJson('[$i]'), [i]);
    }
    expect(await backlog(js), 0);
  });

  test('evaluate without dispatch leaves nothing', () async {
    final js = QuickJsRuntime2(webApis: const JsWebApis.none());
    addTearDown(js.dispose);
    for (var i = 0; i < calls; i++) {
      js.evaluate('$i');
    }
    expect(await backlog(js), 0);
  });
}
