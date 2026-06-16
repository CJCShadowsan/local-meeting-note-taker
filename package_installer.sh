#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export COPYFILE_DISABLE=1

APP_WORK="$REPO_ROOT/.package-work/Local Meeting Note Taker.app"
PKG_WORK="$REPO_ROOT/.pkg-work"
PKG_ROOT="$PKG_WORK/root"
PKG_APP="$PKG_ROOT/Applications/Local Meeting Note Taker.app"
PKG_PATH="$REPO_ROOT/LocalMeetingNoteTaker-installer.pkg"
PKG_SCRIPTS="$REPO_ROOT/macos/pkg-scripts"
VERSION="${LMNT_PACKAGE_VERSION:-}"

if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/Local Meeting Note Taker.app/Contents/Info.plist")"
fi

if [ "${LMNT_USE_EXISTING_APP:-0}" != "1" ] || [ ! -x "$APP_WORK/Contents/MacOS/LocalMeetingNoteTaker" ]; then
  "$REPO_ROOT/package_redistributable.sh"
fi

rm -rf "$PKG_WORK" "$PKG_PATH"
mkdir -p "$PKG_ROOT/Applications"

rsync -a --delete "$APP_WORK/" "$PKG_APP/"

chmod +x "$PKG_APP/Contents/MacOS/LocalMeetingNoteTaker"
find "$PKG_APP/Contents/Resources/local-meeting-note-taker" \
  -type f \( -name "*.sh" -o -name "*.command" \) \
  -exec chmod +x {} \;
/usr/bin/dot_clean -m "$PKG_ROOT" 2>/dev/null || true
find "$PKG_ROOT" -name "._*" -delete
xattr -cr "$PKG_ROOT" 2>/dev/null || true

pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "local.meeting.note.taker" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG_PATH"

echo "Created $PKG_PATH"
