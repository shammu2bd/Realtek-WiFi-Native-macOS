#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CXX="${CXX:-clang++}"
OUT="${TMPDIR:-/tmp}/rtw88-tx-ba-state-test.$$"
trap 'rm -f "$OUT"' EXIT
"$CXX" -std=c++11 -O2 -Wall -Wextra -Werror -pthread \
  "$ROOT/tests/rtw88_tx_ba_state_test.cpp" -o "$OUT"
"$OUT"
