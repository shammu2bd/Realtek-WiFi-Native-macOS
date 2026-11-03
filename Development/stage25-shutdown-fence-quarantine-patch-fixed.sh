#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
if [ -n "$(printenv RTL88_PROJECT 2>/dev/null || true)" ]; then PROJECT="$(printenv RTL88_PROJECT)"; fi
KEXTSRC="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32"
CTRL="$KEXTSRC/RTW88WCLController.cpp"
CTRLH="$KEXTSRC/RTW88WCLController.hpp"
PCI="$KEXTSRC/RTW88WCLPCIBackend.cpp"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage25-shutdown-fence-fixed-$STAMP"
mkdir -p "$STAGE_DIR"

for f in "$CTRL" "$CTRLH" "$PCI"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required source missing: $f" >&2
        exit 2
    fi
done

# Preserve the known-good working driver: this runner edits only WCL project
# source files and output.log. It never touches the installed/working kext.
cp -p "$CTRL" "$STAGE_DIR/RTW88WCLController.cpp.before"
cp -p "$CTRLH" "$STAGE_DIR/RTW88WCLController.hpp.before"
cp -p "$PCI" "$STAGE_DIR/RTW88WCLPCIBackend.cpp.before"
if [ -f "$OUT" ]; then cp -p "$OUT" "$STAGE_DIR/output.log.before"; fi

python3 - "$CTRL" "$CTRLH" "$PCI" "$STAGE_DIR" <<'PY'
from pathlib import Path
import difflib
import sys

ctrl_path, ctrlh_path, pci_path, stage_dir = map(Path, sys.argv[1:])
ctrl = ctrl_path.read_text()
ctrlh = ctrlh_path.read_text()
pci = pci_path.read_text()
orig = (ctrl, ctrlh, pci)

