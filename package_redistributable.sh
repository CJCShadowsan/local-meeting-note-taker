#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$REPO_ROOT/.package-work"
APP_BUNDLE="$WORK_DIR/Local Meeting Note Taker.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_RESOURCE_ROOT="$APP_RESOURCES/local-meeting-note-taker"
ZIP_PATH="$REPO_ROOT/LocalMeetingNoteTaker-redistributable.zip"

rm -rf "$WORK_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCE_ROOT"

rsync -a \
  "$REPO_ROOT/Local Meeting Note Taker.app/Contents/Info.plist" \
  "$APP_CONTENTS/Info.plist"

rsync -a \
  "$REPO_ROOT/Local Meeting Note Taker.app/Contents/MacOS/LocalMeetingNoteTaker" \
  "$APP_MACOS/LocalMeetingNoteTaker"

rsync -a \
  --exclude ".DS_Store" \
  --exclude ".venv/" \
  --exclude "__pycache__/" \
  --exclude "*.pyc" \
  --exclude "Local Meeting Note Taker.app/" \
  --exclude "data/app.pid" \
  --exclude "data/app.port" \
  --exclude "data/ollama.pid" \
  --exclude "data/logs/*" \
  --exclude "data/uploads/*" \
  --exclude "data/results/*" \
  --exclude "data/notes/*" \
  --exclude "data/native-recordings/*" \
  "$REPO_ROOT/local-meeting-note-taker/" \
  "$APP_RESOURCE_ROOT/"

mkdir -p \
  "$APP_RESOURCE_ROOT/data/logs" \
  "$APP_RESOURCE_ROOT/data/uploads" \
  "$APP_RESOURCE_ROOT/data/results" \
  "$APP_RESOURCE_ROOT/data/notes" \
  "$APP_RESOURCE_ROOT/data/native-recordings"

rm -f "$ZIP_PATH"
(cd "$WORK_DIR" && /usr/bin/ditto -c -k --norsrc --keepParent "Local Meeting Note Taker.app" "$ZIP_PATH")

echo "Created $ZIP_PATH"
