#!/bin/bash
set -Eeuo pipefail
trap 'rc=$?; echo "STAGE31_ERROR: exit=$rc line=$LINENO" >&2; exit "$rc"' ERR
REPO=shammu2bd/Realtek-WiFi-Native-macOS
NAME=RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source
if [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR:-}/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then PROJECT="$HOME/Downloads/$NAME"
else echo "Cannot locate project"; exit 2; fi
command -v gh >/dev/null
gh auth status >/dev/null
STAGE="$PROJECT/build/stage31-full-tree-tx-contract-tests-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE"
REPORT="$STAGE/stage31-full-tree-tx-contract-tests.txt"
python3 - "$PROJECT" "$REPORT" <<'PY'
from pathlib import Path
import hashlib,re,sys
root=Path(sys.argv[1]); out=Path(sys.argv[2])
ext={".c",".cc",".cpp",".cxx",".h",".hpp",".hh"}
skip={".git","build","DerivedData","SDK","Frameworks","Headers","PrivateHeaders","Pods","node_modules"}
rx=re.compile(r'\b(?:rtw_tx|rtw_pci_tx_[A-Za-z0-9_]*|tx_status|tx_report|tx_done|tx_complete|write_txbd|fill_tx|dma_map_[A-Za-z0-9_]*|dma_unmap_[A-Za-z0-9_]*)\b|ieee80211_ops|\.tx\s*=|compat_dma_sync_dev|request_irq|free_irq|tasklet_schedule|tasklet_kill|synchronize_irq')
files=[]; errors=[]
for p in root.rglob("*"):
 if not p.is_file() or p.suffix.lower() not in ext: continue
 rel=p.relative_to(root)
 if any(part in skip for part in rel.parts): continue
 try: raw=p.read_bytes()
 except OSError as e: errors.append(f"{rel}: {e}"); continue
 if len(raw)>8_000_000: continue
 src=raw.decode("utf-8","replace")
 if rx.search(src): files.append((rel.as_posix(),raw,src))
files.sort()
def function_occurrences(src,name):
 # Distinguish a prototype from a definition by checking for '{' after balanced params.
 pat=re.compile(r'\b'+re.escape(name)+r'\s*\(')
 out=[]
 for m in pat.finditer(src):
  i=m.end(); depth=1
  while i<len(src) and depth:
   if src[i]=='(': depth+=1
   elif src[i]==')': depth-=1
   i+=1
  if depth: continue
  j=i
  while j<len(src) and src[j].isspace(): j+=1
  kind="definition" if j<len(src) and src[j]=='{' else "declaration_or_call"
  line=src.count("\n",0,m.start())+1
  out.append((line,kind,src[m.start():min(len(src),j+1)].replace("\n"," ")[:220]))
 return out
lines=["RTL88WiFi Stage31 — full-project TX contract and static test audit",
"ROOT: "+str(root),"SCOPE: entire project source tree; SDK/build/generated directories excluded",
"SOURCE_CHANGES: NONE","BUILD: NOT RUN","INSTALL: NOT RUN","LOAD: NOT RUN","OPENCORE_CHANGE: NONE",
"KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED","MATCHED_SOURCE_FILES: "+str(len(files))]
tx_defs=[]; tx_refs=[]; ops_files=[]
for rel,raw,src in files:
 occ=function_occurrences(src,"rtw_tx")
 if occ:
  tx_refs.append((rel,occ))
  for line,kind,sig in occ:
   if kind=="definition": tx_defs.append((rel,line,sig))
 if "ieee80211_ops" in src or re.search(r'\.tx\s*=',src): ops_files.append(rel)
 lines += ["","=== SOURCE_FILE: "+rel+" SHA256="+hashlib.sha256(raw).hexdigest()+" BYTES="+str(len(raw))+" ==="]
 if occ: lines.append("RTW_TX_OCCURRENCES: "+repr(occ))
 for n,line in enumerate(src.splitlines(),1):
  if re.search(r'compat_dma_sync_dev|request_irq|free_irq|tasklet_schedule|tasklet_kill|synchronize_irq|\.tx\s*=|ieee80211_ops|rtw_pci_tx_|write_txbd|fill_tx|dma_map_|dma_unmap_',line):
   lines.append(f"L{n}: {line}")
 lines.append("--- COMPLETE MATCHED SOURCE ---")
 lines.append(src)
