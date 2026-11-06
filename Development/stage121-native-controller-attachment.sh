#!/bin/bash
# Stage121: verified Apple controller primary Skywalk attachment + native build.
# Builds and validates only. No signing, install/load, hardware activation,
# OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail

EXPECTED_BRANCH="work/stage121-native-controller-attachment"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(git branch --show-current)" != "$EXPECTED_BRANCH" ]]; then
  echo "ERROR: run Stage121 on $EXPECTED_BRANCH"
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is not clean; preserve or resolve local changes first"
  git status --short
  exit 2
fi

if [[ -d "/Applications/Xcode_16.4.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
fi
CXX_BIN="$(xcrun --find clang++ 2>/dev/null || command -v clang++)"
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  echo "ERROR: macOS SDK not found; Stage121 requires the target Mac Xcode SDK"
  exit 2
fi

mkdir -p Development/Logs
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="Development/Logs/stage121-native-controller-attachment-${STAMP}.log"
SOURCE_COMMIT="$(git rev-parse HEAD)"
BUNDLE="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
PLIST="$BUNDLE/Contents/Info.plist"

if (
  set -euo pipefail
  echo "========== STAGE121 NATIVE CONTROLLER ATTACHMENT =========="
  echo "STAGE121_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE121_TARGET=macOS_15.8.1_24H32_x86_64"
  echo "STAGE121_SCOPE=APPLE_PRIMARY_SKYWALK_INTERFACE_ATTACH_VERIFY_DETACH"
  echo "STAGE121_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE"
  echo "STAGE121_SIGNING=DISABLED INSTALL=NOT_RUN LOAD=NOT_RUN REBOOT=NOT_RUN"
  echo

  echo "----- Focused source lifecycle contract -----"
  python3 tests/test-wcl-controller-primary-attachment-stage121.py

  echo
  echo "----- Existing registration and queue ownership regressions -----"
  python3 tests/test-wcl-registration-transaction-stage108.py
  python3 tests/test-wcl-registration-contract.py
  python3 tests/test-wcl-registration-info-stage11.py
  python3 tests/test-wcl-tx-queue-array-contract.py
  python3 tests/test-wcl-resource-transaction.py

  echo
  echo "----- Native 24H32 unsigned bundle build (no activation) -----"
  export CXX="$CXX_BIN"
  export SDKROOT="$SDK_PATH"
  make -C driver/RTL88WiFi rtl88wifi-native

  test -s "$BIN"
  test -s "$PLIST"
  plutil -lint "$PLIST"
  file "$BIN"
  lipo "$BIN" -verify_arch x86_64
  BINARY_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
  echo "STAGE121_NATIVE_BUNDLE_ID=$BUNDLE_ID"
  echo "STAGE121_NATIVE_BINARY_SHA256=$BINARY_SHA"
  echo "STAGE121_NATIVE_BUILD=PASS"
) 2>&1 | tee "$LOG"; then
  RUN_STATUS=0
else
  RUN_STATUS=$?
fi

if [[ $RUN_STATUS -eq 0 ]]; then RESULT="PASS"; else RESULT="FAIL"; fi

{
  echo
  echo "STAGE121_RESULT=$RESULT"
  echo "STAGE121_SOURCE_COMMIT=$SOURCE_COMMIT"
  echo "STAGE121_DETAIL_LOG=$LOG"
  echo "STAGE121_PRIMARY_ATTACHMENT_RUNTIME=NOT_RUN"
  echo "STAGE121_RADIO_START=NOT_RUN"
  echo "STAGE121_TX_RX_RUNTIME=NOT_RUN"
  echo "STAGE121_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN REBOOT=NOT_RUN"
  echo "STAGE121_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE"
  echo "STAGE121_PR4_MERGE=NOT_REQUESTED"
  echo "==========================================================="
} >> "$LOG"

{
  echo
  echo "========== STAGE121 NATIVE CONTROLLER ATTACHMENT =========="
  echo "STAGE121_RESULT=$RESULT"
  echo "STAGE121_DETAIL_LOG=$LOG"
  echo "STAGE121_SOURCE_SCOPE=APPLE_CONTROLLER_PRIMARY_INTERFACE_ATTACHMENT_AND_VERIFIED_TEARDOWN"
  echo "STAGE121_SOURCE_CONTRACT=$([[ $RUN_STATUS -eq 0 ]] && echo PASS || echo CHECK_LOG)"
  echo "STAGE121_NATIVE_BUILD=$([[ $RUN_STATUS -eq 0 ]] && echo PASS || echo FAIL)"
  echo "STAGE121_PRIMARY_ATTACHMENT_RUNTIME=NOT_RUN"
  echo "STAGE121_RADIO_START=NOT_RUN TX_RX_RUNTIME=NOT_RUN"
  echo "STAGE121_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN HARDWARE_TEST=NOT_RUN REBOOT=NOT_RUN"
  echo "STAGE121_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE"
  echo "==========================================================="
} >> Development/output.log

git add -f "$LOG" Development/output.log
# Keep raw compiler diagnostics byte-for-byte; they may contain trailing
# whitespace from included third-party headers. Continue checking source and
# metadata changes for all other whitespace errors.
git -c core.whitespace=-trailing-space diff --cached --check
git commit -m "Stage121: validate native controller primary attachment and build"
git push origin "$EXPECTED_BRANCH"

if [[ $RUN_STATUS -ne 0 ]]; then
  echo "Stage121 tests/build FAILED; inspect $LOG"
  exit "$RUN_STATUS"
fi
echo "Stage121 source checks and native unsigned build PASS; report: $LOG"
