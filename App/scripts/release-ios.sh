#!/usr/bin/env bash
#
# release-ios.sh — archive LinoI for iOS, export an .ipa, and upload it to
# TestFlight (App Store Connect). See PROJECT_PLAN.md §5.X.3 / §5.X.7.
#
# ----------------------------------------------------------------------------
# ONE-TIME SETUP (author must do this once before X-4, on this Mac):
#
#   AUTH = App Store Connect API key (NOT app-specific password).
#
#   Why API key, not altool --store-password-in-keychain-item:
#     Xcode 26.5's altool has a keychain bug — it stores the item with a NULL
#     service attribute, then its own `@keychain:<name>` lookup can't find it
#     ("AuthenticationFailure: Failed to find item ... in keychain"). The
#     App-Specific-Password-in-keychain path is a dead end on this toolchain.
#     API keys sidestep keychain entirely AND are reusable by notarytool.
#
#   Generate the key:
#     1. https://appstoreconnect.apple.com → Users and Access → Integrations
#        tab → App Store Connect API → "+" → name "LinoI CI" → access role
#        "App Manager" → Generate.
#     2. Download the AuthKey_<KEYID>.p8 file — ONE TIME ONLY, cannot
#        re-download. Note the Key ID (10 chars, in the key row) and the
#        Issuer ID (UUID at top of the Keys page).
#     3. Place the .p8 where altool auto-discovers it:
#          mkdir -p ~/.appstoreconnect/private_keys
#          mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
#     4. Fill API_KEY_ID + API_ISSUER_ID below (NOT secret — the .p8 is the
#        secret and stays out of git). The .p8 is never committed.
# ----------------------------------------------------------------------------
#
# USAGE:
#   ./scripts/release-ios.sh              # archive + export + upload TestFlight
#   ./scripts/release-ios.sh --skip-upload  # archive + export only (local verify)
#
# IMPORTANT: the iOS archive MUST pass -allowProvisioningUpdates. Without it,
# the CLI cannot fetch the distribution provisioning profile from Apple and the
# archive fails (verified during X-1).

set -euo pipefail

# --- config -----------------------------------------------------------------
SCHEME="LinoWriting-iOS"
PROJECT="LinoWriting.xcodeproj"
EXPORT_PLIST="scripts/ios-export.plist"
# App Store Connect API key (fill after generating — see ONE-TIME SETUP above).
# Neither value is a secret; the secret is the .p8 file in
# ~/.appstoreconnect/private_keys/AuthKey_<API_KEY_ID>.p8 (never committed).
API_KEY_ID="${LINOI_ASC_KEY_ID:-75J5N6MD4T}"
API_ISSUER_ID="${LINOI_ASC_ISSUER_ID:-58202180-4b05-4605-a309-c485d4dcead1}"

# --- args (parse before cd so $0 still resolves for --help) ------------------
SKIP_UPLOAD=0
for arg in "$@"; do
    case "$arg" in
        --skip-upload) SKIP_UPLOAD=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (use --skip-upload or --help)" >&2
            exit 2
            ;;
    esac
done

cd "$(dirname "$0")/.."

# --- failure trap ------------------------------------------------------------
WORKDIR=""
on_error() {
    echo "" >&2
    echo "FAILED at line $1 (exit $2)." >&2
    if [[ -n "$WORKDIR" ]]; then
        echo "Intermediate artifacts left in: $WORKDIR" >&2
    fi
}
trap 'on_error "$LINENO" "$?"' ERR

# --- step 1: regenerate the Xcode project ------------------------------------
echo "==> [1/4] xcodegen generate"
xcodegen generate

# xcodegen derives scheme BuildableName from the *target* name
# ("LinoWriting"), not PRODUCT_NAME ("LinoI") — every `generate` run cocks
# the 3 schemes' 12 BuildableName entries back to "LinoWriting.app", which
# doesn't match the real build product. CLI build/test still pass either way
# (product name comes from PRODUCT_NAME), so this drifts silently unless
# pinned back after every generate. See project CLAUDE.md. Only the .app
# BuildableName is touched — .xctest bundle names are untouched.
echo "==> pin scheme BuildableName back to LinoI.app (xcodegen regen artifact)"
sed -i '' 's/BuildableName = "LinoWriting.app"/BuildableName = "LinoI.app"/g' LinoWriting.xcodeproj/xcshareddata/xcschemes/*.xcscheme

# --- step 2: archive (MUST keep -allowProvisioningUpdates) -------------------
WORKDIR=$(mktemp -d)
ARCHIVE="$WORKDIR/LinoI.xcarchive"
echo "==> [2/4] xcodebuild archive -> $ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' -configuration Release \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    archive

# --- step 3: export .ipa -----------------------------------------------------
EXPORT_DIR="$WORKDIR/export"
echo "==> [3/4] xcodebuild -exportArchive -> $EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates

IPA="$EXPORT_DIR/LinoI.ipa"
if [[ ! -f "$IPA" ]]; then
    # exportArchive names the .ipa after the product; fall back to first .ipa.
    IPA=$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -n 1)
fi
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
    echo "error: no .ipa produced in $EXPORT_DIR" >&2
    exit 1
fi
echo "    exported: $IPA"

# --- step 4: upload to TestFlight --------------------------------------------
if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
    echo "==> [4/4] --skip-upload set; archive + export verified, NOT uploading."
    echo "    .ipa ready at: $IPA"
    exit 0
fi

echo "==> [4/4] xcrun altool --upload-app (TestFlight, API-key auth)"
if [[ "$API_KEY_ID" == "REPLACE_WITH_KEY_ID" || "$API_ISSUER_ID" == "REPLACE_WITH_ISSUER_ID" ]]; then
    echo "error: API_KEY_ID / API_ISSUER_ID not set. See ONE-TIME SETUP at top of this script." >&2
    echo "       (or export LINOI_ASC_KEY_ID / LINOI_ASC_ISSUER_ID before running)" >&2
    exit 1
fi
# App Store Connect API key auth (Xcode 26.5: the @keychain password path is
# broken — altool stores the item with a NULL service attr and then can't find
# it). altool auto-discovers ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
#   -t / --platform   {macos | ios | appletvos | visionos}
#   --apiKey          API Key ID (10 chars)
#   --apiIssuer       Issuer ID (UUID)
xcrun altool --upload-app -t ios \
    -f "$IPA" \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$API_ISSUER_ID"

echo ""
echo "uploaded to TestFlight. Processing takes 5-30 min (first-ever upload 1-2 days)."
echo "Watch App Store Connect -> LinoI -> Activity for the build to leave 'processing'."
