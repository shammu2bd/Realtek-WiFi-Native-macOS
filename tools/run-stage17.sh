#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$PROJECT_ROOT"
RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)"
OUT_DIR="$PROJECT_ROOT/build/sequoia-abi-24H32-stage17-$RUN_ID"
COMMAND_STRING="python3 '$PROJECT_ROOT/tests/test-skywalk-queue-ownership-stage17.py' && bash '$PROJECT_ROOT/tools/collect-sequoia-abi-24H32-stage17.sh' '$OUT_DIR'"
HELPER="$HOME/.config/rtl88wifi/runlog.zsh"
if [[ -r "$HELPER" ]] && command -v zsh >/dev/null 2>&1; then
  /bin/zsh -c 'source "$1"; project="$2"; command_string="$3"; cd "$project"; runlog /bin/bash -lc "$command_string"' \
    _ "$HELPER" "$PROJECT_ROOT" "$COMMAND_STRING"
else
  echo "WARNING: runlog helper not found; archive/log auto-upload is disabled for this run." >&2
  /bin/bash -lc "$COMMAND_STRING"
fi
