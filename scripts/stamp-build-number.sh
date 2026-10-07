#!/bin/bash
# Build number = number of commits on HEAD, identical for local and CI
# builds of the same commit. Sparkle updates when the feed's build number is
# higher, so a local build of the current code is never "updated" to an
# older release (which a fixed local build number of 1 allowed).
set -euo pipefail

cd "${SRCROOT}"
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 1)
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${COUNT}" "${PLIST}"
echo "CFBundleVersion = ${COUNT}"
