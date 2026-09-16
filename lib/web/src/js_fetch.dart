part of '../web_apis.dart';

/// L2 `fetch`. The network itself is performed by the Dart host; JS owns the
/// request/response objects and the back-pressured body stream.
const String _jsFetch = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const {
    define, Request, createResponse, createHeaders, headersList,
    createReadableStream, controllerEnqueue, controllerClose, controllerError, makeReadable,
  } = internal;

  const pending = new Map();
  let nextId = 1;

  function networkError(message) {
    return new TypeError('Failed to fetch: ' + message);
  }
  function cleanup(entry) {
    pending.delete(entry.id);
    if (entry.onAbort !== null) {
      entry.signal.removeEventListener('abort', entry.onAbort);
      entry.onAbort = null;
    }
  }

  function fetch(input, init = undefined) {
    let request;
    try {
      request = new Request(input, init);
    } catch (error) {
      return Promise.reject(error);
    }
    const signal = request.signal;
    return new Promise((resolve, reject) => {
      if (signal.aborted) {
        reject(signal.reason);
        return;
      }
      const entry = {
        id: nextId++, resolve, reject, signal, controller: null, pull: null,
        settled: false, onAbort: null, ended: false,
      };
      const begin = (bytes) => {
        if (entry.signal.aborted) {
          reject(entry.signal.reason);
          return;
        }
        pending.set(entry.id, entry);
        entry.onAbort = () => {
          const reason = entry.signal.reason;
          host.abort(entry.id);
          const pull = entry.pull;
          entry.pull = null;
          if (!entry.settled) {
            entry.settled = true;
            reject(reason);
          } else if (entry.controller !== null) {
            controllerError(entry.controller, reason);
          }
          if (pull !== null) pull.reject(reason);
          cleanup(entry);
        };
        signal.addEventListener('abort', entry.onAbort, { once: true });
        host.start(entry.id, request.url, request.method,
          headersList(request.headers).map((header) => [header[0], header[1]]),
          bytes, request.redirect);
      };
      const body = request.body === null
        ? Promise.resolve(null)
        : request.arrayBuffer().then((buffer) => new Uint8Array(buffer));
      body.then(begin, (error) => reject(networkError(String(error))));
    });
  }

  function onResponse(id, status, statusText, headers, url, redirected) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    let impl;
    impl = createReadableStream(() => undefined, () => {
      if (entry.ended) return undefined;
      // Resolved by the next onChunk / onEnd / onError: one host read per pull.
      return new Promise((resolve, reject) => {
        entry.pull = { resolve, reject };
        host.pull(id);
      });
    }, () => {
      host.cancel(id);
      cleanup(entry);
      return undefined;
    });
    entry.controller = impl.controller;
    const list = headers.map((header) => [String(header[0]).toLowerCase(), String(header[1])]);
    entry.settled = true;
    entry.resolve(createResponse({
      url, status, statusText,
      headers: createHeaders(list, 'immutable'),
      body: { source: null, stream: makeReadable(impl), length: null, type: null },
      bodyUsed: false, type: 'basic', redirected,
    }));
  }

  function onChunk(id, bytes) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    const pull = entry.pull;
    entry.pull = null;
    controllerEnqueue(entry.controller, bytes);
    if (pull !== null) pull.resolve(undefined);
  }

  function onEnd(id) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    entry.ended = true;
    const pull = entry.pull;
    entry.pull = null;
    controllerClose(entry.controller);
    if (pull !== null) pull.resolve(undefined);
    cleanup(entry);
  }

  function onError(id, message) {
    const entry = pending.get(id);
    if (entry === undefined) return;
    const error = networkError(message);
    const pull = entry.pull;
    entry.pull = null;
    if (!entry.settled) {
      entry.settled = true;
      entry.reject(error);
    } else if (entry.controller !== null) {
      controllerError(entry.controller, error);
    }
    if (pull !== null) pull.reject(error);
    cleanup(entry);
  }

  define(g, 'fetch', fetch);

  return { onResponse, onChunk, onEnd, onError };
})
''';
