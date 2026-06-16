#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

if [ ! -d ".venv" ]; then
  echo "Virtual environment not found. Run ./setup.sh first."
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Warning: ffmpeg was not found. Audio conversion will fail until you install it."
  echo "Install with: brew install ffmpeg"
fi

if ! command -v ollama >/dev/null 2>&1; then
  echo "Warning: ollama was not found. Transcription can run, but summaries will use fallback notes."
fi

./launch_app.sh
