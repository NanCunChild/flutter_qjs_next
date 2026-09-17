// Control for soak RSS attribution: the soak's HTTP traffic with no QuickJS at
// all, reading response bodies the way `_FetchHost` does (pause after every
// chunk, resume on demand) unless CONTROL_DRAIN=1. If RSS climbs here too, the
// growth is in `dart:io`, not in the fetch bridge.
//
// Opt-in — it does nothing without a duration:
//
//   flutter test test/http_control_test.dart --timeout none \
//     --dart-define=CONTROL_SEC=150 [--dart-define=CONTROL_DRAIN=1]
//
// See doc/wiki/guides/soak-rss-analysis.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

const _small = 512;
const _chunks = 8;
const _chunkSize = 4096;

/// Handlers that have started and not yet reached their `finally`. A number
/// that only grows means the server side never notices the client leaving.
int liveHandlers = 0;

Future<HttpServer> _start() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final small = 'x' * _small;
  server.listen((request) async {
    final response = request.response;
    liveHandlers++;
    try {
      switch (request.uri.pathSegments.first) {
        case 'small':
          response.write(small);
        case 'json':
          response.write(jsonEncode({'ok': true, 'n': _small}));
        case 'chunked':
          for (var i = 0; i < _chunks; i++) {
            response.add(Uint8List(_chunkSize)..fillRange(0, _chunkSize, i));
            await response.flush();
          }
        case 'slow':
          // The client aborts this endpoint on purpose. Writing to a peer that
          // aborted neither fails nor flushes, so without noticing `done` the
          // handler never finishes and its response graph is retained forever.
          var connected = true;
          unawaited(
            response.done.then((_) => connected = false,
                onError: (Object _) => connected = false),
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
          response.write(jsonEncode({'length': body.length}));
        default:
          response.statusCode = 404;
      }
    } catch (_) {
      // client went away
    } finally {
      try {
        await response.close().timeout(const Duration(seconds: 1));
      } catch (_) {}
      liveHandlers--;
    }
  });
  return server;
}

String _rss(String tag) {
  final heap = readNativeHeapUsage();
  String mb(int v) => (v / 1e6).toStringAsFixed(1);
  return 'CONTROL[$tag] rss=${mb(ProcessInfo.currentRss)} '
      'arena=${mb(heap.arenaBytes)} inUse=${mb(heap.inUseBytes)} '
      'liveHandlers=$liveHandlers';
}

/// Consume [response] the way `_FetchHost` does: one chunk per "pull", with the
/// subscription paused in between.
Future<int> _pullDrain(HttpClientResponse response) async {
  var total = 0;
  final completerQueue = <void Function()>[];
  late final StreamSubscription<List<int>> subscription;
  var done = false;
  void Function()? waiting;
  subscription = response.listen(
    (chunk) {
      subscription.pause();
      total += chunk.length;
      waiting?.call();
      waiting = null;
    },
    onDone: () {
      done = true;
      waiting?.call();
      waiting = null;
    },
    onError: (Object _) {
      done = true;
      waiting?.call();
      waiting = null;
    },
    cancelOnError: true,
  );
  subscription.pause();
  while (!done) {
    final completer = Completer<void>();
    waiting = completer.complete;
    subscription.resume();
    await completer.future;
  }
  completerQueue.clear();
  return total;
}

const _seconds = int.fromEnvironment('CONTROL_SEC');

void main() {
  test('http control', () async {
    final server = await _start();
    final base = 'http://${server.address.address}:${server.port}';
    // CONTROL_MODE=abort mirrors the soak's fetchAbort op: request the slow
    // endpoint and abort it a few ms in, which is the operation that dominates
    // web_fetch RSS growth.
    const mode =
        String.fromEnvironment('CONTROL_MODE', defaultValue: 'read');
    final paths = mode == 'abort' || mode == 'cancel' || mode == 'cancelpaused'
        ? const ['slow']
        : const ['small', 'json', 'chunked', 'echo'];
    final duration = Duration(seconds: _seconds);
    final drain =
        const String.fromEnvironment('CONTROL_DRAIN', defaultValue: '0') != '0';
    final perClient = int.parse(
      const String.fromEnvironment('CONTROL_BURST', defaultValue: '8'),
    );
    final stopAt = DateTime.now().add(duration);
    var ops = 0;
    // ignore: avoid_print
    print('${_rss('start')} drain=$drain');
    var lastReport = DateTime.now();

    Future<void> worker(int id) async {
      while (DateTime.now().isBefore(stopAt)) {
        final client = HttpClient();
        try {
          for (var i = 0; i < perClient; i++) {
            final path = paths[(ops + id) % paths.length];
            final request = await client.openUrl(
              path == 'echo' ? 'POST' : 'GET',
              Uri.parse('$base/$path'),
            );
            request.followRedirects = false;
            if (path == 'echo') {
              final payload = Uint8List(1024);
              request.contentLength = payload.length;
              request.add(payload);
            }
            if (mode == 'cancelpaused') {
              // Same as 'cancel', but the subscription is paused between
              // chunks the way _FetchHost back-pressures a response body, and
              // the cancel happens while it is paused.
              final response = await request.close();
              late final StreamSubscription<List<int>> subscription;
              subscription = response.listen((_) => subscription.pause());
              subscription.pause();
              subscription.resume();
              await Future<void>.delayed(
                Duration(milliseconds: 5 + (ops % 20)),
              );
              await subscription.cancel();
            } else if (mode == 'cancel') {
              // Stop reading instead of aborting the request: the same
              // "client goes away mid-response" shape without abort().
              final response = await request.close();
              final subscription = response.listen((_) {});
              await Future<void>.delayed(
                Duration(milliseconds: 5 + (ops % 20)),
              );
              await subscription.cancel();
            } else if (mode == 'abort') {
              Timer(Duration(milliseconds: 5 + (ops % 20)), request.abort);
              try {
                final response = await request.close();
                await response.drain<void>();
              } catch (_) {
                // aborted, which is the point
              }
            } else {
              final response = await request.close();
              if (drain) {
                await response.drain<void>();
              } else {
                await _pullDrain(response);
              }
            }
            ops++;
          }
        } catch (_) {
        } finally {
          client.close(force: true);
        }
        if (DateTime.now().difference(lastReport).inSeconds >= 10) {
          lastReport = DateTime.now();
          // ignore: avoid_print
          print('${_rss('tick')} ops=$ops');
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    await Future.wait(List.generate(32, worker));
    // ignore: avoid_print
    print('${_rss('end')} ops=$ops');
    await server.close(force: true);
    expect(ops, greaterThan(0));
  }, timeout: Timeout.none, skip: _seconds <= 0 ? 'set CONTROL_SEC' : null);
}
