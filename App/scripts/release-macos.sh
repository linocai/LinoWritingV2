#!/usr/bin/env bash
#
# release-macos.sh — LinoWriting v0.9 Phase X-2
#
# Builds the macOS app (LinoI.app) in Release, re-signs it with the
# "Developer ID Application" certificate (overriding the X-1 "Apple
# Development" signature), notarizes it via Apple's notary service,
# staples the ticket, verifies Gatekeeper acceptance, and deploys a copy
# to /Applications/LinoI.app.
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
DEPLOY_DEST="/Applications/${APP_NAME}"

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

# xcodegen derives scheme BuildableName from the *target* name
# ("LinoWriting"), not PRODUCT_NAME ("LinoI") — every `generate` run cocks
# the 3 schemes' 12 BuildableName entries back to "LinoWriting.app", which
# doesn't match the real build product. CLI build/test still pass either way
# (product name comes from PRODUCT_NAME), so this drifts silently unless
# pinned back after every generate. See project CLAUDE.md. Only the .app
# BuildableName is touched — .xctest bundle names are untouched.
step "pin scheme BuildableName back to LinoI.app (xcodegen regen artifact)"
sed -i '' 's/BuildableName = "LinoWriting.app"/BuildableName = "LinoI.app"/g' LinoWriting.xcodeproj/xcshareddata/xcschemes/*.xcscheme

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

# ---- v0.9.2 (Plan A): strip any embedded provisioning profile -------------
# Defense-in-depth. v0.9.1 wired CODE_SIGN_ENTITLEMENTS for a
# `keychain-access-groups` entitlement, which made Xcode embed a *development*
# provisioning profile (device-locked). Re-signing with the Developer ID cert
# then produced a cert/profile type mismatch that AMFI rejects at launchd
# spawn (POSIX 163) — the app simply would not open, despite notarize +
# spctl passing. v0.9.2 removed CODE_SIGN_ENTITLEMENTS so no profile *should*
# be embedded, but we delete it unconditionally before re-signing so a stray
# profile can never re-break launch. Developer ID distribution needs no
# embedded profile.
step "strip embedded provisioning profile (Developer ID needs none)"
if [ -f "$APP/Contents/embedded.provisionprofile" ]; then
    rm -f "$APP/Contents/embedded.provisionprofile"
    echo "    removed stale embedded.provisionprofile"
else
    echo "    none present (expected with no CODE_SIGN_ENTITLEMENTS)"
fi

# ---- re-sign with Developer ID (overrides X-1 Apple Development sig) -------
# No --entitlements: Plan A carries no custom entitlements, so re-signing
# plain strips everything Xcode injected (incl. the debug get-task-allow that
# would otherwise fail notarization). This matches the v0.9 model that
# launched + notarized cleanly.
step "codesign with Developer ID (hardened runtime + timestamp)"
codesign --force --deep --options runtime --timestamp \
    --sign "$DEV_ID" "$APP"
echo "    signed."

# verify the signature locally before any upload
step "verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP"
# confirm no get-task-allow + no embedded profile leaked through
step "verify no debug entitlement / profile"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    die "get-task-allow still present — notarize would reject (statusCode 4000)"
fi
[ -f "$APP/Contents/embedded.provisionprofile" ] && die "embedded.provisionprofile re-appeared — launch would fail (POSIX 163)"
echo "    clean: no get-task-allow, no embedded profile ✓"

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

# ---- deploy to /Applications -----------------------------------------------
step "deploy to $DEPLOY_DEST"
# If a copy is currently running from the deploy target, ditto over the top of
# a live bundle risks a corrupt/half-replaced .app. Do NOT force-kill (the user
# may have unsaved work); prompt them to quit and re-run instead.
if pgrep -x LinoI >/dev/null 2>&1; then
    die "LinoI 正在运行。请先退出 App（⌘Q / 右键程序坞图标 → 退出）后重跑本脚本，避免覆盖正在运行的进程。"
fi
# Remove any stale bundle first so a residual mixed-signature copy can't linger.
rm -rf "$DEPLOY_DEST"
# ditto, NOT cp -R: cp -R can silently corrupt .app Resources while codesign
# --verify still passes (project CLAUDE.md landmine). The deployed copy in
# /Applications must be a faithful bundle, or a corrupt-copy launch failure
# gets misread as a code/signing bug.
ditto "$APP" "$DEPLOY_DEST"

# ---- report version --------------------------------------------------------
step "done"
VERSION=$(plutil -p "$DEPLOY_DEST/Contents/Info.plist" 2>/dev/null \
    | grep ShortVersion || true)
echo "    deployed $DEPLOY_DEST"
echo "    $VERSION"
