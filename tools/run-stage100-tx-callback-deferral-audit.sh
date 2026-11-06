#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "===== STAGE100 TX CALLBACK DEFERRAL AUDIT ====="
python3 tests/test-wcl-stage100-tx-callback-deferral.py
TMP_BIN="$(mktemp -t stage100-mpsc-retire.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT
c++ -std=c++17 -O2 -pthread tests/wcl_skb_free_retire_stack_test.cpp -o "$TMP_BIN"
"$TMP_BIN"
echo "MPSC_RETIRE_STRESS=PASS_12_PRODUCERS_36000_NODES_EXACTLY_ONCE"
echo "STAGE100_RESULT=PASS_STATIC_AND_PORTABLE_MODEL_TARGET_MAC_COMPILE_PENDING"
