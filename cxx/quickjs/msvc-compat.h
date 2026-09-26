/*
 * MSVC compatibility for the bundled QuickJS.
 *
 * QuickJS targets GCC and Clang, while Flutter builds the Windows plugin with
 * MSVC. Every workaround lives here so the upstream files keep only a handful
 * of `#ifdef _MSC_VER` lines and a QuickJS upgrade stays close to a plain
 * overwrite of them. cutils.h includes this header and every QuickJS
 * translation unit includes cutils.h.
 *
 * Not part of upstream QuickJS.
 */
#ifndef QUICKJS_MSVC_COMPAT_H
#define QUICKJS_MSVC_COMPAT_H

#ifdef _MSC_VER

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
/* winsock2.h has to precede windows.h, and it declares struct timeval. */
#include <winsock2.h>
#include <windows.h>
#include <errno.h>
#include <intrin.h>
/* quickjs.c calls alloca() but only includes <malloc.h> on Linux and the BSDs.
   Without a declaration MSVC assumes `int alloca()` and truncates the pointer,
   which crashes on the first JS function call. */
#include <malloc.h>
#include <stdint.h>
#include <time.h>

#ifndef alloca
#define alloca _alloca
#endif

/* MSVC has no __attribute__, so it expands to nothing. What QuickJS asks for
   is a diagnostic hint (format, warn_unused_result, unused), an inlining hint
   (always_inline, noinline), `packed`, which cutils.h restates as a
   `#pragma pack`, or `aligned(JS_MALLOC_ALIGN)` on a flexible array member,
   which is the layout MSVC produces anyway — quickjs.c asserts that. */
#define __attribute__(x)
#define __attribute(x)

/* GCC builtins. Defining them here keeps cutils.h free of MSVC branches. */
#define __builtin_expect(x, expected) (x)

static __inline int __qjs_clz32(unsigned int a)
{
    unsigned long index;
    _BitScanReverse(&index, a);
    return 31 - (int)index;
}

static __inline int __qjs_ctz32(unsigned int a)
{
    unsigned long index;
    _BitScanForward(&index, a);
    return (int)index;
}

static __inline int __qjs_clz64(uint64_t a)
{
#if defined(_M_X64) || defined(_M_ARM64)
    unsigned long index;
    _BitScanReverse64(&index, a);
    return 63 - (int)index;
#else
    uint32_t hi = (uint32_t)(a >> 32);
    return hi ? __qjs_clz32(hi) : 32 + __qjs_clz32((uint32_t)a);
#endif
}

static __inline int __qjs_ctz64(uint64_t a)
{
#if defined(_M_X64) || defined(_M_ARM64)
    unsigned long index;
    _BitScanForward64(&index, a);
    return (int)index;
#else
    uint32_t lo = (uint32_t)a;
    return lo ? __qjs_ctz32(lo) : 32 + __qjs_ctz32((uint32_t)(a >> 32));
#endif
}

#define __builtin_clz(a) __qjs_clz32(a)
#define __builtin_clzll(a) __qjs_clz64(a)
#define __builtin_ctz(a) __qjs_ctz32(a)
#define __builtin_ctzll(a) __qjs_ctz64(a)
#define __builtin_frame_address(level) ((void *)_AddressOfReturnAddress())

/* <sys/time.h> */
static __inline int gettimeofday(struct timeval *tv, void *tz)
{
    /* Number of 100ns ticks between 1601-01-01 and 1970-01-01. */
    static const uint64_t EPOCH_OFFSET = 116444736000000000ULL;
    FILETIME ft;
    uint64_t usec;

    (void)tz;
    GetSystemTimeAsFileTime(&ft);
    usec = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    usec = (usec - EPOCH_OFFSET) / 10;
    tv->tv_sec = (long)(usec / 1000000);
    tv->tv_usec = (long)(usec % 1000000);
    return 0;
}

#define CLOCK_REALTIME 0
static __inline int clock_gettime(int clock_id, struct timespec *ts)
{
    (void)clock_id;
    return timespec_get(ts, TIME_UTC) == TIME_UTC ? 0 : -1;
}

/* The subset of pthreads that Atomics.wait/notify and JS_NewClassID use.
   Nothing in QuickJS creates a thread, so only the mutex and the condition
   variable are needed. SRW locks may not be recursive; neither are the
   PTHREAD_MUTEX_INITIALIZER mutexes they replace. */
typedef SRWLOCK pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT

static __inline int pthread_mutex_lock(pthread_mutex_t *mutex)
{
    AcquireSRWLockExclusive(mutex);
    return 0;
}

static __inline int pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    ReleaseSRWLockExclusive(mutex);
    return 0;
}

static __inline int pthread_cond_init(pthread_cond_t *cond, const void *attr)
{
    (void)attr;
    InitializeConditionVariable(cond);
    return 0;
}

static __inline int pthread_cond_destroy(pthread_cond_t *cond)
{
    (void)cond;
    return 0;
}

static __inline int pthread_cond_signal(pthread_cond_t *cond)
{
    WakeConditionVariable(cond);
    return 0;
}

static __inline int pthread_cond_wait(pthread_cond_t *cond,
                                      pthread_mutex_t *mutex)
{
    return SleepConditionVariableSRW(cond, mutex, INFINITE, 0) ? 0 : EINVAL;
}

static __inline int pthread_cond_timedwait(pthread_cond_t *cond,
                                           pthread_mutex_t *mutex,
                                           const struct timespec *abstime)
{
    struct timespec now;
    int64_t msec;

    clock_gettime(CLOCK_REALTIME, &now);
    msec = (int64_t)(abstime->tv_sec - now.tv_sec) * 1000 +
           (abstime->tv_nsec - now.tv_nsec) / 1000000;
    if (msec < 0)
        msec = 0;
    if (SleepConditionVariableSRW(cond, mutex, (DWORD)msec, 0))
        return 0;
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}

#endif /* _MSC_VER */

#endif /* QUICKJS_MSVC_COMPAT_H */
