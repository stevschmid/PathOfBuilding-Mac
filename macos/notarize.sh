#!/usr/bin/env bash
#
# Notarize and staple a Path of Building .dmg.
#
# Usage:
#   macos/notarize.sh [path/to/Name.dmg]
#
# Requires a notarytool keychain profile named "pob-notarytool". Create one
# locally with:
#   xcrun notarytool store-credentials "pob-notarytool" \
#       --apple-id "YOU@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
#
# In CI, the profile is created from secrets at workflow runtime.

set -euo pipefail

PROFILE="${NOTARYTOOL_PROFILE:-pob-notarytool}"
DMG="${1:?Usage: notarize.sh <path/to/Name.dmg>}"

if [[ ! -f "$DMG" ]]; then
    echo "error: DMG not found: $DMG" >&2
    exit 1
fi

echo "==> Submitting $DMG to Apple notary service (profile=$PROFILE)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$PROFILE" \
    --wait

echo
echo "==> Stapling notarization ticket to $DMG"
xcrun stapler staple "$DMG"

echo
echo "==> Verifying"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 || true

echo
echo "ok: $DMG notarized and stapled"
