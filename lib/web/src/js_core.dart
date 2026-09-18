part of '../web_apis.dart';

/// Core primitives shared by every other module.
///
/// Completion value: `(natives, host) => { fire, install }`, where
/// `install(name, moduleFn, moduleHost)` runs
/// `moduleFn(moduleHost, internal, natives)` and records [name] for `has`, so
/// later modules share private helpers without touching `globalThis`.
///
/// Module conventions (checked by `web_apis_internal_names_test.dart`): a
/// module reads `internal` once, in a leading `const { ... } = internal;`, and
/// writes it only through `Object.assign(internal, { ... })`. Names from an
/// optional dependency are used only behind `has('<module>')`.
const String _jsCore = r'''
(function (natives, host) {
  'use strict';
  const g = globalThis;
  const internal = { __proto__: null };
  const illegal = Symbol('illegal constructor');
  const ReflectApply = Reflect.apply;
  const ObjectDefineProperty = Object.defineProperty;
  const ObjectGetOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  const ObjectGetPrototypeOf = Object.getPrototypeOf;

  function define(target, name, value) {
    ObjectDefineProperty(target, name, { value, writable: true, enumerable: false, configurable: true });
  }
  function getter(proto, name) {
    const desc = ObjectGetOwnPropertyDescriptor(proto, name);
    return desc === undefined ? undefined : desc.get;
  }
  function brand(fn, value) {
    try {
      ReflectApply(fn, value, []);
      return true;
    } catch (e) {
      return false;
    }
  }

  // Intrinsics captured before any user code runs.
  const objectToString = Object.prototype.toString;
  const functionToString = Function.prototype.toString;
  const TypedArrayPrototype = ObjectGetPrototypeOf(Uint8Array.prototype);
  const taTag = getter(TypedArrayPrototype, Symbol.toStringTag);
  const taBuffer = getter(TypedArrayPrototype, 'buffer');
  const taByteOffset = getter(TypedArrayPrototype, 'byteOffset');
  const taByteLength = getter(TypedArrayPrototype, 'byteLength');
  const taLength = getter(TypedArrayPrototype, 'length');
  const dvBuffer = getter(DataView.prototype, 'buffer');
  const dvByteOffset = getter(DataView.prototype, 'byteOffset');
  const dvByteLength = getter(DataView.prototype, 'byteLength');
  const abByteLength = getter(ArrayBuffer.prototype, 'byteLength');
  const abDetached = getter(ArrayBuffer.prototype, 'detached');
  const abSlice = ArrayBuffer.prototype.slice;
  const abTransfer = ArrayBuffer.prototype.transfer;
  const mapSize = getter(Map.prototype, 'size');
  const mapForEach = Map.prototype.forEach;
  const mapSet = Map.prototype.set;
  const setSize = getter(Set.prototype, 'size');
  const setForEach = Set.prototype.forEach;
  const setAdd = Set.prototype.add;
  const dateGetTime = Date.prototype.getTime;
  const dateToISOString = Date.prototype.toISOString;
  const regexpSource = getter(RegExp.prototype, 'source');
  const regexpFlags = getter(RegExp.prototype, 'flags');
  const regexpToString = RegExp.prototype.toString;
  const promiseThen = Promise.prototype.then;
  const resolvedPromise = Promise.resolve();
  const typedArrays = { __proto__: null };
  for (const name of ['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array',
    'Int32Array', 'Uint32Array', 'Float16Array', 'Float32Array', 'Float64Array',
    'BigInt64Array', 'BigUint64Array']) {
    if (typeof g[name] === 'function') typedArrays[name] = g[name];
  }
  const errorConstructors = {
    __proto__: null, Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError,
  };
  const customInspect = Symbol.for('nodejs.util.inspect.custom');

  function isArrayBuffer(value) {
    return typeof value === 'object' && value !== null && brand(abByteLength, value);
  }
  function typedArrayTag(value) {
    return ArrayBuffer.isView(value) ? ReflectApply(taTag, value, []) : undefined;
  }
  // Uint8Array over the bytes of a BufferSource, or null.
  function bufferSourceBytes(value) {
    if (ArrayBuffer.isView(value)) {
      if (ReflectApply(taTag, value, []) !== undefined) {
        return new Uint8Array(ReflectApply(taBuffer, value, []),
          ReflectApply(taByteOffset, value, []), ReflectApply(taByteLength, value, []));
      }
      return new Uint8Array(ReflectApply(dvBuffer, value, []),
        ReflectApply(dvByteOffset, value, []), ReflectApply(dvByteLength, value, []));
    }
    if (isArrayBuffer(value)) return new Uint8Array(value);
    return null;
  }

  // ---- DOMException ----
  const legacyCodes = [
    ['INDEX_SIZE_ERR', 1, 'IndexSizeError'], ['DOMSTRING_SIZE_ERR', 2, ''],
    ['HIERARCHY_REQUEST_ERR', 3, 'HierarchyRequestError'], ['WRONG_DOCUMENT_ERR', 4, 'WrongDocumentError'],
    ['INVALID_CHARACTER_ERR', 5, 'InvalidCharacterError'], ['NO_DATA_ALLOWED_ERR', 6, ''],
    ['NO_MODIFICATION_ALLOWED_ERR', 7, 'NoModificationAllowedError'], ['NOT_FOUND_ERR', 8, 'NotFoundError'],
    ['NOT_SUPPORTED_ERR', 9, 'NotSupportedError'], ['INUSE_ATTRIBUTE_ERR', 10, 'InUseAttributeError'],
    ['INVALID_STATE_ERR', 11, 'InvalidStateError'], ['SYNTAX_ERR', 12, 'SyntaxError'],
    ['INVALID_MODIFICATION_ERR', 13, 'InvalidModificationError'], ['NAMESPACE_ERR', 14, 'NamespaceError'],
    ['INVALID_ACCESS_ERR', 15, 'InvalidAccessError'], ['VALIDATION_ERR', 16, ''],
    ['TYPE_MISMATCH_ERR', 17, 'TypeMismatchError'], ['SECURITY_ERR', 18, 'SecurityError'],
    ['NETWORK_ERR', 19, 'NetworkError'], ['ABORT_ERR', 20, 'AbortError'],
    ['URL_MISMATCH_ERR', 21, 'URLMismatchError'], ['QUOTA_EXCEEDED_ERR', 22, 'QuotaExceededError'],
    ['TIMEOUT_ERR', 23, 'TimeoutError'], ['INVALID_NODE_TYPE_ERR', 24, 'InvalidNodeTypeError'],
    ['DATA_CLONE_ERR', 25, 'DataCloneError'],
  ];
  const codeByName = { __proto__: null };
  for (const [, code, name] of legacyCodes) if (name) codeByName[name] = code;

  let isDOMException;
  class DOMException extends Error {
    #name;
    #message;
    constructor(message = '', options = undefined) {
      super();
      this.#message = String(message);
      if (options !== null && typeof options === 'object') {
        this.#name = options.name === undefined ? 'Error' : String(options.name);
        if ('cause' in options) define(this, 'cause', options.cause);
      } else {
        this.#name = options === undefined ? 'Error' : String(options);
      }
    }
    get name() { return this.#name; }
    get message() { return this.#message; }
    get code() { return codeByName[this.#name] || 0; }
    static {
      isDOMException = (value) => #name in value;
    }
  }
  for (const [constant, code] of legacyCodes) {
    ObjectDefineProperty(DOMException, constant, { value: code, enumerable: true });
    ObjectDefineProperty(DOMException.prototype, constant, { value: code, enumerable: true });
  }
  ObjectDefineProperty(DOMException.prototype, Symbol.toStringTag, { value: 'DOMException', configurable: true });

  function isError(value) {
    return ReflectApply(objectToString, value, []) === '[object Error]' || isDOMException(value);
  }

  // ---- inspection / formatting (console, reportError) ----
  const MAX_DEPTH = 2;
  const MAX_ITEMS = 100;
  const identifierPattern = /^[A-Za-z_$][\w$]*$/;

  function quote(text) {
    return "'" + text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n') + "'";
  }
  function list(prefix, open, items, close) {
    return items.length === 0 ? prefix + open + close : prefix + open + ' ' + items.join(', ') + ' ' + close;
  }
  function functionLabel(fn) {
    let source = '';
    try { source = ReflectApply(functionToString, fn, []); } catch (e) {}
    const name = typeof fn.name === 'string' ? fn.name : '';
    if (source.startsWith('class')) return '[class ' + (name || '(anonymous)') + ']';
    return name ? '[Function: ' + name + ']' : '[Function (anonymous)]';
  }
  function constructorName(value) {
    let proto = ObjectGetPrototypeOf(value);
    if (proto === null) return null;
    while (proto !== null) {
      const desc = ObjectGetOwnPropertyDescriptor(proto, 'constructor');
      if (desc !== undefined && typeof desc.value === 'function' && typeof desc.value.name === 'string' &&
        desc.value.name !== '') {
        return desc.value.name;
      }
      proto = ObjectGetPrototypeOf(proto);
    }
    return 'Object';
  }
  function errorHeader(error) {
    let name;
    let message;
    try {
      name = error.name;
      message = error.message;
    } catch (e) {}
    name = name === undefined ? 'Error' : String(name);
    message = message === undefined ? '' : String(message);
    return message === '' ? name : name + ': ' + message;
  }
  function errorWithStack(error) {
    const header = errorHeader(error);
    let stack;
    try { stack = error.stack; } catch (e) {}
    if (typeof stack !== 'string' || stack === '') return header;
    stack = stack.replace(/\s+$/, '');
    return stack.startsWith(header) ? stack : header + '\n' + stack;
  }

  function inspect(value, depth, seen) {
    switch (typeof value) {
      case 'string': return quote(value);
      case 'number': return Object.is(value, -0) ? '-0' : '' + value;
      case 'bigint': return value + 'n';
      case 'boolean': return '' + value;
      case 'undefined': return 'undefined';
      case 'symbol': return String(value);
      case 'function': return functionLabel(value);
    }
    if (value === null) return 'null';
    if (seen.indexOf(value) !== -1) return '[Circular]';
    try {
      return inspectObject(value, depth, seen);
    } catch (e) {
      return '[object ' + (constructorName(value) || 'Object') + ']';
    }
  }

  function inspectObject(value, depth, seen) {
    if (typeof value[customInspect] === 'function') {
      const custom = value[customInspect](MAX_DEPTH - depth, {}, (v) => inspect(v, depth + 1, seen));
      return typeof custom === 'string' ? custom : inspect(custom, depth, seen);
    }
    if (isError(value)) return depth === 0 ? errorWithStack(value) : '[' + errorHeader(value) + ']';
    const name = constructorName(value);
    if (Array.isArray(value)) {
      if (depth > MAX_DEPTH) return '[Array]';
      seen.push(value);
      const items = [];
      const length = value.length;
      let holes = 0;
      const shown = Math.min(length, MAX_ITEMS);
      for (let i = 0; i < shown; i++) {
        if (!(i in value)) {
          holes++;
          continue;
        }
        if (holes > 0) {
          items.push('<' + holes + ' empty item' + (holes > 1 ? 's' : '') + '>');
          holes = 0;
        }
        items.push(inspect(value[i], depth + 1, seen));
      }
      if (holes > 0) items.push('<' + holes + ' empty item' + (holes > 1 ? 's' : '') + '>');
      if (length > MAX_ITEMS) items.push('... ' + (length - MAX_ITEMS) + ' more items');
      seen.pop();
      return list(name === 'Array' ? '' : name + '(' + length + ') ', '[', items, ']');
    }
    const taName = typedArrayTag(value);
    if (taName !== undefined) {
      const length = ReflectApply(taLength, value, []);
      const items = [];
      for (let i = 0; i < Math.min(length, MAX_ITEMS); i++) items.push(inspect(value[i], depth + 1, seen));
      if (length > MAX_ITEMS) items.push('... ' + (length - MAX_ITEMS) + ' more items');
      return list(taName + '(' + length + ') ', '[', items, ']');
    }
    const tag = ReflectApply(objectToString, value, []);
    switch (tag) {
      case '[object ArrayBuffer]':
        if (brand(abByteLength, value)) return 'ArrayBuffer { byteLength: ' + ReflectApply(abByteLength, value, []) + ' }';
        break;
      case '[object DataView]':
        if (brand(dvByteLength, value)) {
          return 'DataView { byteLength: ' + ReflectApply(dvByteLength, value, []) +
            ', byteOffset: ' + ReflectApply(dvByteOffset, value, []) + ' }';
        }
        break;
      case '[object Date]':
        if (brand(dateGetTime, value)) {
          return Number.isNaN(ReflectApply(dateGetTime, value, [])) ? 'Invalid Date' : ReflectApply(dateToISOString, value, []);
        }
        break;
      case '[object RegExp]':
        if (brand(regexpSource, value)) return ReflectApply(regexpToString, value, []);
        break;
      case '[object Map]':
        if (brand(mapSize, value)) {
          if (depth > MAX_DEPTH) return '[Map]';
          seen.push(value);
          const items = [];
          ReflectApply(mapForEach, value, [(v, k) => {
            if (items.length < MAX_ITEMS) items.push(inspect(k, depth + 1, seen) + ' => ' + inspect(v, depth + 1, seen));
          }]);
          seen.pop();
          return list(name + '(' + ReflectApply(mapSize, value, []) + ') ', '{', items, '}');
        }
        break;
      case '[object Set]':
        if (brand(setSize, value)) {
          if (depth > MAX_DEPTH) return '[Set]';
          seen.push(value);
          const items = [];
          ReflectApply(setForEach, value, [(v) => {
            if (items.length < MAX_ITEMS) items.push(inspect(v, depth + 1, seen));
          }]);
          seen.pop();
          return list(name + '(' + ReflectApply(setSize, value, []) + ') ', '{', items, '}');
        }
        break;
      case '[object Promise]':
        return 'Promise {}';
      case '[object WeakMap]':
      case '[object WeakSet]':
      case '[object WeakRef]':
        return tag.slice(8, -1) + ' { <items unknown> }';
      case '[object Number]':
      case '[object String]':
      case '[object Boolean]':
      case '[object BigInt]':
      case '[object Symbol]':
        try {
          return '[' + tag.slice(8, -1) + ': ' + inspect(value.valueOf(), depth + 1, seen) + ']';
        } catch (e) {}
        break;
    }
    if (depth > MAX_DEPTH) return '[' + (name || 'Object') + ']';
    seen.push(value);
    const items = [];
    for (const key of Reflect.ownKeys(value)) {
      const desc = ObjectGetOwnPropertyDescriptor(value, key);
      if (desc === undefined || !desc.enumerable) continue;
      const label = typeof key === 'symbol' ? '[' + String(key) + ']' : identifierPattern.test(key) ? key : quote(key);
      let text;
      if (desc.get !== undefined || desc.set !== undefined) {
        text = desc.get !== undefined && desc.set !== undefined ? '[Getter/Setter]' : desc.get !== undefined ? '[Getter]' : '[Setter]';
      } else {
        text = inspect(desc.value, depth + 1, seen);
      }
      items.push(label + ': ' + text);
      if (items.length >= MAX_ITEMS) break;
    }
    seen.pop();
    const prefix = name === null ? '[Object: null prototype] ' : name === 'Object' ? '' : name + ' ';
    return list(prefix, '{', items, '}');
  }

  // Node util.format-compatible substitution (%s %d %i %f %j %o %O %c %%).
  function formatArgs(args) {
    const first = args[0];
    let out = '';
    let index = 0;
    if (typeof first === 'string') {
      index = 1;
      let last = 0;
      for (let i = 0; i < first.length - 1; i++) {
        if (first.charCodeAt(i) !== 37) continue;
        const next = first.charCodeAt(i + 1);
        if (next === 37) {
          out += first.slice(last, i) + '%';
          last = i + 2;
          i++;
          continue;
        }
        if (index >= args.length) continue;
        const arg = args[index];
        let text;
        switch (next) {
          case 115: // s
            text = typeof arg === 'string' ? arg
              : typeof arg === 'bigint' ? arg + 'n'
                : (typeof arg === 'object' && arg !== null) || typeof arg === 'function' ? inspect(arg, 1, [])
                  : String(arg);
            break;
          case 100: // d
          case 105: // i
            text = typeof arg === 'bigint' ? arg + 'n'
              : typeof arg === 'symbol' ? 'NaN'
                : '' + (next === 105 ? parseInt(arg) : Number(arg));
            break;
          case 102: // f
            text = typeof arg === 'symbol' ? 'NaN' : '' + parseFloat(arg);
            break;
          case 106: // j
            try { text = JSON.stringify(arg); } catch (e) { text = '[Circular]'; }
            break;
          case 111: // o
          case 79: // O
            text = inspect(arg, 0, []);
            break;
          case 99: // c
            text = '';
            break;
          default:
            continue;
        }
        out += first.slice(last, i) + text;
        last = i + 2;
        i++;
        index++;
      }
      out += first.slice(last);
    }
    for (; index < args.length; index++) {
      const arg = args[index];
      if (index > 0) out += ' ';
      out += typeof arg === 'string' ? arg : inspect(arg, 0, []);
    }
    return out;
  }

  function reportError(error) {
    if (arguments.length === 0) {
      throw new TypeError("Failed to execute 'reportError': 1 argument required, but only 0 present.");
    }
    host.log('error', 'Uncaught ' + inspect(error, 0, []));
  }

  // ---- console ----
  const counts = new Map();
  const timings = new Map();
  let groupIndent = '';
  const clock = natives !== undefined ? natives.now : Date.now;

  function emit(level, args) {
    let message = formatArgs(args);
    if (groupIndent !== '') message = groupIndent + message.split('\n').join('\n' + groupIndent);
    host.log(level, message);
  }
  function label(value) {
    return value === undefined ? 'default' : String(value);
  }
  function group(...args) {
    if (args.length > 0) emit('log', args);
    groupIndent += '  ';
  }
  function elapsed(name) {
    return name + ': ' + (Math.round((clock() - timings.get(name)) * 1000) / 1000) + 'ms';
  }
  const console = {
    log(...args) { emit('log', args); },
    info(...args) { emit('info', args); },
    debug(...args) { emit('debug', args); },
    warn(...args) { emit('warn', args); },
    error(...args) { emit('error', args); },
    trace(...args) {
      const stack = String(new Error().stack || '').replace(/\s+$/, '');
      emit('trace', ['Trace' + (args.length > 0 ? ': ' + formatArgs(args) : '') + (stack ? '\n' + stack : '')]);
    },
    assert(condition, ...args) {
      if (condition) return;
      if (typeof args[0] === 'string') args[0] = 'Assertion failed: ' + args[0];
      else args.unshift('Assertion failed');
      emit('error', args);
    },
    dir(value) { emit('log', [inspect(value, 0, [])]); },
    dirxml(...args) { emit('log', args); },
    table(...args) { emit('log', args); },
    count(name = undefined) {
      const key = label(name);
      const count = (counts.get(key) || 0) + 1;
      counts.set(key, count);
      emit('info', [key + ': ' + count]);
    },
    countReset(name = undefined) {
      const key = label(name);
      if (counts.has(key)) counts.set(key, 0);
      else emit('warn', ["Count for '" + key + "' does not exist"]);
    },
    group,
    groupCollapsed: group,
    groupEnd() { groupIndent = groupIndent.slice(2); },
    time(name = undefined) {
      const key = label(name);
      if (timings.has(key)) emit('warn', ["Timer '" + key + "' already exists"]);
      else timings.set(key, clock());
    },
    timeLog(name = undefined, ...args) {
      const key = label(name);
      if (!timings.has(key)) emit('warn', ["Timer '" + key + "' does not exist"]);
      else emit('info', [elapsed(key), ...args]);
    },
    timeEnd(name = undefined) {
      const key = label(name);
      if (!timings.has(key)) {
        emit('warn', ["Timer '" + key + "' does not exist"]);
        return;
      }
      emit('info', [elapsed(key)]);
      timings.delete(key);
    },
    clear() {},
  };
  ObjectDefineProperty(console, Symbol.toStringTag, { value: 'console', configurable: true });

  // ---- timers ----
  const timers = new Map();
  let nextTimerId = 1;

  function startTimer(handler, timeout, args, repeat) {
    let callback = handler;
    if (typeof handler !== 'function') {
      const code = String(handler);
      callback = function () { (0, eval)(code); };
    }
    let delay = Math.trunc(Number(timeout));
    if (!(delay > 0) || delay > 2147483647) delay = 0;
    const id = nextTimerId++;
    timers.set(id, { callback, args, repeat });
    host.schedule(id, delay, repeat);
    return id;
  }
  function clearTimer(id) {
    const key = Number(id);
    if (timers.delete(key)) host.cancel(key);
  }
  function fire(id) {
    const timer = timers.get(id);
    if (timer === undefined) return;
    if (!timer.repeat) timers.delete(id);
    try {
      ReflectApply(timer.callback, g, timer.args);
    } catch (error) {
      reportError(error);
    }
  }
  function setTimeout(handler, timeout = 0, ...args) { return startTimer(handler, timeout, args, false); }
  function setInterval(handler, timeout = 0, ...args) { return startTimer(handler, timeout, args, true); }
  function clearTimeout(id = undefined) { clearTimer(id); }
  function clearInterval(id = undefined) { clearTimer(id); }

  function queueMicrotask(callback) {
    if (typeof callback !== 'function') {
      throw new TypeError("Failed to execute 'queueMicrotask': parameter 1 is not of type 'Function'.");
    }
    ReflectApply(promiseThen, resolvedPromise, [() => {
      try {
        callback();
      } catch (error) {
        reportError(error);
      }
    }]);
  }

  // ---- structuredClone ----
  const cloneHooks = [];
  const NOT_CLONED = Symbol('not cloned');

  function dataCloneError(what) {
    return new DOMException(what + ' could not be cloned.', 'DataCloneError');
  }
  function copyOwn(source, target, memory) {
    for (const key of Object.keys(source)) {
      ObjectDefineProperty(target, key, {
        value: cloneValue(source[key], memory), writable: true, enumerable: true, configurable: true,
      });
    }
  }
  function cloneValue(value, memory) {
    const type = typeof value;
    if (type === 'symbol') throw dataCloneError(String(value));
    if (type !== 'object' && type !== 'function') return value;
    if (value === null) return null;
    if (memory.has(value)) return memory.get(value);
    if (type === 'function') throw dataCloneError(functionLabel(value));
    let out;
    if (Array.isArray(value)) {
      out = new Array(value.length);
      memory.set(value, out);
      copyOwn(value, out, memory);
      return out;
    }
    if (ArrayBuffer.isView(value)) {
      const taName = ReflectApply(taTag, value, []);
      if (taName !== undefined) {
        const buffer = cloneValue(ReflectApply(taBuffer, value, []), memory);
        out = new typedArrays[taName](buffer, ReflectApply(taByteOffset, value, []), ReflectApply(taLength, value, []));
      } else {
        const buffer = cloneValue(ReflectApply(dvBuffer, value, []), memory);
        out = new DataView(buffer, ReflectApply(dvByteOffset, value, []), ReflectApply(dvByteLength, value, []));
      }
      memory.set(value, out);
      return out;
    }
    if (isDOMException(value)) {
      out = new DOMException(value.message, value.name);
      memory.set(value, out);
      return out;
    }
    switch (ReflectApply(objectToString, value, [])) {
      case '[object ArrayBuffer]':
        if (!brand(abByteLength, value)) break;
        if (abDetached !== undefined && ReflectApply(abDetached, value, [])) {
          throw new DOMException('An ArrayBuffer is detached and could not be cloned.', 'DataCloneError');
        }
        out = ReflectApply(abSlice, value, []);
        memory.set(value, out);
        return out;
      case '[object Date]':
        if (!brand(dateGetTime, value)) break;
        out = new Date(ReflectApply(dateGetTime, value, []));
        memory.set(value, out);
        return out;
      case '[object RegExp]':
        if (!brand(regexpSource, value)) break;
        out = new RegExp(ReflectApply(regexpSource, value, []), ReflectApply(regexpFlags, value, []));
        memory.set(value, out);
        return out;
      case '[object Boolean]':
      case '[object Number]':
      case '[object String]':
      case '[object BigInt]': {
        let primitive = NOT_CLONED;
        try { primitive = value.valueOf(); } catch (e) {}
        if (primitive === NOT_CLONED || typeof primitive === 'object') break;
        out = Object(primitive);
        memory.set(value, out);
        return out;
      }
      case '[object Map]': {
        if (!brand(mapSize, value)) break;
        out = new Map();
        memory.set(value, out);
        const entries = [];
        ReflectApply(mapForEach, value, [(v, k) => { entries.push(k, v); }]);
        for (let i = 0; i < entries.length; i += 2) {
          ReflectApply(mapSet, out, [cloneValue(entries[i], memory), cloneValue(entries[i + 1], memory)]);
        }
        return out;
      }
      case '[object Set]': {
        if (!brand(setSize, value)) break;
        out = new Set();
        memory.set(value, out);
        const entries = [];
        ReflectApply(setForEach, value, [(v) => { entries.push(v); }]);
        for (const entry of entries) ReflectApply(setAdd, out, [cloneValue(entry, memory)]);
        return out;
      }
      case '[object Error]': {
        const name = value.name;
        const Ctor = typeof name === 'string' && errorConstructors[name] !== undefined ? errorConstructors[name] : Error;
        out = new Ctor();
        memory.set(value, out);
        const message = ObjectGetOwnPropertyDescriptor(value, 'message');
        if (message !== undefined && 'value' in message) define(out, 'message', String(message.value));
        const stack = ObjectGetOwnPropertyDescriptor(value, 'stack');
        if (stack !== undefined && typeof stack.value === 'string') define(out, 'stack', stack.value);
        if (Object.prototype.hasOwnProperty.call(value, 'cause')) define(out, 'cause', cloneValue(value.cause, memory));
        return out;
      }
      case '[object WeakMap]':
      case '[object WeakSet]':
      case '[object WeakRef]':
      case '[object Promise]':
      case '[object Symbol]':
        throw dataCloneError('#<' + (constructorName(value) || 'Object') + '>');
    }
    for (const hook of cloneHooks) {
      const result = hook(value, memory, cloneValue);
      if (result !== NOT_CLONED) return result;
    }
    out = {};
    memory.set(value, out);
    copyOwn(value, out, memory);
    return out;
  }

  function structuredClone(value, options = undefined) {
    if (arguments.length === 0) {
      throw new TypeError("Failed to execute 'structuredClone': 1 argument required, but only 0 present.");
    }
    let transfer = [];
    if (options !== undefined && options !== null) {
      if (typeof options !== 'object' && typeof options !== 'function') {
        throw new TypeError("Failed to execute 'structuredClone': The provided value is not of type 'StructuredSerializeOptions'.");
      }
      if (options.transfer !== undefined) transfer = Array.from(options.transfer);
    }
    const transferred = new Set();
    for (const buffer of transfer) {
      if (!isArrayBuffer(buffer)) throw new DOMException('Value not transferable', 'DataCloneError');
      if (transferred.has(buffer)) throw new DOMException('ArrayBuffer is duplicated in the transfer list.', 'DataCloneError');
      if (abDetached !== undefined && ReflectApply(abDetached, buffer, [])) {
        throw new DOMException('An ArrayBuffer is detached and could not be cloned.', 'DataCloneError');
      }
      transferred.add(buffer);
    }
    const result = cloneValue(value, new Map());
    // Detach only after serialization succeeded.
    for (const buffer of transferred) ReflectApply(abTransfer, buffer, []);
    return result;
  }

  // ---- base64 ----
  const BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const BASE64_LOOKUP = new Int16Array(128).fill(-1);
  for (let i = 0; i < BASE64.length; i++) BASE64_LOOKUP[BASE64.charCodeAt(i)] = i;

  function btoa(data) {
    if (arguments.length === 0) throw new TypeError("Failed to execute 'btoa': 1 argument required, but only 0 present.");
    data = String(data);
    const length = data.length;
    let out = '';
    for (let i = 0; i < length; i += 3) {
      const a = data.charCodeAt(i);
      const b = i + 1 < length ? data.charCodeAt(i + 1) : 0;
      const c = i + 2 < length ? data.charCodeAt(i + 2) : 0;
      if (a > 255 || b > 255 || c > 255) {
        throw new DOMException('The string to be encoded contains characters outside of the Latin1 range.', 'InvalidCharacterError');
      }
      const triple = (a << 16) | (b << 8) | c;
      out += BASE64[(triple >> 18) & 63] + BASE64[(triple >> 12) & 63] +
        (i + 1 < length ? BASE64[(triple >> 6) & 63] : '=') + (i + 2 < length ? BASE64[triple & 63] : '=');
    }
    return out;
  }
  function atob(data) {
    if (arguments.length === 0) throw new TypeError("Failed to execute 'atob': 1 argument required, but only 0 present.");
    data = String(data).replace(/[\t\n\f\r ]/g, '');
    if (data.length % 4 === 0) data = data.replace(/==?$/, '');
    if (data.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(data)) {
      throw new DOMException('The string to be decoded is not correctly encoded.', 'InvalidCharacterError');
    }
    let out = '';
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < data.length; i++) {
      buffer = ((buffer << 6) | BASE64_LOOKUP[data.charCodeAt(i)]) & 0xffffff;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((buffer >> bits) & 0xff);
      }
    }
    return out;
  }

  // ---- performance ----
  const clockOrigin = clock();
  const timeOrigin = Date.now();
  class Performance {
    constructor(key = undefined) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
    }
    get timeOrigin() { return timeOrigin; }
    now() { return clock() - clockOrigin; }
    toJSON() { return { timeOrigin }; }
  }
  ObjectDefineProperty(Performance.prototype, Symbol.toStringTag, { value: 'Performance', configurable: true });

  // ---- crypto (random values; subtle is installed by the web module) ----
  const HEX = [];
  for (let i = 0; i < 256; i++) HEX.push((i + 256).toString(16).slice(1));
  let uuidPool = null;
  let uuidOffset = 0;
  class Crypto {
    constructor(key = undefined) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
    }
    getRandomValues(array) {
      if (arguments.length === 0) {
        throw new TypeError("Failed to execute 'getRandomValues' on 'Crypto': 1 argument required, but only 0 present.");
      }
      if (!ArrayBuffer.isView(array)) {
        throw new TypeError("Failed to execute 'getRandomValues' on 'Crypto': parameter 1 is not of type 'ArrayBufferView'.");
      }
      const taName = ReflectApply(taTag, array, []);
      if (taName === undefined || taName === 'Float16Array' || taName === 'Float32Array' || taName === 'Float64Array') {
        throw new DOMException("The provided ArrayBufferView is of type '" + (taName || 'DataView') +
          "', which is not an integer array type.", 'TypeMismatchError');
      }
      const byteLength = ReflectApply(taByteLength, array, []);
      if (byteLength > 65536) {
        throw new DOMException("The ArrayBufferView's byte length (" + byteLength +
          ') exceeds the number of bytes of entropy available via this API (65536).', 'QuotaExceededError');
      }
      if (byteLength > 0) {
        new Uint8Array(ReflectApply(taBuffer, array, []), ReflectApply(taByteOffset, array, []), byteLength)
          .set(host.randomBytes(byteLength));
      }
      return array;
    }
    randomUUID() {
      if (uuidPool === null || uuidOffset + 16 > uuidPool.length) {
        uuidPool = host.randomBytes(256);
        uuidOffset = 0;
      }
      const b = uuidPool;
      const o = uuidOffset;
      uuidOffset += 16;
      b[o + 6] = (b[o + 6] & 0x0f) | 0x40;
      b[o + 8] = (b[o + 8] & 0x3f) | 0x80;
      return HEX[b[o]] + HEX[b[o + 1]] + HEX[b[o + 2]] + HEX[b[o + 3]] + '-' +
        HEX[b[o + 4]] + HEX[b[o + 5]] + '-' + HEX[b[o + 6]] + HEX[b[o + 7]] + '-' +
        HEX[b[o + 8]] + HEX[b[o + 9]] + '-' + HEX[b[o + 10]] + HEX[b[o + 11]] +
        HEX[b[o + 12]] + HEX[b[o + 13]] + HEX[b[o + 14]] + HEX[b[o + 15]];
    }
  }
  ObjectDefineProperty(Crypto.prototype, Symbol.toStringTag, { value: 'Crypto', configurable: true });

  // ---- install ----
  define(g, 'DOMException', DOMException);
  define(g, 'console', console);
  define(g, 'setTimeout', setTimeout);
  define(g, 'setInterval', setInterval);
  define(g, 'clearTimeout', clearTimeout);
  define(g, 'clearInterval', clearInterval);
  define(g, 'queueMicrotask', queueMicrotask);
  define(g, 'reportError', reportError);
  define(g, 'structuredClone', structuredClone);
  define(g, 'atob', atob);
  define(g, 'btoa', btoa);
  define(g, 'Performance', Performance);
  define(g, 'performance', new Performance(illegal));
  define(g, 'Crypto', Crypto);
  define(g, 'crypto', new Crypto(illegal));

  // Modules installed so far, for code that uses an optional dependency.
  const installed = new Set(['core']);
  const has = (name) => installed.has(name);

  // Brand checks for types owned by other modules. Without the owning module no
  // such object can exist, so `false` is the right answer; `events` and `blob`
  // replace these when they install.
  const isAbortSignal = (value) => false;
  const isBlob = (value) => false;
  const isFormData = (value) => false;

  Object.assign(internal, {
    illegal, define, brand, getter, isArrayBuffer, typedArrayTag, bufferSourceBytes,
    DOMException, reportError, inspect, customInspect, cloneHooks, NOT_CLONED, Crypto, clock,
    has, isAbortSignal, isBlob, isFormData,
  });

  return {
    fire,
    install(name, moduleFn, moduleHost) {
      const exports = moduleFn(moduleHost, internal, natives);
      installed.add(name);
      return exports;
    },
  };
})
''';
