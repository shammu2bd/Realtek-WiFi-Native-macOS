#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext/wcl24h32"
KEXT="$DRIVER/build/out/RTL88WiFi.kext"
BIN="$KEXT/Contents/MacOS/RTL88WiFi"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27c-forced-rebuild-$STAMP"
BUILD_LOG="$STAGE_DIR/make-forced-build.log"
CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"
OLD_KNOWN_HASH="5132fc77a16ef6afb20293115575f8cadcc418c606765a5e7c0255ee256aec79"
BUILD_START_EPOCH="$(date +%s)"
FINAL_RC=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project/Makefile missing: $PROJECT" >&2
    exit 2
fi
if ! grep -Fq "BUILD_NAME=$NEW_NAME" "$PROJECT/BUILD_NAME.txt"; then
    echo "ERROR: build identity marker mismatch" >&2
    exit 3
fi
for source in RTW88WCLController.cpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
    [ -f "$SRC/$source" ] || { echo "ERROR: required source missing: $source" >&2; exit 4; }
done
mkdir -p "$STAGE_DIR"

# Preserve the latest remote development log before appending.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then cp "$STAGE_DIR/output.log.github-before" "$OUT"; fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage27c — forced recompilation to rule out stale incremental output"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "REASON: Stage27 binary SHA256 matched the earlier Stage23 binary despite later source cleanup changes."
    echo "METHOD: preserve prior experimental output, then invoke make -B to force target rebuild."
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
} >> "$OUT"

# Back up only the experimental Stage27 build artifact, not the installed driver.
if [ -d "$KEXT" ]; then
    mkdir -p "$STAGE_DIR/pre-force-build"
    ditto "$KEXT" "$STAGE_DIR/pre-force-build/RTL88WiFi.kext"
    if [ -f "$BIN" ]; then
        echo "PRE_FORCE_BINARY_SHA256: $(shasum -a 256 "$BIN" | awk '{print $1}')" > "$STAGE_DIR/pre-force-build.txt"
    else
        echo "PRE_FORCE_BINARY: bundle existed but executable missing" > "$STAGE_DIR/pre-force-build.txt"
    fi
else
    echo "PRE_FORCE_BUILD_BUNDLE: NOT_PRESENT" > "$STAGE_DIR/pre-force-build.txt"
fi

python3 - "$SRC" <<'PY' > "$STAGE_DIR/source-preflight.txt"
from pathlib import Path
import sys
root = Path(sys.argv[1])
ctrl = (root / "RTW88WCLController.cpp").read_text()
ctrlh = (root / "RTW88WCLController.hpp").read_text()
pci = (root / "RTW88WCLPCIBackend.cpp").read_text()
queues = (root / "RTW88WCLSkywalkQueues.cpp").read_text()
assert "IOReturn RTW88WCLController::releaseNativeResources()" in ctrl
assert "IOReturn releaseNativeResources();" in ctrlh
assert ctrl.count("const IOReturn cleanupStatus = releaseNativeResources();") == 3
assert "start-failure cleanup incomplete" in ctrl and "stop cleanup incomplete" in ctrl
assert "quarantining controller and retaining workloop/resources" in ctrl
assert "return fenceStatus;" in ctrl and "return closeStatus;" in ctrl
assert "rollbackCommand & 0x0004U" in pci
pci_free = pci[pci.find("void RTW88WCLPCIBackend::free()"):]
assert "command & 0x0004U" in pci_free
assert "refusing to free DMA resources; backend quarantined" in pci_free
body = ctrl[ctrl.find("IOReturn RTW88WCLController::releaseNativeResources()"):]
order = [body.find(x) for x in ("if (_radio && _radioStarted)", "if (_pciBackend && _pciBackend->isRadioRunning())", "if (_rxAdapter)", "if (_skywalkQueues)")]
assert all(x >= 0 for x in order) and order == sorted(order)
assert "refusing publication until Skywalk datapath is ready" in ctrl
names = ("txSubmissionAction", "txCompletionAction", "rxSubmissionAction", "rxCompletionAction")
def callback_body(name):
    pos = queues.find("RTW88WCLSkywalkQueues::" + name + "(")
    assert pos >= 0
    start = queues.rfind("\nIOReturn ", 0, pos)
    brace = queues.find("{", pos)
    end = queues.find("\n}\n", brace)
    assert min(start, brace, end) >= 0
    return queues[start:end+2]
total = 0
for name in names:
    block = callback_body(name)
    assert "return kIOReturnNotReady;" not in block
    assert "return kIOReturnBadArgument;" not in block
    count = block.count("return static_cast<IOReturn>(0);")
    assert count >= 1
    total += count
