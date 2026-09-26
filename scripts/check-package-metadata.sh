#!/usr/bin/env sh
# Check that the iOS/macOS podspec versions match pubspec.yaml. Swift Package
# Manager is the primary Apple path; CocoaPods is the secondary one and its
# metadata has to keep up when the package version is bumped. Run by CI
# (.github/workflows/ci.yml). See doc/wiki/guides/platforms.md.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(sed -n 's/^version: *//p' "$root/pubspec.yaml")
status=0

for platform in ios macos
do
  spec="$root/$platform/flutter_qjs_next.podspec"
  spec_version=$(sed -n "s/.*s\.version *= *'\([^']*\)'.*/\1/p" "$spec" | head -1)
  if [ "$spec_version" != "$version" ]; then
    printf '%s: s.version (%s) differs from pubspec.yaml (%s)\n' \
      "$spec" "$spec_version" "$version"
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  printf '%s\n' 'package metadata is out of sync: set s.version to the pubspec version'
  exit 1
fi
printf '%s\n' 'package metadata is synchronized'
