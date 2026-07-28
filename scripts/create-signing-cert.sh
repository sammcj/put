#!/usr/bin/env bash
# Apple Developer code signing setup guide for Put.
#
# Dev builds sign with an "Apple Development" certificate so that
# Accessibility (TCC) trust persists across rebuilds. Release builds
# sign with "Developer ID Application" + notarisation.
#
# Requires a paid Apple Developer subscription.
#
# Usage: ./scripts/create-signing-cert.sh
set -euo pipefail

echo "Apple Developer Code Signing Setup (Put)"
echo "========================================="
echo ""
echo "Current code signing identities in keychain:"
echo ""
security find-identity -v -p codesigning
echo ""

dev_identity=$(security find-generic-password -s put-release -a dev-signing-identity -w 2>/dev/null || true)
if [[ -n "$dev_identity" ]]; then
    echo "Dev identity in Keychain (put-release/dev-signing-identity): $dev_identity"
    if security find-identity -v -p codesigning | grep -q "$dev_identity"; then
        echo "Cert present in login keychain. Dev builds will sign stably, TCC persists."
    else
        echo "WARNING: cert not installed in login keychain. Sign will fail."
    fi
elif [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "APPLE_SIGNING_IDENTITY env var is set: ${APPLE_SIGNING_IDENTITY}"
    echo "Consider moving it to Keychain with 'make setup-dev-signing' to avoid exporting every session."
else
    echo "No dev signing identity configured. Dev builds will sign ad-hoc and"
    echo "Accessibility trust will be invalidated on every rebuild."
fi
echo ""

echo "Setup steps:"
echo ""
echo "1. Create certificates (if you don't already have them):"
echo "   https://developer.apple.com/account/resources/certificates/list"
echo ""
echo "   You need:"
echo "   - Apple Development         (for dev builds, stable TCC identity)"
echo "   - Developer ID Application  (for release/notarised builds)"
echo ""
echo "   Both certs are tied to your Apple Developer team, not to a specific app,"
echo "   so if you have them installed for another project (e.g. Undertone) Put can reuse them."
echo ""
echo "   If you need new certs:"
echo "   a. Open Keychain Access > Certificate Assistant > Request a Certificate From a"
echo "      Certificate Authority. Enter your email, select 'Saved to disk'."
echo "   b. Upload the CSR at the Apple Developer portal."
echo "   c. Download the .cer and double-click to install."
echo ""
echo "2. Dev builds: store Apple Development identity in Keychain (one-time):"
echo ""
echo "   make setup-dev-signing"
echo ""
echo "   Make reads it from Keychain at parse time, so no shell exports needed."
echo ""
echo "3. Release/notarise: store credentials in Keychain (service: put-release):"
echo ""
echo "   make setup-release-keychain"
echo ""
echo "   Prompts auto-detect defaults from the 'undertone-release' Keychain service,"
echo "   so if Undertone is already set up you can press Enter through all prompts."
echo ""
echo "4. Verify:"
echo "   make setup-signing"
echo ""
