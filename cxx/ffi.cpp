/*
 * @Description:
 * @Author: ekibun
 * @Date: 2020-09-06 18:32:45
 * @LastEditors: ekibun
 * @LastEditTime: 2020-12-02 11:11:42
 */
#include "ffi.h"
#include <atomic>
#include <chrono>
#include <functional>
#include <future>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#endif

extern "C"
{

  static std::atomic<uint64_t> bridge_alloc_calls{0};
  static std::atomic<uint64_t> bridge_alloc_bytes{0};
  static std::atomic<uint64_t> bridge_free_calls{0};
  static std::atomic<uint64_t> bridge_memcpy_calls{0};
  static std::atomic<uint64_t> bridge_memcpy_bytes{0};
  static std::atomic<uint64_t> bridge_copy_calls{0};
  static std::atomic<uint64_t> bridge_copy_bytes{0};
  static std::atomic<uint64_t> bridge_owned_typed_array_calls{0};
  static std::atomic<uint64_t> bridge_typed_array_data_calls{0};

  DLLEXPORT void jsBridgeStatsReset(void)
  {
    bridge_alloc_calls.store(0);
    bridge_alloc_bytes.store(0);
    bridge_free_calls.store(0);
    bridge_memcpy_calls.store(0);
    bridge_memcpy_bytes.store(0);
    bridge_copy_calls.store(0);
    bridge_copy_bytes.store(0);
    bridge_owned_typed_array_calls.store(0);
    bridge_typed_array_data_calls.store(0);
  }

  DLLEXPORT uint64_t jsBridgeStatsAllocCalls(void) { return bridge_alloc_calls.load(); }
  DLLEXPORT uint64_t jsBridgeStatsAllocBytes(void) { return bridge_alloc_bytes.load(); }
  DLLEXPORT uint64_t jsBridgeStatsFreeCalls(void) { return bridge_free_calls.load(); }
  DLLEXPORT uint64_t jsBridgeStatsMemcpyCalls(void) { return bridge_memcpy_calls.load(); }
  DLLEXPORT uint64_t jsBridgeStatsMemcpyBytes(void) { return bridge_memcpy_bytes.load(); }
  DLLEXPORT void jsBridgeStatsRecordCopy(size_t len)
  {
    bridge_copy_calls.fetch_add(1);
    bridge_copy_bytes.fetch_add(len);
  }
  DLLEXPORT uint64_t jsBridgeStatsCopyCalls(void) { return bridge_copy_calls.load(); }
  DLLEXPORT uint64_t jsBridgeStatsCopyBytes(void) { return bridge_copy_bytes.load(); }
  DLLEXPORT uint64_t jsBridgeStatsOwnedTypedArrayCalls(void) { return bridge_owned_typed_array_calls.load(); }
  DLLEXPORT uint64_t jsBridgeStatsTypedArrayDataCalls(void) { return bridge_typed_array_data_calls.load(); }

  /* Wall-clock ms for interrupt timeout (not process CPU time). */
  static int64_t js_monotonic_ms(void)
  {
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#elif defined(CLOCK_MONOTONIC)
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
      return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return 0;
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0)
      return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return 0;
#endif
  }

  DLLEXPORT JSValue *jsThrow(JSContext *ctx, JSValue *obj)
  {
    return new JSValue(JS_Throw(ctx, JS_DupValue(ctx, *obj)));
  }

  DLLEXPORT JSValue *jsEXCEPTION()
  {
    return new JSValue(JS_EXCEPTION);
  }

  DLLEXPORT JSValue *jsUNDEFINED()
  {
    return new JSValue(JS_UNDEFINED);
  }

  DLLEXPORT JSValue *jsNULL()
  {
    return new JSValue(JS_NULL);
  }

  struct RuntimeOpaque {
      JSChannel * channel;
      int64_t timeout; /* ms, 0 = off */
      int64_t start_ms; /* monotonic ms when outermost call began; 0 = inactive */
      int call_depth; /* nested js_begin_call / end */
  };

  JSModuleDef *js_module_loader(
      JSContext *ctx,
      const char *module_name, void *opaque)
  {
    char *str = (char *)((RuntimeOpaque *)opaque)->channel(ctx, JSChannelType_MODULE, (void *)module_name);
    if (str == 0)
    {
      /* The host reports "no such module" by returning null, which leaves no
         pending exception; without this the failure surfaces as a null error
         far from the import that caused it. */
      if (!JS_HasException(ctx))
        JS_ThrowReferenceError(ctx, "could not load module '%s'", module_name);
      return NULL;
    }
    JSValue func_val = JS_Eval(ctx, str, strlen(str), module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    /* Dart allocates module source with malloc; free after copy into QuickJS */
    free(str);
    if (JS_IsException(func_val))
      return NULL;
    /* the module is already referenced, so we must free it */
    JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(func_val);
    JS_FreeValue(ctx, func_val);
    return m;
  }

  JSValue js_channel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    RuntimeOpaque *opaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    void *data[4];
    data[0] = &this_val;
    data[1] = &argc;
    data[2] = argv;
    data[3] = func_data;
    /* The host allocates the reply with `new JSValue` (jsNewString, jsThrow,
       …) and hands over ownership; without this delete every call from JS into
       Dart leaked the cell. A null reply means the Dart callback itself threw. */
    JSValue *reply = (JSValue *)opaque->channel(ctx, JSChannelType_METHON, data);
    if (reply == NULL)
      return JS_ThrowInternalError(ctx, "host call failed");
    JSValue ret = *reply;
    delete reply;
    return ret;
  }

  void js_promise_rejection_tracker(JSContext *ctx, JSValueConst promise,
                                    JSValueConst reason,
                                    JS_BOOL is_handled, void *opaque)
  {
    if (is_handled)
      return;
    ((RuntimeOpaque *)opaque)->channel(ctx, JSChannelType_PROMISE_TRACK, &reason);
  }

  int js_interrupt_handler(JSRuntime * rt, void * opaque) {
    RuntimeOpaque *op = (RuntimeOpaque *)opaque;
    if (op->timeout && op->start_ms &&
        (js_monotonic_ms() - op->start_ms) > op->timeout) {
      op->start_ms = 0;
      return 1;
    }
    return 0;
  }

  DLLEXPORT JSRuntime *jsNewRuntime(JSChannel channel, int64_t timeout)
  {
    JSRuntime *rt = JS_NewRuntime();
    RuntimeOpaque *opaque = new RuntimeOpaque({channel, timeout, 0, 0});
    JS_SetRuntimeOpaque(rt, opaque);
    JS_SetHostPromiseRejectionTracker(rt, js_promise_rejection_tracker, opaque);
    JS_SetModuleLoaderFunc(rt, nullptr, js_module_loader, opaque);
    JS_SetInterruptHandler(rt, js_interrupt_handler, opaque);
    return rt;
  }

  DLLEXPORT uint32_t jsNewClass(JSContext *ctx, const char *name)
  {
    /* Allocate the class id once per process: JS_NewClassID only allocates
       while the id is 0, and ids are global and limited to 16 bits. */
    static JSClassID dartObjectClassId = 0;
    JSClassID QJSClassId = JS_NewClassID(&dartObjectClassId);
    JSRuntime *rt = JS_GetRuntime(ctx);
    if (!JS_IsRegisteredClass(rt, QJSClassId))
    {
      JSClassDef def{
          name,
          // destructor
          [](JSRuntime *rt, JSValue obj) noexcept
          {
            JSClassID classid = JS_GetClassID(obj);
            void *opaque = JS_GetOpaque(obj, classid);
            RuntimeOpaque *runtimeOpaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
            if (runtimeOpaque == nullptr)
              return;
            runtimeOpaque->channel((JSContext *)rt, JSChannelType_FREE_OBJECT, opaque);
          }};
      int e = JS_NewClass(rt, QJSClassId, &def);
      if (e < 0)
      {
        JS_ThrowInternalError(ctx, "Cant register class %s", name);
        return 0;
      }
    }
    return QJSClassId;
  }

  DLLEXPORT void *jsGetObjectOpaque(JSValue *obj, uint32_t classid)
  {
    return JS_GetOpaque(*obj, classid);
  }

  DLLEXPORT JSValue *jsNewObjectClass(JSContext *ctx, uint32_t QJSClassId, void *opaque)
  {
    auto jsobj = new JSValue(JS_NewObjectClass(ctx, QJSClassId));
    if (JS_IsException(*jsobj))
      return jsobj;
    JS_SetOpaque(*jsobj, opaque);
    return jsobj;
  }

  DLLEXPORT void jsSetMaxStackSize(JSRuntime *rt, size_t stack_size)
  {
    JS_SetMaxStackSize(rt, stack_size);
  }

  DLLEXPORT void jsSetMemoryLimit(JSRuntime *rt, size_t limit)
  {
    JS_SetMemoryLimit(rt, limit);
  }

  DLLEXPORT void jsSetStripInfo(JSRuntime *rt, int32_t flags)
  {
    JS_SetStripInfo(rt, flags);
  }

  DLLEXPORT int32_t jsGetStripInfo(JSRuntime *rt)
  {
    return JS_GetStripInfo(rt);
  }

  DLLEXPORT void jsRunGC(JSRuntime *rt)
  {
    JS_RunGC(rt);
  }

  /* out[0..]: malloc_size, malloc_limit, memory_used_size, malloc_count,
     memory_used_count, atom_count, atom_size, str_count, str_size,
     obj_count, obj_size, prop_count, prop_size (n must be >= 13). */
  DLLEXPORT void jsComputeMemoryUsage(JSRuntime *rt, int64_t *out, int32_t n)
  {
    JSMemoryUsage s;
    JS_ComputeMemoryUsage(rt, &s);
    if (!out || n < 13)
      return;
    out[0] = s.malloc_size;
    out[1] = s.malloc_limit;
    out[2] = s.memory_used_size;
    out[3] = s.malloc_count;
    out[4] = s.memory_used_count;
    out[5] = s.atom_count;
    out[6] = s.atom_size;
    out[7] = s.str_count;
    out[8] = s.str_size;
    out[9] = s.obj_count;
    out[10] = s.obj_size;
    out[11] = s.prop_count;
    out[12] = s.prop_size;
  }

  DLLEXPORT void jsFreeRuntime(JSRuntime *rt)
  {
    RuntimeOpaque *opauqe = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (opauqe)
      delete opauqe;
    JS_SetRuntimeOpaque(rt, nullptr);
    JS_FreeRuntime(rt);
  }

  DLLEXPORT JSValue *jsNewCFunction(JSContext *ctx, JSValue *funcData)
  {
    return new JSValue(JS_NewCFunctionData(ctx, js_channel, 0, 0, 1, funcData));
  }

  DLLEXPORT JSContext *jsNewContext(JSRuntime *rt)
  {
    JS_UpdateStackTop(rt);
    JSContext *ctx = JS_NewContext(rt);
    return ctx;
  }

  DLLEXPORT void jsFreeContext(JSContext *ctx)
  {
    JS_FreeContext(ctx);
  }

  DLLEXPORT JSRuntime *jsGetRuntime(JSContext *ctx)
  {
    return JS_GetRuntime(ctx);
  }

  void js_begin_call(JSRuntime *rt) {
    JS_UpdateStackTop(rt);
    RuntimeOpaque *opaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (!opaque)
      return;
    if (opaque->call_depth == 0)
      opaque->start_ms = js_monotonic_ms();
    opaque->call_depth++;
  }

  void js_end_call(JSRuntime *rt) {
    RuntimeOpaque *opaque = (RuntimeOpaque *)JS_GetRuntimeOpaque(rt);
    if (!opaque || opaque->call_depth <= 0)
      return;
    opaque->call_depth--;
    if (opaque->call_depth == 0)
      opaque->start_ms = 0;
  }

  DLLEXPORT void jsBeginCall(JSContext *ctx)
  {
    js_begin_call(JS_GetRuntime(ctx));
  }

  DLLEXPORT void jsEndCall(JSContext *ctx)
  {
    js_end_call(JS_GetRuntime(ctx));
  }

  DLLEXPORT JSValue *jsEval(JSContext *ctx, const char *input, size_t input_len, const char *filename, int32_t eval_flags)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue *ret = new JSValue(JS_Eval(ctx, input, input_len, filename, eval_flags));
    js_end_call(rt);
    return ret;
  }

  DLLEXPORT int32_t jsValueGetTag(JSValue *val)
  {
    return JS_VALUE_GET_TAG(*val);
  }

  DLLEXPORT void *jsValueGetPtr(JSValue *val)
  {
    return JS_VALUE_GET_PTR(*val);
  }

  DLLEXPORT int32_t jsTagIsFloat64(int32_t tag)
  {
    return JS_TAG_IS_FLOAT64(tag);
  }

  DLLEXPORT JSValue *jsNewBool(JSContext *ctx, int32_t val)
  {
    return new JSValue(JS_NewBool(ctx, val));
  }

  DLLEXPORT JSValue *jsNewInt64(JSContext *ctx, int64_t val)
  {
    return new JSValue(JS_NewInt64(ctx, val));
  }

  DLLEXPORT JSValue *jsNewBigInt64(JSContext *ctx, int64_t v)
  {
    return new JSValue(JS_NewBigInt64(ctx, v));
  }

  DLLEXPORT JSValue *jsNewFloat64(JSContext *ctx, double val)
  {
    return new JSValue(JS_NewFloat64(ctx, val));
  }

  DLLEXPORT JSValue *jsNewString(JSContext *ctx, const char *str, size_t len)
  {
    return new JSValue(JS_NewStringLen(ctx, str, len));
  }

  DLLEXPORT JSValue *jsNewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len)
  {
    return new JSValue(JS_NewArrayBufferCopy(ctx, buf, len));
  }

  DLLEXPORT uint8_t *jsAllocBuffer(size_t len)
  {
    bridge_alloc_calls.fetch_add(1);
    bridge_alloc_bytes.fetch_add(len);
    return (uint8_t *)malloc(len == 0 ? 1 : len);
  }

  DLLEXPORT void jsMemcpy(uint8_t *dst, const uint8_t *src, size_t len)
  {
    bridge_memcpy_calls.fetch_add(1);
    bridge_memcpy_bytes.fetch_add(len);
    memcpy(dst, src, len);
  }

  static void js_free_owned_buffer(JSRuntime *rt, void *opaque, void *ptr)
  {
    bridge_free_calls.fetch_add(1);
    free(ptr);
  }

  DLLEXPORT JSValue *jsNewArrayBufferOwned(JSContext *ctx, uint8_t *buf, size_t len)
  {
    JSValue ret = JS_NewArrayBuffer(ctx, buf, len, js_free_owned_buffer, NULL, 0);
    if (JS_IsException(ret))
      free(buf);
    return new JSValue(ret);
  }

  DLLEXPORT JSValue *jsNewArray(JSContext *ctx)
  {
    return new JSValue(JS_NewArray(ctx));
  }

  DLLEXPORT JSValue *jsNewObject(JSContext *ctx)
  {
    return new JSValue(JS_NewObject(ctx));
  }

  DLLEXPORT void jsFreeValue(JSContext *ctx, JSValue *v, int32_t free)
  {
    JS_FreeValue(ctx, *v);
    if (free)
      delete v;
  }

  DLLEXPORT void jsFreeValueRT(JSRuntime *rt, JSValue *v, int32_t free)
  {
    JS_FreeValueRT(rt, *v);
    if (free)
      delete v;
  }

  DLLEXPORT JSValue *jsDupValue(JSContext *ctx, JSValueConst *v)
  {
    return new JSValue(JS_DupValue(ctx, *v));
  }

  DLLEXPORT JSValue *jsDupValueRT(JSRuntime *rt, JSValue *v)
  {
    return new JSValue(JS_DupValueRT(rt, *v));
  }

  DLLEXPORT int32_t jsToBool(JSContext *ctx, JSValueConst *val)
  {
    return JS_ToBool(ctx, *val);
  }

  DLLEXPORT int64_t jsToInt64(JSContext *ctx, JSValueConst *val)
  {
    int64_t p;
    JS_ToInt64(ctx, &p, *val);
    return p;
  }

  DLLEXPORT double jsToFloat64(JSContext *ctx, JSValueConst *val)
  {
    double p;
    JS_ToFloat64(ctx, &p, *val);
    return p;
  }

  DLLEXPORT const char *jsToCString(JSContext *ctx, JSValueConst *val, size_t *plen)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    const char *ret = JS_ToCStringLen(ctx, plen, *val);
    js_end_call(rt);
    return ret;
  }

  DLLEXPORT void jsFreeCString(JSContext *ctx, const char *ptr)
  {
    return JS_FreeCString(ctx, ptr);
  }

  DLLEXPORT uint8_t *jsGetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst *obj)
  {
    uint8_t *ptr = JS_GetArrayBuffer(ctx, psize, *obj);
    /* The host uses this as a probe on every object, and QuickJS reports "not
       an ArrayBuffer" by throwing. Drop that exception so it cannot resurface
       later as a bogus failure of an unrelated call. */
    if (ptr == NULL)
      JS_FreeValue(ctx, JS_GetException(ctx));
    return ptr;
  }

  // Create a JS TypedArray of `type` (JSTypedArrayEnum) from a raw byte buffer.
  DLLEXPORT JSValue *jsNewTypedArray(JSContext *ctx, const uint8_t *buf, size_t len, int32_t type)
  {
    JSValue arrayBuffer = JS_NewArrayBufferCopy(ctx, buf, len);
    if (JS_IsException(arrayBuffer))
      return new JSValue(arrayBuffer);
    // The typed array constructor reads argv[0]=buffer, argv[1]=offset,
    // argv[2]=length; pass undefined offset/length to view the whole buffer.
    JSValueConst argv[3] = {arrayBuffer, JS_UNDEFINED, JS_UNDEFINED};
    JSValue ta = JS_NewTypedArray(ctx, 3, argv, (JSTypedArrayEnum)type);
    JS_FreeValue(ctx, arrayBuffer);
    return new JSValue(ta);
  }

  DLLEXPORT JSValue *jsNewTypedArrayOwned(JSContext *ctx, uint8_t *buf, size_t len, int32_t type)
  {
    bridge_owned_typed_array_calls.fetch_add(1);
    JSValue arrayBuffer = JS_NewArrayBuffer(ctx, buf, len, js_free_owned_buffer, NULL, 0);
    if (JS_IsException(arrayBuffer))
    {
      free(buf);
      return new JSValue(arrayBuffer);
    }
    JSValueConst argv[3] = {arrayBuffer, JS_UNDEFINED, JS_UNDEFINED};
    JSValue ta = JS_NewTypedArray(ctx, 3, argv, (JSTypedArrayEnum)type);
    JS_FreeValue(ctx, arrayBuffer);
    return new JSValue(ta);
  }

  // Infer JSTypedArrayEnum from element size + constructor name.
  // Avoids hardcoding JS_CLASS_* numeric IDs (they change across QuickJS trees).
  static int32_t js_typed_array_type_from_bpe_and_name(JSContext *ctx, JSValueConst val,
                                                      size_t bytes_per_element)
  {
    JSValue ctor = JS_GetPropertyStr(ctx, val, "constructor");
    if (JS_IsException(ctor) || JS_IsUndefined(ctor) || JS_IsNull(ctor)) {
      JS_FreeValue(ctx, ctor);
      return -1;
    }
    JSValue name_val = JS_GetPropertyStr(ctx, ctor, "name");
    JS_FreeValue(ctx, ctor);
    if (JS_IsException(name_val)) {
      JS_FreeValue(ctx, name_val);
      return -1;
    }
    const char *name = JS_ToCString(ctx, name_val);
    JS_FreeValue(ctx, name_val);
    if (!name)
      return -1;

    int32_t type = -1;
    if (bytes_per_element == 1) {
      if (!strcmp(name, "Uint8ClampedArray")) type = JS_TYPED_ARRAY_UINT8C;
      else if (!strcmp(name, "Int8Array")) type = JS_TYPED_ARRAY_INT8;
      else if (!strcmp(name, "Uint8Array")) type = JS_TYPED_ARRAY_UINT8;
    } else if (bytes_per_element == 2) {
      if (!strcmp(name, "Int16Array")) type = JS_TYPED_ARRAY_INT16;
      else if (!strcmp(name, "Uint16Array")) type = JS_TYPED_ARRAY_UINT16;
      else if (!strcmp(name, "Float16Array")) type = JS_TYPED_ARRAY_FLOAT16;
    } else if (bytes_per_element == 4) {
      if (!strcmp(name, "Int32Array")) type = JS_TYPED_ARRAY_INT32;
      else if (!strcmp(name, "Uint32Array")) type = JS_TYPED_ARRAY_UINT32;
      else if (!strcmp(name, "Float32Array")) type = JS_TYPED_ARRAY_FLOAT32;
    } else if (bytes_per_element == 8) {
      if (!strcmp(name, "BigInt64Array")) type = JS_TYPED_ARRAY_BIG_INT64;
      else if (!strcmp(name, "BigUint64Array")) type = JS_TYPED_ARRAY_BIG_UINT64;
      else if (!strcmp(name, "Float64Array")) type = JS_TYPED_ARRAY_FLOAT64;
    }
    JS_FreeCString(ctx, name);
    return type;
  }

  // If `val` is a typed array, return a pointer to its element data, set
  // `*plength` to the byte length and `*ptype` to the JSTypedArrayEnum.
  // Returns NULL when `val` is not a (supported) typed array / DataView.
  DLLEXPORT uint8_t *jsGetTypedArrayData(JSContext *ctx, JSValueConst *val,
                                         size_t *plength, int32_t *ptype)
  {
    bridge_typed_array_data_calls.fetch_add(1);
    size_t byte_offset = 0, byte_length = 0, bytes_per_element = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, *val, &byte_offset, &byte_length, &bytes_per_element);
    if (JS_IsException(buffer))
    {
      JS_FreeValue(ctx, buffer);
      /* "not a TypedArray" is how this probe says no. Leaving it pending would
         make the *next* unrelated exception check in the host report it. */
      JS_FreeValue(ctx, JS_GetException(ctx));
      return NULL;
    }
    // DataView also succeeds; we only want typed arrays with a known enum.
    int32_t type = js_typed_array_type_from_bpe_and_name(ctx, *val, bytes_per_element);
    if (type < 0)
    {
      JS_FreeValue(ctx, buffer);
      JS_FreeValue(ctx, JS_GetException(ctx));
      return NULL;
    }
    size_t buf_size = 0;
    uint8_t *ptr = JS_GetArrayBuffer(ctx, &buf_size, buffer);
    // The typed array still holds a reference to the same underlying buffer,
    // so `ptr` stays valid after freeing this duplicated handle.
    JS_FreeValue(ctx, buffer);
    if (ptr == nullptr)
      return NULL;
    *plength = byte_length;
    *ptype = type;
    return ptr + byte_offset;
  }

  DLLEXPORT int32_t jsIsFunction(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsFunction(ctx, *val);
  }

  DLLEXPORT int32_t jsIsPromise(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsPromise(ctx, *val);
  }

  DLLEXPORT int32_t jsIsArray(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsArray(ctx, *val);
  }

  DLLEXPORT int32_t jsIsMap(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsMap(ctx, *val);
  }

  DLLEXPORT int32_t jsIsError(JSContext *ctx, JSValueConst *val)
  {
    return JS_IsError(ctx, *val);
  }

  DLLEXPORT JSValue *jsNewError(JSContext *ctx)
  {
    return new JSValue(JS_NewError(ctx));
  }

  DLLEXPORT JSValue *jsGetProperty(JSContext *ctx, JSValueConst *this_obj,
                                   JSAtom prop)
  {
    return new JSValue(JS_GetProperty(ctx, *this_obj, prop));
  }

  DLLEXPORT int32_t jsDefinePropertyValue(JSContext *ctx, JSValueConst *this_obj,
                                          JSAtom prop, JSValue *val, int32_t flags)
  {
    int32_t ret = JS_DefinePropertyValue(ctx, *this_obj, prop, *val, flags);
    delete val;
    return ret;
  }

  DLLEXPORT JSValue *jsGetPropertyUint32(JSContext *ctx, JSValueConst *this_obj,
                                         uint32_t idx)
  {
    return new JSValue(JS_GetPropertyUint32(ctx, *this_obj, idx));
  }

  DLLEXPORT int32_t jsDefinePropertyValueUint32(JSContext *ctx, JSValueConst *this_obj,
                                                uint32_t idx, JSValue *val, int32_t flags)
  {
    int32_t ret = JS_DefinePropertyValueUint32(ctx, *this_obj, idx, *val, flags);
    delete val;
    return ret;
  }

  DLLEXPORT void jsFreeAtom(JSContext *ctx, JSAtom v)
  {
    JS_FreeAtom(ctx, v);
  }

  DLLEXPORT JSAtom jsValueToAtom(JSContext *ctx, JSValueConst *val)
  {
    return JS_ValueToAtom(ctx, *val);
  }

  DLLEXPORT JSValue *jsAtomToValue(JSContext *ctx, JSAtom val)
  {
    return new JSValue(JS_AtomToValue(ctx, val));
  }

  DLLEXPORT int32_t jsGetOwnPropertyNames(JSContext *ctx, JSPropertyEnum **ptab,
                                          uint32_t *plen, JSValueConst *obj, int32_t flags)
  {
    return JS_GetOwnPropertyNames(ctx, ptab, plen, *obj, flags);
  }

  DLLEXPORT JSAtom jsPropertyEnumGetAtom(JSPropertyEnum *ptab, int32_t i)
  {
    return ptab[i].atom;
  }

  DLLEXPORT uint32_t sizeOfJSValue()
  {
    return sizeof(JSValue);
  }

  DLLEXPORT void setJSValueList(JSValue *list, uint32_t i, JSValue *val)
  {
    list[i] = *val;
  }

  DLLEXPORT JSValue *jsCall(JSContext *ctx, JSValueConst *func_obj, JSValueConst *this_obj,
                            int32_t argc, JSValueConst *argv)
  {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue *ret = new JSValue(JS_Call(ctx, *func_obj, *this_obj, argc, argv));
    js_end_call(rt);
    return ret;
  }

  DLLEXPORT int32_t jsIsException(JSValueConst *val)
  {
    return JS_IsException(*val);
  }

  DLLEXPORT JSValue *jsGetException(JSContext *ctx)
  {
    return new JSValue(JS_GetException(ctx));
  }

  DLLEXPORT int32_t jsExecutePendingJob(JSRuntime *rt)
  {
    js_begin_call(rt);
    JSContext *ctx;
    int ret = JS_ExecutePendingJob(rt, &ctx);
    js_end_call(rt);
    return ret;
  }

  DLLEXPORT int32_t jsIsJobPending(JSRuntime *rt)
  {
    return JS_IsJobPending(rt);
  }

  DLLEXPORT JSValue *jsNewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs)
  {
    return new JSValue(JS_NewPromiseCapability(ctx, resolving_funcs));
  }

  DLLEXPORT void jsFree(JSContext *ctx, void *ptab)
  {
    js_free(ctx, ptab);
  }

  DLLEXPORT uint8_t *CompileScript(JSContext *ctx, const char *script, const char *fileName, size_t *lengthPtr) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue value = JS_Eval(ctx, script, strlen(script), fileName, JS_EVAL_FLAG_COMPILE_ONLY);

    if (JS_IsException(value)) {
      JS_FreeValue(ctx, value);
      js_end_call(rt);
      return NULL;
    }

    uint8_t *out = JS_WriteObject(ctx, lengthPtr, value, JS_WRITE_OBJ_BYTECODE);
    JS_FreeValue(ctx, value);
    js_end_call(rt);
    return out;
  }

  DLLEXPORT JSValue *EvaluateBytecode(JSContext *ctx, size_t length, uint8_t *buf) {
    JSRuntime *rt = JS_GetRuntime(ctx);
    js_begin_call(rt);
    JSValue obj = JS_ReadObject(ctx, buf, length, JS_READ_OBJ_BYTECODE);

    if (JS_IsException(obj)) {
      js_end_call(rt);
      return NULL;
    }

    JSValue value = JS_EvalFunction(ctx, obj);
    js_end_call(rt);

    return new JSValue(value);
  }

  /* Web API natives (TextEncoder / TextDecoder / performance.now). */

  // Byte view of a TypedArray argument. Returns -1 with a pending exception.
  static int js_web_get_bytes(JSContext *ctx, JSValueConst val, uint8_t **pdata, size_t *plen)
  {
    size_t offset = 0, length = 0, bytes_per_element = 0;
    JSValue buffer = JS_GetTypedArrayBuffer(ctx, val, &offset, &length, &bytes_per_element);
    if (JS_IsException(buffer))
      return -1;
    *pdata = NULL;
    *plen = 0;
    if (length > 0)
    {
      size_t size = 0;
      uint8_t *ptr = JS_GetArrayBuffer(ctx, &size, buffer);
      if (!ptr)
      {
        JS_FreeValue(ctx, buffer);
        return -1;
      }
      *pdata = ptr + offset;
      *plen = length;
    }
    JS_FreeValue(ctx, buffer);
    return 0;
  }

  // QuickJS emits lone surrogates as 3-byte WTF-8 (ED A0..BF xx); TextEncoder
  // must emit U+FFFD instead. 0xED is never a continuation byte.
  static void js_web_replace_surrogates(uint8_t *p, size_t len)
  {
    for (size_t i = 0; i + 2 < len; i++)
    {
      if (p[i] == 0xED && p[i + 1] >= 0xA0)
      {
        p[i] = 0xEF;
        p[i + 1] = 0xBF;
        p[i + 2] = 0xBD;
        i += 2;
      }
    }
  }

  // WHATWG UTF-8 decoder step: length of the valid sequence at p, or 0 with
  // *pskip set to the maximal invalid subpart to replace by one U+FFFD.
  static size_t js_web_utf8_valid(const uint8_t *p, size_t n, size_t *pskip)
  {
    uint8_t b = p[0];
    uint8_t lo = 0x80, hi = 0xBF;
    size_t need;
    if (b < 0x80)
      return 1;
    if (b >= 0xC2 && b <= 0xDF)
      need = 1;
    else if (b >= 0xE0 && b <= 0xEF)
    {
      need = 2;
      if (b == 0xE0)
        lo = 0xA0;
      else if (b == 0xED)
        hi = 0x9F;
    }
    else if (b >= 0xF0 && b <= 0xF4)
    {
      need = 3;
      if (b == 0xF0)
        lo = 0x90;
      else if (b == 0xF4)
        hi = 0x8F;
    }
    else
    {
      *pskip = 1;
      return 0;
    }
    for (size_t j = 1; j <= need; j++)
    {
      if (j >= n || p[j] < lo || p[j] > hi)
      {
        *pskip = j;
        return 0;
      }
      lo = 0x80;
      hi = 0xBF;
    }
    return need + 1;
  }

  // utf8Encode(string) -> Uint8Array
  static JSValue js_web_utf8_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
  {
    size_t len = 0;
    const char *str = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!str)
      return JS_EXCEPTION;
    JSValue buffer = JS_NewArrayBufferCopy(ctx, (const uint8_t *)str, len);
    JS_FreeCString(ctx, str);
    if (JS_IsException(buffer))
      return buffer;
    if (len > 0)
    {
      size_t size = 0;
      uint8_t *data = JS_GetArrayBuffer(ctx, &size, buffer);
      if (data)
        js_web_replace_surrogates(data, size);
    }
    JSValueConst args[3] = {buffer, JS_UNDEFINED, JS_UNDEFINED};
    JSValue ta = JS_NewTypedArray(ctx, 3, args, JS_TYPED_ARRAY_UINT8);
    JS_FreeValue(ctx, buffer);
    return ta;
  }

  // utf8EncodeInto(string, Uint8Array) -> [read (UTF-16 units), written]
  static JSValue js_web_utf8_encode_into(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
  {
    size_t len = 0;
    const char *str = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!str)
      return JS_EXCEPTION;
    uint8_t *dst = NULL;
    size_t cap = 0;
    if (js_web_get_bytes(ctx, argv[1], &dst, &cap) < 0)
    {
      JS_FreeCString(ctx, str);
      return JS_EXCEPTION;
    }
    const uint8_t *src = (const uint8_t *)str;
    size_t i = 0, written = 0;
    int64_t read = 0;
    while (i < len)
    {
      uint8_t b = src[i];
      size_t n = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
      if (i + n > len || written + n > cap)
        break;
      if (n == 3 && b == 0xED && src[i + 1] >= 0xA0)
      {
        dst[written] = 0xEF;
        dst[written + 1] = 0xBF;
        dst[written + 2] = 0xBD;
      }
      else
      {
        memcpy(dst + written, src + i, n);
      }
      written += n;
      i += n;
      read += n == 4 ? 2 : 1;
    }
    JS_FreeCString(ctx, str);
    JSValue ret = JS_NewArray(ctx);
    if (JS_IsException(ret))
      return ret;
    JS_SetPropertyUint32(ctx, ret, 0, JS_NewInt64(ctx, read));
    JS_SetPropertyUint32(ctx, ret, 1, JS_NewInt64(ctx, (int64_t)written));
    return ret;
  }

  // utf8Decode(Uint8Array, fatal) -> string; invalid input throws when fatal.
  static JSValue js_web_utf8_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
  {
    uint8_t *src = NULL;
    size_t len = 0;
    if (js_web_get_bytes(ctx, argv[0], &src, &len) < 0)
      return JS_EXCEPTION;
    int fatal = JS_ToBool(ctx, argv[1]);
    size_t i = 0, skip = 0;
    while (i < len)
    {
      if (src[i] < 0x80)
      {
        i++;
        continue;
      }
      size_t k = js_web_utf8_valid(src + i, len - i, &skip);
      if (!k)
        break;
      i += k;
    }
    if (i == len)
      return JS_NewStringLen(ctx, len ? (const char *)src : "", len);
    if (fatal)
      return JS_ThrowTypeError(ctx, "The encoded data was not valid");
    uint8_t *out = (uint8_t *)js_malloc(ctx, len * 3);
    if (!out)
      return JS_EXCEPTION;
    memcpy(out, src, i);
    size_t o = i;
    while (i < len)
    {
      if (src[i] < 0x80)
      {
        out[o++] = src[i++];
        continue;
      }
      size_t k = js_web_utf8_valid(src + i, len - i, &skip);
      if (k)
      {
        memcpy(out + o, src + i, k);
        o += k;
        i += k;
      }
      else
      {
        out[o++] = 0xEF;
        out[o++] = 0xBF;
        out[o++] = 0xBD;
        i += skip;
      }
    }
    JSValue ret = JS_NewStringLen(ctx, (const char *)out, o);
    js_free(ctx, out);
    return ret;
  }

  // now() -> monotonic milliseconds (double)
  static JSValue js_web_now(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
  {
    using namespace std::chrono;
    return JS_NewFloat64(ctx, duration<double, std::milli>(steady_clock::now().time_since_epoch()).count());
  }

  DLLEXPORT JSValue *jsNewWebNatives(JSContext *ctx)
  {
    static const struct
    {
      const char *name;
      int length;
      JSCFunction *func;
    } funcs[] = {
        {"utf8Encode", 1, js_web_utf8_encode},
        {"utf8EncodeInto", 2, js_web_utf8_encode_into},
        {"utf8Decode", 2, js_web_utf8_decode},
        {"now", 0, js_web_now},
    };
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj))
      return new JSValue(obj);
    for (const auto &f : funcs)
    {
      JSValue fn = JS_NewCFunction(ctx, f.func, f.name, f.length);
      if (JS_IsException(fn) || JS_SetPropertyStr(ctx, obj, f.name, fn) < 0)
      {
        JS_FreeValue(ctx, obj);
        return new JSValue(JS_EXCEPTION);
      }
    }
    return new JSValue(obj);
  }

}
