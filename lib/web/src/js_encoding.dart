part of '../web_apis.dart';

/// L1 encoding: `TextEncoder` and `TextDecoder` (UTF-8 only), backed by the
/// native UTF-8 helpers.
const String _jsEncoding = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const { define, bufferSourceBytes, typedArrayTag } = internal;

  class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(input = '') { return natives.utf8Encode(String(input)); }
    encodeInto(source, destination) {
      if (typedArrayTag(destination) !== 'Uint8Array') {
        throw new TypeError("Failed to execute 'encodeInto' on 'TextEncoder': parameter 2 is not of type 'Uint8Array'.");
      }
      const result = natives.utf8EncodeInto(String(source), destination);
      return { read: result[0], written: result[1] };
    }
  }
  Object.defineProperty(TextEncoder.prototype, Symbol.toStringTag, { value: 'TextEncoder', configurable: true });

  // Only UTF-8 is supported; every label for it is accepted.
  const UTF8_LABELS = new Set(['unicode-1-1-utf-8', 'unicode11utf8', 'unicode20utf8', 'utf-8', 'utf8', 'x-unicode20utf8']);

  // Bytes at the end that are a prefix of a longer sequence, kept for the next
  // chunk in streaming mode.
  function incompleteTail(bytes) {
    const length = bytes.length;
    for (let back = 1; back <= 3 && back <= length; back++) {
      const byte = bytes[length - back];
      if (byte < 0x80) return 0;
      if (byte >= 0xc0) {
        const needed = byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
        return needed > back ? back : 0;
      }
    }
    return 0;
  }

  class TextDecoder {
    #fatal;
    #ignoreBOM;
    #pending = null;
    #bomSeen = false;

    constructor(label = 'utf-8', options = undefined) {
      const key = String(label).trim().toLowerCase();
      if (!UTF8_LABELS.has(key)) {
        throw new RangeError("Failed to construct 'TextDecoder': The encoding label provided ('" + label + "') is invalid.");
      }
      const init = options === undefined || options === null ? {} : options;
      this.#fatal = Boolean(init.fatal);
      this.#ignoreBOM = Boolean(init.ignoreBOM);
    }
    get encoding() { return 'utf-8'; }
    get fatal() { return this.#fatal; }
    get ignoreBOM() { return this.#ignoreBOM; }

    decode(input = undefined, options = undefined) {
      const stream = options === undefined || options === null ? false : Boolean(options.stream);
      let bytes;
      if (input === undefined) {
        bytes = new Uint8Array(0);
      } else {
        bytes = bufferSourceBytes(input);
        if (bytes === null) {
          throw new TypeError("Failed to execute 'decode' on 'TextDecoder': parameter 1 is not of type 'BufferSource'.");
        }
      }
      if (this.#pending !== null) {
        const merged = new Uint8Array(this.#pending.length + bytes.length);
        merged.set(this.#pending);
        merged.set(bytes, this.#pending.length);
        bytes = merged;
        this.#pending = null;
      }
      if (!this.#ignoreBOM && !this.#bomSeen) {
        if (bytes.length >= 3) {
          if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) bytes = bytes.subarray(3);
          this.#bomSeen = true;
        } else if (stream && bytes.length > 0 &&
          (bytes[0] === 0xef && (bytes.length < 2 || bytes[1] === 0xbb))) {
          this.#pending = bytes.slice();
          return '';
        } else {
          this.#bomSeen = true;
        }
      }
      if (stream) {
        const tail = incompleteTail(bytes);
        if (tail > 0) {
          this.#pending = bytes.slice(bytes.length - tail);
          bytes = bytes.subarray(0, bytes.length - tail);
        }
      }
      const text = natives.utf8Decode(bytes, this.#fatal);
      if (!stream) {
        this.#pending = null;
        this.#bomSeen = false;
      }
      return text;
    }
  }
  Object.defineProperty(TextDecoder.prototype, Symbol.toStringTag, { value: 'TextDecoder', configurable: true });

  Object.assign(internal, { TextEncoder, TextDecoder });

  define(g, 'TextEncoder', TextEncoder);
  define(g, 'TextDecoder', TextDecoder);
})
''';
