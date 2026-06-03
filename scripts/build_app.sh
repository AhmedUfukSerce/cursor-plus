#!/bin/bash
#
# Build Cursor+ and assemble a signed, double-clickable Cursor+.app.
#
# For a stable Accessibility / Post-Events grant that SURVIVES rebuilds, create a
# persistent self-signed code-signing certificate once (Keychain Access ->
# Certificate Assistant -> Create a Certificate -> Self Signed Root -> Code
# Signing, e.g. named "CursorPlus Self"), then run:
#
#     CURSORPLUS_SIGN_IDENTITY="CursorPlus Self" ./scripts/build_app.sh
#
# Without it the app is ad-hoc signed and macOS forgets the permission grant on
# every rebuild (re-grant in System Settings, or run:
#     tccutil reset Accessibility com.aus.cursorplus ).

set -euo pipefail
cd "$(dirname "$0")/.."

APP="Cursor+.app"
EXE="CursorPlus"
BUNDLE_ID="com.aus.cursorplus"
IDENTITY="${CURSORPLUS_SIGN_IDENTITY:-}"

# Auto-use the stable self-signed identity if it's installed, so the macOS
# permission grant survives every rebuild (no more re-granting).
# NOTE: no -v — a self-signed cert is "untrusted" (and hidden by -v), but codesign
# can still sign with it, which is all we need for a stable local TCC identity.
if [[ -z "${IDENTITY}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "CursorPlus Self"; then
    IDENTITY="CursorPlus Self"
fi

echo "==> Building (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${EXE}"
if [[ ! -f "${BIN}" ]]; then
    echo "build product not found at ${BIN}"
    exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${EXE}"
cp "SupportFiles/Info.plist" "${APP}/Contents/Info.plist"
if [[ -f "SupportFiles/AppIcon.icns" ]]; then
    cp "SupportFiles/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"   # Finder/Launchpad/Dock icon
fi

if [[ -n "${IDENTITY}" ]]; then
    echo "==> Codesigning with stable identity: ${IDENTITY}"
    codesign --force --identifier "${BUNDLE_ID}" --sign "${IDENTITY}" "${APP}"
else
    echo "==> Codesigning ad-hoc (grant resets each rebuild; install 'CursorPlus Self' to avoid)"
    codesign --force --identifier "${BUNDLE_ID}" --sign - "${APP}"
fi

codesign --verify --strict --verbose=2 "${APP}" || true

# Install ONE canonical copy so stale duplicates can't linger and get launched.
INSTALL_DIR="${CURSORPLUS_INSTALL_DIR:-/Applications}"
DEST="${INSTALL_DIR}/${APP}"
if [[ -d "${INSTALL_DIR}" && -w "${INSTALL_DIR}" ]]; then
    rm -rf "${DEST}"
    cp -R "${APP}" "${DEST}"
    rm -rf "${APP}"                      # keep only the installed copy
    echo ""
    echo "==> Installed: ${DEST}"
    echo "    Launch with:  open \"${DEST}\"   (or Spotlight: Cursor+)"
else
    echo ""
    echo "==> Built: $(pwd)/${APP}  (couldn't write ${INSTALL_DIR}; left it here)"
    echo "    Launch with:  open \"${APP}\""
fi
echo "    (Always launch the .app bundle, never the bare binary.)"
