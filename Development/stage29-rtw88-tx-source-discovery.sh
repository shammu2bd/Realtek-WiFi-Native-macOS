#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE29_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project"; exit 2; fi
command -v gh >/dev/null
gh auth status >/dev/null
STAGE="$PROJECT/build/stage29-tx-source-discovery-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage29-rtw88-tx-source-discovery.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project=Path(sys.argv[1]); driver=project/"driver/RTL88WiFi"; out=Path(sys.argv[2])
# Locate implementation-side TX submission, descriptor, DMA, IRQ and teardown code.
patterns={
 "TX_SUBMIT":re.compile(r'\b(?:_hw->ops->tx|ops->tx|rtw_tx(?:_write|_frame)?|txDataFrame|submitPacket)\b',re.I),
 "TX_RING_DESC":re.compile(r'\b(?:tx[_A-Za-z0-9]*(?:ring|desc|bd|queue)|(?:ring|desc|bd)[_A-Za-z0-9]*tx|write_txbd|fill_tx|txdma)\b',re.I),
 "DMA_LIFECYCLE":re.compile(r'\b(?:dma_map|dma_unmap|dma_alloc|dma_free|map_single|unmap_single|sync_single|prepare(?:For)?Device|complete(?:From)?Device|IODMACommand|IOBufferMemoryDescriptor|bus.?master)\b',re.I),
 "IRQ_COMPLETION":re.compile(r'\b(?:tx_status|tx_complete|tx_report|tx_done|irq_handler|interrupt|tasklet|workqueue|napi|tx_poll)\b',re.I),
 "STOP_PURGE":re.compile(r'\b(?:stop(?:_device|_hw|_tx)?|reset(?:_device|_hw)?|remove(?:_interface|_device)?|purge|flush|cancel_work|synchronize_irq|free_irq|skb_queue_purge|kfree_skb)\b',re.I)
}
excluded=("/Headers/","/PrivateHeaders/","/SDK/","/build/","/DerivedData/","/Frameworks/")
files=[]
for p in driver.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in {".c",".cc",".cpp",".h",".hpp"}: continue
 rel=p.relative_to(driver).as_posix()
 if any(x in "/"+rel for x in excluded): continue
 try: raw=p.read_bytes()
 except OSError: continue
 if len(raw)>2_000_000: continue
 src=raw.decode("utf-8","replace")
 hits={k:[i for i,line in enumerate(src.splitlines(),1) if rx.search(line)] for k,rx in patterns.items()}
 hits={k:v for k,v in hits.items() if v}
 if hits: files.append((rel,raw,src,hits))
files.sort()
lines=["RTL88WiFi Stage29 — RTW88 PCI TX implementation/source discovery",
"PURPOSE: identify the actual hardware TX implementation and its descriptor, DMA, IRQ completion, error, reset and teardown paths.",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN","OPENCORE_CHANGE: NONE","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"DRIVER_SOURCE_FILES_MATCHED: "+str(len(files))]
for rel,raw,src,hits in files:
 lines += ["","=== SOURCE_FILE: "+rel+" SHA256="+hashlib.sha256(raw).hexdigest()+" BYTES="+str(len(raw))+" ==="]
 for category,nums in hits.items():
  lines.append("--- "+category+" LINE INDEX: "+",".join(map(str,nums[:250]))+" ---")
 lines.append(src)
lines += ["","=== REVIEW QUESTIONS ===",
"1. Identify the concrete function assigned to _hw->ops->tx (or equivalent) and every caller.",
"2. Trace skb ownership on every return path, including ring-full, allocation, map, firmware and hardware errors.",
"3. Trace descriptor publication, DMA map/sync, completion/unmap and skb terminal release.",
"4. Trace IRQ/deferred completion and all reset/stop/remove/purge paths; establish callback quiescence before context release.",
"5. Determine whether every submitted skb produces exactly one terminal callback and whether callback races can access freed skb memory.",
"6. Identify generation protection against late completion after ticket reuse/reset.",
"7. Mark any missing indirect call, external implementation or unobserved path OPEN; source search is discovery, not proof.",
"","STAGE29_STATUS: REVIEW_REQUIRED",
"ACTIVATION_GATE: BLOCKED — do not activate Skywalk queues or packet handoff; do not build/install/load or change OpenCore."]
out.write_text("\n".join(lines)+"\n")
print("STAGE29_REPORT_PATH:",out)
print("DRIVER_SOURCE_FILES_MATCHED:",len(files))
print("REPORT_BYTES:",out.stat().st_size)
PY
test -s "$REPORT"
BYTES=$(wc -c < "$REPORT" | tr -d ' ')
(( BYTES <= 5000000 )) || { echo "Report exceeds 5MB upload cap: $BYTES"; exit 2; }
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
# GitHub Contents API payloads are Base64-expanded. Keep each source chunk <=350 KB.
CHUNK_DIR="$STAGE/report-parts"
mkdir -p "$CHUNK_DIR"
split -b 350000 -d -a 3 "$REPORT" "$CHUNK_DIR/part-"
MANIFEST="$STAGE/stage29-report-manifest.txt"
: > "$MANIFEST"
PART_COUNT=0
for PART in "$CHUNK_DIR"/part-*; do
 [[ -f "$PART" ]] || continue
 PART_NAME="$(basename "$PART").txt"
 PART_PATH="Development/stage29-rtw88-tx-source-discovery-$PART_NAME"
 upload_text "$PART" "$PART_PATH" "Add Stage29 TX source report chunk $PART_NAME" "$STAGE/part.json" "$STAGE/part-response.json"
 printf '%s %s %s\n' "$PART_PATH" "$UPLOAD_SHA" "$(wc -c < "$PART" | tr -d ' ')" >> "$MANIFEST"
 PART_COUNT=$((PART_COUNT+1))
done
[[ "$PART_COUNT" -gt 0 ]] || { echo "No report chunks were produced"; exit 2; }
printf 'STAGE29_REPORT_PARTS: %s\nSTAGE29_REPORT_BYTES: %s\n' "$PART_COUNT" "$BYTES" >> "$MANIFEST"
upload_text "$MANIFEST" Development/stage29-rtw88-tx-source-discovery-manifest.txt "Add Stage29 TX source report manifest" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
MANIFEST_SHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$MANIFEST_SHA" "$BYTES" "$PART_COUNT" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE29 RTW88 TX SOURCE DISCOVERY =========="
if mark in old: old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE29_REPORT_MANIFEST: Development/stage29-rtw88-tx-source-discovery-manifest.txt\nSTAGE29_MANIFEST_BLOB_SHA: "+sys.argv[3]+"\nSTAGE29_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE29_REPORT_PARTS: "+sys.argv[5]+"\nSTAGE29_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload_text "$PROJECT/output.log" Development/output.log "Record Stage29 RTW88 TX source discovery" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE29_REPORT_PARTS: $PART_COUNT"
echo "STAGE29_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
