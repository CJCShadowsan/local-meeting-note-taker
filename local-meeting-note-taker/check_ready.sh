#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -x ".venv/bin/python" ]; then
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
  exit 1
fi

".venv/bin/python" - <<'PY'
import importlib
import sys

if sys.version_info < (3, 10):
    raise SystemExit(1)

required = ["flask", "requests", "pydub", "whisper", "webview"]
for module in required:
    importlib.import_module(module)
PY

