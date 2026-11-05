#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CXX="${CXX:-clang++}"
STRESS_RUNS="${STRESS_RUNS:-1}"
OUT="${TMPDIR:-/tmp}/rtw88-tx-state-gate-test.$$"
trap 'rm -f "$OUT"' EXIT
"$CXX" -std=c++11 -O2 -Wall -Wextra -Werror -pthread \
  "$ROOT/tests/rtw88_tx_state_gate_test.cpp" -o "$OUT"
for ((run = 1; run <= STRESS_RUNS; ++run)); do
  echo "STAGE94_MODEL_RUN=$run/$STRESS_RUNS"
  "$OUT"
done
