#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE24_ERROR: exit=$rc line=$LINENO command=$BASH_COMMAND" >&2; exit "$rc"' ERR
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
[[ -n "$PROJECT" ]] || { echo 'Cannot locate Stage26 project.'; exit 2; }
DRIVER="$PROJECT/driver/RTL88WiFi"
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }
STAGE="$PROJECT/build/stage24-rtw88-callback-dma-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage24-rtw88-callback-dma-audit.txt"

python3 - "$PROJECT" "$DRIVER" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project,driver,out=map(Path,sys.argv[1:])
all_files=sorted(p for p in driver.rglob("*") if p.is_file() and p.suffix.lower() in {".cpp",".hpp",".h",".c",".cc"})
key=re.compile(r"rtw88|rtl88|wcl|skywalk|pci|dma|txcompletion|rxadapter",re.I)
files=[p for p in all_files if key.search(str(p.relative_to(driver)))][:120]
patterns=[
 ("OUTPUT_PACKET_WITH_COMPLETION",r"outputPacketWithCompletion|backendCompletion|CompletionCallback|completionCallback"),
 ("TX_SUBMIT_AND_COMPLETION",r"submitPacket|drainCompletions|claimCompleted|TicketPool::|finishTicket|transmitted"),
 ("DMA_ALLOC_FREE_MAP",r"allocCoherent|freeCoherent|dma_map|dma_unmap|map.*DMA|unmap.*DMA|freeDMAList|releaseDMAEntries"),
 ("RADIO_STOP_AND_QUIESCE",r"RTW88IEEE80211::stop|cancel_work|flush_work|synchronize.*(irq|interrupt)|disable.*interrupt|bus.master|BusMaster|stopDMA|stopTx|stopRx"),
 ("SKYWALK_QUEUE_HANDOFF",r"enqueuePackets|dequeuePackets|completePackets|requestDequeue|requestEnqueue|rxCompletionAction|txCompletionAction|rxSubmissionAction|txSubmissionAction"),
]
report=[
 "RTL88WiFi Stage24 — RTW88 callback, DMA and teardown contract audit",
 "PURPOSE: targeted driver-owned source review, including RTW88 core callback implementations and PCI/DMA lifecycle.",
 "SCOPE: all driver source files counted; detailed contexts restricted to RTW88/RTL88/WCL/Skywalk/PCI/DMA-related paths.",
 "SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN",
 "OPENCORE_CHANGE: NONE","QUEUE_REGISTRATION: NOT CALLED","QUEUE_ENABLE: NOT CALLED",
 "RADIO_START: NOT RUN","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",""
]
report += ["=== SOURCE INVENTORY ===","TOTAL_DRIVER_SOURCE_FILES: "+str(len(all_files)),
 "TARGETED_SOURCE_FILES: "+str(len(files))]
for p in files:
 report.append("SOURCE: {} SHA256={}".format(p.relative_to(project),hashlib.sha256(p.read_bytes()).hexdigest()))
for label,pattern in patterns:
 rx=re.compile(pattern,re.I)
 report += ["","=== "+label+" ==="]
 hits=0
 for p in files:
  lines=p.read_text(errors="replace").splitlines()
  found=[i for i,line in enumerate(lines) if rx.search(line) and not line.lstrip().startswith(("//","*"))]
  if not found: continue
  report.append("FILE: {} MATCHES: {}".format(p.relative_to(project),len(found)))
  selected=found[:5]
  for i in selected:
   lo=max(0,i-4); hi=min(len(lines),i+5)
   report.append("CONTEXT: {}:{}-{}".format(p.relative_to(project),lo+1,hi))
   report.extend("  {:05d}: {}".format(n+1,lines[n]) for n in range(lo,hi))
   hits += 1
  if len(found)>len(selected):
   report.append("OMITTED_MATCHES_IN_FILE: "+str(len(found)-len(selected)))
 report.append("DISPLAYED_CONTEXTS: "+str(hits))
