#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$PROJECT_ROOT"
STAGE14="$PROJECT_ROOT/build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz"
STAGE15="$PROJECT_ROOT/build/sequoia-abi-24H32-stage15/RTL88WiFi-Sequoia-24H32-stage15-packet-accessor-audit.tar.gz"
STAGE16="$PROJECT_ROOT/build/sequoia-abi-24H32-stage16/RTL88WiFi-Sequoia-24H32-stage16-packet-semantics-audit.tar.gz"
for f in "$STAGE14" "$STAGE15" "$STAGE16"; do [[ -r "$f" ]] || { echo "ERROR: prerequisite archive missing: $f" >&2; exit 2; }; done
STAGE17="$(find "$PROJECT_ROOT/build" -maxdepth 3 -type f -name 'RTL88WiFi-Sequoia-24H32-stage17-rx-queue-ownership-kcabi.tar.gz' -print | LC_ALL=C sort | tail -n 1)"
[[ -n "$STAGE17" && -r "$STAGE17" ]] || { echo "ERROR: Stage 17 archive not found" >&2; exit 2; }
RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)"
OUT_DIR="$PROJECT_ROOT/build/sequoia-abi-24H32-stage18-$RUN_ID"
mkdir -p "$OUT_DIR"
COMMAND_STRING="python3 '$PROJECT_ROOT/tests/test-stage18-ownership-review.py' && python3 '$PROJECT_ROOT/tools/build-stage18-ownership-review.py' --stage14-archive '$STAGE14' --stage15-archive '$STAGE15' --stage16-archive '$STAGE16' --stage17-archive '$STAGE17' --project-root '$PROJECT_ROOT' --out '$OUT_DIR' && /usr/bin/tar -czf '$OUT_DIR/RTL88WiFi-Sequoia-24H32-stage18-ownership-contract-review.tar.gz' -C '$OUT_DIR' stage18-work && /usr/bin/shasum -a 256 '$OUT_DIR/RTL88WiFi-Sequoia-24H32-stage18-ownership-contract-review.tar.gz' | tee '$OUT_DIR/RTL88WiFi-Sequoia-24H32-stage18-ownership-contract-review.tar.gz.sha256' && echo 'Stage 18 evidence dossier created. Manual contract sign-off remains required.'"
HELPER="$HOME/.config/rtl88wifi/runlog.zsh"
if [[ -r "$HELPER" ]] && command -v zsh >/dev/null 2>&1; then
  /bin/zsh -c 'source "$1"; project="$2"; command_string="$3"; cd "$project"; runlog /bin/bash -lc "$command_string"' \
    _ "$HELPER" "$PROJECT_ROOT" "$COMMAND_STRING"
else
  echo "WARNING: runlog helper not found; auto-upload is disabled for this run." >&2
  /bin/bash -lc "$COMMAND_STRING"
fi
