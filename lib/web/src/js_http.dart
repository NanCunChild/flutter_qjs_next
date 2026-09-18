part of '../web_apis.dart';

/// HTTP types: `Headers`, `Request`, `Response` and the body mixin. `fetch`
/// itself lives in the `fetch` module. `blob()` and `formData()` exist only
/// when `blob` is installed.
const String _jsHttp = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const {
    define, customInspect, cloneHooks, NOT_CLONED, DOMException, illegal, has,
    bufferSourceBytes, isBlob, isFormData,
    FormData, getBlobBytes, createBlob, createFile, formDataEntries,
    URLSearchParams, searchParamsPairs, serializeFormUrlencoded, parseFormUrlencoded, parseURL, serializeURL,
    isAbortSignal, createSignal, signalAbort,
    createReadableStream, controllerEnqueue, controllerClose, controllerError,
    makeReadable, getReadable, acquireReader, readerRead, readerRelease, readableCancel,
  } = internal;

  const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
  const INVALID_VALUE = /[\u0000\r\n]/;
  const HTTP_WHITESPACE = /^[\t\n\f\r ]+|[\t\n\f\r ]+$/g;
  const FORBIDDEN_METHODS = new Set(['CONNECT', 'TRACE', 'TRACK']);
  const NORMALIZED_METHODS = new Set(['DELETE', 'GET', 'HEAD', 'OPTIONS', 'POST', 'PUT']);
  const NULL_BODY_STATUS = new Set([101, 103, 204, 205, 304]);

  function checkName(name, action) {
    const text = String(name);
    if (!TOKEN.test(text)) {
      throw new TypeError("Failed to execute '" + action + "' on 'Headers': Invalid name");
    }
    return text.toLowerCase();
  }
  function checkValue(value, action) {
    const text = String(value).replace(HTTP_WHITESPACE, '');
    if (INVALID_VALUE.test(text)) {
      throw new TypeError("Failed to execute '" + action + "' on 'Headers': Invalid value");
    }
    return text;
  }

  let createHeaders;
  let headersList;
  let headersGuard;
  class Headers {
    #list = [];
    #guard = 'none';

    constructor(init = undefined) {
      if (init === undefined || init === null) return;
      if (init === illegal) return;
      this.#fill(init);
    }
    #fill(init) {
      if (typeof init === 'object' && typeof init[Symbol.iterator] === 'function') {
        for (const entry of init) {
          const pair = Array.from(entry);
          if (pair.length !== 2) {
            throw new TypeError("Failed to construct 'Headers': Invalid value");
          }
          this.append(pair[0], pair[1]);
        }
        return;
      }
      if (typeof init === 'object') {
        for (const key of Object.keys(init)) this.append(key, init[key]);
        return;
      }
      throw new TypeError("Failed to construct 'Headers': The provided value is not of type 'HeadersInit'.");
    }
    #checkMutable(action) {
      if (this.#guard === 'immutable') {
        throw new TypeError("Failed to execute '" + action + "' on 'Headers': Headers are immutable");
      }
    }
    append(name, value) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'append' on 'Headers': 2 arguments required.");
      }
      this.#checkMutable('append');
      this.#list.push([checkName(name, 'append'), checkValue(value, 'append')]);
    }
    set(name, value) {
      if (arguments.length < 2) {
        throw new TypeError("Failed to execute 'set' on 'Headers': 2 arguments required.");
      }
      this.#checkMutable('set');
      const key = checkName(name, 'set');
      const text = checkValue(value, 'set');
      let replaced = false;
      const next = [];
      for (const entry of this.#list) {
        if (entry[0] !== key) {
          next.push(entry);
          continue;
        }
        if (replaced) continue;
        replaced = true;
        next.push([key, text]);
      }
      if (!replaced) next.push([key, text]);
      this.#list = next;
    }
    delete(name) {
      this.#checkMutable('delete');
      const key = checkName(name, 'delete');
      this.#list = this.#list.filter((entry) => entry[0] !== key);
    }
    get(name) {
      const key = checkName(name, 'get');
      const values = this.#list.filter((entry) => entry[0] === key).map((entry) => entry[1]);
      return values.length === 0 ? null : values.join(', ');
    }
    getSetCookie() {
      return this.#list.filter((entry) => entry[0] === 'set-cookie').map((entry) => entry[1]);
    }
    has(name) {
      const key = checkName(name, 'has');
      return this.#list.some((entry) => entry[0] === key);
    }
    #sorted() {
      const names = [...new Set(this.#list.map((entry) => entry[0]))].sort();
      const out = [];
      for (const name of names) {
        if (name === 'set-cookie') {
          for (const entry of this.#list) if (entry[0] === name) out.push([name, entry[1]]);
        } else {
          out.push([name, this.get(name)]);
        }
      }
      return out;
    }
    forEach(callback, thisArg = undefined) {
      for (const entry of this.#sorted()) callback.call(thisArg, entry[1], entry[0], this);
    }
    *entries() { for (const entry of this.#sorted()) yield [entry[0], entry[1]]; }
    *keys() { for (const entry of this.#sorted()) yield entry[0]; }
    *values() { for (const entry of this.#sorted()) yield entry[1]; }
    [Symbol.iterator]() { return this.entries(); }
    [customInspect]() {
      return 'Headers { ' + this.#sorted().map((e) => e[0] + ': ' + JSON.stringify(e[1])).join(', ') + ' }';
    }
    static {
      headersList = (headers) => headers.#list;
      headersGuard = (headers, guard) => {
        if (guard !== undefined) headers.#guard = guard;
        return headers.#guard;
      };
      createHeaders = (list, guard) => {
        const headers = new Headers(illegal);
        headers.#list = list;
        headers.#guard = guard === undefined ? 'none' : guard;
        return headers;
      };
    }
  }
  Object.defineProperty(Headers.prototype, Symbol.toStringTag, { value: 'Headers', configurable: true });

  // ---- body ----
  function randomBoundary() {
    return '----flutterqjsformboundary' + g.crypto.randomUUID().replace(/-/g, '');
  }
  function formDataBytes(formData, boundary) {
    const chunks = [];
    let total = 0;
    const push = (text) => {
      const bytes = natives.utf8Encode(text);
      chunks.push(bytes);
      total += bytes.length;
    };
    const pushBytes = (bytes) => {
      chunks.push(bytes);
      total += bytes.length;
    };
    const escape = (text) => String(text).replace(/\n/g, '%0A').replace(/\r/g, '%0D').replace(/"/g, '%22');
    for (const entry of formDataEntries(formData)) {
      push('--' + boundary + '\r\n');
      if (isBlob(entry[1])) {
        const file = entry[1];
        push('Content-Disposition: form-data; name="' + escape(entry[0]) + '"; filename="' +
          escape(file.name === undefined ? 'blob' : file.name) + '"\r\n');
        push('Content-Type: ' + (file.type === '' ? 'application/octet-stream' : file.type) + '\r\n\r\n');
        pushBytes(getBlobBytes(file));
        push('\r\n');
      } else {
        push('Content-Disposition: form-data; name="' + escape(entry[0]) + '"\r\n\r\n');
        push(entry[1] + '\r\n');
      }
    }
    push('--' + boundary + '--\r\n');
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  }

  // Returns { source, stream, length, type }.
  function extractBody(body, keepalive) {
    if (body === null || body === undefined) return null;
    if (typeof body === 'string') {
      const bytes = natives.utf8Encode(body);
      return { source: bytes, stream: null, length: bytes.length, type: 'text/plain;charset=UTF-8' };
    }
    if (isBlob(body)) {
      const bytes = getBlobBytes(body);
      return { source: bytes, stream: null, length: bytes.length, type: body.type === '' ? null : body.type };
    }
    if (body instanceof URLSearchParams) {
      const bytes = natives.utf8Encode(serializeFormUrlencoded(searchParamsPairs(body)));
      return {
        source: bytes, stream: null, length: bytes.length,
        type: 'application/x-www-form-urlencoded;charset=UTF-8',
      };
    }
    if (isFormData(body)) {
      const boundary = randomBoundary();
      const bytes = formDataBytes(body, boundary);
      return {
        source: bytes, stream: null, length: bytes.length,
        type: 'multipart/form-data; boundary=' + boundary,
      };
    }
    const view = bufferSourceBytes(body);
    if (view !== null) {
      const bytes = view.slice();
      return { source: bytes, stream: null, length: bytes.length, type: null };
    }
    const stream = getReadable(body);
    if (stream !== null) {
      return { source: null, stream: body, length: null, type: null };
    }
    const bytes = natives.utf8Encode(String(body));
    return { source: bytes, stream: null, length: bytes.length, type: 'text/plain;charset=UTF-8' };
  }

  function bytesToStream(bytes) {
    let done = false;
    let impl;
    impl = createReadableStream(() => undefined, () => {
      if (done) return undefined;
      done = true;
      if (bytes.length > 0) controllerEnqueue(impl.controller, bytes.slice());
      controllerClose(impl.controller);
      return undefined;
    }, () => undefined);
    return makeReadable(impl);
  }

  async function readAll(stream) {
    const reader = acquireReader(getReadable(stream));
    const chunks = [];
    let total = 0;
    try {
      for (;;) {
        const result = await readerRead(reader);
        if (result.done) break;
        const view = bufferSourceBytes(result.value);
        if (view === null) {
          throw new TypeError('Body stream chunks must be BufferSource values');
        }
        chunks.push(view);
        total += view.length;
      }
    } finally {
      readerRelease(reader);
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  }

  function parseMultipart(bytes, boundary) {
    const formData = new FormData();
    const entries = formDataEntries(formData);
    const marker = natives.utf8Encode('--' + boundary);
    const indexOf = (needle, from) => {
      outer: for (let i = from; i <= bytes.length - needle.length; i++) {
        for (let j = 0; j < needle.length; j++) if (bytes[i + j] !== needle[j]) continue outer;
        return i;
      }
      return -1;
    };
    const crlfcrlf = natives.utf8Encode('\r\n\r\n');
    let position = indexOf(marker, 0);
    while (position >= 0) {
      const start = position + marker.length;
      if (bytes[start] === 0x2d && bytes[start + 1] === 0x2d) break;
      const next = indexOf(marker, start);
      const end = next < 0 ? bytes.length : next;
      const headerEnd = indexOf(crlfcrlf, start);
      if (headerEnd < 0 || headerEnd > end) break;
      const headerText = natives.utf8Decode(bytes.subarray(start, headerEnd), false);
      let body = bytes.subarray(headerEnd + 4, end);
      if (body.length >= 2 && body[body.length - 2] === 0x0d && body[body.length - 1] === 0x0a) {
        body = body.subarray(0, body.length - 2);
      }
      let name = null;
      let filename;
      let contentType = '';
      for (const line of headerText.split('\r\n')) {
        const colon = line.indexOf(':');
        if (colon < 0) continue;
        const key = line.slice(0, colon).trim().toLowerCase();
        const value = line.slice(colon + 1).trim();
        if (key === 'content-type') contentType = value;
        if (key !== 'content-disposition') continue;
        const nameMatch = /name="([^"]*)"/.exec(value);
        const fileMatch = /filename="([^"]*)"/.exec(value);
        if (nameMatch !== null) name = nameMatch[1];
        if (fileMatch !== null) filename = fileMatch[1];
      }
      if (name !== null) {
        entries.push([name, filename === undefined
          ? natives.utf8Decode(body, false)
          : createFile(body.slice(), filename, contentType, Date.now())]);
      }
      position = next;
    }
    return formData;
  }

  // Per spec the body is used once its stream has been disturbed, even when
  // the consumer read the stream directly instead of calling text()/json().
  function isBodyUsed(state) {
    if (state.bodyUsed) return true;
    if (state.body === null || state.body.stream === null) return false;
    return getReadable(state.body.stream).disturbed;
  }

  // `state` is the shared body record of Request / Response.
  function bodyStream(state) {
    if (state.body === null) return null;
    if (state.body.stream === null) state.body.stream = bytesToStream(state.body.source);
    return state.body.stream;
  }
  async function consumeBody(state, kind) {
    if (isBodyUsed(state)) {
      throw new TypeError('Body has already been consumed.');
    }
    state.bodyUsed = true;
    let bytes;
    if (state.body === null) bytes = new Uint8Array(0);
    else if (state.body.source !== null && state.body.stream === null) bytes = state.body.source;
    else bytes = await readAll(state.body.stream);
    switch (kind) {
      case 'text':
        return natives.utf8Decode(bytes, false);
      case 'json':
        return JSON.parse(natives.utf8Decode(bytes, false));
      case 'bytes':
        return bytes.slice();
      case 'arrayBuffer':
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
      case 'blob': {
        const type = state.headers.get('content-type');
        return createBlob(bytes.slice(), type === null ? '' : type);
      }
      case 'formData': {
        const type = state.headers.get('content-type');
        if (type !== null && type.toLowerCase().startsWith('multipart/form-data')) {
          const match = /boundary=("?)([^";]+)\1/.exec(type);
          if (match === null) throw new TypeError('Missing multipart boundary');
          return parseMultipart(bytes, match[2]);
        }
        if (type !== null && type.toLowerCase().startsWith('application/x-www-form-urlencoded')) {
          const formData = new FormData();
          const entries = formDataEntries(formData);
          for (const pair of parseFormUrlencoded(natives.utf8Decode(bytes, false))) {
            entries.push([pair[0], pair[1]]);
          }
          return formData;
        }
        throw new TypeError('Body cannot be decoded as form data');
      }
      default:
        throw new TypeError('Unsupported body type');
    }
  }
  function cloneBodyState(state) {
    if (state.body === null) return null;
    if (state.body.stream === null) {
      return { source: state.body.source, stream: null, length: state.body.length, type: state.body.type };
    }
    const [a, b] = state.body.stream.tee();
    state.body.stream = a;
    return { source: null, stream: b, length: state.body.length, type: state.body.type };
  }

  let requestState;
  let createRequest;
  class Request {
    #state;

    constructor(input, init = undefined) {
      if (input === illegal) {
        this.#state = init;
        return;
      }
      if (arguments.length === 0) {
        throw new TypeError("Failed to construct 'Request': 1 argument required, but only 0 present.");
      }
      const options = init === undefined || init === null ? {} : init;
      const source = requestState(input);
      let url;
      let method = 'GET';
      let headerList = [];
      let body = null;
      let signal = null;
      let redirect = 'follow';
      let credentials = 'same-origin';
      let mode = 'cors';
      let cache = 'default';
      let referrer = 'about:client';
      let integrity = '';
      let keepalive = false;

      if (source !== null) {
        url = source.url;
        method = source.method;
        headerList = headersList(source.headers).map((entry) => [entry[0], entry[1]]);
        signal = source.signal;
        redirect = source.redirect;
        credentials = source.credentials;
        mode = source.mode;
        cache = source.cache;
        referrer = source.referrer;
        integrity = source.integrity;
        keepalive = source.keepalive;
        if (options.body === undefined && source.body !== null) {
          // The spec transfers the body: the source request becomes unusable.
          if (isBodyUsed(source)) {
            throw new TypeError("Failed to construct 'Request': Request body is already used.");
          }
          body = source.body;
          source.bodyUsed = true;
        }
      } else {
        const record = parseURL(String(input));
        if (record === null) {
          throw new TypeError("Failed to construct 'Request': Invalid URL: " + String(input));
        }
        url = serializeURL(record);
      }

      if (options.method !== undefined) {
        const raw = String(options.method);
        const upper = raw.toUpperCase();
        if (!TOKEN.test(raw) || FORBIDDEN_METHODS.has(upper)) {
          throw new TypeError("Failed to construct 'Request': '" + raw + "' is not a valid HTTP method.");
        }
        method = NORMALIZED_METHODS.has(upper) ? upper : raw;
      }
      if (options.redirect !== undefined) {
        redirect = String(options.redirect);
        if (redirect !== 'follow' && redirect !== 'error' && redirect !== 'manual') {
          throw new TypeError("Failed to construct 'Request': '" + redirect + "' is not a valid redirect mode.");
        }
      }
      if (options.credentials !== undefined) credentials = String(options.credentials);
      if (options.mode !== undefined) mode = String(options.mode);
      if (options.cache !== undefined) cache = String(options.cache);
      if (options.referrer !== undefined) referrer = String(options.referrer);
      if (options.integrity !== undefined) integrity = String(options.integrity);
      if (options.keepalive !== undefined) keepalive = Boolean(options.keepalive);
      if (options.signal !== undefined && options.signal !== null) {
        if (!isAbortSignal(options.signal)) {
          throw new TypeError("Failed to construct 'Request': member signal is not of type AbortSignal.");
        }
        signal = options.signal;
      }
      if (options.headers !== undefined) {
        const headers = new Headers(options.headers);
        headerList = headersList(headers).map((entry) => [entry[0], entry[1]]);
      }
      if (options.body !== undefined && options.body !== null) {
        if (method === 'GET' || method === 'HEAD') {
          throw new TypeError('Request with GET/HEAD method cannot have body.');
        }
        body = extractBody(options.body);
      }

      const headers = createHeaders(headerList, 'request');
      if (body !== null && body.type !== null && !headers.has('content-type')) {
        headersList(headers).push(['content-type', body.type]);
      }
      this.#state = {
        url, method, headers, body, bodyUsed: false, signal: signal === null ? createSignal() : signal,
        redirect, credentials, mode, cache, referrer, integrity, keepalive,
      };
    }

    get url() { return this.#state.url; }
    get method() { return this.#state.method; }
    get headers() { return this.#state.headers; }
    get redirect() { return this.#state.redirect; }
    get credentials() { return this.#state.credentials; }
    get mode() { return this.#state.mode; }
    get cache() { return this.#state.cache; }
    get referrer() { return this.#state.referrer; }
    get integrity() { return this.#state.integrity; }
    get keepalive() { return this.#state.keepalive; }
    get signal() { return this.#state.signal; }
    get destination() { return ''; }
    get isReloadNavigation() { return false; }
    get isHistoryNavigation() { return false; }
    get body() { return bodyStream(this.#state); }
    get bodyUsed() { return isBodyUsed(this.#state); }
    arrayBuffer() { return consumeBody(this.#state, 'arrayBuffer'); }
    blob() { return consumeBody(this.#state, 'blob'); }
    bytes() { return consumeBody(this.#state, 'bytes'); }
    formData() { return consumeBody(this.#state, 'formData'); }
    json() { return consumeBody(this.#state, 'json'); }
    text() { return consumeBody(this.#state, 'text'); }
    clone() {
      const state = this.#state;
      if (isBodyUsed(state)) {
        throw new TypeError("Failed to execute 'clone' on 'Request': Request body is already used.");
      }
      return createRequest({
        url: state.url, method: state.method,
        headers: createHeaders(headersList(state.headers).map((entry) => [entry[0], entry[1]]), 'request'),
        body: cloneBodyState(state), bodyUsed: false, signal: state.signal, redirect: state.redirect,
        credentials: state.credentials, mode: state.mode, cache: state.cache,
        referrer: state.referrer, integrity: state.integrity, keepalive: state.keepalive,
      });
    }
    [customInspect]() {
      return 'Request { method: ' + JSON.stringify(this.#state.method) + ', url: ' + JSON.stringify(this.#state.url) + ' }';
    }
    static {
      requestState = (value) => (typeof value === 'object' && value !== null && #state in value ? value.#state : null);
      createRequest = (state) => new Request(illegal, state);
    }
  }
  Object.defineProperty(Request.prototype, Symbol.toStringTag, { value: 'Request', configurable: true });

  let responseState;
  let createResponse;
  class Response {
    #state;

    constructor(body = undefined, init = undefined) {
      if (body === illegal) {
        this.#state = init;
        return;
      }
      const options = init === undefined || init === null ? {} : init;
      const status = options.status === undefined ? 200 : Math.trunc(Number(options.status));
      if (!(status >= 200 && status <= 599)) {
        throw new RangeError("Failed to construct 'Response': The status provided (" + status +
          ') is outside the range [200, 599].');
      }
      const statusText = options.statusText === undefined ? '' : String(options.statusText);
      const headers = options.headers === undefined ? new Headers() : new Headers(options.headers);
      let bodyState = null;
      if (body !== undefined && body !== null) {
        if (NULL_BODY_STATUS.has(status)) {
          throw new TypeError('Response with null body status cannot have body');
        }
        bodyState = extractBody(body);
        if (bodyState.type !== null && !headers.has('content-type')) {
          headersList(headers).push(['content-type', bodyState.type]);
        }
      }
      this.#state = {
        url: '', status, statusText, headers: createHeaders(headersList(headers), 'response'),
        body: bodyState, bodyUsed: false, type: 'default', redirected: false,
      };
    }

    static error() {
      return createResponse({
        url: '', status: 0, statusText: '', headers: createHeaders([], 'immutable'),
        body: null, bodyUsed: false, type: 'error', redirected: false,
      });
    }
    static redirect(url, status = 302) {
      const code = Math.trunc(Number(status));
      if (![301, 302, 303, 307, 308].includes(code)) {
        throw new RangeError("Failed to execute 'redirect' on 'Response': Invalid status code");
      }
      const record = parseURL(String(url));
      if (record === null) {
        throw new TypeError("Failed to execute 'redirect' on 'Response': Invalid URL");
      }
      return createResponse({
        url: '', status: code, statusText: '',
        headers: createHeaders([['location', serializeURL(record)]], 'immutable'),
        body: null, bodyUsed: false, type: 'default', redirected: false,
      });
    }
    static json(data, init = undefined) {
      const options = init === undefined || init === null ? {} : init;
      const text = JSON.stringify(data);
      if (text === undefined) throw new TypeError('The data is not JSON serializable');
      const response = new Response(text, options);
      const list = headersList(response.headers);
      const index = list.findIndex((entry) => entry[0] === 'content-type');
      if (index >= 0) list[index] = ['content-type', 'application/json'];
      else list.push(['content-type', 'application/json']);
      return response;
    }

    get type() { return this.#state.type; }
    get url() { return this.#state.url; }
    get redirected() { return this.#state.redirected; }
    get status() { return this.#state.status; }
    get ok() { return this.#state.status >= 200 && this.#state.status < 300; }
    get statusText() { return this.#state.statusText; }
    get headers() { return this.#state.headers; }
    get body() { return bodyStream(this.#state); }
    get bodyUsed() { return isBodyUsed(this.#state); }
    arrayBuffer() { return consumeBody(this.#state, 'arrayBuffer'); }
    blob() { return consumeBody(this.#state, 'blob'); }
    bytes() { return consumeBody(this.#state, 'bytes'); }
    formData() { return consumeBody(this.#state, 'formData'); }
    json() { return consumeBody(this.#state, 'json'); }
    text() { return consumeBody(this.#state, 'text'); }
    clone() {
      if (isBodyUsed(this.#state)) {
        throw new TypeError("Failed to execute 'clone' on 'Response': Response body is already used.");
      }
      const body = cloneBodyState(this.#state);
      return createResponse({
        url: this.#state.url, status: this.#state.status, statusText: this.#state.statusText,
        headers: createHeaders(headersList(this.#state.headers).map((e) => [e[0], e[1]]),
          this.#state.type === 'error' ? 'immutable' : 'response'),
        body, bodyUsed: false, type: this.#state.type, redirected: this.#state.redirected,
      });
    }
    [customInspect]() {
      return 'Response { status: ' + this.#state.status + ', url: ' + JSON.stringify(this.#state.url) + ' }';
    }
    static {
      responseState = (value) => (typeof value === 'object' && value !== null && #state in value ? value.#state : null);
      createResponse = (state) => new Response(illegal, state);
    }
  }
  Object.defineProperty(Response.prototype, Symbol.toStringTag, { value: 'Response', configurable: true });
  if (!has('blob')) {
    delete Request.prototype.blob;
    delete Request.prototype.formData;
    delete Response.prototype.blob;
    delete Response.prototype.formData;
  }

  cloneHooks.push((value) => {
    if (responseState(value) !== null || requestState(value) !== null ||
      (typeof value === 'object' && value !== null && value instanceof Headers)) {
      throw new DOMException('An object could not be cloned.', 'DataCloneError');
    }
    return NOT_CLONED;
  });

  Object.assign(internal, {
    Headers, Request, Response, createHeaders, headersList, headersGuard, requestState, createRequest,
    responseState, createResponse, extractBody, bytesToStream, consumeBody, formDataBytes,
  });

  define(g, 'Headers', Headers);
  define(g, 'Request', Request);
  define(g, 'Response', Response);
})
''';
