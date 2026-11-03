#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE32_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project; cd to the project root first"; exit 2; fi
command -v python3 >/dev/null
command -v gh >/dev/null
gh auth status >/dev/null
STAGE="$PROJECT/build/stage32-tx-ownership-dma-irq-skywalk-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage32-combined-tx-integration-audit.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project=Path(sys.argv[1]); out=Path(sys.argv[2])
ext={".c",".cc",".cpp",".cxx",".h",".hpp",".hh"}
skip={".git","build","DerivedData","SDK","Frameworks","Headers","PrivateHeaders","Pods","node_modules"}
groups={
"OPS_REGISTRATION":re.compile(r"ieee80211_ops|(?:^|[,{])\s*\.tx\s*=|(?:_hw|hw)->ops|ops\s*=\s*&?\s*\w+",re.I),
"TX_SUBMISSION":re.compile(r"\brtw_tx\s*\(|\brtw_pci_tx_\w*|\btxDataFrame\s*\(|\boutputPacketWithCompletion\s*\(|txSubmissionAction",re.I),
"COMPLETION_OWNERSHIP":re.compile(r"ieee80211_(?:tx_status|free_txskb)|(?:dev_)?kfree_skb|skb_queue_(?:purge|tail|head)|tx_(?:status|report|done|complete)|completion|terminal|exactly.once",re.I),
"DMA_DESCRIPTOR":re.compile(r"dma_(?:map|unmap|alloc|free|sync)\w*|compat_dma_sync_dev|(?:tx|dma)[_-]?(?:desc|bd|ring|queue)|write_txbd|fill_tx|bus.?master",re.I),
"IRQ_QUIESCE":re.compile(r"request_irq|free_irq|synchronize_irq|tasklet_(?:schedule|kill)|cancel_work_sync|flush_work|workqueue|interrupt|irq_handler|napi",re.I),
"SKYWALK_INTEGRATION":re.compile(r"RTW88WCL|IOSkywalk|Skywalk|txSubmissionAction|drainCompletions|register.*queue|queue.*register|bsd.*publish|ifnet",re.I),
"SAFETY_FENCES":re.compile(r"kIOReturnNotReady|kPacketPathDisabled|Publication fence|ACTIVATION_GATE|return false",re.I)
}
files=[]; errors=[]
for p in project.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in ext: continue
 rel=p.relative_to(project)
 if any(x in skip for x in rel.parts): continue
 try: raw=p.read_bytes()
 except OSError as e: errors.append(f"{rel}: {e}"); continue
 if len(raw)>8_000_000: continue
 src=raw.decode("utf-8","replace")
 hits={k:[i for i,line in enumerate(src.splitlines(),1) if rx.search(line)] for k,rx in groups.items()}
 hits={k:v for k,v in hits.items() if v}
 if hits: files.append((rel.as_posix(),raw,src,hits))
files.sort()
def occurrences(src, name):
 pat=re.compile(r"\b"+re.escape(name)+r"\s*\("); found=[]
 for m in pat.finditer(src):
  i=m.end(); depth=1
  while i<len(src) and depth:
   if src[i]=="(": depth+=1
   elif src[i]==")": depth-=1
   i+=1
  if depth: continue
  j=i
  while j<len(src) and src[j].isspace(): j+=1
  found.append((src.count("\n",0,m.start())+1,"definition" if j<len(src) and src[j]=="{" else "declaration_or_call"))
 return found
defs=[]; opfiles=[]; dmafiles=[]; irqfiles=[]; skyfiles=[]
lines=[
"RTL88WiFi Stage32 — combined TX registration, skb ownership, DMA/IRQ lifecycle and native Skywalk integration audit",
"PROJECT: "+str(project),
"PURPOSE: one-pass full-project source evidence collection for the four requested integration gates.",
"SOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE",
"KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"IMPORTANT: this is a source audit, not proof of runtime hardware behavior. Every semantic item requires review against complete control flow and target 24H32 ABI.",
"MATCHED_SOURCE_FILES: "+str(len(files))]
for rel,raw,src,hits in files:
 if hits.get("OPS_REGISTRATION"): opfiles.append(rel)
 if hits.get("DMA_DESCRIPTOR"): dmafiles.append(rel)
 if hits.get("IRQ_QUIESCE"): irqfiles.append(rel)
 if hits.get("SKYWALK_INTEGRATION"): skyfiles.append(rel)
 occ=occurrences(src,"rtw_tx")
 defs += [(rel,n) for n,k in occ if k=="definition"]
 lines += ["","=== FILE "+rel+" SHA256="+hashlib.sha256(raw).hexdigest()+" BYTES="+str(len(raw))+" ==="]
 for k,nums in hits.items(): lines.append(k+"_LINES: "+",".join(map(str,nums[:500])))
 if occ: lines.append("RTW_TX_OCCURRENCES: "+repr(occ))
 lines.append("----- COMPLETE SOURCE -----")
 lines.append(src)
