#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_APP_ROOT="$PACKAGE_ROOT/Local Meeting Note Taker.app/Contents/Resources/local-meeting-note-taker"
SIDECAR_APP_ROOT="$PACKAGE_ROOT/local-meeting-note-taker"

if [ -x "$RESOURCE_APP_ROOT/launch_app.sh" ]; then
  APP_ROOT="$RESOURCE_APP_ROOT"
else
  APP_ROOT="$SIDECAR_APP_ROOT"
fi

cd "$APP_ROOT"
./launch_app.sh