def brace_end(text: str, opening: int) -> int:
    depth = 0
    state = "normal"
    i = opening
    while i < len(text):
        ch = text[i]
        nxt = text[i+1] if i + 1 < len(text) else ""
        if state == "normal":
            if ch == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if ch == "/" and nxt == "*":
                state = "block"; i += 2; continue
            if ch == '"':
                state = "string"; i += 1; continue
            if ch == "'":
                state = "char"; i += 1; continue
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: return i + 1
        elif state == "line":
            if ch == "\n": state = "normal"
        elif state == "block":
            if ch == "*" and nxt == "/":
                state = "normal"; i += 2; continue
        elif state in ("string", "char"):
            if ch == chr(92): i += 2; continue
            if (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "normal"
        i += 1
    raise SystemExit("ERROR: unmatched C++ brace")

def function_span(text: str, signature: str):
    pos = text.find(signature)
    if pos < 0: raise SystemExit("ERROR: function signature missing: " + signature)
    brace = text.find("{", pos)
    if brace < 0: raise SystemExit("ERROR: function body missing: " + signature)
    return pos, brace, brace_end(text, brace)

def if_block(text: str, condition: str):
    pos = text.find(condition)
    if pos < 0: raise SystemExit("ERROR: expected condition missing: " + condition)
    brace = text.find("{", pos)
    if brace < 0: raise SystemExit("ERROR: if body missing: " + condition)
    return pos, brace, brace_end(text, brace)

def replace_one(old: str, new: str, text: str, label: str):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly one source match, found {n}; no source files changed")
    return text.replace(old, new, 1)

# Controller: convert cleanup from fire-and-forget to a status-returning transaction.
sig = "void RTW88WCLController::releaseNativeResources()"
_, _, end = function_span(ctrl, sig)
start = ctrl.rfind("\n", 0, ctrl.find(sig)) + 1
body = ctrl[start:end]
if body.count("return;") != 4:
    raise SystemExit("ERROR: releaseNativeResources expected four guarded bare returns; source differs")
for required in (
    "const IOReturn packetPathStatus = quiescePacketPath();",
    "const IOReturn recycleStatus = recycleStagedRxPackets();",
    "const IOReturn fenceStatus = _pciBackend->setRadioRunning(false);",
    "const IOReturn closeStatus = _pciBackend->close();",
):
    if body.count(required) != 1:
        raise SystemExit("ERROR: controller cleanup source shape mismatch: " + required)

for condition, variable in (
    ("if (packetPathStatus != kIOReturnSuccess)", "packetPathStatus"),
    ("if (recycleStatus != kIOReturnSuccess)", "recycleStatus"),
    ("if (fenceStatus != kIOReturnSuccess)", "fenceStatus"),
    ("if (closeStatus != kIOReturnSuccess)", "closeStatus"),
):
    p, _, e = if_block(body, condition)
    block = body[p:e]
    if block.count("return;") != 1:
        raise SystemExit("ERROR: expected one bare return in " + condition)
    block = block.replace("return;", "return " + variable + ";", 1)
    body = body[:p] + block + body[e:]

# Move the PCI DMA fence to immediately after the RTW88 producer is stopped
# and BEFORE RX adapter, staged packet, Skywalk queue/pool teardown.
fence_condition = "if (_pciBackend && _pciBackend->isRadioRunning())"
fp, _, fe = if_block(body, fence_condition)
fence_block = body[fp:fe]
body = body[:fp] + body[fe:]
radio_condition = "if (_radio && _radioStarted)"
_, _, radio_end = if_block(body, radio_condition)
body = body[:radio_end] + "\n\n    " + fence_block.strip() + body[radio_end:]

_, _, body_end = function_span(body, sig)
closing = body.rfind("}")
if "return kIOReturnSuccess;" in body:
    raise SystemExit("ERROR: unexpected existing final success return; inspect manually")
body = body[:closing] + "    return kIOReturnSuccess;\n" + body[closing:]
ctrl = ctrl[:start] + body + ctrl[end:]
ctrlh = replace_one("    void releaseNativeResources();",
                    "    IOReturn releaseNativeResources();", ctrlh,
                    "controller header cleanup return type")
ctrl = replace_one("void RTW88WCLController::releaseNativeResources()",
                   "IOReturn RTW88WCLController::releaseNativeResources()",
                   ctrl, "controller cleanup definition return type")

# Controller free retains the object/workloop if cleanup cannot be proven safe.
free_sig = "void RTW88WCLController::free()"
pf, _, pe = function_span(ctrl, free_sig)
new_free = """void RTW88WCLController::free()
{
    const IOReturn cleanupStatus = releaseNativeResources();
    if (cleanupStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: controller shutdown incomplete (0x%08x); quarantining controller and retaining workloop/resources\\n",
              cleanupStatus);
        /* Do not release the workloop or call super::free() while any child,
         * packet pool, or PCI/DMA resource may still reference this controller.
         * This deliberately leaks the object rather than risking a UAF/DMA UAF. */
        return;
    }
    if (_workLoop) {
        _workLoop->release();
        _workLoop = nullptr;
    }
    super::free();
}"""
ctrl = ctrl[:pf] + new_free + ctrl[pe:]

# PCI source uses an unbraced one-line failure conditional. Do not search for
# the next brace (which belongs to the outer running block): match the complete
# two-line statement, then wrap it in an explicit rollback/readback block.
old_enable = (
    "        if ((command & 0x0006U) != 0x0006U)\n"
    "            return kIOReturnNotReady;"
)
new_enable = """        if ((command & 0x0006U) != 0x0006U) {
            _interruptSource->disable();
            _pciDev->setBusMasterEnable(false);
            const UInt16 rollbackCommand = _pciDev->configRead16(kIOPCIConfigCommand);
            if (rollbackCommand & 0x0004U) {
                /* Bus mastering may still be active. Keep the backend marked
                 * running so close/free cannot reclaim DMA mappings. */
                _radioRunning = true;
                IOLog("rtl88wifi-wcl: partial PCI enable rollback failed (command=0x%04x); DMA resources quarantined\\n",
                      rollbackCommand);
            } else {
                _radioRunning = false;
                _pciDev->setMemoryEnable(false);
            }
            return kIOReturnNotReady;
        }"""
pci = replace_one(old_enable, new_enable, pci, "unbraced PCI enable failure statement")

# PCI backend final free verifies the bus-master bit before releasing DMA,
# locks, MMIO and PCI provider state.
pci_free_sig = "void RTW88WCLPCIBackend::free()"
pf, _, pe = function_span(pci, pci_free_sig)
new_pci_free = """void RTW88WCLPCIBackend::free()
{
    if (_pciDev) {
        if (_interruptSource)
            _interruptSource->disable();
        _pciDev->setBusMasterEnable(false);
        const UInt16 command = _pciDev->configRead16(kIOPCIConfigCommand);
        if (command & 0x0004U) {
            IOLog("rtl88wifi-wcl: PCI bus-master bit remains set (command=0x%04x); refusing to free DMA resources; backend quarantined\\n",
                  command);
            /* Keep this object, DMA descriptors, MMIO map, locks, and PCI
             * reference alive until hardware bus mastering is demonstrably off. */
            return;
        }
    }
    _radioRunning = false;
    closeResources();
    super::free();
}"""
pci = pci[:pf] + new_pci_free + pci[pe:]

# Verify all lifecycle invariants before the first source write.
new_sig = "IOReturn RTW88WCLController::releaseNativeResources()"
_, _, new_end = function_span(ctrl, new_sig)
new_start = ctrl.rfind("\n", 0, ctrl.find(new_sig)) + 1
new_body = ctrl[new_start:new_end]
for status in ("packetPathStatus", "recycleStatus", "fenceStatus", "closeStatus"):
    if new_body.count("return " + status + ";") != 1:
        raise SystemExit("ERROR: controller status was not propagated: " + status)
radio_end = if_block(new_body, "if (_radio && _radioStarted)")[2]
fence_pos = new_body.find("if (_pciBackend && _pciBackend->isRadioRunning())")
adapter_pos = new_body.find("if (_rxAdapter)")
queue_pos = new_body.find("if (_skywalkQueues)")
if not (radio_end <= fence_pos < adapter_pos < queue_pos):
    raise SystemExit("ERROR: PCI fence is not ordered after radio stop and before adapter/queue release")
if "return kIOReturnSuccess;" not in new_body:
    raise SystemExit("ERROR: controller cleanup success return missing")
if "cleanupStatus != kIOReturnSuccess" not in ctrl or "quarantining controller" not in ctrl:
    raise SystemExit("ERROR: controller free quarantine guard missing")
if "rollbackCommand & 0x0004U" not in pci:
    raise SystemExit("ERROR: PCI partial-enable rollback guard missing")
pci_free_body = pci[pci.find(pci_free_sig):]
if "command & 0x0004U" not in pci_free_body:
    raise SystemExit("ERROR: PCI final-free bus-master verification missing")
if pci_free_body.find("command & 0x0004U") > pci_free_body.find("closeResources();"):
    raise SystemExit("ERROR: PCI resources could be released before bus-master readback")

# Save only after every source-shape and ordering guard has passed.
ctrl_path.write_text(ctrl)
ctrlh_path.write_text(ctrlh)
pci_path.write_text(pci)

for path, before, after in (
    (ctrl_path, orig[0], ctrl),
    (ctrlh_path, orig[1], ctrlh),
    (pci_path, orig[2], pci),
):
    patch = difflib.unified_diff(
        before.splitlines(True), after.splitlines(True),
        fromfile="a/" + path.name, tofile="b/" + path.name
    )
    (stage_dir / (path.name + ".patch")).write_text("".join(patch))

(stage_dir / "verification.txt").write_text(
    "PASS: releaseNativeResources now returns IOReturn status\n"
    "PASS: quiesce, RX recycle, PCI fence, and backend close failures are propagated\n"
    "PASS: PCI bus-master fence moved after RTW88 radio stop and before RX adapter / Skywalk queue release\n"
    "PASS: controller free quarantines rather than releasing workloop/super when cleanup fails\n"
    "PASS: unbraced PCI enable failure is now explicitly braced and performs bus-master rollback/readback\n"
    "PASS: backend free verifies PCI bus-master bit before closeResources and DMA reclamation\n"
    "LIMIT: compile, kext load, registration and hardware testing not performed\n"
)
print("PATCH_STATUS: APPLIED")
print("FILES_PATCHED: 3")
print("CONTROLLER_SHUTDOWN: STATUS_PROPAGATION_AND_QUARANTINE")
print("PCI_FENCE: VERIFIED_BEFORE_QUEUE_AND_POOL_RELEASE")
print("PCI_PARTIAL_ENABLE: ROLLBACK_AND_READBACK_GUARD")
print("BACKEND_FREE: PCI_BUS_MASTER_READBACK_GUARD")
print("PATCH_DIR: " + str(stage_dir))
PY

# Append this stage to the existing report so earlier diagnostic and audit
# results are not discarded.
TMP_OUT="$OUT.tmp"
{
    if [ -f "$STAGE_DIR/output.log.before" ]; then
        cat "$STAGE_DIR/output.log.before"
        printf "\n\n"
    fi
    echo "RTL88WiFi Stage 25 — corrected shutdown fence and quarantine patch"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "ARCH: $(uname -m)"
    echo "PROJECT: $PROJECT"
    echo "STAGE_DIR: $STAGE_DIR"
    echo
    cat "$STAGE_DIR/verification.txt"
    echo
    for f in RTW88WCLController.cpp.patch RTW88WCLController.hpp.patch RTW88WCLPCIBackend.cpp.patch; do
        echo "========== $f =========="
        cat "$STAGE_DIR/$f"
    done
    echo
    echo "KNOWN_GOOD_DRIVER: existing working rtl88wifi.kext left untouched and remains the fallback"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_STAGE25_COMPILE_AND_REMAINING_ABI_DEPENDENCY_REVIEW"
} > "$TMP_OUT"
mv "$TMP_OUT" "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 25 apply corrected shutdown fence quarantine patch" \
            -f content="$B64" -f sha="$SHA" >/dev/null
        echo "UPLOAD_STATUS: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "UPLOAD_STATUS: GH_AUTH_OK_BUT_OUTPUT_LOG_SHA_NOT_RETRIEVED"
    fi
else
    echo "UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — output.log ready for existing uploader."
fi
echo "REPORT: $OUT"
echo "PATCH_BACKUPS_AND_DIFFS: $STAGE_DIR"
