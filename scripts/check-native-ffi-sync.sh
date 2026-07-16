#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for file in \
  cxx-windows/ffi.cpp \
  ios/flutter_qjs_next/Sources/flutter_qjs_next/ffi.cpp \
  macos/flutter_qjs_next/Sources/flutter_qjs_next/ffi.cpp
do
  cmp "$root/cxx/ffi.cpp" "$root/$file"
done

for file in \
  cxx-windows/ffi.h \
  ios/flutter_qjs_next/Sources/flutter_qjs_next/ffi.h \
  macos/flutter_qjs_next/Sources/flutter_qjs_next/ffi.h
do
  cmp "$root/cxx/ffi.h" "$root/$file"
done

printf '%s\n' 'native FFI sources are synchronized'
