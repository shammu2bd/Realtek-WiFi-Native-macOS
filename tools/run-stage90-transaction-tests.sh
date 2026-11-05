#!/bin/bash
# Stage90 transaction, rollback, and regression validation.
# Host/source tests only: no complete kext link, signing, install, load, or hardware I/O.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

mkdir -p "$ROOT/Development/Logs" "$ROOT/Development" || exit 1
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LOG="$ROOT/Development/Logs/stage90-transaction-tests-$STAMP.log"
SUMMARY="$ROOT/Development/output.log"

(
    set -e
    echo "RTL88WIFI STAGE90 TRANSACTION VALIDATION"
    echo "DATE_UTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "PROJECT: $ROOT"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "COMMIT: $(git rev-parse HEAD)"
        echo "BRANCH: $(git branch --show-current)"
    else
        echo "ERROR: This folder is not a Git checkout."
        exit 20
    fi

    echo
    echo "===== TEST 1: STAGE89 FOUR-QUEUE C++ CONTRACT ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_tx_submission_queue_array_test.cpp \
        -o /tmp/wcl-tx-submission-queue-array-test
    /tmp/wcl-tx-submission-queue-array-test
    echo "PASS: Stage89 C++ queue-array contract"

    echo
    echo "===== TEST 2: STAGE89 SOURCE INTEGRATION ====="
    python3 tests/test-wcl-tx-queue-array-contract.py
    echo "PASS: Stage89 source integration"

    echo
    echo "===== TEST 3: STAGE89 SKYWALK SOURCE AUDIT ====="
    python3 tests/test-wcl-skywalk-queues.py
    echo "PASS: Stage89 Skywalk audit"

    echo
    echo "===== TEST 4: STAGE90 JOURNAL FAULT INJECTION ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_resource_acquisition_journal_test.cpp \
        -o /tmp/wcl-resource-acquisition-journal-test
    /tmp/wcl-resource-acquisition-journal-test
    echo "PASS: Stage90 acquisition journal fault-injection test"

    echo
    echo "===== TEST 5: STAGE90 SOURCE INTEGRATION ====="
    python3 tests/test-wcl-resource-transaction.py
    echo "PASS: Stage90 resource transaction source audit"

    echo
    echo "ALL FIVE TESTS PASSED"
) > "$LOG" 2>&1
RESULT=$?

echo "===== STAGE90 VALIDATION OUTPUT ====="
cat "$LOG"
echo
echo "EXIT_CODE=$RESULT"
echo "LOG_FILE=$LOG"

{
    echo
    echo "## Stage90 transaction validation — $STAMP"
    echo "- Branch: $(git branch --show-current 2>/dev/null || echo unknown)"
    echo "- Commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "- Result: $([ "$RESULT" -eq 0 ] && echo PASS || echo FAIL)"
    echo "- Full log: Development/Logs/$(basename "$LOG")"
    echo "- Scope: portable/source tests only; registration remains disabled."
} >> "$SUMMARY"

exit "$RESULT"
