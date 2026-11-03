#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE28_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project"; exit 2; fi
command -v gh >/dev/null && gh auth status >/dev/null
STAGE="$PROJECT/build/stage28-rtw88-skb-ownership-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage28-rtw88-skb-terminal-ownership-audit.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project=Path(sys.argv[1]); driver=project/"driver/RTL88WiFi"; out=Path(sys.argv[2])
# Audit the implementation that receives the skb after RTW88IEEE80211::txDataFrame().
# Exclude SDK copies and generated/build artifacts; include complete source files to preserve control flow.
rx=re.compile(r'\b(?:rtw_tx\s*\(|rtw_tx_write\s*\(|rtw_tx_complete\s*\(|rtw_tx_report\s*\(|'
              r'rtw_txq|tx_report|tx_complete|tx_write|tx_ring|tx_queue|'
              r'skb_queue_(?:tail|head|purge)|skb_dequeue|kfree_skb|dev_kfree_skb|'
              r'ieee80211_(?:tx_status|free_txskb))\b',re.I)
files=[]
for p in driver.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in {".c",".cc",".cpp",".h",".hpp"}: continue
 rel=p.relative_to(driver).as_posix()
 if any(x in rel for x in ("/Headers/","/PrivateHeaders/","/SDK/","/build/","/DerivedData/")): continue
 try: data=p.read_bytes()
 except: continue
 if rx.search(data.decode("utf-8","replace")): files.append((rel,p,data))
files.sort()
r=["RTL88WiFi Stage28 — RTW88 core skb terminal ownership audit",
"PURPOSE: follow each skb handed to _hw->ops->tx() through enqueue, DMA, completion, rejection, purge, reset and teardown.",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN","OPENCORE_CHANGE: NONE","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"","MATCHED_SOURCE_FILES: "+str(len(files)),""]
for rel,p,data in files:
 src=data.decode("utf-8","replace")
 r += ["\n=== COMPLETE_FILE: {} SHA256={} BYTES={} ===".format(rel,hashlib.sha256(data).hexdigest(),len(data)),src]
 lines=src.splitlines()
 hits=[i for i,line in enumerate(lines) if rx.search(line) and not line.lstrip().startswith(("//","*","/*"))]
 r.append("--- TX/SKB OCCURRENCE INDEX ---")
 r.extend("{:05d}: {}".format(i+1,lines[i]) for i in hits)
r += ["","=== REQUIRED OWNERSHIP MATRIX ===",
"1. For every _hw->ops->tx() implementation, identify whether skb ownership transfers unconditionally, conditionally, or not at all.",
"2. Enumerate every success and error return in rtw_tx and downstream TX submission. For each, show who frees skb and whether TX status is guaranteed.",
"3. Follow skb through software queues, hardware descriptors, DMA mapping, IRQ completion, status report and free. Identify the unique terminal owner.",
"4. Trace every TX ring full, descriptor allocation failure, DMA map failure, firmware/hardware rejection, timeout, reset and device removal path.",
"5. Identify all skb_queue_purge and kfree_skb paths reachable for submitted TX skbs; establish whether callback token is reported before skb reclamation.",
"6. Prove whether txStatus and kfree_skb can execute concurrently on the same skb. Atomic token exchange alone does not prove skb lifetime safety if a losing reporter dereferences freed skb memory.",
"7. Establish IRQ/workqueue synchronization and DMA-stop ordering before queues, skb, descriptors or callback context are freed.",
"8. Identify TX paths that free skb without status callback, and paths that report status without freeing; map them to exactly one terminal callback.",
"9. Any untraced indirect callback, asynchronous queue or unsupported error path remains OPEN. Do not infer from function names or comments.",
"10. Source review cannot certify runtime race freedom or hardware behavior.",
"","STAGE28_STATUS: REVIEW_REQUIRED",
"ACTIVATION_GATE: BLOCKED — no Skywalk TX/RX activation, queue registration/enable, BSD publication, radio start, build/install/load, or OpenCore changes."]
text="\n".join(r)+"\n"; out.write_text(text)
print("STAGE28_REPORT_PATH:",out); print("MATCHED_SOURCE_FILES:",len(files)); print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 900000 )) || { echo "Report exceeds upload cap: $BYTES"; exit 2; }
upload() {
 local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,s,m,p=sys.argv[1:]; d={"message":m,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if s:d["sha"]=s
pathlib.Path(p).write_text(json.dumps(d))
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "Readback SHA mismatch: $path"; return 1; }
 echo "UPLOAD_VERIFIED $path $got"; UPLOAD_SHA="$got"
}
upload "$REPORT" Development/stage28-rtw88-skb-terminal-ownership-audit.txt "Add Stage28 RTW88 skb terminal ownership audit" "$STAGE/report.json" "$STAGE/report-response.json"
RPTSHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$RPTSHA" "$BYTES" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE28 RTW88 SKB TERMINAL OWNERSHIP =========="
if mark in old:old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE28_REPORT: Development/stage28-rtw88-skb-terminal-ownership-audit.txt\nSTAGE28_REPORT_BLOB_SHA: "+sys.argv[3]+"\nSTAGE28_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE28_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload "$PROJECT/output.log" Development/output.log "Record Stage28 RTW88 skb ownership audit" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE28_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
