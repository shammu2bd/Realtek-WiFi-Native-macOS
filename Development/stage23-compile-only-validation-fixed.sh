#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
if [ -n "$(printenv RTL88_PROJECT 2>/dev/null || true)" ]; then PROJECT="$(printenv RTL88_PROJECT)"; fi
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage23-compile-only-fixed-$STAMP"
DRYRUN="$STAGE_DIR/make-dry-run.txt"
BUILD_LOG="$STAGE_DIR/make-build.log"
mkdir -p "$STAGE_DIR"
CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"

write_report() {
    {
        echo "RTL88WiFi Stage 23 — corrected compile-only validation"
        echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
        echo "ARCH: $(uname -m)"
        echo "PROJECT: $PROJECT"
        echo "STAGE_DIR: $STAGE_DIR"
        cat "$STAGE_DIR/status.txt" 2>/dev/null || true
        if [ -f "$DRYRUN" ]; then
            echo "========== MAKE DRY-RUN SOURCE MATCH =========="
            grep -n -F 'RTW88WCLSkywalkQueues.cpp' "$DRYRUN" | head -20 || true
        fi
        if [ -f "$BUILD_LOG" ]; then
            echo "========== BUILD COUNTS =========="
            echo "WARNING_COUNT: $(grep -c 'warning:' "$BUILD_LOG" 2>/dev/null || true)"
            echo "ERROR_COUNT: $(grep -c 'error:' "$BUILD_LOG" 2>/dev/null || true)"
            echo "========== BUILD LOG LAST 120 LINES =========="
            tail -120 "$BUILD_LOG"
        fi
    } > "$OUT"
}

upload_report() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
        B64="$(base64 < "$OUT" | tr -d '\n')"
        if [ -n "$SHA" ]; then
            gh api --method PUT "repos/$REPO/contents/Development/output.log" -f message="Stage 23 corrected compile-only validation" -f content="$B64" -f sha="$SHA" >/dev/null
            echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
        else
            echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
        fi
    else
        echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log is ready for the existing GitHub runlog uploader."
    fi
}

