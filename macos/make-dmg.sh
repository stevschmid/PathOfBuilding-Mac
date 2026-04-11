#!/usr/bin/env bash
#
# Package the signed Path of Building .app bundle into a distributable .dmg.
#
# Usage:
#   macos/make-dmg.sh [path/to/Path of Building.app] [output.dmg]
#
# Defaults:
#   input  = /tmp/pob-install-wrapper/Path of Building.app
#   output = ./Path of Building.dmg (next to the caller's CWD)
#
# Expects the .app to already be signed (e.g. via macos/sign.sh). This script
# intentionally does NOT sign anything — keeping sign/package separate means
# the same make-dmg.sh is used for both ad-hoc local testing and notarized
# release builds. Notarization is applied later to the .dmg, not here.
#
# Uses plain hdiutil (no brew/create-dmg dependency). The layout is minimal:
# a read-only compressed DMG containing the .app and an /Applications
# symlink so the user can drag-drop without opening /Applications separately.
# Cosmetic polish (custom background, window geometry, icon positions) is
# deliberately deferred — it can be added later without changing the script's
# interface.

set -euo pipefail

APP_PATH="${1:-/tmp/pob-install-wrapper/Path of Building.app}"
OUTPUT_DMG="${2:-Path of Building.dmg}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: bundle not found: $APP_PATH" >&2
    echo "hint: run 'cmake --install build --prefix /tmp/pob-install-wrapper'" >&2
    echo "      and 'macos/sign.sh' before this script" >&2
    exit 1
fi

# Sanity-check that the bundle is at least signed. hdiutil doesn't care, but
# catching an unsigned input here prevents shipping a .dmg that wouldn't run.
if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    echo "error: bundle is not validly signed: $APP_PATH" >&2
    echo "hint: run 'macos/sign.sh $APP_PATH' first" >&2
    exit 1
fi

VOLUME_NAME="Path of Building"

STAGING_DIR="$(mktemp -d -t pob-dmg-staging.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "==> Staging bundle in $STAGING_DIR"
# Use cp -a (archive): preserves symlinks, xattrs, permissions, and the code
# signature. A plain `cp -R` can strip quarantine-related metadata but not
# codesign metadata, so -a is just belt-and-braces.
cp -a "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Remove any stale output. hdiutil refuses to overwrite by default.
rm -f "$OUTPUT_DMG"

echo "==> Building DMG: $OUTPUT_DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$OUTPUT_DMG" >/dev/null

echo
echo "==> DMG info"
hdiutil imageinfo "$OUTPUT_DMG" | grep -E '^(Format|Size Information|Checksum Type):' || true
ls -lh "$OUTPUT_DMG"

echo
echo "ok: $OUTPUT_DMG"
echo "note: the .app inside inherits its signing identity from the input bundle."
echo "      For a release build, run sign.sh with a real Developer ID BEFORE this script,"
echo "      then notarize/staple the .dmg afterwards."
