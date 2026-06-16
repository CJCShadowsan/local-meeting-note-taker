#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

LAUNCH_AFTER=0
if [ "${1:-}" = "--launch-after" ]; then
  LAUNCH_AFTER=1
fi

mkdir -p data/logs data/uploads data/results data/notes data/native-recordings

log() {
  printf "\n==> %s\n" "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

python_ok() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

load_brew_env() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

install_homebrew_if_needed() {
  load_brew_env
  if have brew; then
    return 0
  fi

  cat <<'TEXT'

Homebrew is required so this app can install ffmpeg, Ollama, and a modern Python when needed.
This will run Homebrew's official installer from https://brew.sh.
TEXT
  read -r -p "Install Homebrew now? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      load_brew_env
      ;;
    *)
      echo "Cannot continue without Homebrew on a fresh Mac."
      exit 1
      ;;
  esac
}

ensure_system_tools() {
  install_homebrew_if_needed

  if ! have ffmpeg; then
    log "Installing ffmpeg"
    brew install ffmpeg
  fi

  if ! have ollama; then
    log "Installing Ollama"
    brew install ollama
  fi
}

select_python() {
  if have python3 && python_ok "$(command -v python3)"; then
    command -v python3
    return 0
  fi

  install_homebrew_if_needed
  log "Installing Python"
  brew install python@3.12 || brew install python

  if have python3.12 && python_ok "$(command -v python3.12)"; then
    command -v python3.12
    return 0
  fi
  if have python3 && python_ok "$(command -v python3)"; then
    command -v python3
    return 0
  fi

  echo "Python 3.10 or newer was not found after installation."
  exit 1
}

ensure_python_environment() {
  local python_bin
  python_bin="$(select_python)"

  if [ -x ".venv/bin/python" ] && ".venv/bin/python" - <<'PY' >/dev/null 2>&1
import flask, requests, pydub, whisper, webview
PY
  then
    log "Bundled Python environment is ready"
    return 0
  fi

  log "Creating local Python environment"
  rm -rf .venv
  "$python_bin" -m venv .venv
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt
}

ensure_ollama_running() {
  mkdir -p data/logs
  if ollama list >/dev/null 2>&1; then
    return 0
  fi

  log "Starting Ollama"
  if have brew; then
    brew services start ollama >/dev/null 2>&1 || true
  fi

  for _ in $(seq 1 20); do
    if ollama list >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  nohup ollama serve > data/logs/ollama.log 2>&1 &
  echo $! > data/ollama.pid

  for _ in $(seq 1 20); do
    if ollama list >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "Ollama did not start. Check data/logs/ollama.log."
  exit 1
}

ensure_ollama_model() {
  if ollama list | awk 'NR > 1 && $1 != "" { found = 1 } END { exit(found ? 0 : 1) }'; then
    return 0
  fi

  local model="${OLLAMA_MODEL:-llama3.2:3b}"
  log "Pulling Ollama model ${model}"
  ollama pull "$model"
}

ensure_whisper_model() {
  local model="${WHISPER_MODEL:-base.en}"
  log "Prefetching Whisper model ${model}"
  .venv/bin/python - <<PY
import whisper
whisper.load_model("${model}")
PY
}

log "Preparing Local Meeting Note Taker"
ensure_system_tools
ensure_python_environment
ensure_ollama_running
ensure_ollama_model
ensure_whisper_model

log "Installation complete"

if [ "$LAUNCH_AFTER" = "1" ]; then
  exec .venv/bin/python launcher.py
fi

