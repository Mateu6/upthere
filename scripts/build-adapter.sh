#!/bin/bash
# Builds ungive/mediaremote-adapter and copies it into the app bundle's
# Resources. The framework is never linked: it is loaded by /usr/bin/perl
# (an Apple platform binary entitled to use MediaRemote on macOS 15.4+).
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SRC="${SRCROOT}/Vendor/mediaremote-adapter"
OUT="${PROJECT_TEMP_DIR:-/tmp}/mediaremote-adapter-build"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/MediaRemoteAdapter"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "error: Vendor/mediaremote-adapter is missing. Run: git submodule update --init"
  exit 1
fi
if ! command -v cmake >/dev/null; then
  echo "error: cmake is required to build the MediaRemote adapter (brew install cmake)"
  exit 1
fi

if [ ! -f "$OUT/CMakeCache.txt" ]; then
  cmake -S "$SRC" -B "$OUT" -DCMAKE_BUILD_TYPE=Release >/dev/null
fi
cmake --build "$OUT" --config Release >/dev/null

mkdir -p "$DEST"
rsync -a --delete "$OUT/MediaRemoteAdapter.framework" "$DEST/"
install -m 0644 "$SRC/bin/mediaremote-adapter.pl" "$DEST/mediaremote-adapter.pl"
install -m 0755 "$OUT/MediaRemoteAdapterTestClient" "$DEST/MediaRemoteAdapterTestClient"
install -m 0644 "$SRC/LICENSE" "$DEST/LICENSE"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force --sign "$IDENTITY" --options runtime \
  "$DEST/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapterTestClient" >/dev/null
