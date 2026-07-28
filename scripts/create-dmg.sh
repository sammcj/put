#!/usr/bin/env bash
# Create, sign, and notarise a DMG from a bundled Put.app.
#
# Uses explicit hdiutil mount/copy/convert steps instead of
# `hdiutil create -srcfolder` to avoid "Operation not permitted" on
# macOS Sequoia+ where the implicit mount under /Volumes/ can be
# blocked by TCC.
#
# Expects the .app to already be Developer-ID signed, notarised, and
# stapled (the Makefile `notarise` target does this before invoking
# this script from `make release`).
#
# Required env vars:
#   APP_NAME                - Bundle short name, e.g. "Put"
#   APP_PATH                - Path to the bundled .app
#   VERSION                 - Version string baked into the DMG filename
#   DMG_DIR                 - Output directory (defaults to dist/)
#   APPLE_SIGNING_IDENTITY  - Developer ID Application identity
#   APPLE_API_ISSUER        - App Store Connect API Issuer ID
#   APPLE_API_KEY           - App Store Connect API Key ID
#   APPLE_API_KEY_PATH      - Path to .p8 key file
set -euo pipefail

APP_NAME="${APP_NAME:-Put}"
APP_PATH="${APP_PATH:-${APP_NAME}.app}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.0.0)}"
DMG_DIR="${DMG_DIR:-dist}"
ARCH=$(uname -m)
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
DMG_PATH="${DMG_DIR}/${DMG_NAME}"
VOLUME_NAME="${APP_NAME}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "ERROR: App bundle not found at ${APP_PATH}" >&2
    exit 1
fi

if [[ ! -f "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "ERROR: Binary not found at ${APP_PATH}/Contents/MacOS/${APP_NAME}" >&2
    exit 1
fi

echo "Creating DMG: ${DMG_NAME}"
mkdir -p "${DMG_DIR}"

rm -f "${DMG_PATH}"

# Detach any existing volume with the same name (leftover from a previous run).
hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

TEMP_DIR=$(mktemp -d)
TEMP_MOUNT="${TEMP_DIR}/mount"
TEMP_RW_DMG="${TEMP_DIR}/temp_rw.dmg"
mkdir -p "${TEMP_MOUNT}"
trap 'hdiutil detach "${TEMP_MOUNT}" 2>/dev/null || true; rm -rf "${TEMP_DIR}"' EXIT

APP_SIZE_MB=$(du -sm "${APP_PATH}" | cut -f1)
DMG_SIZE_MB=$(( APP_SIZE_MB + 20 ))

# 1. Create a temporary read-write DMG.
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -fs HFS+ \
    -size "${DMG_SIZE_MB}m" \
    -ov \
    "${TEMP_RW_DMG}"

# 2. Mount at our temp path (-nobrowse prevents Finder, -noautoopen prevents opening).
hdiutil attach "${TEMP_RW_DMG}" \
    -mountpoint "${TEMP_MOUNT}" \
    -nobrowse \
    -noverify \
    -noautoopen

# 3. Copy app with ditto (preserves signatures and extended attributes).
ditto "${APP_PATH}" "${TEMP_MOUNT}/${APP_NAME}.app"
ln -s /Applications "${TEMP_MOUNT}/Applications"

# 4. Unmount.
hdiutil detach "${TEMP_MOUNT}"

# 5. Convert to compressed UDBZ (bzip2, best for distribution).
hdiutil convert "${TEMP_RW_DMG}" \
    -format UDBZ \
    -ov \
    -o "${DMG_PATH}"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "Signing DMG with: ${APPLE_SIGNING_IDENTITY}"
    codesign --force --sign "${APPLE_SIGNING_IDENTITY}" "${DMG_PATH}"
else
    echo "WARNING: APPLE_SIGNING_IDENTITY not set, DMG is unsigned"
fi

if [[ -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
    echo "Submitting DMG for notarisation..."
    xcrun notarytool submit "${DMG_PATH}" \
        --issuer "${APPLE_API_ISSUER}" \
        --key-id "${APPLE_API_KEY}" \
        --key "${APPLE_API_KEY_PATH}" \
        --wait
    echo "Stapling notarisation ticket..."
    xcrun stapler staple "${DMG_PATH}"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_ID_PASSWORD:-}" ]]; then
    echo "Submitting DMG for notarisation (app-specific password)..."
    xcrun notarytool submit "${DMG_PATH}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_ID_PASSWORD}" \
        --wait
    echo "Stapling notarisation ticket..."
    xcrun stapler staple "${DMG_PATH}"
else
    echo "WARNING: Notarisation credentials not set, DMG is not notarised"
fi

xattr -c "${DMG_PATH}" 2>/dev/null || true

echo ""
echo "Done: ${DMG_PATH}"
echo "Size: $(du -h "${DMG_PATH}" | cut -f1)"
