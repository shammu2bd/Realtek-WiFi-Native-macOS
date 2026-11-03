#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE25_ERROR: exit=$rc line=$LINENO command=$BASH_COMMAND" >&2; exit "$rc"' ERR
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
STAGE="$PROJECT/build/stage25-source-complete-tx-dma-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage25-source-complete-tx-dma-audit.txt"
python3 - "$PROJECT" "$DRIVER" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project,driver,out=map(Path,sys.argv[1:])
exts={".c",".cc",".cpp",".cxx",".h",".hh",".hpp",".hxx"}
all_code=sorted(p for p in driver.rglob("*") if p.is_file() and p.suffix.lower() in exts)
sdk=("MacKernelSDK/Headers/","MacKernelSDK/PrivateHeaders/")
impl=[p for p in all_code if not any(x in p.relative_to(driver).as_posix() for x in sdk)]
groups=[
("EXACT_OUTPUT_PACKET_WITH_COMPLETION",r"\boutputPacketWithCompletion\b"),
("TX_CALLBACK_AND_TICKET_LIFECYCLE",r"CompletionCallback|completionCallback|backendCompletion|finishTicket|claimCompleted|TicketPool|submitPacket|transmitPacket|outputPacket|txCompletion|tx_complete|tx_done|tx_status|tx.*callback|callback.*tx"),
("TX_COMPLETION_PRODUCERS_AND_FAILURES",r"complete.*packet|packet.*complete|tx.*(error|drop|fail|timeout|reset|stop)|(?:error|drop|fail|timeout|reset|stop).*tx|free.*skb|dev_kfree_skb|consume_skb|ieee80211_free_txskb|ieee80211_tx_status"),
("DMA_ALLOC_MAP_SYNC",r"dma_(alloc|free|map|unmap|sync|mapping)|allocCoherent|freeCoherent|prepare.*(DMA|Packet)|complete.*(DMA|Packet)|IODMACommand|IODMAEventSource|dma_addr_t"),
("DMA_DESCRIPTOR_LIFETIME",r"desc.*(alloc|free|map|unmap|prepare|complete)|ring.*(alloc|free|reset|release)|buffer.*(alloc|free|map|unmap)|coherent|bus.?addr|physical.?addr"),
("STOP_RESET_QUIESCE",r"cancel_work_sync|flush_workqueue|flush_work|cancel_work|synchronize_irq|free_irq|disable_irq|stop\(|shutdown\(|reset\(|remove\(|release.*(dma|ring|queue)|quiesc|bus.?master|BusMaster"),
("SKYWALK_TX_HANDOFF",r"txSubmissionAction|txCompletionAction|enqueuePackets|dequeuePackets|completePackets|requestDequeue|requestEnqueue|packetCompletion|_kern_packet_tx_completion|IOSkywalkTx")]
report=[
"RTL88WiFi Stage25 — source-complete TX callback, DMA and teardown audit",
"PURPOSE: identify exact RTW88 callback implementation and every driver-owned call/producer across the full source tree.",
"SCOPE: every C/C++ source/header file under driver/RTL88WiFi; no first-N-file cutoff.",
"SDK_HEADERS: counted but excluded from implementation matching to prevent SDK declarations dominating results.",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN","OPENCORE_CHANGE: NONE",
"QUEUE_REGISTRATION: NOT CALLED","QUEUE_ENABLE: NOT CALLED","RADIO_START: NOT RUN","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED","",
"=== INVENTORY ===","ALL_CODE_FILES: "+str(len(all_code)),
"SDK_HEADER_FILES_EXCLUDED_FROM_IMPLEMENTATION_SCAN: "+str(len(all_code)-len(impl)),
"IMPLEMENTATION_AND_PROJECT_HEADER_FILES_SCANNED: "+str(len(impl)),""]
for p in impl:
 report.append("SCANNED: {} SHA256={}".format(p.relative_to(project),hashlib.sha256(p.read_bytes()).hexdigest()))
for label,pat in groups:
 rx=re.compile(pat,re.I); report += ["","=== "+label+" ==="]; total=0
 for p in impl:
  src=p.read_text(encoding="utf-8",errors="replace").splitlines()
  hits=[i for i,s in enumerate(src) if rx.search(s) and not s.lstrip().startswith(("//","*","/*"))]
  if not hits: continue
  total+=len(hits); report.append("FILE: {} MATCHES: {}".format(p.relative_to(project),len(hits)))
  spans=[]
  for i in hits:
   a=max(0,i-7); b=min(len(src),i+9)
   if spans and a<=spans[-1][1]: spans[-1]=(spans[-1][0],max(spans[-1][1],b))
   else: spans.append((a,b))
  for a,b in spans:
   report.append("CONTEXT: {}:{}-{}".format(p.relative_to(project),a+1,b))
   report.extend("  {:05d}: {}".format(j+1,src[j]) for j in range(a,b))
 report.append("TOTAL_MATCHING_LINES: "+str(total))
