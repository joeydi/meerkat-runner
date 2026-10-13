#!/usr/bin/env bash
# Release pipeline (AGENTS.md §12): archive → export → notarize → staple → DMG/zip → Sparkle appcast.
# Runs locally only; signing and notarization never run in CI.
#
# Required environment:
#   DEVELOPER_ID_TEAM      Developer ID team ID (AGENTS.md §13 Q3)
#   NOTARY_PROFILE         keychain profile for `xcrun notarytool` (see `notarytool store-credentials`)
#   SPARKLE_BIN            directory containing Sparkle's `generate_appcast` (v0.3+)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/release"
SCHEME="MeerkatRunner"
APP_NAME="Meerkat Runner"

: "${DEVELOPER_ID_TEAM:?set DEVELOPER_ID_TEAM}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

echo "release.sh is a stub until the first v0.1 release. Steps:" >&2
cat >&2 <<STEPS
  1. cd "$ROOT" && xcodegen
  2. xcodebuild archive -scheme "$SCHEME" -configuration Release \\
       -archivePath "$BUILD/$SCHEME.xcarchive" DEVELOPMENT_TEAM="$DEVELOPER_ID_TEAM"
  3. xcodebuild -exportArchive -archivePath "$BUILD/$SCHEME.xcarchive" \\
       -exportOptionsPlist ExportOptions.plist (method: developer-id) -exportPath "$BUILD"
  4. ditto -c -k --keepParent "$BUILD/$APP_NAME.app" "$BUILD/$SCHEME.zip"
  5. xcrun notarytool submit "$BUILD/$SCHEME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  6. xcrun stapler staple "$BUILD/$APP_NAME.app"
  7. Build DMG + zip from the stapled app
  8. "\$SPARKLE_BIN/generate_appcast" "$BUILD"   (EdDSA private key stays out of the repo)
STEPS
exit 1