report += [
 "","=== REQUIRED CONTRACT QUESTIONS ===",
 "1. Locate exact outputPacketWithCompletion implementation and prove mbuf ownership for every return path.",
 "2. Prove synchronous/asynchronous callback timing, exactly-once behavior, and cancellation/reset/stop completion.",
 "3. Prove ticket publication ordering and prevent completion racing initialization or ticket reuse.",
 "4. Trace all RTW88 TX completion producers and supplied callback invocations, including errors and teardown.",
 "5. Trace coherent DMA allocation/free and descriptor prepare/complete pairing through reset, failed start and stop.",
 "6. Prove stop synchronizes workqueues, interrupt callbacks and DMA before bus-master disable/resource release.",
 "7. Match Skywalk queue callback return-count semantics and packet ownership transfer to the 24H32 ABI.",
 "","STAGE24_STATUS: REVIEW_REQUIRED — targeted contexts require call-graph and branch analysis.",
 "ACTIVATION_GATE: BLOCKED — no queue registration/enable, packet handoff, BSD publication, radio start, build/install/load or OpenCore changes."
]
out.write_text("\n".join(report)+"\n",encoding="utf-8")
print("STAGE24_REPORT_PATH: "+str(out))
print("DRIVER_SOURCE_FILES: "+str(len(all_files)))
print("TARGETED_SOURCE_FILES: "+str(len(files)))
print("REPORT_BYTES: "+str(out.stat().st_size))
PY

[[ -s "$REPORT" ]] || { echo 'Stage24 report missing.'; exit 2; }
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Targeted report exceeds 900KB upload cap: $BYTES"; exit 2; }

upload_file() {
 local path="$1" api="$2" message="$3" payload="$4" response="$5"
 local oldsha putsha readsha
 echo "GITHUB_UPLOAD_BEGIN: $api"
 oldsha="$(gh api "$api" --jq '.sha' 2>/dev/null || true)"
 python3 - "$path" "$oldsha" "$message" "$payload" <<'PY'
import base64,json,pathlib,sys
path,sha,message,payload=sys.argv[1:]
d={"message":message,"content":base64.b64encode(pathlib.Path(path).read_bytes()).decode()}
if sha: d["sha"]=sha
pathlib.Path(payload).write_text(json.dumps(d))
print("UPLOAD_PAYLOAD_BYTES:",pathlib.Path(payload).stat().st_size)
PY
 if ! gh api --method PUT "$api" --input "$payload" > "$response"; then
   echo "GITHUB_UPLOAD_FAILED: PUT $api" >&2
   cat "$response" >&2 2>/dev/null || true
   return 1
 fi
 putsha="$(python3 - "$response" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("content",{}).get("sha",""))
PY
)"
 if [[ -z "$putsha" ]]; then
   echo "GITHUB_UPLOAD_FAILED: GitHub response contains no content SHA" >&2
   cat "$response" >&2
   return 1
 fi
 readsha="$(gh api "$api" --jq '.sha')"
 if [[ "$putsha" != "$readsha" ]]; then
   echo "GITHUB_UPLOAD_FAILED: read-back SHA mismatch put=$putsha read=$readsha" >&2
   return 1
 fi
 echo "GITHUB_UPLOAD_VERIFIED: $api $readsha"
 UPLOAD_RESULT_SHA="$readsha"
}
upload_file "$REPORT" "repos/$REPO/contents/Development/stage24-rtw88-callback-dma-audit.txt" "Add Stage24 RTW88 callback and DMA audit" "$STAGE/report-payload.json" "$STAGE/report-response.json"
SHA="$UPLOAD_RESULT_SHA"
echo "STAGE24_REPORT_UPLOAD: SUCCESS"
echo "GITHUB_REPORT: Development/stage24-rtw88-callback-dma-audit.txt"
echo "GITHUB_REPORT_BLOB_SHA: $SHA"

LOG="$PROJECT/output.log"
API="repos/$REPO/contents/Development/output.log"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/remote-output.log"
python3 - "$STAGE/remote-output.log" "$LOG" "$SHA" "$BYTES" <<'PY'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8",errors="replace")
marker="========== STAGE24 RTW88 CALLBACK / DMA AUDIT =========="
if marker in old:
 old=old[:old.index(marker)].rstrip()+"\n"
entry=("\n"+marker+"\n"
 "STAGE24_REPORT: Development/stage24-rtw88-callback-dma-audit.txt\n"
 "STAGE24_REPORT_BLOB_SHA: "+sys.argv[3]+"\n"
 "STAGE24_REPORT_BYTES: "+sys.argv[4]+"\n"
 "STAGE24_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\n"
 "SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\n"
 "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n")
pathlib.Path(sys.argv[2]).write_text(old+entry,encoding="utf-8")
PY
upload_file "$LOG" "$API" "Record Stage24 RTW88 callback and DMA audit" "$STAGE/log-payload.json" "$STAGE/log-response.json"
LOGSHA="$UPLOAD_RESULT_SHA"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "CANONICAL_OUTPUT_LOG_BLOB_SHA: $LOGSHA"
echo "STAGE24_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
