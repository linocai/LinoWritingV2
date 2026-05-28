#!/usr/bin/env bash
#
# release-ios.sh — archive LinoI for iOS, export an .ipa, and upload it to
# TestFlight (App Store Connect). See PROJECT_PLAN.md §5.X.3 / §5.X.7.
#
# ----------------------------------------------------------------------------
# ONE-TIME SETUP (author must run this once before X-4, on this Mac):
#
#   xcrun altool --store-password-in-keychain-item "LinoI-altool" \
#       -u linocai@hotmail.com -p <16-char App-Specific Password>
#
#   This stores the App-Specific Password under the Keychain item name
#   "LinoI-altool". The script below references it as "@keychain:LinoI-altool"
#   so the password never appears in git, env vars, or shell history.
#
#   NOTE: this "LinoI-altool" Keychain item is NOT the same as the
#   "LinoI-deploy" notarytool profile used by release-macos.sh. They are two
#   separate credential mechanisms:
#     - notarytool  -> reads a "credentials profile" created via
#                      `xcrun notarytool store-credentials LinoI-deploy ...`
#     - altool      -> reads a generic Keychain item created via
#                      `xcrun altool --store-password-in-keychain-item ...`
#   The notarytool profile cannot be reused by altool, and vice versa, so the
#   author must create the "LinoI-altool" item explicitly. Both wrap the same
#   App-Specific Password, but they are stored under different schemes.
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
APPLE_ID="linocai@hotmail.com"
TEAM_ID="HX73DFL88G"
KEYCHAIN_ITEM="LinoI-altool"
EXPORT_PLIST="scripts/ios-export.plist"

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

echo "==> [4/4] xcrun altool --upload-app (TestFlight)"
# Password is read from the Keychain item; it is never printed or logged.
xcrun altool --upload-app -t ios \
    -f "$IPA" \
    --apple-id "$APPLE_ID" \
    --password "@keychain:$KEYCHAIN_ITEM" \
    --team-id "$TEAM_ID"

echo ""
echo "uploaded to TestFlight. Processing takes 5-30 min (first-ever upload 1-2 days)."
echo "Watch App Store Connect -> LinoI -> Activity for the build to leave 'processing'."
