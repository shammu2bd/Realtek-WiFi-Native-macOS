#!/bin/bash
# Stage91 TX submission callback host/source validation.
# No native WCL build, full kext link, signing, install, load, hardware I/O,
# queue registration, or OpenCore/SIP/NVRAM changes are performed here.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [ "$BRANCH" != "$EXPECTED_BRANCH" ]; then
    echo "ERROR: run this validation only on $EXPECTED_BRANCH"
    echo "CURRENT_BRANCH=$BRANCH"
    exit 91
fi

mkdir -p "$ROOT/Development/Logs" "$ROOT/Development" || exit 1
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LOG="$ROOT/Development/Logs/stage91-tx-submission-tests-$STAMP.log"
SUMMARY="$ROOT/Development/output.log"

(
    set -e
    echo "RTL88WIFI STAGE91 TX SUBMISSION VALIDATION"
    echo "DATE_UTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "PROJECT: $ROOT"
    echo "COMMIT: $(git rev-parse HEAD)"
    echo "BRANCH: $(git branch --show-current)"
    echo "TARGET: macOS Sequoia 15.8.1 / 24H32 / x86_64"
    echo "SCOPE: host C++ and source-integration tests only"

    echo
    echo "===== TEST 1: STAGE89 FOUR-QUEUE C++ CONTRACT ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_tx_submission_queue_array_test.cpp \
        -o /tmp/rtl88-stage91-stage89-queue-test
    /tmp/rtl88-stage91-stage89-queue-test
    echo "PASS: Stage89 four-queue C++ contract"

    echo
    echo "===== TEST 2: STAGE89 QUEUE ARRAY SOURCE INTEGRATION ====="
    python3 tests/test-wcl-tx-queue-array-contract.py
    echo "PASS: Stage89 queue-array source integration"

    echo
    echo "===== TEST 3: STAGE89 SKYWALK OWNER SOURCE AUDIT ====="
    python3 tests/test-wcl-skywalk-queues.py
    echo "PASS: Stage89 Skywalk source audit"

    echo
    echo "===== TEST 4: STAGE90 JOURNAL FAULT INJECTION ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_resource_acquisition_journal_test.cpp \
        -o /tmp/rtl88-stage91-stage90-journal-test
    /tmp/rtl88-stage91-stage90-journal-test
    echo "PASS: Stage90 journal fault injection"

    echo
    echo "===== TEST 5: STAGE90 RESOURCE TRANSACTION SOURCE AUDIT ====="
    python3 tests/test-wcl-resource-transaction.py
    echo "PASS: Stage90 resource transaction source audit"

    echo
    echo "===== TEST 6: PACKET SPAN BOUNDS ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_packet_span_test.cpp \
        -o /tmp/rtl88-stage91-packet-span-test
    /tmp/rtl88-stage91-packet-span-test
    echo "PASS: packet span bounds"

    echo
    echo "===== TEST 7: TX COMPLETION TICKET CONCURRENCY REGRESSION ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 -pthread \
        tests/wcl_tx_completion_slots_test.cpp \
        -o /tmp/rtl88-stage91-completion-ticket-test
    /tmp/rtl88-stage91-completion-ticket-test
    echo "PASS: TX completion ticket concurrency regression"

    echo
    echo "===== TEST 8: STAGE91 SUBMISSION GATE / TEARDOWN RACES ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 -pthread \
        tests/wcl_tx_submission_gate_test.cpp \
        -o /tmp/rtl88-stage91-submission-gate-test
    /tmp/rtl88-stage91-submission-gate-test
    echo "PASS: Stage91 submission admission and teardown gate"

    echo
    echo "===== TEST 9: STAGE91 BOUNDED PREFIX ACCEPTANCE ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 \
        tests/wcl_tx_submission_batch_test.cpp \
        -o /tmp/rtl88-stage91-submission-batch-test
    /tmp/rtl88-stage91-submission-batch-test
    echo "PASS: Stage91 bounded contiguous-prefix acceptance"

    echo
    echo "===== TEST 10: STAGE91 SOURCE / ABI / OWNERSHIP INTEGRATION ====="
    python3 tests/test-wcl-tx-submission-stage91.py
    echo "PASS: Stage91 target ABI, ownership and teardown source audit"

    echo
    echo "===== TEST 11: ATOMIC PER-TID SEQUENCE / CCMP PN REGRESSION ====="
    c++ -std=c++17 -Wall -Wextra -Werror -O2 -pthread \
        tests/rtw88_tx_sequence_numbers_test.cpp \
        -o /tmp/rtl88-stage91-sequence-number-test
    /tmp/rtl88-stage91-sequence-number-test
    echo "PASS: per-TID QoS sequences and CCMP packet numbers are unique under concurrency"

    echo
    echo "ALL ELEVEN STAGE91 TESTS PASSED"
) > "$LOG" 2>&1
RESULT=$?

echo "===== STAGE91 VALIDATION OUTPUT ====="
cat "$LOG"
echo
echo "EXIT_CODE=$RESULT"
echo "LOG_FILE=$LOG"

{
    echo
    echo "## Stage91 TX submission validation — $STAMP"
    echo "- Branch: $BRANCH"
    echo "- Commit: $(git rev-parse HEAD)"
    echo "- Result: $([ "$RESULT" -eq 0 ] && echo PASS || echo FAIL)"
    echo "- Full log: Development/Logs/$(basename "$LOG")"
    echo "- Scope: 11 host C++/source tests; no native build or packet-path activation."
} >> "$SUMMARY"

git add -f -- "$LOG" "$SUMMARY" || exit 92
if git diff --cached --quiet; then
    echo "GITHUB_LOG_COMMIT=NO_CHANGES"
else
    git commit -m "Stage91: record TX submission validation $STAMP" || exit 93
fi

git push origin HEAD
PUSH_RESULT=$?
echo "GITHUB_PUSH_EXIT_CODE=$PUSH_RESULT"
if [ "$PUSH_RESULT" -ne 0 ]; then
    echo "GITHUB_LOG_UPLOAD=FAILED"
    exit 94
fi

echo "GITHUB_LOG_UPLOAD=PASS"
exit "$RESULT"
