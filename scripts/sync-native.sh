#!/usr/bin/env sh
# Copy the native bridge and QuickJS from cxx/ into the Apple Swift Package
# Manager trees, and set CONFIG_VERSION in each Package.swift from
# cxx/quickjs/VERSION.txt. Edit cxx/ only, then run this script.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$root/cxx/quickjs/VERSION.txt")

for platform in ios macos
do
  sources="$root/$platform/flutter_qjs_next/Sources/flutter_qjs_next"
  cp "$root/cxx/ffi.cpp" "$root/cxx/ffi.h" "$sources/"
  rm -rf "$sources/quickjs"
  cp -R "$root/cxx/quickjs" "$sources/quickjs"

  manifest="$root/$platform/flutter_qjs_next/Package.swift"
  sed "s/\.define(\"CONFIG_VERSION\", to: \"\\\\\"[^\"\\\\]*\\\\\"\")/.define(\"CONFIG_VERSION\", to: \"\\\\\"$version\\\\\"\")/" \
    "$manifest" > "$manifest.tmp"
  # Overwrite in place so the file keeps its mode.
  cat "$manifest.tmp" > "$manifest"
  rm "$manifest.tmp"
done

printf '%s\n' "native sources synchronized (QuickJS $version)"
