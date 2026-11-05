#!/bin/bash
# Stage89 four-TX-queue validation. Host/source tests only; no kext build/load.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

mkdir -p "$ROOT/Development" || exit 1
LOG="$ROOT/Development/output.log"

(
    echo "RTL88WIFI STAGE89 FOUR-QUEUE VALIDATION"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "PROJECT: $ROOT"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "COMMIT: $(git rev-parse HEAD)"
        echo "BRANCH: $(git branch --show-current)"
    else
        echo "ERROR: This folder is not a Git checkout."
        exit 20
    fi

    echo
    echo "===== TEST 1: C++ QUEUE ARRAY ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_tx_submission_queue_array_test.cpp \
        -o /tmp/wcl-tx-submission-queue-array-test || {
            rc=$?
            echo "FAIL: C++ test compilation (exit $rc)"
            exit "$rc"
        }
    /tmp/wcl-tx-submission-queue-array-test || {
        rc=$?
        echo "FAIL: C++ queue array runtime test (exit $rc)"
        exit "$rc"
    }
    echo "PASS: C++ queue array"

    echo
    echo "===== TEST 2: SOURCE INTEGRATION ====="
    python3 tests/test-wcl-tx-queue-array-contract.py || {
        rc=$?
        echo "FAIL: source integration (exit $rc)"
        exit "$rc"
    }
    echo "PASS: source integration"

    echo
    echo "===== TEST 3: EXISTING SKYWALK QUEUE AUDIT ====="
    python3 tests/test-wcl-skywalk-queues.py || {
        rc=$?
        echo "FAIL: Skywalk queue audit (exit $rc)"
        exit "$rc"
    }
    echo "PASS: Skywalk queue audit"

    echo
    echo "ALL THREE TESTS PASSED"
) > "$LOG" 2>&1
RESULT=$?

echo "===== VALIDATION OUTPUT ====="
cat "$LOG"
echo
echo "EXIT_CODE=$RESULT"
echo "LOG_FILE=$LOG"
exit "$RESULT"
