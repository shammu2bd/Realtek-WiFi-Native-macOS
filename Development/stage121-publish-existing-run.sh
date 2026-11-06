#!/bin/bash
# Publish the Stage121 target-Mac run that built successfully but stopped at
# git diff --check because the preserved compiler log contains trailing spaces.
# No source/build/install/load/EFI/OpenCore/SIP/NVRAM changes are performed here.
set -euo pipefail

EXPECTED_BRANCH="work/stage121-native-controller-attachment"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
LOG="Development/Logs/stage121-native-controller-attachment-20261106T142556Z.log"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: expected branch $EXPECTED_BRANCH"
  exit 2
fi
if [[ ! -s "$LOG" ]]; then
  echo "ERROR: target-Mac Stage121 run log not found: $LOG"
  exit 2
fi
grep -q '^STAGE121_NATIVE_BUILD=PASS$' "$LOG" || {
  echo "ERROR: log does not contain a native-build PASS marker"
  exit 2
}
grep -q '^STAGE121_RESULT=PASS$' "$LOG" || {
  echo "ERROR: log does not contain a Stage121 test/build PASS marker"
  exit 2
}

# This recovery is intentionally limited to the two files the original runner
# stages. Do not disturb unrelated user changes.
STATUS="$(git status --porcelain)"
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  changed="${entry:3}"
  case "$changed" in
    "$LOG"|"Development/output.log") ;;
    *)
      echo "ERROR: unrelated working-tree change found: $changed"
      git status --short
      exit 2
      ;;
  esac
done <<< "$STATUS"

# Discard only the runner's stale local output.log append. It will be rebuilt
# from the target-Mac result after rebasing onto the current GitHub branch.
git restore --source=HEAD --staged --worktree -- Development/output.log
git add -f "$LOG"
git -c core.whitespace=-trailing-space diff --cached --check
git commit -m "Stage121: publish target-Mac native build log"

# The GitHub source-review checkpoint and whitespace-safe runner fix were added
# after this target run began. Rebase this log-only commit so neither is lost.
git fetch origin "$EXPECTED_BRANCH"
git rebase FETCH_HEAD

cat >> Development/output.log <<EOF

========== STAGE121 TARGET-MAC BUILD AND TEST RESULT ==========
STAGE121_TARGET_MAC_VALIDATION=PASS
STAGE121_SOURCE_CONTRACT=PASS
STAGE121_REGRESSION_TESTS=PASS
STAGE121_NATIVE_BUILD=PASS
STAGE121_NATIVE_BUNDLE_ID=io.github.x1ren41l.RTL88WiFi
STAGE121_NATIVE_BINARY_SHA256=de7cf579008a650cc7a12fd4f15005cdb7347daac335edc193e1f5be21b11611
STAGE121_COMPILER_WARNINGS=NONFATAL_WARNING_OBSERVED
STAGE121_DETAIL_LOG=$LOG
STAGE121_PRIMARY_INTERFACE_RUNTIME=NOT_RUN
STAGE121_RADIO_START=NOT_RUN
STAGE121_TX_RX_RUNTIME=NOT_RUN
STAGE121_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN REBOOT=NOT_RUN
STAGE121_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE
===============================================================
EOF

git add -f Development/output.log
git -c core.whitespace=-trailing-space diff --cached --check
git commit -m "Stage121: publish target-Mac build and test checkpoint"
git push origin "HEAD:$EXPECTED_BRANCH"

git fetch origin "$EXPECTED_BRANCH"
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse FETCH_HEAD)"
[[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || {
  echo "ERROR: pushed HEAD does not match fetched remote HEAD"
  exit 3
}
git show "FETCH_HEAD:$LOG" >/dev/null
git show "FETCH_HEAD:Development/output.log" | grep -F "$LOG" >/dev/null
echo "STAGE121_UPLOAD=PASS"
echo "STAGE121_BRANCH=$EXPECTED_BRANCH"
echo "STAGE121_DETAIL_LOG=$LOG"
echo "STAGE121_REMOTE_HEAD=$REMOTE_HEAD"
