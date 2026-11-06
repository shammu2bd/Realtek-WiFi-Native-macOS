#!/bin/bash
# Stage108: host contract tests and native 24H32 kext rebuild.
# No signing, install/load, hardware activation, EFI, SIP or NVRAM operations.
set -euo pipefail

EXPECTED_BRANCH="work/stage91-tx-submission-callback-v1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: run Stage108 on $EXPECTED_BRANCH"
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is not clean; preserve or resolve local changes first"
  git status --short
  exit 2
fi

mkdir -p Development/Logs
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="Development/Logs/stage108-registration-transaction-${STAMP}.log"
SOURCE_COMMIT="$(git rev-parse HEAD)"
CXX_BIN="${CXX:-$(xcrun --find clang++ 2>/dev/null || command -v clang++)}"
TMP_BASE="${TMPDIR:-/tmp}"
[[ -d "$TMP_BASE" && -w "$TMP_BASE" ]] || TMP_BASE="/tmp"
TMP_DIR="$(mktemp -d "$TMP_BASE/rtl88wcl-stage108.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if (
  set -euo pipefail
  echo "========== STAGE108 REGISTRATION TRANSACTION =========="
  echo "STAGE108_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE108_TARGET=macOS_15.8.1_24H32_x86_64"
  echo "STAGE108_SCOPE=ATOMIC_REGISTRATION_DEREGISTRATION_QUEUE_OWNER_ROLLBACK"
  echo "STAGE108_SIGNING=DISABLED"
  echo "STAGE108_SIP_OR_OPENCORE_CHANGE=NONE"
  echo

  echo "----- C++ transaction state-machine test -----"
  "$CXX_BIN" -std=c++17 -Wall -Wextra -Werror -O2 \
    tests/wcl_registration_transaction_stage108_test.cpp \
    -o "$TMP_DIR/registration-transaction-test" &&
  "$TMP_DIR/registration-transaction-test" &&
  echo "PASS: Stage108 C++ transaction state machine"

  echo
  echo "----- Python source-contract suite -----"
  python3 tests/test-wcl-registration-transaction-stage108.py &&
  python3 tests/test-wcl-registration-contract.py &&
  python3 tests/test-wcl-registration-info-stage11.py &&
  python3 tests/test-wcl-tx-queue-array-contract.py &&
  python3 tests/test-wcl-resource-transaction.py

  echo
  echo "----- Native unsigned kext rebuild -----"
  make -C driver/RTL88WiFi rtl88wifi-native

  BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
  BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
  PLIST="$BUNDLE/Contents/Info.plist"
  test -s "$BIN"
  test -s "$PLIST"
  plutil -lint "$PLIST"
  file "$BIN"
  lipo "$BIN" -verify_arch x86_64
  echo "STAGE108_NATIVE_BINARY_SHA256=$(shasum -a 256 "$BIN" | awk '{print $1}')"
  echo "STAGE108_BUILD_RESULT=PASS"
) 2>&1 | tee "$LOG"; then
  RUN_STATUS=0
else
  RUN_STATUS=$?
fi

if [[ $RUN_STATUS -eq 0 ]]; then
  RESULT="PASS"
else
  RESULT="FAIL"
fi

{
  echo
  echo "STAGE108_RESULT=$RESULT"
  echo "STAGE108_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE108_DETAIL_LOG=$LOG"
  echo "STAGE108_REGISTRATION_RUNTIME=NOT_RUN"
  echo "STAGE108_RADIO_START=SOURCE_PATH_IMPLEMENTED_RUNTIME_NOT_RUN"
  echo "STAGE108_TX_RX_RUNTIME=NOT_RUN"
  echo "STAGE108_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN"
  echo "STAGE108_SIP_CHANGE=NONE NVRAM_CHANGE=NONE EFI_WRITE=NONE"
  echo "STAGE108_PR4_MERGE=BLOCKED"
  echo "======================================================="
} >> "$LOG"

{
  echo
  echo "========== STAGE108 REGISTRATION TRANSACTION =========="
  echo "STAGE108_RESULT=$RESULT"
  echo "STAGE108_DETAIL_LOG=$LOG"
  echo "STAGE108_SCOPE=24H32_INTERFACE_START_REGISTER_PUBLISH_POWER_RX_OWNERSHIP_AND_TRANSACTIONAL_TEARDOWN"
  echo "STAGE108_NATIVE_BUILD=$([[ $RUN_STATUS -eq 0 ]] && echo PASS || echo FAIL)"
  echo "STAGE108_REGISTRATION_RUNTIME=NOT_RUN"
  echo "STAGE108_RADIO_START=BLOCKED"
  echo "STAGE108_TX_RX_RUNTIME=NOT_RUN"
  echo "STAGE108_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN"
  echo "STAGE108_SIP_CHANGE=NONE NVRAM_CHANGE=NONE EFI_WRITE=NONE"
  echo "STAGE108_PR4_MERGE=BLOCKED"
  echo "======================================================="
} >> Development/output.log

git add -f "$LOG" Development/output.log
git diff --cached --check
git commit -m "Stage108: record registration transaction tests and native build"
git push origin "$EXPECTED_BRANCH"

if [[ $RUN_STATUS -ne 0 ]]; then
  echo "Stage108 tests/build FAILED; inspect $LOG"
  exit "$RUN_STATUS"
fi
echo "Stage108 tests and native unsigned build PASS; report: $LOG"
