#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CXX="${CXX:-c++}"
TMP_BIN="${TMPDIR:-/tmp}/stage99-bounded-mpsc-token-test-$$"
trap 'rm -f "$TMP_BIN"' EXIT

echo "===== STAGE99 BOUNDED MPSC TOKEN RETIREMENT STRESS ====="
"$CXX" -std=c++17 -O2 -pthread -Wall -Wextra -Werror \
    tests/wcl_tx_completion_retire_list_test.cpp -o "$TMP_BIN"
"$TMP_BIN"
echo "PASS: 12-producer MPSC retirement stress and exactly-once consumption"

echo
echo "===== STAGE99 SOURCE / LOCK / OWNERSHIP AUDIT ====="
python3 tests/test-wcl-stage99-tx-completion-reclamation-audit.py