lines += [
"","=== COMBINED CHECKLIST / EVIDENCE INDEX ===",
"1. TX OPERATIONS REGISTRATION",
"Candidate files: "+(";".join(opfiles) if opfiles else "NONE"),
"rtw_tx true definitions: "+repr(defs),
"Result: REVIEW_REQUIRED — prove the exact ieee80211_ops object assigned to the live hardware and the exact function pointer value; textual matches alone do not prove runtime registration.",
"2. HARDWARE COMPLETION OWNERSHIP",
"Candidate files: "+(";".join([x for x,_,_,h in files if "COMPLETION_OWNERSHIP" in h or "TX_SUBMISSION" in h]) or "NONE"),
"Result: REVIEW_REQUIRED — build a branch-by-branch ownership matrix for success, ring-full, allocation/map failure, firmware rejection, IRQ completion, timeout, reset and removal; establish exactly one terminal skb disposition and no use-after-free/double completion.",
"3. DMA AND IRQ LIFECYCLE",
"DMA candidate files: "+(";".join(dmafiles) if dmafiles else "NONE"),
"IRQ/quiesce candidate files: "+(";".join(irqfiles) if irqfiles else "NONE"),
"Result: REVIEW_REQUIRED — verify map/sync/device ownership/unmap ordering, descriptor publication, hardware stop/bus-master fence, IRQ synchronization and deferred-work drain before freeing rings or callback context.",
"4. NATIVE SKYWALK TX INTEGRATION",
"Skywalk candidate files: "+(";".join(skyfiles) if skyfiles else "NONE"),
"Result: REVIEW_REQUIRED — prove 24H32 queue registration/configuration, packet conversion, submission callback, completion queue handoff, backpressure, rollback and stop/deregister ordering. A staged adapter or kIOReturnNotReady fence is not active integration.",
"5. SOURCE TREE SCAN",
"Result: "+("PASS — scanned all eligible project C/C++ source files" if files and not errors else "REVIEW_REQUIRED — empty scan or read errors"),
"Read errors: "+("; ".join(errors) if errors else "NONE"),
"6. ACTIVATION DECISION",
"STAGE32_STATUS: REVIEW_REQUIRED",
"ACTIVATION_GATE: BLOCKED — do not register/enable queues, start radio, publish BSD interface, or install/load experimental Kext until all four gates have target-backed evidence and independent review.",
"NO AUTOMATIC SOURCE PATCHES WERE APPLIED."
]
out.write_text("\n".join(lines)+"\n")
print("STAGE32_REPORT:",out)
print("MATCHED_SOURCE_FILES:",len(files))
print("RTW_TX_DEFINITIONS:",len(defs))
print("OPS_FILES:",len(opfiles),"DMA_FILES:",len(dmafiles),"IRQ_FILES:",len(irqfiles),"SKYWALK_FILES:",len(skyfiles))
print("READ_ERRORS:",len(errors))
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
upload_text() {
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
 echo "UPLOAD_VERIFIED $path $got"
 UPLOAD_SHA="$got"
}
CHUNK_DIR="$STAGE/report-parts"; mkdir -p "$CHUNK_DIR"
split -b 350000 -d -a 3 "$REPORT" "$CHUNK_DIR/part-"
MANIFEST="$STAGE/stage32-report-manifest.txt"; : > "$MANIFEST"; PART_COUNT=0
for PART in "$CHUNK_DIR"/part-*; do
 [[ -f "$PART" ]] || continue
 PART_NAME="$(basename "$PART").txt"
 PART_PATH="Development/stage32-combined-tx-integration-$PART_NAME"
 upload_text "$PART" "$PART_PATH" "Add Stage32 combined TX integration report chunk $PART_NAME" "$STAGE/part.json" "$STAGE/part-response.json"
 printf '%s %s %s\n' "$PART_PATH" "$UPLOAD_SHA" "$(wc -c < "$PART" | tr -d ' ')" >> "$MANIFEST"
 PART_COUNT=$((PART_COUNT+1))
done
[[ "$PART_COUNT" -gt 0 ]] || { echo "No report chunks were produced"; exit 2; }
printf 'STAGE32_REPORT_PARTS: %s\nSTAGE32_REPORT_BYTES: %s\n' "$PART_COUNT" "$BYTES" >> "$MANIFEST"
upload_text "$MANIFEST" Development/stage32-combined-tx-integration-manifest.txt "Add Stage32 combined TX integration report manifest" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
MANIFEST_SHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$MANIFEST_SHA" "$BYTES" "$PART_COUNT" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE32 COMBINED TX INTEGRATION AUDIT =========="
if mark in old: old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE32_REPORT_MANIFEST: Development/stage32-combined-tx-integration-manifest.txt\nSTAGE32_MANIFEST_BLOB_SHA: "+sys.argv[3]+"\nSTAGE32_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE32_REPORT_PARTS: "+sys.argv[5]+"\nSTAGE32_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload_text "$PROJECT/output.log" Development/output.log "Record Stage32 combined TX integration audit" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE32_REPORT_PARTS: $PART_COUNT"
echo "STAGE32_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
