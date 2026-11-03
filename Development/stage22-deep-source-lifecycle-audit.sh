#!/bin/bash
set -u

REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/output.log"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''

if [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi
if [[ -z "$PROJECT" ]]; then
  echo 'Cannot locate the Stage26 project. Run from its project root or set PROJECT_DIR.'
  exit 2
fi

DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext/wcl24h32"
LOG="$PROJECT/output.log"
STAGE="$PROJECT/build/stage22-deep-source-lifecycle-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE" || exit 2
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }
[[ -d "$SRC" ]] || { echo "Native WCL source directory missing: $SRC"; exit 2; }

gh api "$API" > "$STAGE/remote-log.json" || exit 2
python3 - "$STAGE/remote-log.json" "$LOG" <<'PY'
import base64, json, pathlib, sys
doc=json.loads(pathlib.Path(sys.argv[1]).read_text())
data=base64.b64decode(doc.get("content",""))
old=data.decode("utf-8",errors="replace")
required=["STAGE21_STATUS: REVIEW_REQUIRED","NATIVE_ACTUAL_BUILD: PASS","STAGE29G_PREFLIGHT: COMPLETE"]
missing=[x for x in required if x not in old]
if missing:
    raise SystemExit("Canonical output.log missing prerequisites: "+", ".join(missing))
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || { echo 'Canonical output.log prerequisite validation failed.'; exit 2; }

python3 - "$PROJECT" "$SRC" "$STAGE" <<'PY'
from pathlib import Path
import hashlib, re, sys

project, src, stage = map(Path, sys.argv[1:])
report = [
 "RTL88WiFi Stage22 — deep source lifecycle and ownership audit",
 "PURPOSE: collect exact Stage26 source contexts for manual correlation with the saved Sequoia 24H32 ABI dossier",
 "SOURCE_CHANGES: NONE", "BUILD: NOT RUN", "INSTALL: NOT RUN", "LOAD: NOT RUN",
 "OPENCORE_CHANGE: NONE", "QUEUE_REGISTRATION: NOT CALLED", "QUEUE_ENABLE: NOT CALLED",
 "RADIO_START: NOT RUN", "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED", ""
]
files=sorted(p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in {".cpp",".hpp",".h",".c"})
report.append("=== SOURCE INVENTORY / SHA-256 ===")
report.append("SOURCE_FILE_COUNT: "+str(len(files)))
for p in files:
    report.append("SOURCE: {} SHA256={}".format(p.relative_to(project),hashlib.sha256(p.read_bytes()).hexdigest()))

