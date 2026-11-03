#!/bin/bash
set -euo pipefail

REPO='shammu2bd/Realtek-WiFi-Native-macOS'
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''
if [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project; run from project root or set PROJECT_DIR.'; exit 2; }
SRC="$PROJECT/driver/RTL88WiFi/src/kext/wcl24h32"
[[ -d "$SRC" ]] || { echo "Missing native WCL source: $SRC"; exit 2; }
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }

STAGE="$PROJECT/build/stage23-targeted-datapath-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage23-targeted-datapath-audit.txt"

python3 - "$PROJECT" "$SRC" "$REPORT" <<'PY'
from pathlib import Path
import hashlib, re, sys

project, src, out = map(Path, sys.argv[1:])
allfiles=sorted(p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in {".cpp",".hpp",".h",".c"})
targets=[
 "RTW88WCLSkywalkRxAdapter.cpp","RTW88WCLSkywalkRxAdapter.hpp",
 "RTW88WCLSkywalkTxAdapter.cpp","RTW88WCLSkywalkTxAdapter.hpp",
 "RTW88WCLSkywalkQueues.cpp","RTW88WCLSkywalkQueues.hpp",
 "RTW88WCLController.cpp","RTW88WCLController.hpp",
 "RTW88WCLInfraInterface.cpp","RTW88WCLInfraInterface.hpp",
 "RTW88WCLTxCompletionSlots.hpp","RTW88WCLRegistrationInfo.hpp",
 "RTW88WCLPacketView.hpp","RTW88WCLPacketSpanValidation.hpp",
 "RTW88WCLPCIBackend.cpp","RTW88WCLPCIBackend.hpp"
]
report=[
 "RTL88WiFi Stage23 — targeted RX/TX datapath, DMA and teardown audit",
 "PURPOSE: replace Stage22's overly narrow RX regex with exact adapter/queue/controller source capture and broad ownership callsite indexing.",
 "SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN",
 "OPENCORE_CHANGE: NONE","QUEUE_REGISTRATION: NOT CALLED","QUEUE_ENABLE: NOT CALLED",
 "RADIO_START: NOT RUN","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",""
]
report += ["=== SOURCE INVENTORY / SHA-256 ===","SOURCE_FILE_COUNT: "+str(len(allfiles))]
for p in allfiles:
 report.append("SOURCE: {} SHA256={}".format(p.relative_to(project),hashlib.sha256(p.read_bytes()).hexdigest()))

report += ["","=== COMPLETE TARGET FILES (line numbered; source not modified) ==="]
found=set()
for name in targets:
 matches=[p for p in allfiles if p.name==name]
 if not matches:
  report += ["","--- MISSING TARGET: "+name+" ---"]
  continue
 for p in matches:
  found.add(p)
  lines=p.read_text(errors="replace").splitlines()
  report += ["","--- FILE: {} | LINES: {} | SHA256: {} ---".format(p.relative_to(project),len(lines),hashlib.sha256(p.read_bytes()).hexdigest())]
  report += ["{:05d}: {}".format(i+1,line) for i,line in enumerate(lines)]

# Broad cross-file index catches callback registration, aliases, indirect dispatch,
# and ownership primitives missed by a narrow function-name regex.
patterns=[
 ("RX_AND_QUEUE_CALLBACKS",r"rx|receive|refill|dequeue|enqueuePackets|stagedRxFrame|allocateInputPacket|injectRxFrame|completePreparedPacket|recycle"),
 ("TX_AND_TICKETS",r"tx|transmit|outputPacketWithCompletion|backendCompletion|TicketPool|reserve\(|complete|cancel|outstanding"),
 ("DMA_AND_MEMORY_LIFETIME",r"prepareWithDirection|completeWithDirection|prepare\(|complete\(|IODMA|IOMemoryDescriptor|dma|mapMemory|unmap|memoryDescriptor"),
 ("QUEUE_LIFECYCLE",r"register.*Queue|register.*Interface|deregister|disable|synchronize|finalize|quiesce|drain|shutdown|stop\("),
 ("OWNERSHIP_PRIMITIVES",r"retain\(|release\(|push\(|pop\(|consume|recycle|disposeAllPackets|set.*Owner|owner")
]
for label,pattern in patterns:
 rx=re.compile(pattern,re.I)
 report += ["","=== CROSS-FILE INDEX: "+label+" ==="]
 total=0
 for p in allfiles:
  lines=p.read_text(errors="replace").splitlines()
  hits=[(i,line) for i,line in enumerate(lines) if rx.search(line) and not line.lstrip().startswith(("//","*"))]
  if not hits: continue
  total += len(hits)
  report.append("FILE: {} MATCHES: {}".format(p.relative_to(project),len(hits)))
  for i,line in hits:
   report.append("  {:05d}: {}".format(i+1,line.strip()[:260]))
 report.append("TOTAL_MATCHES: "+str(total))

