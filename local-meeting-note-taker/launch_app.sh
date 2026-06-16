#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_ROOT"

if ./check_ready.sh >/dev/null 2>&1; then
  exec .venv/bin/python launcher.py --browser
fi

if [ -t 1 ]; then
  exec ./install_requirements.sh --launch-after
fi

if command -v osascript >/dev/null 2>&1; then
  osascript -e 'display dialog "First-run setup is required. Open the redistributable app bundle, or run install_requirements.sh from Terminal for a source checkout." buttons {"OK"} default button "OK" with title "Local Meeting Note Taker"'
  exit 0
fi

echo "First-run setup is required. Run:"
echo "  cd \"$APP_ROOT\" && ./install_requirements.sh --launch-after"
exit 1