# Match exact implementation names and related callback/ownership primitives.
patterns = [
 ("CONTROLLER_START_STOP", r"RTW88WCLController::(start|stop)\s*\("),
 ("INFRA_START_STOP", r"RTW88WCLInfraInterface::(start|stop)\s*\("),
 ("REGISTRATION", r"(registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterEthernetInterface|deregisterNetworkInterface|deregisterInterfaceWithQueues|initRegistrationInfo)"),
 ("RX_PATH", r"(refillRxRing|requestDequeue|enqueuePackets|completePreparedPacket|RX.*(Callback|callback)|rx.*(callback|Callback))"),
 ("TX_PATH", r"(requestEnqueue|completePackets|TX.*(Callback|callback)|tx.*(callback|Callback)|finishTicket|ticket)"),
 ("PACKET_POOL_DMA", r"(prepare.*(Packet|Segment|Memory)|complete.*(Packet|Segment|Memory)|prepareWithDirection|completeWithDirection|IOMemoryDescriptor|IODMA|DMAMap|dmaMap|dmaUnmap)"),
 ("QUEUE_TEARDOWN", r"(disable\s*\(|synchronize\s*\(|finalize\s*\(|quiesce|shutdown|stop\s*\(|drain|cancel)"),
 ("OWNERSHIP_REFERENCES", r"(retain\s*\(|release\s*\(|OSRetain|OSRelease|retainCount|reference|refCount|packetTable|packetPool|sourceQueue)")
]
MAX_HITS=32
CONTEXT=12
for label, pattern in patterns:
    rx=re.compile(pattern,re.I)
    hits=[]
    for p in files:
        try: lines=p.read_text(errors="replace").splitlines()
        except Exception: continue
        for i,line in enumerate(lines):
            stripped=line.strip()
            if not stripped or stripped.startswith("//") or stripped.startswith("*"):
                continue
            if rx.search(line):
                hits.append((p,i,lines))
    report.extend(["", "=== "+label+" ===", "MATCH_COUNT: "+str(len(hits))])
    if not hits:
        report.append("No direct textual matches. This does not prove the path is absent; inspect indirect/vtable/macro call paths.")
        continue
    # Deduplicate overlapping hits in same file, while preserving representative exact contexts.
    selected=[]
    seen=set()
    for p,i,lines in hits:
        key=(str(p), i//max(1,CONTEXT))
        if key in seen: continue
        seen.add(key); selected.append((p,i,lines))
        if len(selected)>=MAX_HITS: break
    for p,i,lines in selected:
        lo=max(0,i-CONTEXT); hi=min(len(lines),i+CONTEXT+1)
        report.append("CONTEXT: {}:{}-{}".format(p.relative_to(project),lo+1,hi))
        report.extend("  {:05d}: {}".format(n+1,lines[n]) for n in range(lo,hi))
    if len(hits)>len(selected):
        report.append("CONTEXTS_OMITTED_BY_CAP: "+str(len(hits)-len(selected)))

report.extend([
 "", "=== REVIEW QUESTIONS / DO NOT INFER ===",
 "1. For every RX callback, identify the exact packet owner before callback, during callback, after consumed-count return, and on partial/error return.",
 "2. For every TX ticket, trace allocation, packet retain, DMA submit, completion callback, cancellation, timeout, stop and every release exactly once.",
 "3. Pair every memory/segment prepare with its matching complete/unmap on success, partial failure, reset and stop.",
 "4. Establish RegistrationInfo field layout, queue array ordering/count, pool roles, successful-registration ownership and every rollback path.",
 "5. Establish global stop ordering across callback quiescence, queue disable, synchronize, finalize, deregistration and pool destruction.",
 "6. Distinguish direct calls from declarations, dead code, conditional code, vtable dispatch and callback registration.",
 "", "STAGE22_STATUS: REVIEW_REQUIRED — excerpts are evidence collection, not proof that all ownership contracts are closed.",
 "ACTIVATION_GATE: BLOCKED — do not register/enable queues, hand off packets, publish BSD interface, start radio, install/load or alter OpenCore."
])
out=stage/"stage22-deep-source-lifecycle-report.txt"
out.write_text("\n".join(report)+"\n",encoding="utf-8")
print("STAGE22_REPORT_PATH: "+str(out))
print("\n".join(report[:55]))
print("REPORT_TOTAL_LINES: "+str(len(report)))
PY
RC=$?

{
 echo
 echo '========== STAGE22 DEEP SOURCE LIFECYCLE / OWNERSHIP AUDIT =========='
 echo "STAGE_DIR: $STAGE"
 cat "$STAGE/stage22-deep-source-lifecycle-report.txt" 2>/dev/null || true
 echo "STAGE22_ANALYSIS_EXIT: $RC"
 echo 'SOURCE_CHANGES: NONE'
 echo 'BUILD: NOT RUN'
 echo 'INSTALL: NOT RUN'
 echo 'LOAD: NOT RUN'
 echo 'OPENCORE_CHANGE: NONE'
 echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'
} >> "$LOG"

SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$LOG" "$SHA" "$STAGE/payload.json" <<'PY'
import base64,json,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({"message":"Stage22 deep source lifecycle and ownership audit","content":base64.b64encode(data).decode(),"sha":sys.argv[2]}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT" && "$PUT" == "$READ" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }
echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
