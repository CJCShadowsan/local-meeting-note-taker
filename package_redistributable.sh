#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$REPO_ROOT/.package-work"
PACKAGE_ROOT="$WORK_DIR/Local Meeting Note Taker"
ZIP_PATH="$REPO_ROOT/LocalMeetingNoteTaker-redistributable.zip"

rm -rf "$WORK_DIR"
mkdir -p "$PACKAGE_ROOT"

rsync -a \
  --exclude ".DS_Store" \
  --exclude ".git/" \
  --exclude ".package-work/" \
  --exclude "LocalMeetingNoteTaker-redistributable.zip" \
  --exclude "local-meeting-note-taker/.venv/" \
  --exclude "local-meeting-note-taker/__pycache__/" \
  --exclude "local-meeting-note-taker/data/app.pid" \
  --exclude "local-meeting-note-taker/data/app.port" \
  --exclude "local-meeting-note-taker/data/ollama.pid" \
  --exclude "local-meeting-note-taker/data/logs/*" \
  --exclude "local-meeting-note-taker/data/uploads/*" \
  --exclude "local-meeting-note-taker/data/results/*" \
  --exclude "local-meeting-note-taker/data/notes/*" \
  --exclude "local-meeting-note-taker/data/native-recordings/*" \
  "$REPO_ROOT/" \
  "$PACKAGE_ROOT/"

mkdir -p \
  "$PACKAGE_ROOT/local-meeting-note-taker/data/logs" \
  "$PACKAGE_ROOT/local-meeting-note-taker/data/uploads" \
  "$PACKAGE_ROOT/local-meeting-note-taker/data/results" \
  "$PACKAGE_ROOT/local-meeting-note-taker/data/notes" \
  "$PACKAGE_ROOT/local-meeting-note-taker/data/native-recordings"

rm -f "$ZIP_PATH"
(cd "$WORK_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Local Meeting Note Taker" "$ZIP_PATH")

echo "Created $ZIP_PATH"

