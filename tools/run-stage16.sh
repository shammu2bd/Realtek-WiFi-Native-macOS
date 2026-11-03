#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$PROJECT_ROOT"
STAGE14="$PROJECT_ROOT/build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz"
STAGE15="$PROJECT_ROOT/build/sequoia-abi-24H32-stage15/RTL88WiFi-Sequoia-24H32-stage15-packet-accessor-audit.tar.gz"
for input in "$STAGE14" "$STAGE15"; do
  if [[ ! -f "$input" ]]; then
    echo "ERROR: required evidence archive not found: $input" >&2
    exit 2
  fi
done

COMMAND_STRING="python3 '$PROJECT_ROOT/tests/test-skywalk-packet-semantics-stage16.py' && python3 '$PROJECT_ROOT/tools/audit-skywalk-packet-semantics-stage16.py' --stage14-archive '$STAGE14' --stage15-archive '$STAGE15' --project-root '$PROJECT_ROOT' --out '$PROJECT_ROOT/build/sequoia-abi-24H32-stage16'"
HELPER="$HOME/.config/rtl88wifi/runlog.zsh"
if [[ -r "$HELPER" ]] && command -v zsh >/dev/null 2>&1; then
  /bin/zsh -c 'source "$1"; project="$2"; command_string="$3"; cd "$project"; runlog /bin/bash -lc "$command_string"' \
    _ "$HELPER" "$PROJECT_ROOT" "$COMMAND_STRING"
else
  echo "WARNING: runlog helper not found; archive/log auto-upload is disabled for this run." >&2
  /bin/bash -lc "$COMMAND_STRING"
fi
