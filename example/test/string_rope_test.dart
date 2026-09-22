// QuickJS returns a rope (JS_TAG_STRING_ROPE) when the right operand of a
// string concatenation is longer than 512 characters.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late QuickJsRuntime2 js;

  setUp(() => js = QuickJsRuntime2(timeout: 2000));
  tearDown(() => js.dispose());

  test('evaluate returns a rope string', () {
    final r = js.evaluate("'a' + 'b'.repeat(600)");
    expect(r.isError, isFalse);
    expect(r.rawResult, 'a${'b' * 600}');
    expect(r.stringResult, 'a${'b' * 600}');
  });

  test('rope strings nested in objects and arrays', () {
    final r = js.evaluate("const s = 'x' + 'y'.repeat(600); ({k: s, a: [s]})");
    final expected = 'x${'y' * 600}';
    expect(r.rawResult, {
      'k': expected,
      'a': [expected],
    });
  });

  test('rope string passed to a host function', () {
    Object? received;
    final call = js.evaluate('(f) => f("a" + "\\u00e9".repeat(600))').rawResult
        as JSInvokable;
    addTearDown(call.free);
    call.invoke([(dynamic v) => received = v]);
    expect(received, 'a${'é' * 600}');
  });

  test('evaluateJson of a rope string', () {
    expect(js.evaluateJson("'a' + 'b'.repeat(600)"), 'a${'b' * 600}');
  });
}
