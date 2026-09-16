part of '../web_apis.dart';

/// `Navigator` and the `navigator` global.
const String _jsNavigator = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const { define, illegal } = internal;

  class Navigator {
    constructor(key = undefined) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
    }
    get userAgent() { return host.userAgent(); }
    get hardwareConcurrency() { return 1; }
    get language() { return 'en-US'; }
    get languages() { return ['en-US']; }
    get onLine() { return true; }
  }
  Object.defineProperty(Navigator.prototype, Symbol.toStringTag, { value: 'Navigator', configurable: true });

  define(g, 'Navigator', Navigator);
  define(g, 'navigator', new Navigator(illegal));
})
''';
