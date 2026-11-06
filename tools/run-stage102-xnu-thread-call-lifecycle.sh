#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "===== STAGE102 XNU THREAD-CALL + TOKEN LIFECYCLE SOURCE AUDIT ====="
python3 tests/test-stage102-xnu-thread-call-lifecycle.py

TMP_BIN="$(mktemp -t stage102-thread-call-model.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT
c++ -std=c++17 -O2 -pthread tests/wcl_thread_call_lifecycle_model_test.cpp -o "$TMP_BIN"
"$TMP_BIN"
echo "THREAD_CALL_CANCEL_WAIT_EDGE_MODEL=PASS"
echo "PRODUCER_ADMISSION_CLOSE_AND_JOIN_MODEL=PASS_12_PRODUCERS"
echo "STAGE102_RESULT=PASS_STATIC_AND_PORTABLE_MODEL_TARGET_MAC_COMPILE_PENDING"