if [ ! -f "$SRC" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "PREFLIGHT: FAIL — expected Stage22 source or driver Makefile missing" > "$STAGE_DIR/status.txt"
    write_report
    upload_report
    exit 2
fi

if ! python3 - "$SRC" <<'PY' > "$STAGE_DIR/source-check.txt"
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
names = ("txSubmissionAction", "txCompletionAction", "rxSubmissionAction", "rxCompletionAction")
def body(name):
    sig = "RTW88WCLSkywalkQueues::" + name + "("
    pos = s.find(sig)
    if pos < 0: raise SystemExit("FAIL: callback missing: " + name)
    start = s.rfind("\nIOReturn ", 0, pos)
    brace = s.find("{", pos)
    end = s.find("\n}\n", brace)
    if min(start, brace, end) < 0: raise SystemExit("FAIL: callback boundaries: " + name)
    return s[start:end+2]
total = 0
for name in names:
    b = body(name)
    if "return kIOReturnNotReady;" in b or "return kIOReturnBadArgument;" in b:
        raise SystemExit("FAIL: error-style return remains: " + name)
    n = b.count("return static_cast<IOReturn>(0);")
    if n < 1: raise SystemExit("FAIL: no zero-count return: " + name)
    total += n
if total != 7: raise SystemExit("FAIL: expected 7 callback zero-count returns, found " + str(total))
print("PASS: four callback bodies; seven zero-count fail-closed returns; no error-style returns")
PY
then
    {
        echo "PREFLIGHT: FAIL — source callback check did not pass"
        cat "$STAGE_DIR/source-check.txt"
        echo "BUILD: NOT RUN"
        echo "INSTALL_OR_LOAD: NOT ATTEMPTED"
    } > "$STAGE_DIR/status.txt"
    write_report
    upload_report
    exit 3
fi

{
    echo "SOURCE_CHECK: PASS"
    cat "$STAGE_DIR/source-check.txt"
    echo "XCODE_SELECT: $(xcode-select -p 2>&1 || true)"
    echo "CLANG: $(xcrun --find clang 2>&1 || true)"
    echo "MACOS_SDK: $(xcrun --sdk macosx --show-sdk-path 2>&1 || true)"
    echo "CPU_JOBS: $CPU_COUNT"
} > "$STAGE_DIR/status.txt"

cd "$DRIVER"
set +e
make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
DRY_RC=$?
set -e
if [ "$DRY_RC" -ne 0 ]; then
    {
        echo "PREFLIGHT: FAIL — make dry-run exit $DRY_RC"
        echo "BUILD: NOT RUN"
        tail -60 "$DRYRUN"
        echo "INSTALL_OR_LOAD: NOT ATTEMPTED"
    } >> "$STAGE_DIR/status.txt"
    write_report
    upload_report
    exit 4
fi

if ! grep -Fq 'RTW88WCLSkywalkQueues.cpp' "$DRYRUN"; then
    {
        echo "PREFLIGHT: FAIL-CLOSED — rtl88wifi target does not include RTW88WCLSkywalkQueues.cpp"
        echo "BUILD: NOT RUN; inspect Makefile integration"
        tail -80 "$DRYRUN"
        echo "INSTALL_OR_LOAD: NOT ATTEMPTED"
    } >> "$STAGE_DIR/status.txt"
    write_report
    upload_report
    exit 5
fi

echo "DRY_RUN: PASS — rtl88wifi target includes RTW88WCLSkywalkQueues.cpp" >> "$STAGE_DIR/status.txt"
echo "BUILD_COMMAND: make -j$CPU_COUNT rtl88wifi" >> "$STAGE_DIR/status.txt"
echo "INSTALL: NOT RUN" >> "$STAGE_DIR/status.txt"
echo "LOAD: NOT RUN" >> "$STAGE_DIR/status.txt"

set +e
if make -j"$CPU_COUNT" rtl88wifi 2>&1 | tee "$BUILD_LOG"; then BUILD_RC=0; else BUILD_RC=$?; fi
set -e

KEXT_BIN="$(find "$DRIVER/build" -type f -path '*/RTL88WiFi.kext/Contents/MacOS/RTL88WiFi' -print -quit 2>/dev/null || true)"
if [ "$BUILD_RC" -eq 0 ] && [ -n "$KEXT_BIN" ]; then
    {
        echo "BUILD_RESULT: SUCCEEDED"
        echo "BUILD_EXIT_CODE: 0"
        echo "KEXT_BINARY: $KEXT_BIN"
        echo "FILE_INFO: $(file "$KEXT_BIN" 2>&1)"
        echo "SHA256: $(shasum -a 256 "$KEXT_BIN" | awk '{print $1}')"
        echo "INSTALL: NOT RUN"
        echo "LOAD: NOT RUN"
        echo "QUEUE_REGISTRATION: STILL DISABLED"
        echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_LIFECYCLE_AND_TEARDOWN_REVIEW"
    } >> "$STAGE_DIR/status.txt"
    FINAL_RC=0
else
    KEXT_DISPLAY="$KEXT_BIN"
    if [ -z "$KEXT_DISPLAY" ]; then KEXT_DISPLAY="NOT_FOUND"; fi
    {
        echo "BUILD_RESULT: FAILED_OR_OUTPUT_MISSING"
        echo "BUILD_EXIT_CODE: $BUILD_RC"
        echo "KEXT_BINARY: $KEXT_DISPLAY"
        echo "INSTALL: NOT RUN"
        echo "LOAD: NOT RUN"
    } >> "$STAGE_DIR/status.txt"
    FINAL_RC=6
fi

write_report
upload_report
echo "FULL_BUILD_LOG: $BUILD_LOG"
echo "STATUS_FILE: $STAGE_DIR/status.txt"
exit "$FINAL_RC"
