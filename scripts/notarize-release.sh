#!/usr/bin/env bash
# Build, Developer ID-sign, notarize, and staple a distributable zip of
# audio-pipeline.app. Run OUTSIDE the Claude Code sandbox — it needs the login
# keychain's signing key and network. Mirrors the proven fecni release flow.
#
# Usage:  scripts/notarize-release.sh <notary-keychain-profile>
#
# <notary-keychain-profile> is a profile you stored once with notarytool, e.g.:
#   xcrun notarytool store-credentials audio-pipeline-notary \
#     --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#   # or: --apple-id <id> --team-id V378YWVH44 --password <app-specific-pw>
# The Developer ID Application identity is read from the keychain automatically.
set -euo pipefail

PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  echo "usage: $0 <notary-keychain-profile>" >&2
  exit 2
fi

PROJECT="audio-pipeline.xcodeproj"
SCHEME="audio-pipeline"
APP_NAME="audio-pipeline.app"
DERIVED="/tmp/audio-pipeline-release"   # off iCloud, per project convention
APP="$DERIVED/Build/Products/Release/$APP_NAME"
ZIP="$PWD/audio-pipeline.zip"

# The "Developer ID Application" identity (skips the unrelated Apple Configurator
# cert). Passed by hash so codesign picks it unambiguously.
IDENTITY="$(security find-identity -v -p codesigning \
  | awk '/Developer ID Application/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' identity found in keychain" >&2
  exit 1
fi
echo "Signing identity: $IDENTITY"

# Build & sign. Hardened Runtime comes from the project (ENABLE_HARDENED_RUNTIME=YES),
# so Xcode signs with --options runtime; --timestamp adds the secure timestamp the
# notary requires. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO drops the get-task-allow
# debugger entitlement (a plain `build` injects it, and the notary rejects it) —
# the app's own entitlements file (audio-input, sandbox off) is still applied.
# Letting xcodebuild sign also signs any nested frameworks/dylibs correctly.
rm -rf "$DERIVED" "$ZIP"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES

# Submit for notarization. notarytool exits 0 even on a rejected result, so we
# read the status ourselves and dump Apple's per-issue log on anything but Accepted.
ditto -c -k --keepParent "$APP" "$ZIP"
SUBMIT_OUT="$(mktemp)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" \
  --wait --output-format json | tee "$SUBMIT_OUT"
SUB_ID="$(jq -r '.id' "$SUBMIT_OUT")"
STATUS="$(jq -r '.status' "$SUBMIT_OUT")"

if [ "$STATUS" != "Accepted" ]; then
  echo "--- notary log for $SUB_ID ---" >&2
  xcrun notarytool log "$SUB_ID" --keychain-profile "$PROFILE" || true
  echo "error: notarization failed with status: $STATUS" >&2
  exit 1
fi

# Staple onto the .app (you can't staple a zip), then re-zip the stapled app.
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "=== Gatekeeper assessment ==="
spctl -a -vvv -t exec "$APP"
echo "=== staple ==="
xcrun stapler validate "$APP"
echo "=== signature / hardened runtime / entitlements ==="
codesign -dvvv --entitlements - "$APP" 2>&1 \
  | rg -i 'Authority|flags|runtime|sandbox|audio-input|get-task-allow' || true

echo
echo "Notarized + stapled. Distributable zip: $ZIP"
echo "Before sharing: launch the app and confirm system-audio recording still"
echo "works under Hardened Runtime (notarization does not exercise the tap)."
