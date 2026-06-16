#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_ROOT"

if ./check_ready.sh >/dev/null 2>&1; then
  exec .venv/bin/python launcher.py
fi

if [ -t 1 ]; then
  exec ./install_requirements.sh --launch-after
fi

if command -v osascript >/dev/null 2>&1; then
  install_command="cd $(printf '%q' "$APP_ROOT") && ./install_requirements.sh --launch-after"
  escaped_command="$(printf '%s' "$install_command" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript -e 'tell application "Terminal" to activate' \
    -e "tell application \"Terminal\" to do script \"$escaped_command\""
  exit 0
fi

echo "First-run setup is required. Run:"
echo "  cd \"$APP_ROOT\" && ./install_requirements.sh --launch-after"
exit 1

