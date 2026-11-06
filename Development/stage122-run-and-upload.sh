#!/bin/bash
# Stage122 one-command entry point: verify pin, collect diagnostics, and verify
# that the Stage122 runner committed its report and canonical checkpoint to GitHub.
set -euo pipefail

EXPECTED_BRANCH="work/stage122-primary-interface-runtime-diagnostics"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: run Stage122 on $EXPECTED_BRANCH"
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is not clean; preserve or resolve local changes first"
  git status --short
  exit 2
fi

RUNNER="Development/stage122-readonly-runtime-diagnostics.sh"
PIN="Development/stage122-readonly-runtime-diagnostics.pin"
EXPECTED_BLOB="$(sed -n 's/^STAGE122_RUNNER_GIT_BLOB_SHA1=//p' "$PIN")"
ACTUAL_BLOB="$(git hash-object "$RUNNER")"
if [[ -z "$EXPECTED_BLOB" || "$ACTUAL_BLOB" != "$EXPECTED_BLOB" ]]; then
  echo "ERROR: Stage122 diagnostic runner pin mismatch"
  echo "EXPECTED=$EXPECTED_BLOB"
  echo "ACTUAL=$ACTUAL_BLOB"
  exit 3
fi
echo "STAGE122_RUNNER_PIN=PASS"
echo "STAGE122_AUTO_UPLOAD=ENABLED"

# The diagnostic runner creates the timestamped report, appends the canonical
# checkpoint, commits both, pushes the branch, and verifies GitHub read-back.
bash "$RUNNER"

# Confirm the local published commit is the current remote branch head.
git fetch origin "$EXPECTED_BRANCH"
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse FETCH_HEAD)"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
  echo "ERROR: Stage122 report was not fully synchronized to GitHub"
  echo "LOCAL_HEAD=$LOCAL_HEAD"
  echo "REMOTE_HEAD=$REMOTE_HEAD"
  exit 4
fi

LATEST_LOG="$(git show "FETCH_HEAD:Development/output.log" | grep -E '^STAGE122_DETAIL_LOG=Development/Logs/stage122-readonly-runtime-diagnostics-[0-9]{8}T[0-9]{6}Z\.log$' | tail -n 1 | cut -d= -f2-)"
if [[ -z "$LATEST_LOG" ]]; then
  echo "ERROR: canonical output.log does not contain the Stage122 detail-log pointer"
  exit 5
fi
git show "FETCH_HEAD:$LATEST_LOG" >/dev/null

echo "STAGE122_AUTO_UPLOAD=PASS"
echo "STAGE122_BRANCH=$EXPECTED_BRANCH"
echo "STAGE122_DETAIL_LOG=$LATEST_LOG"
echo "STAGE122_REMOTE_HEAD=$REMOTE_HEAD"