assert total == 7
print("PASS: Stage25/26 cleanup guards and PCI quarantine")
print("PASS: PCI bus-master fence ordered before RX adapter and Skywalk teardown")
print("PASS: publication fence remains enabled")
print("PASS: four Skywalk callbacks retain seven fail-closed zero-count returns")
PY

{
    echo "SOURCE_SHA256:"
    for source in RTW88WCLController.cpp RTW88WCLController.hpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
        shasum -a 256 "$SRC/$source"
    done
} > "$STAGE_DIR/source-sha256.txt"

cd "$DRIVER"
set +e
make -B -j"$CPU_COUNT" rtl88wifi > "$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
cat "$BUILD_LOG" | tail -80

: > "$STAGE_DIR/compile-source-checks.txt"
COMPILE_CHECKS=0
for source in RTW88WCLController.cpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
    if grep -Fq "$source" "$BUILD_LOG"; then
        echo "PASS: build log contains $source" >> "$STAGE_DIR/compile-source-checks.txt"
        COMPILE_CHECKS=$((COMPILE_CHECKS + 1))
    else
        echo "FAIL: build log does not show $source" >> "$STAGE_DIR/compile-source-checks.txt"
    fi
done

if [ -f "$BIN" ]; then
    NEW_HASH="$(shasum -a 256 "$BIN" | awk '{print $1}')"
    BIN_MTIME="$(stat -f '%m' "$BIN" 2>/dev/null || echo 0)"
    FILE_INFO="$(file "$BIN" 2>&1)"
else
    NEW_HASH="NOT_FOUND"
    BIN_MTIME=0
    FILE_INFO="NOT_FOUND"
fi
WARNING_COUNT="$(grep -c 'warning:' "$BUILD_LOG" 2>/dev/null || true)"
ERROR_COUNT="$(grep -c 'error:' "$BUILD_LOG" 2>/dev/null || true)"

if [ "$BUILD_RC" -ne 0 ]; then FINAL_RC=7
elif [ ! -f "$BIN" ]; then FINAL_RC=8
elif [ "$BIN_MTIME" -lt "$BUILD_START_EPOCH" ]; then FINAL_RC=9
elif [ "$COMPILE_CHECKS" -ne 3 ]; then FINAL_RC=10
elif [ "$ERROR_COUNT" -ne 0 ]; then FINAL_RC=11
elif [ "$NEW_HASH" = "$OLD_KNOWN_HASH" ]; then FINAL_RC=12
fi

{
    echo
    echo "RTL88WiFi Stage27c — forced recompilation result"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "BUILD_COMMAND: make -B -j$CPU_COUNT rtl88wifi"
    echo "BUILD_EXIT_CODE: $BUILD_RC"
    echo "BUILD_RESULT: $([ "$FINAL_RC" -eq 0 ] && echo PASS || echo FAIL)"
    echo "KEXT_BINARY: $BIN"
    echo "FILE_INFO: $FILE_INFO"
    echo "BINARY_MTIME_EPOCH: $BIN_MTIME"
    echo "BUILD_START_EPOCH: $BUILD_START_EPOCH"
    echo "SHA256: $NEW_HASH"
    echo "PREVIOUS_STAGE23_STAGE27_SHA256: $OLD_KNOWN_HASH"
    echo "SAME_AS_PREVIOUS_BINARY: $([ "$NEW_HASH" = "$OLD_KNOWN_HASH" ] && echo YES || echo NO)"
    echo "WCL_TRANSLATION_UNITS_CONFIRMED_IN_BUILD_LOG: $COMPILE_CHECKS/3"
    cat "$STAGE_DIR/compile-source-checks.txt"
    echo "WARNING_COUNT: $WARNING_COUNT"
    echo "ERROR_COUNT: $ERROR_COUNT"
    cat "$STAGE_DIR/source-preflight.txt"
    cat "$STAGE_DIR/source-sha256.txt"
    if [ "$FINAL_RC" -ne 0 ]; then
        echo "FAILURE_CODE: $FINAL_RC"
        echo "BUILD_LOG_LAST_100_LINES:"
        tail -100 "$BUILD_LOG"
    fi
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_FRESH_BINARY_AUDIT_AND_DEPENDENCY_REVIEW"
} | tee "$STAGE_DIR/status.txt" >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    API_PATH="repos/$REPO/contents/Development/output.log"
    REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$REMOTE_SHA" ]; then
        gh api --method PUT "$API_PATH" -f message="Stage27c forced rebuild verification" -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null
        echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote output.log SHA unavailable"
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local report retained"
fi

echo "BUILD_LOG: $BUILD_LOG"
echo "STATUS_FILE: $STAGE_DIR/status.txt"
echo "REPORT: $OUT"
exit "$FINAL_RC"
