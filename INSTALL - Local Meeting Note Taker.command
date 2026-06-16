#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/local-meeting-note-taker"
./install_requirements.sh --launch-after

