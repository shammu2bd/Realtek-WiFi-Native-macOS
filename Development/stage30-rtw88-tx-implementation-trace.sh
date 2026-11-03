#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE30_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project"; exit 2; fi
command -v gh >/dev/null
gh auth status >/dev/null
STAGE="$PROJECT/build/stage30-tx-implementation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage30-rtw88-tx-implementation-trace.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
project=Path(sys.argv[1]); root=project/"driver/RTL88WiFi"; out=Path(sys.argv[2])
suffixes={".c",".cc",".cpp",".h",".hpp"}
excluded=("/Headers/","/PrivateHeaders/","/SDK/","/build/","/DerivedData/","/Frameworks/")
# Definitions/registrations and concrete PCI TX path symbols. Discovery is intentionally broad.
patterns={
 "RTW_TX_DEFINITION":re.compile(r'(?m)^\s*(?:static\s+)?(?:void|int|bool|netdev_tx_t)\s+rtw_tx\s*\('),
 "OPS_REGISTRATION":re.compile(r'(?i)(?:\.tx\s*=\s*rtw_tx|\.tx\s*=|ieee80211_ops|rtw_ops|hw->ops|ops\s*=)'),
 "PCI_TX_PATH":re.compile(r'(?i)\b(?:rtw_pci_tx_[A-Za-z0-9_]*|rtw_tx_[A-Za-z0-9_]*|tx_isr|tx_report|tx_done|tx_complete|tx_write_data|write_txbd|fill_tx|txdma)\b'),
 "DMA_AND_DESC":re.compile(r'(?i)\b(?:dma_map|dma_unmap|dma_alloc|dma_free|dma_sync|tx_desc|txdesc|txbd|tx_ring|tx_queue|txq|bus.?master)\b'),
 "OWNERSHIP_TERMINALS":re.compile(r'(?i)\b(?:ieee80211_tx_status|ieee80211_free_txskb|ieee80211_tx_status_irqsafe|dev_kfree_skb|kfree_skb|skb_queue_purge|purge_tx|flush_tx|synchronize_irq|cancel_work_sync)\b')
}
files=[]
for p in root.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in suffixes: continue
 rel=p.relative_to(root).as_posix()
 if any(x in "/"+rel for x in excluded): continue
 try: raw=p.read_bytes()
 except OSError: continue
 if len(raw)>8_000_000: continue
 src=raw.decode("utf-8","replace")
 hits={k:[i for i,line in enumerate(src.splitlines(),1) if rx.search(line)] for k,rx in patterns.items()}
 hits={k:v for k,v in hits.items() if v}
 if hits: files.append((rel,raw,src,hits))
files.sort()
lines=[
"RTL88WiFi Stage30 — RTW88 concrete TX implementation and registration trace",
"PURPOSE: locate the actual rtw_tx definition, ieee80211_ops registration, PCI TX descriptor/ring implementation, DMA calls, IRQ completion and skb terminal ownership.",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN","OPENCORE_CHANGE: NONE","KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
"SCAN_ROOT: driver/RTL88WiFi","IMPLEMENTATION_FILES_MATCHED: "+str(len(files))]
definitions=[]
registrations=[]
for rel,raw,src,hits in files:
 if hits.get("RTW_TX_DEFINITION"): definitions.append(rel)
 if hits.get("OPS_REGISTRATION"): registrations.append(rel)
 lines += ["","=== SOURCE_FILE: "+rel+" SHA256="+hashlib.sha256(raw).hexdigest()+" BYTES="+str(len(raw))+" ==="]
 for category,nums in hits.items():
  lines.append("--- "+category+" LINE INDEX: "+",".join(map(str,nums[:500]))+" ---")
 lines.append(src)
lines += ["","=== SUMMARY ===","RTW_TX_DEFINITION_FILES: "+(";".join(definitions) if definitions else "NOT_FOUND"),
"OPS_REGISTRATION_FILES: "+(";".join(registrations) if registrations else "NOT_FOUND"),
"=== REQUIRED REVIEW ===",
"1. Confirm the exact rtw_tx definition and the exact ieee80211_ops instance assigned to _hw->ops.",
"2. Follow each call to rtw_tx and determine whether the function consumes skb on every branch.",
"3. Trace PCI ring-full, descriptor allocation/fill, DMA map/sync, descriptor publication and hardware kick.",
"4. Trace every TX completion/error/reset path to its single skb terminal action and callback.",
"5. Prove DMA unmap/free occurs only after hardware completion or a verified bus-master fence.",
"6. Prove IRQ/workqueue/NAPI callbacks are quiesced before rings, skbs, callback contexts or tickets are released.",
"7. Identify indirect/external/missing implementations explicitly; no source-search result alone is a PASS.",
"STAGE30_STATUS: REVIEW_REQUIRED","ACTIVATION_GATE: BLOCKED"]
out.write_text("\n".join(lines)+"\n")
print("STAGE30_REPORT_PATH:",out)
print("IMPLEMENTATION_FILES_MATCHED:",len(files))
print("RTW_TX_DEFINITION_FILES:",len(definitions))
print("OPS_REGISTRATION_FILES:",len(registrations))
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
# Chunk uploads avoid GitHub Contents API Base64 payload limits.
CHUNK_DIR="$STAGE/report-parts"; mkdir -p "$CHUNK_DIR"
split -b 350000 -d -a 3 "$REPORT" "$CHUNK_DIR/part-"
MANIFEST="$STAGE/stage30-report-manifest.txt"; : > "$MANIFEST"
PART_COUNT=0
for PART in "$CHUNK_DIR"/part-*; do
 [[ -f "$PART" ]] || continue
 PART_NAME="$(basename "$PART").txt"
 PART_PATH="Development/stage30-rtw88-tx-implementation-$PART_NAME"
 upload_text "$PART" "$PART_PATH" "Add Stage30 TX implementation report chunk $PART_NAME" "$STAGE/part.json" "$STAGE/part-response.json"
 printf '%s %s %s\n' "$PART_PATH" "$UPLOAD_SHA" "$(wc -c < "$PART" | tr -d ' ')" >> "$MANIFEST"
 PART_COUNT=$((PART_COUNT+1))
done
[[ "$PART_COUNT" -gt 0 ]] || { echo "No report chunks were produced"; exit 2; }
printf 'STAGE30_REPORT_PARTS: %s\nSTAGE30_REPORT_BYTES: %s\n' "$PART_COUNT" "$BYTES" >> "$MANIFEST"
upload_text "$MANIFEST" Development/stage30-rtw88-tx-implementation-manifest.txt "Add Stage30 TX implementation report manifest" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
MANIFEST_SHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$MANIFEST_SHA" "$BYTES" "$PART_COUNT" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE30 RTW88 TX IMPLEMENTATION TRACE =========="
if mark in old: old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE30_REPORT_MANIFEST: Development/stage30-rtw88-tx-implementation-manifest.txt\nSTAGE30_MANIFEST_BLOB_SHA: "+sys.argv[3]+"\nSTAGE30_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE30_REPORT_PARTS: "+sys.argv[5]+"\nSTAGE30_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload_text "$PROJECT/output.log" Development/output.log "Record Stage30 RTW88 TX implementation trace" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE30_REPORT_PARTS: $PART_COUNT"
echo "STAGE30_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
