#!/usr/bin/env bash
#
# Sign the Path of Building .app bundle with the hardened runtime and the
# entitlements required by LuaJIT's JIT.
#
# Usage:
#   macos/sign.sh [path/to/Path of Building.app]
#
# If no path is given, defaults to /tmp/pob-install-wrapper/Path of Building.app
# (the install prefix used by the local `cmake --install` workflow).
#
# The signing identity is read from $CODESIGN_IDENTITY and defaults to "-"
# (ad-hoc). For a real release build, set it to the full Developer ID:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#       macos/sign.sh
#
# Sign order matters:
#   1. Leaf dylibs first. Signing the bundle in step 2 seals the directory;
#      re-signing a dylib afterwards would invalidate that seal.
#   2. Bundle root with entitlements + hardened runtime. Signing a .app bundle
#      IS signing its main executable (codesign reads Info.plist's
#      CFBundleExecutable and signs that), so the entitlements have to be
#      passed here, not in a separate "sign the exe" pass — a later bundle
#      sign would overwrite them.
#
# The linker already ad-hoc signs every Mach-O it produces on Apple Silicon
# (otherwise they wouldn't run). This script RE-signs those with the proper
# options so the bundle passes `codesign --verify --deep --strict` and can be
# submitted to notarytool.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

APP_PATH="${1:-/tmp/pob-install-wrapper/Path of Building.app}"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: bundle not found: $APP_PATH" >&2
    echo "hint: run 'cmake --install build --prefix /tmp/pob-install-wrapper' first" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> Signing $APP_PATH"
echo "    identity:     $IDENTITY"
echo "    entitlements: $ENTITLEMENTS"
echo

# ----- 1. Leaf dylibs -----
# libSimpleGraphic.dylib, libEGL.dylib, libGLESv2.dylib, lcurl.dylib,
# lua-utf8.dylib, socket.dylib, lzip.dylib — all land in Contents/MacOS/.
echo "==> [1/2] Signing dylibs"
find "$APP_PATH/Contents/MacOS" -type f -name '*.dylib' -print0 |
while IFS= read -r -d '' dylib; do
    echo "    $(basename "$dylib")"
    codesign --force --options runtime --timestamp=none \
        --sign "$IDENTITY" "$dylib"
done

# ----- 2. Bundle (= main executable + sealed resources) -----
# Signing the bundle path signs Contents/MacOS/<CFBundleExecutable> and
# computes the sealed resource manifest. The entitlements attach to that
# main exe's signature and are what gets checked at exec time.
echo
echo "==> [2/2] Signing bundle with entitlements"
codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP_PATH"

# ----- Verify -----
echo
echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "==> Signature summary"
codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|CodeDirectory|Signature|flags)' || true

echo
echo "ok: $APP_PATH signed with identity '$IDENTITY'"
if [[ "$IDENTITY" == "-" ]]; then
    echo "note: ad-hoc signature. Gatekeeper will reject this on a downloaded"
    echo "      (quarantined) bundle. Use right-click -> Open for local testing."
fi
