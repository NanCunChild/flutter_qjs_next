// JS → Dart object conversion keeps the enumerable string keys only.
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late QuickJsRuntime2 js;

  setUp(() => js = QuickJsRuntime2(timeout: 2000));
  tearDown(() => js.dispose());

  test('symbol keys are skipped instead of collapsing onto null', () {
    final r = js.evaluate("({[Symbol('a')]: 1, [Symbol('b')]: 2, x: 3})");
    expect(r.rawResult, {'x': 3});
  });

  test('non-enumerable and private members stay hidden', () {
    final r = js.evaluate('''
      class A { #p = 1; q = 2 }
      const o = new A();
      Object.defineProperty(o, 'hidden', {value: 3, enumerable: false});
      o
    ''');
    expect(r.rawResult, {'q': 2});
  });

  test('integer-like keys arrive as strings', () {
    expect(js.evaluate('({1: "a", b: 2})').rawResult, {'1': 'a', 'b': 2});
  });
}
