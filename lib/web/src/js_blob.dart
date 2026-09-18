part of '../web_apis.dart';

/// `Blob`, `File` and `FormData`.
const String _jsBlob = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const {
    define, customInspect, cloneHooks, NOT_CLONED, DOMException, illegal,
    bufferSourceBytes, createReadableStream, controllerEnqueue, controllerClose, makeReadable,
  } = internal;

  function normalizeType(type) {
    const text = String(type);
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      if (code < 0x20 || code > 0x7e) return '';
    }
    return text.toLowerCase();
  }
  function concatBytes(chunks, total) {
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  }

  let getBlobBytes;
  let createBlob;
  let isBlob;
  class Blob {
    #bytes;
    #type;

    constructor(blobParts = undefined, options = undefined) {
      if (blobParts === illegal) {
        this.#bytes = options.bytes;
        this.#type = options.type;
        return;
      }
      const init = options === undefined || options === null ? {} : options;
      const native = String(init.endings === undefined ? 'transparent' : init.endings) === 'native';
      const chunks = [];
      let total = 0;
      if (blobParts !== undefined && blobParts !== null) {
        if (typeof blobParts[Symbol.iterator] !== 'function') {
          throw new TypeError("Failed to construct 'Blob': The provided value cannot be converted to a sequence.");
        }
        for (const part of blobParts) {
          let chunk;
          const inner = getBlobBytes(part);
          if (inner !== null) {
            chunk = inner;
          } else {
            const view = bufferSourceBytes(part);
            if (view !== null) {
              chunk = view.slice();
            } else {
              let text = String(part);
              if (native) text = text.replace(/\r\n|\r|\n/g, '\n');
              chunk = natives.utf8Encode(text);
            }
          }
          chunks.push(chunk);
          total += chunk.length;
        }
      }
      this.#bytes = concatBytes(chunks, total);
      this.#type = normalizeType(init.type === undefined ? '' : init.type);
    }

    get size() { return this.#bytes.length; }
    get type() { return this.#type; }

    slice(start = undefined, end = undefined, contentType = undefined) {
      const size = this.#bytes.length;
      let from = start === undefined ? 0 : Math.trunc(Number(start)) || 0;
      let to = end === undefined ? size : Math.trunc(Number(end)) || 0;
      if (from < 0) from = Math.max(size + from, 0);
      else from = Math.min(from, size);
      if (to < 0) to = Math.max(size + to, 0);
      else to = Math.min(to, size);
      const span = Math.max(to - from, 0);
      return createBlob(this.#bytes.slice(from, from + span),
        contentType === undefined ? '' : normalizeType(contentType));
    }
    arrayBuffer() {
      const bytes = this.#bytes;
      return Promise.resolve(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
    }
    bytes() { return Promise.resolve(this.#bytes.slice()); }
    text() { return Promise.resolve(natives.utf8Decode(this.#bytes, false)); }
    stream() {
      const bytes = this.#bytes;
      let done = false;
      const impl = createReadableStream(() => undefined, () => {
        if (done) return undefined;
        done = true;
        if (bytes.length > 0) controllerEnqueue(impl.controller, bytes.slice());
        controllerClose(impl.controller);
        return undefined;
      }, () => undefined);
      return makeReadable(impl);
    }
    [customInspect]() {
      return this.constructor.name + ' { size: ' + this.#bytes.length + ', type: ' + JSON.stringify(this.#type) + ' }';
    }
    static {
      isBlob = (value) => typeof value === 'object' && value !== null && #bytes in value;
      getBlobBytes = (value) => (typeof value === 'object' && value !== null && #bytes in value ? value.#bytes : null);
      createBlob = (bytes, type) => new Blob(illegal, { bytes, type });
    }
  }
  Object.defineProperty(Blob.prototype, Symbol.toStringTag, { value: 'Blob', configurable: true });

  let createFile;
  class File extends Blob {
    #name;
    #lastModified;
    constructor(fileBits, fileName, options = undefined) {
      if (fileBits === illegal) {
        super(illegal, options);
        this.#name = options.name;
        this.#lastModified = options.lastModified;
        return;
      }
      if (arguments.length < 2) {
        throw new TypeError("Failed to construct 'File': 2 arguments required.");
      }
      const init = options === undefined || options === null ? {} : options;
      super(fileBits, init);
      this.#name = String(fileName);
      this.#lastModified = init.lastModified === undefined ? Date.now() : Math.trunc(Number(init.lastModified));
    }
    get name() { return this.#name; }
    get lastModified() { return this.#lastModified; }
    get webkitRelativePath() { return ''; }
    [customInspect]() {
      return 'File { name: ' + JSON.stringify(this.#name) + ', size: ' + this.size +
        ', type: ' + JSON.stringify(this.type) + ' }';
    }
    static {
      createFile = (bytes, name, type, lastModified) =>
        new File(illegal, undefined, { bytes, type, name, lastModified });
    }
  }
  Object.defineProperty(File.prototype, Symbol.toStringTag, { value: 'File', configurable: true });

  function toFormValue(name, value, filename) {
    if (isBlob(value)) {
      const bytes = getBlobBytes(value);
      const isFile = value instanceof File;
      const resolvedName = filename !== undefined ? String(filename)
        : isFile ? value.name : 'blob';
      return createFile(bytes.slice(), resolvedName, value.type,
        isFile ? value.lastModified : Date.now());
    }
    if (filename !== undefined) {
      throw new TypeError("Failed to execute 'append' on 'FormData': parameter 2 is not of type 'Blob'.");
    }
    return String(value);
  }

  let formDataEntries;
  let isFormData;
  class FormData {
    #entries = [];
    constructor(form = undefined) {
      if (form !== undefined && form !== null) {
        throw new TypeError("Failed to construct 'FormData': parameter 1 is not of type 'HTMLFormElement'.");
      }
    }
    append(name, value, filename = undefined) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'append' on 'FormData': 2 arguments required.");
      }
      this.#entries.push([String(name), toFormValue(name, value, filename)]);
    }
    set(name, value, filename = undefined) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'set' on 'FormData': 2 arguments required.");
      }
      const key = String(name);
      const entry = [key, toFormValue(name, value, filename)];
      let replaced = false;
      const next = [];
      for (const existing of this.#entries) {
        if (existing[0] !== key) {
          next.push(existing);
          continue;
        }
        if (replaced) continue;
        replaced = true;
        next.push(entry);
      }
      if (!replaced) next.push(entry);
      this.#entries = next;
    }
    delete(name) {
      const key = String(name);
      this.#entries = this.#entries.filter((entry) => entry[0] !== key);
    }
    get(name) {
      const key = String(name);
      for (const entry of this.#entries) if (entry[0] === key) return entry[1];
      return null;
    }
    getAll(name) {
      const key = String(name);
      return this.#entries.filter((entry) => entry[0] === key).map((entry) => entry[1]);
    }
    has(name) {
      const key = String(name);
      return this.#entries.some((entry) => entry[0] === key);
    }
    forEach(callback, thisArg = undefined) {
      for (const entry of this.#entries.slice()) callback.call(thisArg, entry[1], entry[0], this);
    }
    *entries() { for (const entry of this.#entries.slice()) yield [entry[0], entry[1]]; }
    *keys() { for (const entry of this.#entries.slice()) yield entry[0]; }
    *values() { for (const entry of this.#entries.slice()) yield entry[1]; }
    [Symbol.iterator]() { return this.entries(); }
    [customInspect]() {
      return 'FormData { ' + this.#entries.map((entry) => JSON.stringify(entry[0])).join(', ') + ' }';
    }
    static {
      isFormData = (value) => typeof value === 'object' && value !== null && #entries in value;
      formDataEntries = (value) => value.#entries;
    }
  }
  Object.defineProperty(FormData.prototype, Symbol.toStringTag, { value: 'FormData', configurable: true });

  cloneHooks.push((value, memory, cloneValue) => {
    if (!isBlob(value)) return NOT_CLONED;
    const bytes = getBlobBytes(value).slice();
    const clone = value instanceof File
      ? createFile(bytes, value.name, value.type, value.lastModified)
      : createBlob(bytes, value.type);
    memory.set(value, clone);
    return clone;
  });
  cloneHooks.push((value, memory) => {
    if (!isFormData(value)) return NOT_CLONED;
    const clone = new FormData();
    memory.set(value, clone);
    for (const entry of formDataEntries(value)) {
      const copy = isBlob(entry[1])
        ? (entry[1] instanceof File
          ? createFile(getBlobBytes(entry[1]).slice(), entry[1].name, entry[1].type, entry[1].lastModified)
          : createBlob(getBlobBytes(entry[1]).slice(), entry[1].type))
        : entry[1];
      formDataEntries(clone).push([entry[0], copy]);
    }
    return clone;
  });

  Object.assign(internal, {
    Blob, File, FormData, isBlob, getBlobBytes, createBlob, createFile, isFormData, formDataEntries,
  });

  define(g, 'Blob', Blob);
  define(g, 'File', File);
  define(g, 'FormData', FormData);
})
''';
