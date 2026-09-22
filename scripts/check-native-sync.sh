#!/usr/bin/env sh
# Check that the Apple Swift Package Manager trees match cxx/, the single
# source of truth for the native bridge and QuickJS. Regenerate them with
# scripts/sync-native.sh. Run by CI (.github/workflows/ci.yml).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$root/cxx/quickjs/VERSION.txt")
status=0

for platform in ios macos
do
  sources="$root/$platform/flutter_qjs_next/Sources/flutter_qjs_next"
  for file in ffi.cpp ffi.h
  do
    cmp "$root/cxx/$file" "$sources/$file" || status=1
  done
  # -r also reports files present on only one side.
  diff -rq "$root/cxx/quickjs" "$sources/quickjs" || status=1

  manifest="$root/$platform/flutter_qjs_next/Package.swift"
  if grep 'CONFIG_VERSION' "$manifest" | grep -vq "\\\\\"$version\\\\\""; then
    printf '%s\n' "$manifest: CONFIG_VERSION differs from cxx/quickjs/VERSION.txt ($version)"
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  printf '%s\n' 'native sources are out of sync: run scripts/sync-native.sh'
  exit 1
fi
printf '%s\n' 'native sources are synchronized'
