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
STAGE_DIR="$PROJECT/build/stage25-shutdown-fence-guard-$STAMP"
mkdir -p "$STAGE_DIR"

for f in "$CTRL" "$CTRLH" "$PCI"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required source missing: $f" >&2
        exit 2
    fi
done

cp -p "$CTRL" "$STAGE_DIR/RTW88WCLController.cpp.before"
cp -p "$CTRLH" "$STAGE_DIR/RTW88WCLController.hpp.before"
cp -p "$PCI" "$STAGE_DIR/RTW88WCLPCIBackend.cpp.before"

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
            if ch == "\\":
                i += 2; continue
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
        raise SystemExit(f"ERROR: {label}: expected exactly one source match, found {n}; no files changed")
    return text.replace(old, new, 1)

# Controller: convert cleanup from fire-and-forget to a status-returning transaction.
sig = "void RTW88WCLController::releaseNativeResources()"
_, _, end = function_span(ctrl, sig)
start = ctrl.rfind("\n", 0, ctrl.find(sig)) + 1
body = ctrl[start:end]
if body.count("return;") != 4:
    raise SystemExit("ERROR: releaseNativeResources expected four guarded bare returns; source differs")
if body.count("const IOReturn packetPathStatus = quiescePacketPath();") != 1:
    raise SystemExit("ERROR: packet-path quiesce shape mismatch")
if body.count("const IOReturn recycleStatus = recycleStagedRxPackets();") != 1:
    raise SystemExit("ERROR: staged RX recycle shape mismatch")
if body.count("const IOReturn fenceStatus = _pciBackend->setRadioRunning(false);") != 1:
    raise SystemExit("ERROR: PCI fence call missing or duplicated")
if body.count("const IOReturn closeStatus = _pciBackend->close();") != 1:
    raise SystemExit("ERROR: backend close shape mismatch")

# Convert the guarded returns to typed status returns.
for condition, variable in (
    ("if (packetPathStatus != kIOReturnSuccess)", "packetPathStatus"),
    ("if (recycleStatus != kIOReturnSuccess)", "recycleStatus"),
    ("if (fenceStatus != kIOReturnSuccess)", "fenceStatus"),
    ("if (closeStatus != kIOReturnSuccess)", "closeStatus"),
):
    p, b, e = if_block(body, condition)
    block = body[p:e]
    if block.count("return;") != 1:
        raise SystemExit("ERROR: expected one bare return in " + condition)
    block = block.replace("return;", "return " + variable + ";", 1)
    body = body[:p] + block + body[e:]

# Move the PCI bus-master fence directly after the RTW88 producer is stopped,
# and before RX workloop/packet-pool/queue release.
fence_condition = "if (_pciBackend && _pciBackend->isRadioRunning())"
fp, fb, fe = if_block(body, fence_condition)
fence_block = body[fp:fe]
body = body[:fp] + body[fe:]
radio_condition = "if (_radio && _radioStarted)"
rp, rb, re = if_block(body, radio_condition)
insert_at = re
body = body[:insert_at] + "\n\n    " + fence_block.strip() + body[insert_at:]

# Function now reports success only after every native resource phase is complete.
_, body_brace, body_end = function_span(body, sig)
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

# Controller free must retain its workloop and object if cleanup cannot complete.
free_sig = "void RTW88WCLController::free()"
fp, fb, fe = function_span(ctrl, free_sig)
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
ctrl = ctrl[:fp] + new_free + ctrl[fe:]

# PCI backend: a failed initial bus-master enable must be rolled back and its
# actual hardware state retained in _radioRunning if the rollback does not stick.
enable_cond = "if ((command & 0x0006U) != 0x0006U)"
ep, eb, ee = if_block(pci, enable_cond)
enable_block = pci[ep:ee]
if enable_block.count("return kIOReturnNotReady;") != 1:
    raise SystemExit("ERROR: PCI enable failure block shape mismatch")
new_enable_block = """if ((command & 0x0006U) != 0x0006U) {
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
pci = pci[:ep] + new_enable_block + pci[ee:]

# PCI backend final free must verify the actual bus-master bit before it tears
# down DMA descriptors, locks, the MMIO map, or the PCI provider reference.
pci_free_sig = "void RTW88WCLPCIBackend::free()"
pf, pb, pe = function_span(pci, pci_free_sig)
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

# Validate key sequencing and safety invariants after transformation.
_, _, new_end = function_span(ctrl, "IOReturn RTW88WCLController::releaseNativeResources()")
new_start = ctrl.rfind("\n", 0, ctrl.find("IOReturn RTW88WCLController::releaseNativeResources()")) + 1
new_body = ctrl[new_start:new_end]
if new_body.count("return packetPathStatus;") != 1 or new_body.count("return recycleStatus;") != 1:
    raise SystemExit("ERROR: controller cleanup statuses were not propagated")
if new_body.count("return fenceStatus;") != 1 or new_body.count("return closeStatus;") != 1:
    raise SystemExit("ERROR: controller fence/close statuses were not propagated")
radio_end = if_block(new_body, "if (_radio && _radioStarted)")[2]
fence_pos = new_body.find("if (_pciBackend && _pciBackend->isRadioRunning())")
adapter_pos = new_body.find("if (_rxAdapter)")
queue_pos = new_body.find("if (_skywalkQueues)")
if not (radio_end <= fence_pos < adapter_pos < queue_pos):
    raise SystemExit("ERROR: PCI fence is not ordered after radio stop and before adapter/queue release")
if "return kIOReturnSuccess;" not in new_body:
    raise SystemExit("ERROR: controller cleanup success return missing")
if "cleanupStatus != kIOReturnSuccess" not in ctrl[ctrl.find(pci_free_sig):] and "cleanupStatus != kIOReturnSuccess" not in ctrl:
    raise SystemExit("ERROR: controller free cleanup guard missing")
if "quarantining controller" not in ctrl:
    raise SystemExit("ERROR: controller quarantine marker missing")
if "rollbackCommand & 0x0004U" not in pci:
    raise SystemExit("ERROR: PCI partial-enable rollback guard missing")
if "command & 0x0004U" not in pci[pci.find(pci_free_sig):]:
    raise SystemExit("ERROR: PCI final-free bus-master verification missing")

# Save patched sources only after every guard passed.
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
    "PASS: failed initial PCI enable attempts bus-master rollback and preserves running/quarantine state if bit remains set\n"
    "PASS: backend free verifies PCI bus-master bit before closeResources and DMA reclamation\n"
    "LIMIT: compile, kext load, registration and hardware testing not performed\n"
)
print("PATCH_STATUS: APPLIED")
print("FILES_PATCHED: 3")
print("CONTROLLER_SHUTDOWN: STATUS_PROPAGATION_AND_QUARANTINE")
print("PCI_FENCE: VERIFIED_BEFORE_QUEUE_AND_POOL_RELEASE")
print("BACKEND_FREE: PCI_BUS_MASTER_READBACK_GUARD")
print("PATCH_DIR: " + str(stage_dir))
PY

{
    echo "RTL88WiFi Stage 25 — shutdown fence and resource quarantine patch"
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
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_COMPILE_AND_FOLLOWUP_REVIEW"
} > "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    SHA="$(gh api "repos/$REPO/contents/Development/output.log" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$SHA" ]; then
        gh api --method PUT "repos/$REPO/contents/Development/output.log" \
            -f message="Stage 25 apply shutdown fence quarantine patch" \
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