report += ["","=== STAGE25 REVIEW GATES ===",
"1. Identify exactly one outputPacketWithCompletion definition (or report all definitions); follow every return branch and ownership transfer.",
"2. Enumerate every call site and callback invocation, including synchronous failure, asynchronous completion, cancellation, reset and stop.",
"3. Trace ticket allocation, publication, callback lookup, completion, release and reuse; identify locking/atomic ordering.",
"4. Trace all RTW88 TX completion producers and prove exactly-once terminal completion for every submitted skb.",
"5. Pair every DMA map/alloc/prepare with unmap/free/complete across normal TX, errors, reset, failed start and stop.",
"6. Establish workqueue, tasklet, interrupt and DMA quiescence before reclaiming descriptors or packet memory.",
"7. Compare ownership transitions with existing 24H32 Skywalk adapter contracts.",
"","STAGE25_STATUS: REVIEW_REQUIRED — source scan is evidence collection, not a semantic pass.",
"ACTIVATION_GATE: BLOCKED — no queue registration/enable, packet handoff, BSD publication, radio start, build/install/load or OpenCore changes."]
out.write_text("\n".join(report)+"\n",encoding="utf-8")
print("STAGE25_REPORT_PATH: "+str(out))
print("ALL_CODE_FILES: "+str(len(all_code)))
print("IMPLEMENTATION_AND_PROJECT_HEADER_FILES_SCANNED: "+str(len(impl)))
print("REPORT_BYTES: "+str(out.stat().st_size))
PY
[[ -s "$REPORT" ]] || { echo 'Stage25 report missing.'; exit 2; }
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Stage25 report exceeds 900KB upload cap: $BYTES"; exit 2; }
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
  echo "GITHUB_UPLOAD_FAILED: PUT $api" >&2; cat "$response" >&2 2>/dev/null || true; return 1
 fi
 putsha="$(python3 - "$response" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(d.get("content",{}).get("sha",""))
PY
)"
 [[ -n "$putsha" ]] || { echo "GITHUB_UPLOAD_FAILED: no content SHA" >&2; cat "$response" >&2; return 1; }
 readsha="$(gh api "$api" --jq '.sha')"
 [[ "$putsha" == "$readsha" ]] || { echo "GITHUB_UPLOAD_FAILED: SHA mismatch put=$putsha read=$readsha" >&2; return 1; }
 echo "GITHUB_UPLOAD_VERIFIED: $api $readsha"
 UPLOAD_RESULT_SHA="$readsha"
}
upload_file "$REPORT" "repos/$REPO/contents/Development/stage25-source-complete-tx-dma-audit.txt" "Add Stage25 source-complete TX and DMA audit" "$STAGE/report-payload.json" "$STAGE/report-response.json"
SHA="$UPLOAD_RESULT_SHA"
echo "STAGE25_REPORT_UPLOAD: SUCCESS"
echo "STAGE25_REPORT_BLOB_SHA: $SHA"
LOG="$PROJECT/output.log"
API="repos/$REPO/contents/Development/output.log"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/remote-output.log"
python3 - "$STAGE/remote-output.log" "$LOG" "$SHA" "$BYTES" <<'PY'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8",errors="replace")
marker="========== STAGE25 SOURCE-COMPLETE TX / DMA AUDIT =========="
if marker in old: old=old[:old.index(marker)].rstrip()+"\n"
entry=("\n"+marker+"\n"
"STAGE25_REPORT: Development/stage25-source-complete-tx-dma-audit.txt\n"
"STAGE25_REPORT_BLOB_SHA: "+sys.argv[3]+"\n"
"STAGE25_REPORT_BYTES: "+sys.argv[4]+"\n"
"STAGE25_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\n"
"SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\n"
"KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n")
pathlib.Path(sys.argv[2]).write_text(old+entry,encoding="utf-8")
PY
upload_file "$LOG" "$API" "Record Stage25 source-complete TX and DMA audit" "$STAGE/log-payload.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "CANONICAL_OUTPUT_LOG_BLOB_SHA: $UPLOAD_RESULT_SHA"
echo "STAGE25_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
