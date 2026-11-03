#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
ARCHIVE="$HOME/Downloads/$NEW_NAME.zip"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27-compile-only-$STAMP"
DRYRUN="$STAGE_DIR/make-dry-run.txt"
BUILD_LOG="$STAGE_DIR/make-build.log"
CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: Stage26 project or ZIP missing. Run the Stage26 resume runner first." >&2
    exit 2
fi
if [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: new-tree driver Makefile missing: $DRIVER/Makefile" >&2
    exit 3
fi
mkdir -p "$STAGE_DIR"

# Verify the downloaded source ZIP and new build identity.
ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if ! grep -Fq "BUILD_NAME=$NEW_NAME" "$PROJECT/BUILD_NAME.txt"; then
    echo "ERROR: build identity marker mismatch" >&2
    exit 4
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
assert "start-failure cleanup incomplete" in ctrl
assert "stop cleanup incomplete" in ctrl
assert "quarantining controller and retaining workloop/resources" in ctrl
assert "return fenceStatus;" in ctrl and "return closeStatus;" in ctrl
assert "rollbackCommand & 0x0004U" in pci
pci_free = pci[pci.find("void RTW88WCLPCIBackend::free()"):]
assert "command & 0x0004U" in pci_free
assert "refusing to free DMA resources; backend quarantined" in pci_free

# Verify the PCI fence appears after RTW radio stop and before RX adapter/queue release.
body_start = ctrl.find("IOReturn RTW88WCLController::releaseNativeResources()")
body = ctrl[body_start:]
radio_stop = body.find("if (_radio && _radioStarted)")
fence = body.find("if (_pciBackend && _pciBackend->isRadioRunning())")
rx_adapter = body.find("if (_rxAdapter)")
skywalk_queues = body.find("if (_skywalkQueues)")
assert -1 not in (radio_stop, fence, rx_adapter, skywalk_queues)
assert radio_stop < fence < rx_adapter < skywalk_queues

# Keep the native publication fence in place. A compile does not authorize
# queue registration or radio start.
assert "refusing publication until Skywalk datapath is ready" in ctrl

names = ("txSubmissionAction", "txCompletionAction", "rxSubmissionAction", "rxCompletionAction")
def callback_body(name):
    marker = "RTW88WCLSkywalkQueues::" + name + "("
    pos = queues.find(marker)
    assert pos >= 0, "missing callback " + name
    start = queues.rfind("\nIOReturn ", 0, pos)
    brace = queues.find("{", pos)
    end = queues.find("\n}\n", brace)
    assert min(start, brace, end) >= 0, "callback boundary mismatch " + name
    return queues[start:end+2]
zero_total = 0
for name in names:
    b = callback_body(name)
    assert "return kIOReturnNotReady;" not in b
    assert "return kIOReturnBadArgument;" not in b
    n = b.count("return static_cast<IOReturn>(0);")
    assert n >= 1, "missing fail-closed zero-count return " + name
    zero_total += n
assert zero_total == 7, "expected 7 zero-count returns, found " + str(zero_total)

print("PASS: Stage26 build identity and new project source tree")
print("PASS: exactly 3 controller cleanup-status guards (start, stop, free)")
print("PASS: Stage25 PCI rollback, cleanup propagation and bus-master quarantine checks")
print("PASS: PCI fence ordered before RX adapter and Skywalk queue/pool release")
print("PASS: native publication fence remains enabled; no queue registration")
print("PASS: four Skywalk callbacks retain seven fail-closed zero-count returns")
PY

# Confirm all three WCL translation units are in the target before compiling.
cd "$DRIVER"
set +e
make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
DRY_RC=$?
set -e
if [ "$DRY_RC" -ne 0 ]; then
    {
        echo "STAGE27_PREFLIGHT: FAILED — make dry-run exit $DRY_RC"
        tail -100 "$DRYRUN"
    } | tee "$STAGE_DIR/status.txt"
    exit 5
fi
for source in RTW88WCLController.cpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
    if ! grep -Fq "$source" "$DRYRUN"; then
        {
            echo "STAGE27_PREFLIGHT: FAIL-CLOSED — target omitted $source"
            echo "BUILD: NOT RUN"
        } | tee "$STAGE_DIR/status.txt"
        exit 6
    fi
done

{
    echo "STAGE27_PREFLIGHT: PASS"
    cat "$STAGE_DIR/source-preflight.txt"
    echo "MAKE_DRY_RUN: PASS — controller, PCI backend and Skywalk queues included"
    echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
    echo "XCODE_SELECT: $(xcode-select -p 2>&1 || true)"
    echo "CLANG: $(xcrun --find clang 2>&1 || true)"
    echo "MACOS_SDK: $(xcrun --sdk macosx --show-sdk-path 2>&1 || true)"
    echo "CPU_JOBS: $CPU_COUNT"
} > "$STAGE_DIR/status.txt"

set +e
make -j"$CPU_COUNT" rtl88wifi 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

KEXT_BIN="$(find "$DRIVER/build" -type f -path '*/RTL88WiFi.kext/Contents/MacOS/RTL88WiFi' -print -quit 2>/dev/null || true)"
if [ "$BUILD_RC" -eq 0 ] && [ -n "$KEXT_BIN" ]; then
    {
        echo "BUILD_RESULT: SUCCEEDED"
        echo "BUILD_EXIT_CODE: 0"
        echo "KEXT_BINARY: $KEXT_BIN"
        echo "FILE_INFO: $(file "$KEXT_BIN" 2>&1)"
        echo "SHA256: $(shasum -a 256 "$KEXT_BIN" | awk '{print $1}')"
        echo "WARNING_COUNT: $(grep -c 'warning:' "$BUILD_LOG" 2>/dev/null || true)"
        echo "ERROR_COUNT: $(grep -c 'error:' "$BUILD_LOG" 2>/dev/null || true)"
    } >> "$STAGE_DIR/status.txt"
    FINAL_RC=0
else
    {
        echo "BUILD_RESULT: FAILED_OR_OUTPUT_MISSING"
        echo "BUILD_EXIT_CODE: $BUILD_RC"
        echo "KEXT_BINARY: ${KEXT_BIN:-NOT_FOUND}"
    } >> "$STAGE_DIR/status.txt"
    FINAL_RC=7
fi

{
    echo
    echo "RTL88WiFi Stage27 — compile-only validation in the new project tree"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "BUILD_NAME: $NEW_NAME"
    echo "STAGE_DIR: $STAGE_DIR"
    cat "$STAGE_DIR/status.txt"
    echo "BUILD_LOG: $BUILD_LOG"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_BINARY_DEPENDENCY_AND_RUNTIME_ABI_AUDIT"
} >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 27 new-tree compile-only validation" \
            -f content="$B64" -f sha="$SHA" >/dev/null
        echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
    fi
else
    echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log ready for upload."
fi

echo "STATUS_FILE: $STAGE_DIR/status.txt"
echo "BUILD_LOG: $BUILD_LOG"
exit "$FINAL_RC"
