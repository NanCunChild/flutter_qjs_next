part of '../web_apis.dart';

/// `crypto.subtle`: SHA digests and HMAC only.
///
/// Every other algorithm rejects with `NotSupportedError`.
const String _jsCrypto = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const { define, DOMException, illegal, bufferSourceBytes, customInspect, Crypto } = internal;

  const HASHES = new Set(['SHA-1', 'SHA-256', 'SHA-384', 'SHA-512']);
  const JWK_ALG = { __proto__: null, 'SHA-1': 'HS1', 'SHA-256': 'HS256', 'SHA-384': 'HS384', 'SHA-512': 'HS512' };
  const BLOCK_BYTES = { __proto__: null, 'SHA-1': 64, 'SHA-256': 64, 'SHA-384': 128, 'SHA-512': 128 };

  function notSupported(what) {
    return new DOMException(what + ' is not supported by this runtime', 'NotSupportedError');
  }
  function algorithmName(algorithm) {
    if (typeof algorithm === 'string') return algorithm;
    if (algorithm !== null && typeof algorithm === 'object' && algorithm.name !== undefined) {
      return String(algorithm.name);
    }
    throw new TypeError('Algorithm: Not an object');
  }
  function normalizeHash(algorithm) {
    const name = algorithmName(algorithm).toUpperCase();
    return HASHES.has(name) ? name : null;
  }
  function toBytes(data, method) {
    const view = bufferSourceBytes(data);
    if (view === null) {
      throw new TypeError("Failed to execute '" + method + "' on 'SubtleCrypto': parameter is not of type 'BufferSource'.");
    }
    return view;
  }
  function toArrayBuffer(bytes) {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
  }
  function base64urlEncode(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return g.btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function base64urlDecode(text) {
    const binary = g.atob(String(text).replace(/-/g, '+').replace(/_/g, '/'));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }
  function checkUsages(usages, allowed) {
    const list = Array.from(usages === undefined ? [] : usages, (usage) => String(usage));
    for (const usage of list) {
      if (!allowed.includes(usage)) {
        throw new SyntaxError('Cannot create a key using the specified key usages: ' + usage);
      }
    }
    return list;
  }

  let keyBytes;
  let createKey;
  class CryptoKey {
    #type;
    #extractable;
    #algorithm;
    #usages;
    #bytes;
    constructor(key, init) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
      this.#type = init.type;
      this.#extractable = init.extractable;
      this.#algorithm = init.algorithm;
      this.#usages = init.usages;
      this.#bytes = init.bytes;
    }
    get type() { return this.#type; }
    get extractable() { return this.#extractable; }
    get algorithm() { return this.#algorithm; }
    get usages() { return this.#usages.slice(); }
    [customInspect]() {
      return 'CryptoKey { type: ' + JSON.stringify(this.#type) + ', algorithm: ' + this.#algorithm.name + ' }';
    }
    static {
      keyBytes = (value) => (typeof value === 'object' && value !== null && #bytes in value ? value.#bytes : null);
      createKey = (init) => new CryptoKey(illegal, init);
    }
  }
  Object.defineProperty(CryptoKey.prototype, Symbol.toStringTag, { value: 'CryptoKey', configurable: true });

  function hmacKeyFromBytes(bytes, hash, extractable, usages) {
    return createKey({
      type: 'secret', extractable: Boolean(extractable), usages,
      algorithm: { name: 'HMAC', hash: { name: hash }, length: bytes.length * 8 },
      bytes: bytes.slice(),
    });
  }
  function requireHmacKey(key, usage, method) {
    const bytes = keyBytes(key);
    if (bytes === null || key.algorithm.name !== 'HMAC') {
      throw new TypeError("Failed to execute '" + method + "' on 'SubtleCrypto': parameter is not a valid HMAC CryptoKey.");
    }
    if (!key.usages.includes(usage)) {
      throw new DOMException('key.usages does not permit this operation', 'InvalidAccessError');
    }
    return bytes;
  }

  class SubtleCrypto {
    constructor(key = undefined) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
    }

    digest(algorithm, data) {
      return new Promise((resolve) => {
        const hash = normalizeHash(algorithm);
        if (hash === null) throw notSupported(algorithmName(algorithm));
        resolve(toArrayBuffer(host.digest(hash, toBytes(data, 'digest'))));
      });
    }

    importKey(format, keyData, algorithm, extractable, keyUsages) {
      return new Promise((resolve) => {
        if (algorithmName(algorithm).toUpperCase() !== 'HMAC') {
          throw notSupported(algorithmName(algorithm));
        }
        const hash = normalizeHash(algorithm.hash);
        if (hash === null) throw notSupported('HMAC hash ' + String(algorithm.hash));
        const usages = checkUsages(keyUsages, ['sign', 'verify']);
        let bytes;
        if (format === 'raw') {
          bytes = toBytes(keyData, 'importKey');
        } else if (format === 'jwk') {
          if (keyData === null || typeof keyData !== 'object' || keyData.kty !== 'oct') {
            throw new DOMException('Invalid JWK key', 'DataError');
          }
          bytes = base64urlDecode(keyData.k);
        } else {
          throw notSupported("Key format '" + String(format) + "'");
        }
        resolve(hmacKeyFromBytes(bytes, hash, extractable, usages));
      });
    }

    generateKey(algorithm, extractable, keyUsages) {
      return new Promise((resolve) => {
        if (algorithmName(algorithm).toUpperCase() !== 'HMAC') {
          throw notSupported(algorithmName(algorithm));
        }
        const hash = normalizeHash(algorithm.hash);
        if (hash === null) throw notSupported('HMAC hash ' + String(algorithm.hash));
        const usages = checkUsages(keyUsages, ['sign', 'verify']);
        const bits = algorithm.length === undefined ? BLOCK_BYTES[hash] * 8 : Math.trunc(Number(algorithm.length));
        if (!(bits > 0)) throw new DOMException('Invalid key length', 'OperationError');
        const bytes = new Uint8Array(Math.ceil(bits / 8));
        g.crypto.getRandomValues(bytes);
        resolve(hmacKeyFromBytes(bytes, hash, extractable, usages));
      });
    }

    exportKey(format, key) {
      return new Promise((resolve) => {
        const bytes = keyBytes(key);
        if (bytes === null) {
          throw new TypeError("Failed to execute 'exportKey' on 'SubtleCrypto': parameter 2 is not of type 'CryptoKey'.");
        }
        if (!key.extractable) {
          throw new DOMException('key is not extractable', 'InvalidAccessError');
        }
        if (format === 'raw') {
          resolve(toArrayBuffer(bytes.slice()));
          return;
        }
        if (format === 'jwk') {
          resolve({
            kty: 'oct', k: base64urlEncode(bytes), alg: JWK_ALG[key.algorithm.hash.name],
            key_ops: key.usages, ext: key.extractable,
          });
          return;
        }
        throw notSupported("Key format '" + String(format) + "'");
      });
    }

    sign(algorithm, key, data) {
      return new Promise((resolve) => {
        if (algorithmName(algorithm).toUpperCase() !== 'HMAC') {
          throw notSupported(algorithmName(algorithm));
        }
        const bytes = requireHmacKey(key, 'sign', 'sign');
        resolve(toArrayBuffer(host.hmac(key.algorithm.hash.name, bytes, toBytes(data, 'sign'))));
      });
    }

    verify(algorithm, key, signature, data) {
      return new Promise((resolve) => {
        if (algorithmName(algorithm).toUpperCase() !== 'HMAC') {
          throw notSupported(algorithmName(algorithm));
        }
        const bytes = requireHmacKey(key, 'verify', 'verify');
        const expected = host.hmac(key.algorithm.hash.name, bytes, toBytes(data, 'verify'));
        const actual = toBytes(signature, 'verify');
        // Constant-time comparison.
        let diff = expected.length ^ actual.length;
        for (let i = 0; i < expected.length && i < actual.length; i++) diff |= expected[i] ^ actual[i];
        resolve(diff === 0);
      });
    }

    encrypt() { return Promise.reject(notSupported('encrypt')); }
    decrypt() { return Promise.reject(notSupported('decrypt')); }
    deriveBits() { return Promise.reject(notSupported('deriveBits')); }
    deriveKey() { return Promise.reject(notSupported('deriveKey')); }
    wrapKey() { return Promise.reject(notSupported('wrapKey')); }
    unwrapKey() { return Promise.reject(notSupported('unwrapKey')); }
  }
  Object.defineProperty(SubtleCrypto.prototype, Symbol.toStringTag, { value: 'SubtleCrypto', configurable: true });

  const subtle = new SubtleCrypto(illegal);
  Object.defineProperty(Crypto.prototype, 'subtle', {
    get() { return subtle; },
    enumerable: false,
    configurable: true,
  });

  define(g, 'SubtleCrypto', SubtleCrypto);
  define(g, 'CryptoKey', CryptoKey);
})
''';
