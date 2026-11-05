#!/bin/bash
# Stage93 independent source/concurrency audit. No driver builds or source edits.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
EXPECTED_TEST_BLOB="4ef6896e109fd456cb030b537a6abd1519cd3b8f"
VALIDATED_SOURCE_BASELINE="b385ff2edd5c60adb5730f80fc3c67000965b226"

BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [ "$BRANCH" != "$EXPECTED_BRANCH" ]; then
    echo "STOP: Stage93 is pinned to $EXPECTED_BRANCH"
    echo "CURRENT_BRANCH=$BRANCH"
    exit 91
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "STOP: local changes detected; no reset or overwrite performed."
    exit 2
fi

git fetch origin || exit 3
git merge --ff-only "origin/$BRANCH" || exit 4

if ! git merge-base --is-ancestor "$VALIDATED_SOURCE_BASELINE" HEAD; then
    echo "STOP: validated Stage92 source baseline is not an ancestor of HEAD."
    exit 5
fi

SOURCE_DIFF="$(git diff --name-only "$VALIDATED_SOURCE_BASELINE" HEAD -- \
    driver/RTL88WiFi/src driver/RTL88WiFi/Makefile)"
if [ -n "$SOURCE_DIFF" ]; then
    echo "STOP: driver source moved after the Stage92 eight-object validation."
    printf '%s\n' "$SOURCE_DIFF"
    echo "Do not interpret this audit against an unvalidated source revision."
    exit 6
fi

ACTUAL_TEST_BLOB="$(git hash-object tests/test-wcl-stage93-independent-tx-audit.py 2>/dev/null || true)"
if [ "$ACTUAL_TEST_BLOB" != "$EXPECTED_TEST_BLOB" ]; then
    echo "STOP: Stage93 audit test hash is not the reviewed allowlisted blob."
    echo "EXPECTED=$EXPECTED_TEST_BLOB"
    echo "ACTUAL=$ACTUAL_TEST_BLOB"
    exit 7
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p Development/Logs Development || exit 8
LOG="Development/Logs/stage93-independent-tx-audit-$STAMP.log"

echo "STAGE93_BRANCH=$BRANCH"
echo "STAGE93_SOURCE_BASELINE=$VALIDATED_SOURCE_BASELINE"
echo "STAGE93_TEST_BLOB=$ACTUAL_TEST_BLOB"
echo "STAGE93_SCOPE=READ_ONLY_SOURCE_AND_CONCURRENCY_AUDIT"
echo "STAGE93_DRIVER_SOURCE_DIFF=NONE"
echo "STAGE93_BUILD=NOT_RUN"
echo "STAGE93_LINK_SIGN_INSTALL_LOAD=NOT_RUN"
echo "STAGE93_HARDWARE_TEST=NOT_RUN"

set +e
python3 tests/test-wcl-stage93-independent-tx-audit.py > "$LOG" 2>&1
RESULT=$?
set -e

echo "===== STAGE93 AUDIT OUTPUT ====="
cat "$LOG"
echo "STAGE93_AUDIT_EXIT_CODE=$RESULT"

{
    echo
    echo "## Stage93 independent TX completion/concurrency audit — $STAMP"
    echo "- Branch: $BRANCH"
    echo "- Source baseline: $VALIDATED_SOURCE_BASELINE"
    echo "- Audit test blob: $ACTUAL_TEST_BLOB"
    echo "- Result: $( [ "$RESULT" -eq 0 ] && echo PASS || { [ "$RESULT" -eq 20 ] && echo BLOCKED || echo REVIEW_REQUIRED; } )"
    echo "- Full log: $LOG"
    echo "- Scope: read-only source/SDK contract audit; driver source unchanged; no build, link, signing, install, load or hardware test."
    echo "- Native activation: BLOCKED pending resolution of any Stage93 findings and fresh approval."
} >> Development/output.log

git add -f -- "$LOG" Development/output.log || exit 9
if git diff --cached --quiet; then
    echo "GITHUB_LOG_COMMIT=NO_CHANGES"
else
    git commit -m "Stage93: record independent TX completion audit $STAMP" || exit 10
fi

git push origin HEAD || exit 11
echo "GITHUB_AUDIT_LOG_UPLOAD=PASS"
exit "$RESULT"
