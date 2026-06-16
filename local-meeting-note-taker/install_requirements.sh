#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

LAUNCH_AFTER=0
if [ "${1:-}" = "--launch-after" ]; then
  LAUNCH_AFTER=1
fi

ensure_app_root_writable() {
  local test_file=".lmnt-write-test"
  if ! ( : > "$test_file" ) 2>/dev/null; then
    cat >&2 <<TEXT
Local Meeting Note Taker cannot write to its application resource directory:
$(pwd)

First-run setup needs write access here so it can create the local Python environment,
logs, notes, and runtime files. Reinstall with LocalMeetingNoteTaker-installer.pkg,
or make this directory writable by the user launching the app.
TEXT
    exit 1
  fi
  rm -f "$test_file"
}

ensure_app_root_writable
mkdir -p data/logs data/uploads data/results data/notes data/native-recordings
PROGRESS_STEP=0
PROGRESS_TOTAL=7

log() {
  printf "\n==> %s\n" "$1"
}

progress_step() {
  PROGRESS_STEP=$((PROGRESS_STEP + 1))
  if [ "${LMNT_MACHINE_PROGRESS:-0}" = "1" ]; then
    printf "LMNT_PROGRESS|%s|%s|%s\n" "$PROGRESS_STEP" "$PROGRESS_TOTAL" "$1"
  fi
  log "$1"
}

progress_detail() {
  if [ "${LMNT_MACHINE_PROGRESS:-0}" = "1" ]; then
    printf "LMNT_DETAIL|%s\n" "$1"
  fi
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
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
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
  progress_detail "Installing Homebrew from brew.sh"

  if [ "${LMNT_ASSUME_YES:-0}" = "1" ]; then
    answer="y"
  else
    read -r -p "Install Homebrew now? [y/N] " answer
  fi

  case "$answer" in
    y|Y|yes|YES)
      if [ "${LMNT_ASSUME_YES:-0}" = "1" ]; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      fi
      load_brew_env
      ;;
    *)
      echo "Cannot continue without Homebrew on a fresh Mac."
      exit 1
      ;;
  esac

  if ! have brew; then
    echo "Homebrew installation finished, but brew was not found on PATH."
    echo "PATH=$PATH"
    exit 1
  fi
}

ensure_brew_formula() {
  local formula="$1"
  local binary="$2"

  install_homebrew_if_needed

  if have "$binary"; then
    progress_detail "$binary is ready at $(command -v "$binary")"
    return 0
  fi

  progress_detail "Installing $formula with Homebrew"
  if ! brew install "$formula"; then
    progress_detail "Homebrew install failed; updating Homebrew and retrying $formula"
    brew update
    brew install "$formula"
  fi

  load_brew_env
  hash -r

  if ! have "$binary"; then
    echo "Homebrew installed $formula, but $binary is still not available."
    echo "PATH=$PATH"
    echo "brew prefix: $(brew --prefix 2>/dev/null || true)"
    brew list --versions "$formula" || true
    exit 1
  fi

  progress_detail "$binary is ready at $(command -v "$binary")"
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
progress_step "Checking Homebrew"
install_homebrew_if_needed
progress_step "Installing ffmpeg"
ensure_brew_formula ffmpeg ffmpeg
progress_step "Installing Ollama"
ensure_brew_formula ollama ollama
progress_step "Preparing Python environment"
ensure_python_environment
progress_step "Starting Ollama"
ensure_ollama_running
progress_step "Preparing Ollama model"
ensure_ollama_model
progress_step "Preparing Whisper model"
ensure_whisper_model

log "Installation complete"

if [ "$LAUNCH_AFTER" = "1" ]; then
  exec .venv/bin/python launcher.py
fi
