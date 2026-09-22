#!/usr/bin/env bash
# Builds llama.xcframework for iOS (device + simulator) and macOS, then
# drops it where the podspecs expect it.
#
# Run once after cloning, and again whenever the llama.cpp submodule moves.
# Takes 10-20 minutes. The output is ~200MB and is deliberately gitignored;
# CI rebuilds it and caches it by submodule SHA.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
llama="$repo/third_party/llama.cpp"

if [ ! -f "$llama/build-xcframework.sh" ]; then
  echo "llama.cpp submodule missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

(cd "$llama" && ./build-xcframework.sh)

for platform in ios macos; do
  dest="$here/../$platform/Frameworks"
  mkdir -p "$dest"
  rm -rf "$dest/llama.xcframework"
  cp -R "$llama/build-apple/llama.xcframework" "$dest/"
  echo "installed -> $dest/llama.xcframework"
done
