import 'dart:async';
import 'package:flutter_qjs_next/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispose after host function calls does not throw reference leak', () {
    final js = getJavascriptRuntime();
    final set = js.evaluate('(k,v)=>{globalThis[k]=v}').rawResult as JSInvokable;
    set.invoke(['add', (a, b) => (a as num) + (b as num)]);
    set.free();
    for (var i = 0; i < 200; i++) {
      final r = js.evaluate('add(1,2)');
      expect(r.rawResult, 3);
    }
    expect(() => js.dispose(), returnsNormally);
  });

  test('unevaluated function rawResult auto-cleaned on dispose', () {
    final js = getJavascriptRuntime();
    final fn = js.evaluate('(x)=>x').rawResult;
    expect(fn, isA<JSInvokable>());
    // _JSFunction is JSRefLeakable → auto-freed during dispose.
    expect(() => js.dispose(), returnsNormally);
  });

  test('freed function rawResult dispose clean', () {
    final js = getJavascriptRuntime();
    final fn = js.evaluate('(x)=>x').rawResult as JSInvokable;
    fn.free();
    expect(() => js.dispose(), returnsNormally);
  });

  test('object with method property — methods are JSRef', () {
    final js = getJavascriptRuntime();
    final obj = js.evaluate('({a:1, f:function(){return 2}})').rawResult as Map;
    // f should be JSInvokable / JSRef
    final f = obj['f'];
    expect(f, isA<JSInvokable>());
    // free map's refs
    (f as JSInvokable).free();
    expect(() => js.dispose(), returnsNormally);
  });

  test('object with method not freed — auto-cleaned on dispose', () {
    final js = getJavascriptRuntime();
    js.evaluate('({a:1, f:function(){return 2}})');
    // _JSFunction refs are JSRefLeakable → auto-freed.
    expect(() => js.dispose(), returnsNormally);
  });

  test('array of functions not freed — auto-cleaned on dispose', () {
    final js = getJavascriptRuntime();
    js.evaluate('[function(){return 1}, function(){return 2}]');
    // _JSFunction refs are JSRefLeakable → auto-freed.
    expect(() => js.dispose(), returnsNormally);
  });

  test('promise future value with function needs free', () async {
    final js = getJavascriptRuntime();
    final r = js.evaluate('Promise.resolve(() => 1)');
    final v = await (r.rawResult as Future);
    expect(v, isA<JSInvokable>());
    (v as JSInvokable).free();
    expect(() => js.dispose(), returnsNormally);
  });

  test('promise future value function not freed — auto-cleaned on dispose', () async {
    final js = getJavascriptRuntime();
    final r = js.evaluate('Promise.resolve(() => 1)');
    await (r.rawResult as Future);
    // _JSFunction from resolved promise is JSRefLeakable → auto-freed.
    expect(() => js.dispose(), returnsNormally);
  });

  test('dart Future to JS then dispose after settle', () async {
    final js = getJavascriptRuntime();
    final set = js.evaluate('(k,v)=>{globalThis[k]=v}').rawResult as JSInvokable;
    set.invoke(['getP', () => Future.value(7)]);
    set.free();
    js.evaluate('getP().then(v => { globalThis.__v = v; })');
    // drain jobs / allow dart microtasks
    for (var i = 0; i < 10; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
      js.executePendingJobs();
    }
    expect(js.evaluate('globalThis.__v').rawResult, 7);
    expect(() => js.dispose(), returnsNormally);
  });

  test('dart Future to JS dispose before settle', () async {
    final js = getJavascriptRuntime();
    final set = js.evaluate('(k,v)=>{globalThis[k]=v}').rawResult as JSInvokable;
    final c = Completer<int>();
    set.invoke(['getP', () => c.future]);
    set.free();
    js.evaluate('getP()');
    // dispose while future pending — may throw if _JSFunction still held
    Object? err;
    try {
      js.dispose();
    } catch (e) {
      err = e;
    }
    // complete after dispose
    if (!c.isCompleted) c.complete(1);
    await Future.delayed(const Duration(milliseconds: 20));
    // just record
    print('early dispose err=$err');
  });

  test('setTimeout pending then dispose', () async {
    final js = getJavascriptRuntime();
    js.evaluate('setTimeout(() => {}, 10000)');
    expect(() => js.dispose(), returnsNormally);
  });

  test('setTimeout fires then dispose', () async {
    final js = getJavascriptRuntime();
    js.evaluate('setTimeout(() => { globalThis.x = 1 }, 20)');
    await Future.delayed(const Duration(milliseconds: 80));
    expect(js.evaluate('globalThis.x').rawResult, 1);
    expect(() => js.dispose(), returnsNormally);
  });

  test('evaluate function result used via invoke then free', () {
    final js = getJavascriptRuntime();
    final fn = js.evaluate('(a,b)=>a+b').rawResult as JSInvokable;
    expect(fn.invoke([2, 3]), 5);
    fn.free();
    expect(() => js.dispose(), returnsNormally);
  });

  test('nested evaluate sendMessage path via console', () {
    final js = getJavascriptRuntime();
    js.evaluate('console.log("hi")');
    expect(() => js.dispose(), returnsNormally);
  });
}
