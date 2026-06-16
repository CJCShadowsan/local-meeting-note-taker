#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

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
