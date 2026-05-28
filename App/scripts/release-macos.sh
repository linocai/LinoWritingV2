#!/usr/bin/env bash
#
# release-macos.sh — LinoWriting v0.9 Phase X-2
#
# Builds the macOS app (LinoI.app) in Release, re-signs it with the
# "Developer ID Application" certificate (overriding the X-1 "Apple
# Development" signature), notarizes it via Apple's notary service,
# staples the ticket, verifies Gatekeeper acceptance, and deploys a copy
# to ~/Desktop/LinoI.app.
#
# Prerequisites (set up once by the author, NOT by this script):
#   - "Developer ID Application: <Name> (HX73DFL88G)" cert in the login
#     keychain. Generate via Xcode > Settings > Accounts > linocai@hotmail.com
#     > Manage Certificates > + > Developer ID Application; or
#     developer.apple.com > Certificates > + > Developer ID Application.
#   - notarytool keychain profile "LinoI-deploy" stored via:
#       xcrun notarytool store-credentials LinoI-deploy
#     (Apple ID linocai@hotmail.com + app-specific password + Team ID HX73DFL88G)
#
# Usage:
#   ./scripts/release-macos.sh                 full pipeline (sign + notarize + staple + deploy)
#   ./scripts/release-macos.sh --skip-notarize sign + deploy only (fast local smoke test)
#
set -euo pipefail

# ---- config ---------------------------------------------------------------
SCHEME="LinoWriting-macOS"
PROJECT="LinoWriting.xcodeproj"
CONFIG="Release"
APP_NAME="LinoI.app"
TEAM_ID="HX73DFL88G"
NOTARY_PROFILE="LinoI-deploy"
DEPLOY_DEST="$HOME/Desktop/${APP_NAME}"

SKIP_NOTARIZE=0

# ---- arg parsing ----------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "usage: $0 [--skip-notarize]" >&2
            exit 2
            ;;
    esac
done

# ---- error trap: report which step failed ---------------------------------
CURRENT_STEP="startup"
on_error() {
    local rc=$?
    echo "" >&2
    echo "!! FAILED during step: ${CURRENT_STEP} (exit ${rc})" >&2
    exit "$rc"
}
trap on_error ERR

die() {
    echo "" >&2
    echo "!! ${1}" >&2
    exit 1
}

step() {
    CURRENT_STEP="$1"
    echo "==> $1"
}

# ---- locate App/ dir (script lives in App/scripts/) -----------------------
step "cd to App/ project dir"
cd "$(dirname "$0")/.."
echo "    working dir: $(pwd)"

# ---- regenerate xcodeproj from project.yml --------------------------------
step "xcodegen generate"
xcodegen generate

# ---- clean Release build --------------------------------------------------
step "xcodebuild Release clean build (macOS)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS' -configuration "$CONFIG" clean build

# ---- locate the built .app via build settings (do NOT hardcode hash) ------
# DerivedData path contains a per-machine hash that changes; resolve
# BUILT_PRODUCTS_DIR from xcodebuild instead of globbing a fixed hash.
step "resolve BUILT_PRODUCTS_DIR"
BUILT_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
[ -n "$BUILT_DIR" ] || die "could not resolve BUILT_PRODUCTS_DIR from xcodebuild -showBuildSettings"
APP="$BUILT_DIR/$APP_NAME"
[ -d "$APP" ] || die "built app not found at: $APP"
echo "    app: $APP"

# ---- find Developer ID Application identity --------------------------------
step "find Developer ID Application certificate"
# Match the full identity name, e.g.
#   Developer ID Application: Some Name (HX73DFL88G)
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(.*)"$/\1/')

if [ -z "$DEV_ID" ]; then
    die "未找到 Developer ID Application 证书。\
在 Xcode → Settings → Accounts → 选 linocai@hotmail.com → Manage Certificates → + → Developer ID Application 生成;\
或 developer.apple.com → Certificates → + → Developer ID Application。\
生成后重跑本脚本。"
fi
echo "    identity: $DEV_ID"

# ---- re-sign with Developer ID (overrides X-1 Apple Development sig) -------
step "codesign with Developer ID (hardened runtime + timestamp)"
codesign --force --deep --options runtime --timestamp \
    --sign "$DEV_ID" "$APP"
echo "    signed."

# verify the signature locally before any upload
step "verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "==> --skip-notarize set: skipping notarytool submit + stapler staple"
else
    # ---- zip for notarytool ------------------------------------------------
    step "ditto zip for notarization"
    ZIP="${APP}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "    zip: $ZIP"

    # ---- submit to Apple notary service (blocks until result) --------------
    step "notarytool submit --wait (uploads to Apple)"
    # --keychain-profile reads creds from the keychain; no secrets printed.
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    rm -f "$ZIP"

    # ---- staple ticket into the app ----------------------------------------
    step "stapler staple"
    xcrun stapler staple "$APP"

    # ---- Gatekeeper assessment ---------------------------------------------
    step "spctl assess (expect: accepted / source=Notarized Developer ID)"
    spctl --assess --type execute -vv "$APP"
fi

# ---- deploy to Desktop -----------------------------------------------------
step "deploy to $DEPLOY_DEST"
rm -rf "$DEPLOY_DEST"
cp -R "$APP" "$DEPLOY_DEST"

# ---- report version --------------------------------------------------------
step "done"
VERSION=$(plutil -p "$DEPLOY_DEST/Contents/Info.plist" 2>/dev/null \
    | grep ShortVersion || true)
echo "    deployed $DEPLOY_DEST"
echo "    $VERSION"
