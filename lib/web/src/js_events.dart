part of '../web_apis.dart';

/// L1 events: `Event`, `CustomEvent`, `EventTarget`, `AbortController`,
/// `AbortSignal`.
const String _jsEvents = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const { define, DOMException, illegal, customInspect, reportError, cloneHooks, NOT_CLONED } = internal;
  const perf = g.performance;

  const NONE = 0;
  const AT_TARGET = 2;

  let eventAccess;
  class Event {
    #type;
    #bubbles;
    #cancelable;
    #composed;
    #target = null;
    #currentTarget = null;
    #phase = NONE;
    #defaultPrevented = false;
    #stopImmediate = false;
    #stopPropagation = false;
    #isTrusted = false;
    #dispatching = false;
    #timeStamp = perf.now();

    constructor(type, eventInitDict = undefined) {
      if (arguments.length === 0) {
        throw new TypeError("Failed to construct 'Event': 1 argument required, but only 0 present.");
      }
      const init = eventInitDict === undefined || eventInitDict === null ? {} : eventInitDict;
      this.#type = String(type);
      this.#bubbles = Boolean(init.bubbles);
      this.#cancelable = Boolean(init.cancelable);
      this.#composed = Boolean(init.composed);
    }
    get type() { return this.#type; }
    get target() { return this.#target; }
    get srcElement() { return this.#target; }
    get currentTarget() { return this.#currentTarget; }
    get eventPhase() { return this.#phase; }
    get bubbles() { return this.#bubbles; }
    get cancelable() { return this.#cancelable; }
    get composed() { return this.#composed; }
    get defaultPrevented() { return this.#defaultPrevented; }
    get isTrusted() { return this.#isTrusted; }
    get timeStamp() { return this.#timeStamp; }
    get returnValue() { return !this.#defaultPrevented; }
    set returnValue(value) { if (!value) this.preventDefault(); }
    get cancelBubble() { return this.#stopPropagation; }
    set cancelBubble(value) { if (value) this.#stopPropagation = true; }
    composedPath() { return this.#dispatching && this.#currentTarget !== null ? [this.#currentTarget] : []; }
    stopPropagation() { this.#stopPropagation = true; }
    stopImmediatePropagation() {
      this.#stopPropagation = true;
      this.#stopImmediate = true;
    }
    preventDefault() { if (this.#cancelable) this.#defaultPrevented = true; }
    [customInspect]() {
      return 'Event { type: ' + JSON.stringify(this.#type) + ', defaultPrevented: ' + this.#defaultPrevented + ' }';
    }
    static {
      eventAccess = {
        is: (value) => typeof value === 'object' && value !== null && #type in value,
        dispatching: (event) => event.#dispatching,
        begin(event, target, trusted) {
          event.#target = target;
          event.#currentTarget = target;
          event.#phase = AT_TARGET;
          event.#dispatching = true;
          event.#isTrusted = trusted;
        },
        end(event) {
          event.#currentTarget = null;
          event.#phase = NONE;
          event.#dispatching = false;
        },
        stopImmediate: (event) => event.#stopImmediate,
        defaultPrevented: (event) => event.#defaultPrevented,
      };
    }
  }
  ObjectDefine(Event, 'NONE', 0);
  ObjectDefine(Event, 'AT_TARGET', 2);
  ObjectDefine(Event, 'BUBBLING_PHASE', 3);
  ObjectDefine(Event, 'CAPTURING_PHASE', 1);
  function ObjectDefine(target, name, value) {
    Object.defineProperty(target, name, { value, enumerable: true });
  }
  Object.defineProperty(Event.prototype, Symbol.toStringTag, { value: 'Event', configurable: true });

  class CustomEvent extends Event {
    #detail;
    constructor(type, eventInitDict = undefined) {
      super(type, eventInitDict);
      const init = eventInitDict === undefined || eventInitDict === null ? {} : eventInitDict;
      this.#detail = init.detail === undefined ? null : init.detail;
    }
    get detail() { return this.#detail; }
  }
  Object.defineProperty(CustomEvent.prototype, Symbol.toStringTag, { value: 'CustomEvent', configurable: true });

  let dispatchTrusted;
  let isEventTarget;
  class EventTarget {
    #listeners = new Map();

    addEventListener(type, callback, options = undefined) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'addEventListener' on 'EventTarget': 2 arguments required.");
      }
      if (callback === null || callback === undefined) return;
      if (typeof callback !== 'function' && typeof callback !== 'object') {
        throw new TypeError("Failed to execute 'addEventListener' on 'EventTarget': parameter 2 is not of type 'Object'.");
      }
      let capture = false;
      let once = false;
      let signal;
      if (typeof options === 'boolean') {
        capture = options;
      } else if (options !== undefined && options !== null) {
        capture = Boolean(options.capture);
        once = Boolean(options.once);
        signal = options.signal;
        if (signal !== undefined && signal !== null && !internal.isAbortSignal(signal)) {
          throw new TypeError("Failed to execute 'addEventListener' on 'EventTarget': member signal is not of type AbortSignal.");
        }
      }
      if (signal !== undefined && signal !== null && signal.aborted) return;
      const key = String(type);
      let list = this.#listeners.get(key);
      if (list === undefined) {
        list = [];
        this.#listeners.set(key, list);
      }
      for (const entry of list) {
        if (entry.callback === callback && entry.capture === capture) return;
      }
      const entry = { callback, capture, once, removed: false };
      list.push(entry);
      if (signal !== undefined && signal !== null) {
        signal.addEventListener('abort', () => { this.#remove(key, entry); }, { once: true });
      }
    }

    removeEventListener(type, callback, options = undefined) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'removeEventListener' on 'EventTarget': 2 arguments required.");
      }
      const capture = typeof options === 'boolean' ? options
        : options !== undefined && options !== null ? Boolean(options.capture) : false;
      const key = String(type);
      const list = this.#listeners.get(key);
      if (list === undefined) return;
      for (const entry of list) {
        if (entry.callback === callback && entry.capture === capture) {
          this.#remove(key, entry);
          return;
        }
      }
    }

    dispatchEvent(event) {
      if (!eventAccess.is(event)) {
        throw new TypeError("Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'.");
      }
      if (eventAccess.dispatching(event)) {
        throw new DOMException("Failed to execute 'dispatchEvent' on 'EventTarget': The event is already being dispatched.", 'InvalidStateError');
      }
      return this.#dispatch(event, false);
    }

    #remove(key, entry) {
      entry.removed = true;
      const list = this.#listeners.get(key);
      if (list === undefined) return;
      const index = list.indexOf(entry);
      if (index >= 0) list.splice(index, 1);
    }

    #dispatch(event, trusted) {
      const list = this.#listeners.get(event.type);
      eventAccess.begin(event, this, trusted);
      try {
        if (list !== undefined) {
          for (const entry of list.slice()) {
            if (entry.removed) continue;
            if (entry.once) this.#remove(event.type, entry);
            try {
              if (typeof entry.callback === 'function') entry.callback.call(this, event);
              else if (typeof entry.callback.handleEvent === 'function') entry.callback.handleEvent(event);
            } catch (error) {
              reportError(error);
            }
            if (eventAccess.stopImmediate(event)) break;
          }
        }
      } finally {
        eventAccess.end(event);
      }
      return !eventAccess.defaultPrevented(event);
    }

    static {
      isEventTarget = (value) => typeof value === 'object' && value !== null && #listeners in value;
      dispatchTrusted = (target, event) => target.#dispatch(event, true);
    }
  }
  Object.defineProperty(EventTarget.prototype, Symbol.toStringTag, { value: 'EventTarget', configurable: true });

  let createSignal;
  let signalAbort;
  let isAbortSignal;
  class AbortSignal extends EventTarget {
    #aborted = false;
    #reason = undefined;
    #onabort = null;

    constructor(key = undefined) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
      super();
    }
    get aborted() { return this.#aborted; }
    get reason() { return this.#reason; }
    throwIfAborted() { if (this.#aborted) throw this.#reason; }
    get onabort() { return this.#onabort; }
    set onabort(value) {
      if (this.#onabort !== null) this.removeEventListener('abort', this.#onabort);
      this.#onabort = typeof value === 'function' ? value : null;
      if (this.#onabort !== null) this.addEventListener('abort', this.#onabort);
    }
    static abort(reason = undefined) {
      const signal = new AbortSignal(illegal);
      signalAbort(signal, reason);
      return signal;
    }
    static timeout(milliseconds) {
      const signal = new AbortSignal(illegal);
      g.setTimeout(() => {
        signalAbort(signal, new DOMException('The operation was aborted due to timeout', 'TimeoutError'));
      }, milliseconds);
      return signal;
    }
    static any(signals) {
      const list = Array.from(signals);
      const result = new AbortSignal(illegal);
      for (const signal of list) {
        if (!isAbortSignal(signal)) {
          throw new TypeError("Failed to execute 'any' on 'AbortSignal': parameter 1 is not of type 'AbortSignal'.");
        }
      }
      for (const signal of list) {
        if (signal.aborted) {
          signalAbort(result, signal.reason);
          return result;
        }
      }
      for (const signal of list) {
        signal.addEventListener('abort', () => { signalAbort(result, signal.reason); }, { once: true });
      }
      return result;
    }
    [customInspect]() {
      return 'AbortSignal { aborted: ' + this.#aborted + ' }';
    }
    static {
      isAbortSignal = (value) => typeof value === 'object' && value !== null && #aborted in value;
      createSignal = () => new AbortSignal(illegal);
      signalAbort = (signal, reason) => {
        if (signal.#aborted) return;
        signal.#aborted = true;
        signal.#reason = reason === undefined
          ? new DOMException('signal is aborted without reason', 'AbortError')
          : reason;
        dispatchTrusted(signal, new Event('abort'));
      };
    }
  }
  Object.defineProperty(AbortSignal.prototype, Symbol.toStringTag, { value: 'AbortSignal', configurable: true });

  class AbortController {
    #signal = createSignal();
    get signal() { return this.#signal; }
    abort(reason = undefined) { signalAbort(this.#signal, reason); }
    [customInspect]() {
      return 'AbortController { signal: ' + this.#signal[customInspect]() + ' }';
    }
  }
  Object.defineProperty(AbortController.prototype, Symbol.toStringTag, { value: 'AbortController', configurable: true });

  cloneHooks.push((value) => {
    if (eventAccess.is(value) || isEventTarget(value)) {
      throw new DOMException('An object could not be cloned.', 'DataCloneError');
    }
    return NOT_CLONED;
  });

  Object.assign(internal, { Event, EventTarget, isAbortSignal, signalAbort, createSignal, dispatchTrusted });

  define(g, 'Event', Event);
  define(g, 'CustomEvent', CustomEvent);
  define(g, 'EventTarget', EventTarget);
  define(g, 'AbortController', AbortController);
  define(g, 'AbortSignal', AbortSignal);
})
''';