report += [
 "","=== REQUIRED MANUAL TRACE / NO INFERENCE ===",
 "A. RX: identify allocation owner; prepare/map; callback argument shape; consumed-count semantics; partial return; enqueue success/failure; completion; recycle/dispose; every error branch.",
 "B. TX: identify packet retain and ticket reservation; backend ownership of mbuf; exactly-once callback evidence; queue completion acceptance; cancellation/reset/stop; every ticket and adapter release.",
 "C. DMA: pair every prepare/map with complete/unmap; establish whether descriptor/buffer lifetime spans device DMA and completion; cover partial failure and reset.",
 "D. Registration: prove queue array order/count, queue roles, pool roles, ownership transfer on success, and rollback for every failed registration step.",
 "E. Teardown: prove callback source is stopped/quiesced before queue disable/synchronize/finalize/deregister and pool destruction; account for in-flight workloop tasks.",
 "F. ABI: separate declarations from implementations and direct calls from vtable/callback dispatch; compare each callsite with saved Sequoia 24H32 ABI evidence.",
 "","STAGE23_STATUS: REVIEW_REQUIRED — complete source capture and callsite index are evidence, not proof of ownership safety.",
 "ACTIVATION_GATE: BLOCKED — no queue registration/enable, packet ownership handoff, BSD publication, radio start, build/install/load or OpenCore changes."
]
out.write_text("\n".join(report)+"\n",encoding="utf-8")
print("STAGE23_REPORT: "+str(out))
print("SOURCE_FILES: "+str(len(allfiles)))
print("TARGET_FILES_CAPTURED: "+str(len(found))+"/"+str(len(targets)))
print("REPORT_BYTES: "+str(out.stat().st_size))
PY

[[ -s "$REPORT" ]] || { echo 'Stage23 report was not generated.'; exit 2; }
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Report exceeds safe upload limit: $BYTES bytes"; exit 2; }

upload_file() {
  local path="$1" api="$2" message="$3" payload="$4" response="$5"
  local oldsha
  oldsha="$(gh api "$api" --jq '.sha' 2>/dev/null || true)"
  python3 - "$path" "$oldsha" "$message" "$payload" <<'PY'
import base64,json,pathlib,sys
path,sha,message,payload=sys.argv[1:]
doc={"message":message,"content":base64.b64encode(pathlib.Path(path).read_bytes()).decode()}
if sha: doc["sha"]=sha
pathlib.Path(payload).write_text(json.dumps(doc))
PY
  gh api --method PUT "$api" --input "$payload" > "$response"
  local putsha readsha
  putsha="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
  readsha="$(gh api "$api" --jq '.sha')"
  [[ -n "$putsha" && "$putsha" == "$readsha" ]] || { echo "Read-back SHA mismatch for $api"; return 1; }
  echo "$readsha"
}

REPORT_SHA="$(upload_file "$REPORT" "repos/$REPO/contents/Development/stage23-targeted-datapath-audit.txt" "Add Stage23 targeted datapath audit report" "$STAGE/report-payload.json" "$STAGE/report-response.json")"
echo "STAGE23_REPORT_UPLOAD: SUCCESS"
echo "GITHUB_REPORT: Development/stage23-targeted-datapath-audit.txt"
echo "GITHUB_REPORT_BLOB_SHA: $REPORT_SHA"

# Append only a concise, auditable pointer to the canonical log.
LOG="$PROJECT/output.log"
API="repos/$REPO/contents/Development/output.log"
gh api "$API" > "$STAGE/remote-log.json"
python3 - "$STAGE/remote-log.json" "$LOG" "$REPORT_SHA" "$BYTES" <<'PY'
import base64,json,pathlib,sys
doc=json.loads(pathlib.Path(sys.argv[1]).read_text())
data=base64.b64decode(doc.get("content",""))
old=data.decode("utf-8",errors="replace")
entry=(
 "\n========== STAGE23 TARGETED DATAPATH AUDIT ==========\n"
 "STAGE23_REPORT: Development/stage23-targeted-datapath-audit.txt\n"
 "STAGE23_REPORT_BLOB_SHA: "+sys.argv[3]+"\n"
 "STAGE23_REPORT_BYTES: "+sys.argv[4]+"\n"
 "STAGE23_STATUS: REVIEW_REQUIRED\n"
 "ACTIVATION_GATE: BLOCKED\n"
 "SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\n"
 "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
)
pathlib.Path(sys.argv[2]).write_text(old+entry,encoding="utf-8")
PY
LOG_SHA="$(upload_file "$LOG" "$API" "Record Stage23 targeted datapath audit" "$STAGE/log-payload.json" "$STAGE/log-response.json")"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "CANONICAL_OUTPUT_LOG_BLOB_SHA: $LOG_SHA"
echo "STAGE23_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
