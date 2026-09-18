part of '../web_apis.dart';

/// `ReadableStream`, `WritableStream`, `TransformStream`, the queuing
/// strategies and the encoding streams.
///
/// Deviation: byte streams (`type: 'bytes'`, BYOB readers) are not implemented
/// and throw `TypeError`.
const String _jsStreams = r'''
(function (host, internal, natives) {
  'use strict';
  const g = globalThis;
  const {
    define, customInspect, cloneHooks, NOT_CLONED, DOMException, illegal,
    isAbortSignal, createSignal,
    TextEncoder, TextDecoder,
  } = internal;

  function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
    // Rejections are always observed by the stream that owns the deferred.
    promise.catch(() => {});
    return { promise, resolve, reject };
  }
  const rejected = (error) => {
    const promise = Promise.reject(error);
    promise.catch(() => {});
    return promise;
  };

  // ---- queue with sizes ----
  function resetQueue(container) {
    container.queue = [];
    container.queueTotalSize = 0;
  }
  function enqueueValueWithSize(container, value, size) {
    const number = Number(size);
    if (!Number.isFinite(number) || number < 0) {
      throw new RangeError('Stream chunk size must be a finite, non-negative number');
    }
    container.queue.push({ value, size: number });
    container.queueTotalSize += number;
  }
  function dequeueValue(container) {
    const pair = container.queue.shift();
    container.queueTotalSize -= pair.size;
    if (container.queueTotalSize < 0) container.queueTotalSize = 0;
    return pair.value;
  }

  function extractHighWaterMark(strategy, fallback) {
    if (strategy.highWaterMark === undefined) return fallback;
    const value = Number(strategy.highWaterMark);
    if (Number.isNaN(value) || value < 0) throw new RangeError('Invalid highWaterMark');
    return value;
  }
  function extractSizeAlgorithm(strategy) {
    if (strategy.size === undefined) return () => 1;
    const size = strategy.size;
    if (typeof size !== 'function') throw new TypeError('strategy.size is not a function');
    return (chunk) => size(chunk);
  }

  // ---- readable stream ----
  function newReadable() {
    return { state: 'readable', storedError: undefined, reader: undefined, disturbed: false, controller: undefined };
  }
  const readableLocked = (stream) => stream.reader !== undefined;

  function readableError(stream, error) {
    stream.state = 'errored';
    stream.storedError = error;
    const reader = stream.reader;
    if (reader === undefined) return;
    for (const request of reader.readRequests) request.reject(error);
    reader.readRequests = [];
    reader.closed.reject(error);
  }
  function readableClose(stream) {
    stream.state = 'closed';
    const reader = stream.reader;
    if (reader === undefined) return;
    for (const request of reader.readRequests) request.resolve({ value: undefined, done: true });
    reader.readRequests = [];
    reader.closed.resolve(undefined);
  }
  function readableCancel(stream, reason) {
    stream.disturbed = true;
    if (stream.state === 'closed') return Promise.resolve(undefined);
    if (stream.state === 'errored') return rejected(stream.storedError);
    readableClose(stream);
    const controller = stream.controller;
    resetQueue(controller);
    const result = controller.cancelAlgorithm(reason);
    controllerClearAlgorithms(controller);
    return Promise.resolve(result).then(() => undefined);
  }

  function controllerClearAlgorithms(controller) {
    controller.pullAlgorithm = () => Promise.resolve(undefined);
    controller.cancelAlgorithm = () => Promise.resolve(undefined);
    controller.strategySizeAlgorithm = () => 1;
  }
  function controllerCanCloseOrEnqueue(controller) {
    return !controller.closeRequested && controller.stream.state === 'readable';
  }
  function controllerDesiredSize(controller) {
    const state = controller.stream.state;
    if (state === 'errored') return null;
    if (state === 'closed') return 0;
    return controller.strategyHWM - controller.queueTotalSize;
  }
  function controllerShouldCallPull(controller) {
    const stream = controller.stream;
    if (!controllerCanCloseOrEnqueue(controller)) return false;
    if (!controller.started) return false;
    if (readableLocked(stream) && stream.reader.readRequests.length > 0) return true;
    return controllerDesiredSize(controller) > 0;
  }
  function controllerCallPullIfNeeded(controller) {
    if (!controllerShouldCallPull(controller)) return;
    if (controller.pulling) {
      controller.pullAgain = true;
      return;
    }
    controller.pulling = true;
    Promise.resolve(controller.pullAlgorithm(controller.facade)).then(() => {
      controller.pulling = false;
      if (controller.pullAgain) {
        controller.pullAgain = false;
        controllerCallPullIfNeeded(controller);
      }
    }, (error) => controllerError(controller, error));
  }
  function controllerError(controller, error) {
    if (controller.stream.state !== 'readable') return;
    resetQueue(controller);
    controllerClearAlgorithms(controller);
    readableError(controller.stream, error);
  }
  function controllerEnqueue(controller, chunk) {
    if (!controllerCanCloseOrEnqueue(controller)) {
      throw new TypeError('The stream is not in a state that permits enqueue');
    }
    const stream = controller.stream;
    if (readableLocked(stream) && stream.reader.readRequests.length > 0) {
      stream.reader.readRequests.shift().resolve({ value: chunk, done: false });
    } else {
      let size;
      try {
        size = controller.strategySizeAlgorithm(chunk);
      } catch (error) {
        controllerError(controller, error);
        throw error;
      }
      try {
        enqueueValueWithSize(controller, chunk, size);
      } catch (error) {
        controllerError(controller, error);
        throw error;
      }
    }
    controllerCallPullIfNeeded(controller);
  }
  function controllerClose(controller) {
    if (!controllerCanCloseOrEnqueue(controller)) {
      throw new TypeError('The stream is not in a state that permits close');
    }
    controller.closeRequested = true;
    if (controller.queue.length === 0) {
      controllerClearAlgorithms(controller);
      readableClose(controller.stream);
    }
  }
  function controllerPullSteps(controller) {
    const stream = controller.stream;
    if (controller.queue.length > 0) {
      const chunk = dequeueValue(controller);
      if (controller.closeRequested && controller.queue.length === 0) {
        controllerClearAlgorithms(controller);
        readableClose(stream);
      } else {
        controllerCallPullIfNeeded(controller);
      }
      return Promise.resolve({ value: chunk, done: false });
    }
    const request = deferred();
    stream.reader.readRequests.push(request);
    controllerCallPullIfNeeded(controller);
    return request.promise;
  }

  function setUpReadableController(stream, startAlgorithm, pullAlgorithm, cancelAlgorithm, highWaterMark, sizeAlgorithm) {
    const controller = {
      stream, queue: [], queueTotalSize: 0, started: false, closeRequested: false,
      pullAgain: false, pulling: false, strategyHWM: highWaterMark,
      strategySizeAlgorithm: sizeAlgorithm, pullAlgorithm, cancelAlgorithm, facade: undefined,
    };
    controller.facade = createReadableController(controller);
    stream.controller = controller;
    Promise.resolve(startAlgorithm(controller.facade)).then(() => {
      controller.started = true;
      controllerCallPullIfNeeded(controller);
    }, (error) => controllerError(controller, error));
    return controller;
  }

  function createReadableStream(startAlgorithm, pullAlgorithm, cancelAlgorithm, highWaterMark = 1, sizeAlgorithm = () => 1) {
    const stream = newReadable();
    setUpReadableController(stream, startAlgorithm, pullAlgorithm, cancelAlgorithm, highWaterMark, sizeAlgorithm);
    return stream;
  }

  function acquireReader(stream) {
    if (readableLocked(stream)) throw new TypeError('ReadableStream is locked');
    const reader = { stream, readRequests: [], closed: deferred() };
    stream.reader = reader;
    if (stream.state === 'closed') reader.closed.resolve(undefined);
    else if (stream.state === 'errored') reader.closed.reject(stream.storedError);
    return reader;
  }
  function readerRead(reader) {
    if (reader.stream === undefined) return rejected(new TypeError('Reader has been released'));
    const stream = reader.stream;
    stream.disturbed = true;
    if (stream.state === 'closed') return Promise.resolve({ value: undefined, done: true });
    if (stream.state === 'errored') return rejected(stream.storedError);
    return controllerPullSteps(stream.controller);
  }
  function readerRelease(reader) {
    const stream = reader.stream;
    if (stream === undefined) return;
    const error = new TypeError('Reader was released');
    for (const request of reader.readRequests) request.reject(error);
    reader.readRequests = [];
    reader.closed.reject(error);
    stream.reader = undefined;
    reader.stream = undefined;
  }
  function readerCancel(reader, reason) {
    if (reader.stream === undefined) return rejected(new TypeError('Reader has been released'));
    return readableCancel(reader.stream, reason);
  }

  // ---- writable stream ----
  function newWritable() {
    return {
      state: 'writable', storedError: undefined, writer: undefined, controller: undefined,
      inFlightWriteRequest: undefined, closeRequest: undefined, inFlightCloseRequest: undefined,
      pendingAbortRequest: undefined, writeRequests: [], backpressure: false,
    };
  }
  const writableLocked = (stream) => stream.writer !== undefined;

  function writableStartErroring(stream, reason) {
    const controller = stream.controller;
    stream.state = 'erroring';
    stream.storedError = reason;
    const writer = stream.writer;
    if (writer !== undefined) writableWriterEnsureReadyRejected(writer, reason);
    if (!writableHasOperations(stream) && controller.started) writableFinishErroring(stream);
  }
  const writableHasOperations = (stream) =>
    stream.inFlightWriteRequest !== undefined || stream.inFlightCloseRequest !== undefined;

  function writableFinishErroring(stream) {
    stream.state = 'errored';
    const error = stream.storedError;
    for (const request of stream.writeRequests) request.reject(error);
    stream.writeRequests = [];
    const abortRequest = stream.pendingAbortRequest;
    stream.pendingAbortRequest = undefined;
    if (abortRequest === undefined) {
      writableRejectClosedPromiseIfNeeded(stream);
      return;
    }
    if (abortRequest.wasAlreadyErroring) {
      abortRequest.reject(error);
      writableRejectClosedPromiseIfNeeded(stream);
      return;
    }
    Promise.resolve(stream.controller.abortAlgorithm(abortRequest.reason)).then(() => {
      abortRequest.resolve(undefined);
      writableRejectClosedPromiseIfNeeded(stream);
    }, (reason) => {
      abortRequest.reject(reason);
      writableRejectClosedPromiseIfNeeded(stream);
    });
  }
  function writableRejectClosedPromiseIfNeeded(stream) {
    const writer = stream.writer;
    if (writer === undefined) return;
    writer.closed.reject(stream.storedError);
  }
  function writableWriterEnsureReadyRejected(writer, error) {
    if (writer.readyState === 'pending') writer.ready.reject(error);
    else writer.ready = { promise: rejected(error), resolve: () => {}, reject: () => {} };
    writer.readyState = 'rejected';
  }
  function writableWriterEnsureReadyPending(writer) {
    if (writer.readyState === 'pending') return;
    writer.ready = deferred();
    writer.readyState = 'pending';
  }
  function writableWriterResolveReady(writer) {
    if (writer.readyState !== 'pending') return;
    writer.ready.resolve(undefined);
    writer.readyState = 'fulfilled';
  }
  function writableUpdateBackpressure(stream, backpressure) {
    stream.backpressure = backpressure;
    const writer = stream.writer;
    if (writer === undefined) return;
    if (backpressure) writableWriterEnsureReadyPending(writer);
    else writableWriterResolveReady(writer);
  }

  function writableAbort(stream, reason) {
    if (stream.state === 'closed' || stream.state === 'errored') return Promise.resolve(undefined);
    if (stream.pendingAbortRequest !== undefined) return stream.pendingAbortRequest.promise;
    const wasAlreadyErroring = stream.state === 'erroring';
    const request = deferred();
    stream.pendingAbortRequest = {
      promise: request.promise, resolve: request.resolve, reject: request.reject,
      reason: wasAlreadyErroring ? undefined : reason, wasAlreadyErroring,
    };
    if (!wasAlreadyErroring) writableStartErroring(stream, reason);
    return request.promise;
  }
  function writableClose(stream) {
    if (stream.state === 'closed' || stream.state === 'errored') {
      return rejected(new TypeError('The stream is closing or closed'));
    }
    const request = deferred();
    stream.closeRequest = request;
    const writer = stream.writer;
    if (writer !== undefined && stream.backpressure && stream.state === 'writable') {
      writableWriterResolveReady(writer);
    }
    const controller = stream.controller;
    enqueueValueWithSize(controller, 'close', 0);
    writableAdvanceQueueIfNeeded(controller);
    return request.promise;
  }
  function writableAddWriteRequest(stream) {
    const request = deferred();
    stream.writeRequests.push(request);
    return request.promise;
  }
  function writableWrite(stream, chunk) {
    const controller = stream.controller;
    let size;
    try {
      size = controller.strategySizeAlgorithm(chunk);
    } catch (error) {
      writableErrorIfNeeded(stream, error);
      return rejected(error);
    }
    if (stream.state === 'erroring' || stream.state === 'errored') return rejected(stream.storedError);
    if (stream.state === 'closed' || stream.closeRequest !== undefined) {
      return rejected(new TypeError('The stream is closing or closed'));
    }
    const promise = writableAddWriteRequest(stream);
    try {
      enqueueValueWithSize(controller, { chunk }, size);
    } catch (error) {
      writableErrorIfNeeded(stream, error);
      return rejected(error);
    }
    writableUpdateBackpressure(stream, controllerWritableDesiredSize(controller) <= 0);
    writableAdvanceQueueIfNeeded(controller);
    return promise;
  }
  function writableErrorIfNeeded(stream, error) {
    if (stream.state === 'writable') writableStartErroring(stream, error);
  }
  const controllerWritableDesiredSize = (controller) => controller.strategyHWM - controller.queueTotalSize;

  function writableAdvanceQueueIfNeeded(controller) {
    const stream = controller.stream;
    if (!controller.started || stream.inFlightWriteRequest !== undefined) return;
    if (stream.state === 'erroring') {
      writableFinishErroring(stream);
      return;
    }
    if (controller.queue.length === 0) return;
    const value = controller.queue[0].value;
    if (value === 'close') writableProcessClose(controller);
    else writableProcessWrite(controller, value.chunk);
  }
  function writableProcessClose(controller) {
    const stream = controller.stream;
    dequeueValue(controller);
    stream.inFlightCloseRequest = stream.closeRequest;
    stream.closeRequest = undefined;
    Promise.resolve(controller.closeAlgorithm()).then(() => {
      const request = stream.inFlightCloseRequest;
      stream.inFlightCloseRequest = undefined;
      request.resolve(undefined);
      if (stream.state === 'erroring') {
        stream.storedError = undefined;
        if (stream.pendingAbortRequest !== undefined) {
          stream.pendingAbortRequest.resolve(undefined);
          stream.pendingAbortRequest = undefined;
        }
      }
      stream.state = 'closed';
      const writer = stream.writer;
      if (writer !== undefined) writer.closed.resolve(undefined);
    }, (reason) => {
      const request = stream.inFlightCloseRequest;
      stream.inFlightCloseRequest = undefined;
      request.reject(reason);
      if (stream.pendingAbortRequest !== undefined) {
        stream.pendingAbortRequest.reject(reason);
        stream.pendingAbortRequest = undefined;
      }
      writableErrorIfNeeded(stream, reason);
      if (stream.state === 'erroring') writableFinishErroring(stream);
    });
  }
  function writableProcessWrite(controller, chunk) {
    const stream = controller.stream;
    stream.inFlightWriteRequest = stream.writeRequests.shift();
    Promise.resolve(controller.writeAlgorithm(chunk, controller.facade)).then(() => {
      const request = stream.inFlightWriteRequest;
      stream.inFlightWriteRequest = undefined;
      request.resolve(undefined);
      dequeueValue(controller);
      if (stream.state !== 'erroring' && stream.closeRequest === undefined) {
        writableUpdateBackpressure(stream, controllerWritableDesiredSize(controller) <= 0);
      }
      writableAdvanceQueueIfNeeded(controller);
    }, (reason) => {
      const request = stream.inFlightWriteRequest;
      stream.inFlightWriteRequest = undefined;
      request.reject(reason);
      if (stream.state === 'writable') writableErrorIfNeeded(stream, reason);
      else if (stream.state === 'erroring') writableFinishErroring(stream);
    });
  }

  function setUpWritableController(stream, startAlgorithm, writeAlgorithm, closeAlgorithm, abortAlgorithm, highWaterMark, sizeAlgorithm) {
    const controller = {
      stream, queue: [], queueTotalSize: 0, started: false, strategyHWM: highWaterMark,
      strategySizeAlgorithm: sizeAlgorithm, writeAlgorithm, closeAlgorithm, abortAlgorithm,
      facade: undefined,
    };
    controller.facade = createWritableController(controller);
    stream.controller = controller;
    writableUpdateBackpressure(stream, controllerWritableDesiredSize(controller) <= 0);
    Promise.resolve(startAlgorithm(controller.facade)).then(() => {
      controller.started = true;
      writableAdvanceQueueIfNeeded(controller);
    }, (error) => {
      controller.started = true;
      writableErrorIfNeeded(stream, error);
    });
    return controller;
  }
  function createWritableStream(startAlgorithm, writeAlgorithm, closeAlgorithm, abortAlgorithm, highWaterMark = 1, sizeAlgorithm = () => 1) {
    const stream = newWritable();
    setUpWritableController(stream, startAlgorithm, writeAlgorithm, closeAlgorithm, abortAlgorithm, highWaterMark, sizeAlgorithm);
    return stream;
  }

  function acquireWriter(stream) {
    if (writableLocked(stream)) throw new TypeError('WritableStream is locked');
    const writer = { stream, closed: deferred(), ready: deferred(), readyState: 'pending' };
    stream.writer = writer;
    if (stream.state === 'writable') {
      if (!stream.backpressure) writableWriterResolveReady(writer);
    } else if (stream.state === 'erroring') {
      writableWriterEnsureReadyRejected(writer, stream.storedError);
    } else if (stream.state === 'closed') {
      writer.ready = { promise: Promise.resolve(undefined), resolve: () => {}, reject: () => {} };
      writer.readyState = 'fulfilled';
      writer.closed.resolve(undefined);
    } else {
      writableWriterEnsureReadyRejected(writer, stream.storedError);
      writer.closed.reject(stream.storedError);
    }
    return writer;
  }
  function writerRelease(writer) {
    const stream = writer.stream;
    if (stream === undefined) return;
    const error = new TypeError('Writer was released');
    writableWriterEnsureReadyRejected(writer, error);
    writer.closed.reject(error);
    stream.writer = undefined;
    writer.stream = undefined;
  }

  // ---- public classes ----
  let getReadable;
  let makeReadable;
  let createReadableController;
  let createWritableController;

  class ReadableStreamDefaultController {
    #controller;
    constructor(key, controller) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
      this.#controller = controller;
    }
    get desiredSize() { return controllerDesiredSize(this.#controller); }
    close() { controllerClose(this.#controller); }
    enqueue(chunk = undefined) { controllerEnqueue(this.#controller, chunk); }
    error(reason = undefined) { controllerError(this.#controller, reason); }
  }
  Object.defineProperty(ReadableStreamDefaultController.prototype, Symbol.toStringTag,
    { value: 'ReadableStreamDefaultController', configurable: true });
  createReadableController = (controller) =>
    new ReadableStreamDefaultController(illegal, controller);

  class ReadableStreamDefaultReader {
    #reader;
    constructor(stream) {
      const impl = getReadable(stream);
      if (impl === null) {
        throw new TypeError("Failed to construct 'ReadableStreamDefaultReader': parameter 1 is not of type 'ReadableStream'.");
      }
      this.#reader = acquireReader(impl);
    }
    get closed() { return this.#reader.closed.promise; }
    read() {
      try {
        return readerRead(this.#reader);
      } catch (error) {
        return rejected(error);
      }
    }
    releaseLock() { readerRelease(this.#reader); }
    cancel(reason = undefined) { return readerCancel(this.#reader, reason); }
  }
  Object.defineProperty(ReadableStreamDefaultReader.prototype, Symbol.toStringTag,
    { value: 'ReadableStreamDefaultReader', configurable: true });

  class ReadableStream {
    #impl;
    constructor(underlyingSource = undefined, strategy = undefined) {
      // Internal construction from an existing stream record.
      if (underlyingSource === illegal) {
        this.#impl = strategy;
        return;
      }
      const source = underlyingSource === undefined || underlyingSource === null ? {} : underlyingSource;
      const options = strategy === undefined || strategy === null ? {} : strategy;
      if (source.type !== undefined) {
        throw new TypeError('Byte streams are not supported by this runtime');
      }
      const highWaterMark = extractHighWaterMark(options, 1);
      const sizeAlgorithm = extractSizeAlgorithm(options);
      const startAlgorithm = (controller) =>
        typeof source.start === 'function' ? source.start.call(source, controller) : undefined;
      const pullAlgorithm = (controller) =>
        typeof source.pull === 'function' ? source.pull.call(source, controller) : undefined;
      const cancelAlgorithm = (reason) =>
        typeof source.cancel === 'function' ? source.cancel.call(source, reason) : undefined;
      this.#impl = createReadableStream(startAlgorithm, pullAlgorithm, cancelAlgorithm, highWaterMark, sizeAlgorithm);
    }
    get locked() { return readableLocked(this.#impl); }
    cancel(reason = undefined) {
      if (readableLocked(this.#impl)) return rejected(new TypeError('Cannot cancel a locked stream'));
      return readableCancel(this.#impl, reason);
    }
    getReader(options = undefined) {
      const mode = options === undefined || options === null ? undefined : options.mode;
      if (mode !== undefined) {
        throw new TypeError('BYOB readers are not supported by this runtime');
      }
      return new ReadableStreamDefaultReader(this);
    }
    tee() {
      const impl = this.#impl;
      const reader = acquireReader(impl);
      let reading = false;
      let canceled1 = false;
      let canceled2 = false;
      let reason1;
      let reason2;
      let branch1;
      let branch2;
      const cancelResult = deferred();
      const pull = () => {
        if (reading) return Promise.resolve(undefined);
        reading = true;
        readerRead(reader).then((result) => {
          reading = false;
          if (result.done) {
            if (!canceled1) controllerClose(branch1.controller);
            if (!canceled2) controllerClose(branch2.controller);
            return;
          }
          if (!canceled1) controllerEnqueue(branch1.controller, result.value);
          if (!canceled2) controllerEnqueue(branch2.controller, result.value);
        }, (error) => {
          reading = false;
          controllerError(branch1.controller, error);
          controllerError(branch2.controller, error);
        });
        return Promise.resolve(undefined);
      };
      const cancel = (which, reason) => {
        if (which === 1) {
          canceled1 = true;
          reason1 = reason;
        } else {
          canceled2 = true;
          reason2 = reason;
        }
        if (canceled1 && canceled2) {
          readableCancel(impl, [reason1, reason2]).then(cancelResult.resolve, cancelResult.reject);
        }
        return cancelResult.promise;
      };
      branch1 = createReadableStream(() => undefined, pull, (reason) => cancel(1, reason));
      branch2 = createReadableStream(() => undefined, pull, (reason) => cancel(2, reason));
      return [makeReadable(branch1), makeReadable(branch2)];
    }
    values(options = undefined) {
      const preventCancel = options === undefined || options === null ? false : Boolean(options.preventCancel);
      const reader = acquireReader(this.#impl);
      return {
        next() {
          return readerRead(reader).then((result) => {
            if (result.done) readerRelease(reader);
            return result;
          }, (error) => {
            readerRelease(reader);
            throw error;
          });
        },
        return(value = undefined) {
          if (!preventCancel) readerCancel(reader, value);
          readerRelease(reader);
          return Promise.resolve({ value, done: true });
        },
        [Symbol.asyncIterator]() { return this; },
      };
    }
    pipeTo(destination, options = undefined) {
      const target = getWritable(destination);
      if (target === null) {
        return rejected(new TypeError("Failed to execute 'pipeTo' on 'ReadableStream': parameter 1 is not of type 'WritableStream'."));
      }
      if (readableLocked(this.#impl)) return rejected(new TypeError('ReadableStream is locked'));
      if (writableLocked(target)) return rejected(new TypeError('WritableStream is locked'));
      return pipeToImpl(this.#impl, target, options === undefined || options === null ? {} : options);
    }
    pipeThrough(transform, options = undefined) {
      if (transform === undefined || transform === null) {
        throw new TypeError("Failed to execute 'pipeThrough' on 'ReadableStream': parameter 1 is not an object.");
      }
      const writable = getWritable(transform.writable);
      const readable = getReadable(transform.readable);
      if (writable === null || readable === null) {
        throw new TypeError("Failed to execute 'pipeThrough' on 'ReadableStream': invalid transform.");
      }
      const result = this.pipeTo(transform.writable, options);
      result.catch(() => {});
      return transform.readable;
    }
    static from(asyncIterable) {
      const iteratorFactory = asyncIterable[Symbol.asyncIterator] || asyncIterable[Symbol.iterator];
      if (typeof iteratorFactory !== 'function') {
        throw new TypeError("Failed to execute 'from' on 'ReadableStream': parameter 1 is not async iterable.");
      }
      const iterator = iteratorFactory.call(asyncIterable);
      let impl;
      impl = createReadableStream(() => undefined, () =>
        Promise.resolve(iterator.next()).then((result) => {
          if (result.done) controllerClose(impl.controller);
          else controllerEnqueue(impl.controller, result.value);
        }), (reason) => (typeof iterator.return === 'function' ? iterator.return(reason) : undefined));
      return makeReadable(impl);
    }
    [Symbol.asyncIterator](options = undefined) { return this.values(options); }
    [customInspect]() { return 'ReadableStream { locked: ' + readableLocked(this.#impl) + ' }'; }
    static {
      getReadable = (value) => (typeof value === 'object' && value !== null && #impl in value ? value.#impl : null);
      makeReadable = (impl) => new ReadableStream(illegal, impl);
    }
  }
  Object.defineProperty(ReadableStream.prototype, Symbol.toStringTag, { value: 'ReadableStream', configurable: true });

  let getWritable;
  let makeWritable;
  class WritableStreamDefaultController {
    #controller;
    constructor(key, controller) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
      this.#controller = controller;
    }
    get signal() {
      if (this.#controller.abortSignal === undefined) {
        this.#controller.abortSignal = createSignal();
      }
      return this.#controller.abortSignal;
    }
    error(reason = undefined) {
      if (this.#controller.stream.state === 'writable') writableStartErroring(this.#controller.stream, reason);
    }
  }
  Object.defineProperty(WritableStreamDefaultController.prototype, Symbol.toStringTag,
    { value: 'WritableStreamDefaultController', configurable: true });
  createWritableController = (controller) =>
    new WritableStreamDefaultController(illegal, controller);

  class WritableStreamDefaultWriter {
    #writer;
    constructor(stream) {
      const impl = getWritable(stream);
      if (impl === null) {
        throw new TypeError("Failed to construct 'WritableStreamDefaultWriter': parameter 1 is not of type 'WritableStream'.");
      }
      this.#writer = acquireWriter(impl);
    }
    get closed() { return this.#writer.closed.promise; }
    get ready() { return this.#writer.ready.promise; }
    get desiredSize() {
      const stream = this.#writer.stream;
      if (stream === undefined) throw new TypeError('Writer was released');
      if (stream.state === 'errored' || stream.state === 'erroring') return null;
      if (stream.state === 'closed') return 0;
      return controllerWritableDesiredSize(stream.controller);
    }
    write(chunk = undefined) {
      const stream = this.#writer.stream;
      if (stream === undefined) return rejected(new TypeError('Writer was released'));
      return writableWrite(stream, chunk);
    }
    close() {
      const stream = this.#writer.stream;
      if (stream === undefined) return rejected(new TypeError('Writer was released'));
      return writableClose(stream);
    }
    abort(reason = undefined) {
      const stream = this.#writer.stream;
      if (stream === undefined) return rejected(new TypeError('Writer was released'));
      return writableAbort(stream, reason);
    }
    releaseLock() { writerRelease(this.#writer); }
  }
  Object.defineProperty(WritableStreamDefaultWriter.prototype, Symbol.toStringTag,
    { value: 'WritableStreamDefaultWriter', configurable: true });

  class WritableStream {
    #impl;
    constructor(underlyingSink = undefined, strategy = undefined) {
      // Internal construction from an existing stream record.
      if (underlyingSink === illegal) {
        this.#impl = strategy;
        return;
      }
      const sink = underlyingSink === undefined || underlyingSink === null ? {} : underlyingSink;
      const options = strategy === undefined || strategy === null ? {} : strategy;
      if (sink.type !== undefined) throw new RangeError('Invalid underlying sink type');
      const highWaterMark = extractHighWaterMark(options, 1);
      const sizeAlgorithm = extractSizeAlgorithm(options);
      const startAlgorithm = (controller) =>
        typeof sink.start === 'function' ? sink.start.call(sink, controller) : undefined;
      const writeAlgorithm = (chunk, controller) =>
        typeof sink.write === 'function' ? sink.write.call(sink, chunk, controller) : undefined;
      const closeAlgorithm = () => (typeof sink.close === 'function' ? sink.close.call(sink) : undefined);
      const abortAlgorithm = (reason) =>
        typeof sink.abort === 'function' ? sink.abort.call(sink, reason) : undefined;
      this.#impl = createWritableStream(startAlgorithm, writeAlgorithm, closeAlgorithm, abortAlgorithm, highWaterMark, sizeAlgorithm);
    }
    get locked() { return writableLocked(this.#impl); }
    abort(reason = undefined) {
      if (writableLocked(this.#impl)) return rejected(new TypeError('Cannot abort a locked stream'));
      return writableAbort(this.#impl, reason);
    }
    close() {
      if (writableLocked(this.#impl)) return rejected(new TypeError('Cannot close a locked stream'));
      return writableClose(this.#impl);
    }
    getWriter() { return new WritableStreamDefaultWriter(this); }
    [customInspect]() { return 'WritableStream { locked: ' + writableLocked(this.#impl) + ' }'; }
    static {
      getWritable = (value) => (typeof value === 'object' && value !== null && #impl in value ? value.#impl : null);
      makeWritable = (impl) => new WritableStream(illegal, impl);
    }
  }
  Object.defineProperty(WritableStream.prototype, Symbol.toStringTag, { value: 'WritableStream', configurable: true });

  async function pipeToImpl(source, destination, options) {
    const preventClose = Boolean(options.preventClose);
    const preventAbort = Boolean(options.preventAbort);
    const preventCancel = Boolean(options.preventCancel);
    const signal = options.signal;
    if (signal !== undefined && signal !== null && !isAbortSignal(signal)) {
      throw new TypeError("Failed to execute 'pipeTo' on 'ReadableStream': member signal is not of type AbortSignal.");
    }
    const reader = acquireReader(source);
    const writer = acquireWriter(destination);
    source.disturbed = true;

    const finish = (error) => {
      readerRelease(reader);
      writerRelease(writer);
      if (error !== undefined) throw error;
    };
    const abortBoth = async (reason) => {
      const actions = [];
      if (!preventAbort && (destination.state === 'writable' || destination.state === 'erroring')) {
        actions.push(writableAbort(destination, reason));
      }
      if (!preventCancel && source.state === 'readable') actions.push(readableCancel(source, reason));
      try {
        await Promise.all(actions);
      } catch (e) {}
    };

    if (signal !== undefined && signal !== null && signal.aborted) {
      await abortBoth(signal.reason);
      return finish(signal.reason);
    }
    let abortReason;
    const onAbort = () => { abortReason = signal.reason; };
    if (signal !== undefined && signal !== null) signal.addEventListener('abort', onAbort, { once: true });

    try {
      while (true) {
        if (abortReason !== undefined) {
          await abortBoth(abortReason);
          return finish(abortReason);
        }
        await writer.ready.promise;
        const result = await readerRead(reader);
        if (result.done) break;
        const write = writableWrite(destination, result.value);
        write.catch(() => {});
      }
      if (!preventClose) await writableClose(destination);
      return finish(undefined);
    } catch (error) {
      if (source.state === 'errored') {
        if (!preventAbort) await abortBoth(source.storedError);
        return finish(source.storedError);
      }
      if (destination.state === 'errored' || destination.state === 'erroring') {
        const reason = destination.storedError;
        if (!preventCancel && source.state === 'readable') {
          try {
            await readableCancel(source, reason);
          } catch (e) {}
        }
        return finish(reason);
      }
      return finish(error);
    } finally {
      if (signal !== undefined && signal !== null) signal.removeEventListener('abort', onAbort);
    }
  }

  class TransformStreamDefaultController {
    #state;
    constructor(key, state) {
      if (key !== illegal) throw new TypeError('Illegal constructor');
      this.#state = state;
    }
    get desiredSize() { return controllerDesiredSize(this.#state.readable.controller); }
    enqueue(chunk = undefined) { controllerEnqueue(this.#state.readable.controller, chunk); }
    error(reason = undefined) {
      controllerError(this.#state.readable.controller, reason);
      writableErrorIfNeeded(this.#state.writable, reason);
    }
    terminate() {
      const readableController = this.#state.readable.controller;
      if (controllerCanCloseOrEnqueue(readableController)) controllerClose(readableController);
      const error = new TypeError('The transform stream has been terminated');
      writableErrorIfNeeded(this.#state.writable, error);
    }
  }
  Object.defineProperty(TransformStreamDefaultController.prototype, Symbol.toStringTag,
    { value: 'TransformStreamDefaultController', configurable: true });

  class TransformStream {
    #readable;
    #writable;
    constructor(transformer = undefined, writableStrategy = undefined, readableStrategy = undefined) {
      const source = transformer === undefined || transformer === null ? {} : transformer;
      if (source.readableType !== undefined || source.writableType !== undefined) {
        throw new RangeError('Invalid transformer type');
      }
      const writableOptions = writableStrategy === undefined || writableStrategy === null ? {} : writableStrategy;
      const readableOptions = readableStrategy === undefined || readableStrategy === null ? {} : readableStrategy;
      const state = { readable: undefined, writable: undefined, controller: undefined, backpressure: deferred() };
      state.controller = new TransformStreamDefaultController(illegal, state);
      state.backpressure.resolve(undefined);

      const transform = (chunk) => {
        if (typeof source.transform === 'function') return source.transform.call(source, chunk, state.controller);
        controllerEnqueue(state.readable.controller, chunk);
        return undefined;
      };
      const flush = () => (typeof source.flush === 'function' ? source.flush.call(source, state.controller) : undefined);

      state.writable = createWritableStream(
        () => undefined,
        (chunk) => Promise.resolve(transform(chunk)).catch((error) => {
          controllerError(state.readable.controller, error);
          throw error;
        }),
        () => Promise.resolve(flush()).then(() => {
          if (controllerCanCloseOrEnqueue(state.readable.controller)) controllerClose(state.readable.controller);
        }, (error) => {
          controllerError(state.readable.controller, error);
          throw error;
        }),
        (reason) => {
          controllerError(state.readable.controller, reason);
          return undefined;
        },
        extractHighWaterMark(writableOptions, 1),
        extractSizeAlgorithm(writableOptions),
      );
      state.readable = createReadableStream(
        () => undefined,
        () => undefined,
        (reason) => {
          writableErrorIfNeeded(state.writable, reason);
          return undefined;
        },
        extractHighWaterMark(readableOptions, 0),
        extractSizeAlgorithm(readableOptions),
      );
      if (typeof source.start === 'function') source.start.call(source, state.controller);
      this.#readable = makeReadable(state.readable);
      this.#writable = makeWritable(state.writable);
    }
    get readable() { return this.#readable; }
    get writable() { return this.#writable; }
  }
  Object.defineProperty(TransformStream.prototype, Symbol.toStringTag, { value: 'TransformStream', configurable: true });

  class CountQueuingStrategy {
    #highWaterMark;
    constructor(init) {
      if (init === undefined || init === null || init.highWaterMark === undefined) {
        throw new TypeError("Failed to construct 'CountQueuingStrategy': member highWaterMark is required.");
      }
      this.#highWaterMark = Number(init.highWaterMark);
    }
    get highWaterMark() { return this.#highWaterMark; }
    get size() { return () => 1; }
  }
  class ByteLengthQueuingStrategy {
    #highWaterMark;
    constructor(init) {
      if (init === undefined || init === null || init.highWaterMark === undefined) {
        throw new TypeError("Failed to construct 'ByteLengthQueuingStrategy': member highWaterMark is required.");
      }
      this.#highWaterMark = Number(init.highWaterMark);
    }
    get highWaterMark() { return this.#highWaterMark; }
    get size() { return (chunk) => chunk.byteLength; }
  }

  class TextEncoderStream {
    #transform;
    #encoder = new TextEncoder();
    constructor() {
      const encoder = this.#encoder;
      this.#transform = new TransformStream({
        transform(chunk, controller) {
          const bytes = encoder.encode(String(chunk));
          if (bytes.length > 0) controller.enqueue(bytes);
        },
      });
    }
    get encoding() { return 'utf-8'; }
    get readable() { return this.#transform.readable; }
    get writable() { return this.#transform.writable; }
  }
  class TextDecoderStream {
    #transform;
    #decoder;
    constructor(label = 'utf-8', options = undefined) {
      const decoder = new TextDecoder(label, options);
      this.#decoder = decoder;
      this.#transform = new TransformStream({
        transform(chunk, controller) {
          const text = decoder.decode(chunk, { stream: true });
          if (text !== '') controller.enqueue(text);
        },
        flush(controller) {
          const text = decoder.decode();
          if (text !== '') controller.enqueue(text);
        },
      });
    }
    get encoding() { return this.#decoder.encoding; }
    get fatal() { return this.#decoder.fatal; }
    get ignoreBOM() { return this.#decoder.ignoreBOM; }
    get readable() { return this.#transform.readable; }
    get writable() { return this.#transform.writable; }
  }

  cloneHooks.push((value) => {
    if (getReadable(value) !== null || getWritable(value) !== null) {
      throw new DOMException('A stream could not be cloned.', 'DataCloneError');
    }
    return NOT_CLONED;
  });

  Object.assign(internal, {
    ReadableStream, WritableStream, TransformStream, getReadable, makeReadable, getWritable,
    createReadableStream, readableCancel, controllerEnqueue, controllerClose, controllerError,
    acquireReader, readerRead, readerRelease,
  });

  define(g, 'ReadableStream', ReadableStream);
  define(g, 'ReadableStreamDefaultReader', ReadableStreamDefaultReader);
  define(g, 'ReadableStreamDefaultController', ReadableStreamDefaultController);
  define(g, 'WritableStream', WritableStream);
  define(g, 'WritableStreamDefaultWriter', WritableStreamDefaultWriter);
  define(g, 'WritableStreamDefaultController', WritableStreamDefaultController);
  define(g, 'TransformStream', TransformStream);
  define(g, 'TransformStreamDefaultController', TransformStreamDefaultController);
  define(g, 'CountQueuingStrategy', CountQueuingStrategy);
  define(g, 'ByteLengthQueuingStrategy', ByteLengthQueuingStrategy);
  define(g, 'TextEncoderStream', TextEncoderStream);
  define(g, 'TextDecoderStream', TextDecoderStream);
})
''';