lines += ["","=== STATIC TEST RESULTS ===",
"RTW_TX_OCCURRENCE_FILES: "+str(len(tx_refs)),
"RTW_TX_TRUE_DEFINITION_COUNT: "+str(len(tx_defs)),
"RTW_TX_TRUE_DEFINITIONS: "+(repr(tx_defs) if tx_defs else "NONE FOUND IN FULL PROJECT TREE"),
"OPS_REGISTRATION_CANDIDATE_FILES: "+(";".join(ops_files) if ops_files else "NONE"),
"TEST_1_DECLARATION_VS_DEFINITION: "+("PASS — true function body found" if tx_defs else "FAIL — implementation definition not located"),
"TEST_2_OPS_REGISTRATION: REVIEW — inspect candidate files; generic .tx matches may be unrelated",
"TEST_3_DMA_SYNC_AND_IRQ_STUBS: REVIEW — inspect complete source excerpts above",
"TEST_4_TX_DESCRIPTOR_AND_COMPLETION_PATH: REVIEW — all matched project source excerpts above",
"TEST_5_SOURCE_TREE_COVERAGE: "+("PASS — full project source tree scanned" if files else "FAIL — no source files matched"),
"READ_ERRORS: "+("; ".join(errors) if errors else "NONE"),
"INTERPRETATION: a missing true rtw_tx definition means the source package is incomplete or implementation is outside the scanned project; do not guess or patch ownership code.",
"STAGE31_STATUS: REVIEW_REQUIRED","ACTIVATION_GATE: BLOCKED"]
out.write_text("\n".join(lines)+"\n")
print("STAGE31_REPORT_PATH:",out)
print("MATCHED_SOURCE_FILES:",len(files))
print("RTW_TX_TRUE_DEFINITION_COUNT:",len(tx_defs))
print("OPS_REGISTRATION_CANDIDATE_FILES:",len(ops_files))
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
 echo "UPLOAD_VERIFIED $path $got"; UPLOAD_SHA="$got"
}
CHUNK_DIR="$STAGE/report-parts"; mkdir -p "$CHUNK_DIR"
split -b 350000 -d -a 3 "$REPORT" "$CHUNK_DIR/part-"
MANIFEST="$STAGE/stage31-report-manifest.txt"; : > "$MANIFEST"; PART_COUNT=0
for PART in "$CHUNK_DIR"/part-*; do
 [[ -f "$PART" ]] || continue
 PART_NAME="$(basename "$PART").txt"; PART_PATH="Development/stage31-full-tree-tx-contract-tests-$PART_NAME"
 upload_text "$PART" "$PART_PATH" "Add Stage31 full-tree TX audit report chunk $PART_NAME" "$STAGE/part.json" "$STAGE/part-response.json"
 printf '%s %s %s\n' "$PART_PATH" "$UPLOAD_SHA" "$(wc -c < "$PART" | tr -d ' ')" >> "$MANIFEST"
 PART_COUNT=$((PART_COUNT+1))
done
[[ "$PART_COUNT" -gt 0 ]] || { echo "No report chunks were produced"; exit 2; }
printf 'STAGE31_REPORT_PARTS: %s\nSTAGE31_REPORT_BYTES: %s\n' "$PART_COUNT" "$BYTES" >> "$MANIFEST"
upload_text "$MANIFEST" Development/stage31-full-tree-tx-contract-tests-manifest.txt "Add Stage31 full-tree TX audit manifest" "$STAGE/manifest.json" "$STAGE/manifest-response.json"
MANIFEST_SHA="$UPLOAD_SHA"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/Development/output.log" -o "$STAGE/old.log"
python3 - "$STAGE/old.log" "$PROJECT/output.log" "$MANIFEST_SHA" "$BYTES" "$PART_COUNT" <<'PY2'
import pathlib,sys
old=pathlib.Path(sys.argv[1]).read_text(errors="replace")
mark="========== STAGE31 FULL-TREE TX CONTRACT TESTS =========="
if mark in old: old=old[:old.index(mark)].rstrip()+"\n"
old+="\n"+mark+"\nSTAGE31_REPORT_MANIFEST: Development/stage31-full-tree-tx-contract-tests-manifest.txt\nSTAGE31_MANIFEST_BLOB_SHA: "+sys.argv[3]+"\nSTAGE31_REPORT_BYTES: "+sys.argv[4]+"\nSTAGE31_REPORT_PARTS: "+sys.argv[5]+"\nSTAGE31_STATUS: REVIEW_REQUIRED\nACTIVATION_GATE: BLOCKED\nSOURCE_CHANGES: NONE | BUILD: NOT RUN | INSTALL: NOT RUN | LOAD: NOT RUN | OPENCORE_CHANGE: NONE\nKNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED\n"
pathlib.Path(sys.argv[2]).write_text(old)
PY2
upload_text "$PROJECT/output.log" Development/output.log "Record Stage31 full-tree TX contract tests" "$STAGE/log.json" "$STAGE/log-response.json"
echo "CANONICAL_OUTPUT_LOG_UPLOAD: SUCCESS"
echo "STAGE31_REPORT_PARTS: $PART_COUNT"
echo "STAGE31_STATUS: REVIEW_REQUIRED"
echo "ACTIVATION_GATE: BLOCKED"
