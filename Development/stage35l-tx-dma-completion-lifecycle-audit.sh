#!/bin/bash
# Stage 35L — trace TX DMA mapping, bounce-copy, descriptor submission, completion and teardown.
# Read-only static audit. No compilation, build, install, Kext load, or OpenCore edits.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35L-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35L_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split grep find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$RTW/pci.c" ]] || { echo "ERROR: expected RTW88 PCI driver source missing: $RTW/pci.c"; exit 3; }
[[ -f "$SRC/src/compat/linux/dma-mapping.h" ]] || { echo "ERROR: DMA compatibility header missing"; exit 4; }
[[ -f "$SRC/src/kext/RTW88IEEE80211.cpp" ]] || { echo "ERROR: RTW88 state-machine source missing"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 6; }

{
 echo "========== STAGE 35L: TX DMA / COMPLETION LIFECYCLE AUDIT =========="
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "host=$(hostname 2>/dev/null || echo unknown)"
 echo "source_root=$SOURCE_ROOT"
 echo "rtw88_pci_source=$RTW/pci.c"
 echo "mode=read-only static source/call-chain audit"
 echo
} > "$REPORT"

python3 - "$SRC" "$RTW" "$OUT" >> "$REPORT" <<'PY'
import hashlib,os,pathlib,re,sys
src,rtw,out=map(pathlib.Path,sys.argv[1:])
files={
 "pci":rtw/"pci.c",
 "dma":src/"src/compat/linux/dma-mapping.h",
 "hwops":src/"src/kext/RTW88HwOps.cpp",
 "backend":src/"src/kext/wcl24h32/RTW88WCLPCIBackend.cpp",
 "ieee":src/"src/kext/RTW88IEEE80211.cpp",
 "ieee_h":src/"src/kext/RTW88IEEE80211.hpp",
 "compat":src/"src/compat/rtw88_compat.c",
 "compat_h":src/"src/compat/rtw88_compat.h",
}
def rel(p):
 try: return str(p.relative_to(src))
 except ValueError: return "../rtw88-stable/drivers/net/wireless/realtek/rtw88/"+p.name
def show(p,lo,hi,label):
 lines=p.read_text(errors="replace").splitlines()
 lo=max(1,lo); hi=min(len(lines),hi)
 print("\n[%s lines %d-%d]"%(label,lo,hi))
 for n in range(lo,hi+1): print("%4d %s"%(n,lines[n-1]))
 print("[END %s]"%label)
def contexts(p,patterns,before=12,after=22,limit=100):
 lines=p.read_text(errors="replace").splitlines()
 hits=[]
 for i,line in enumerate(lines):
  if any(re.search(pattern,line) for pattern in patterns):
   hits.append(i)
 merged=[]
 for i in hits:
  lo=max(0,i-before); hi=min(len(lines),i+after+1)
  if merged and lo<=merged[-1][1]+2: merged[-1]=(merged[-1][0],max(merged[-1][1],hi))
  else: merged.append((lo,hi))
 print("MATCH_LINES=%d CONTEXT_WINDOWS=%d"%(len(hits),len(merged)))
 for lo,hi in merged[:limit]:
  print("\n[lines %d-%d]"%(lo+1,hi))
  for j in range(lo,hi): print("%4d %s"%(j+1,lines[j]))
 if len(merged)>limit: print("CONTEXT_WINDOWS_TRUNCATED=%d"%(len(merged)-limit))
print("--- Source snapshots ---")
for name,p in files.items():
 if p.exists():
  raw=p.read_bytes()
  print("SOURCE name=%s path=%s bytes=%d sha256=%s"%(name,rel(p),len(raw),hashlib.sha256(raw).hexdigest()))
 else: print("MISSING_SOURCE name="+name+" path="+str(p))
pci=files["pci"]
print("\n--- TX DMA map and descriptor publication path ---")
contexts(pci,[r"dma_map_single",r"skb_push\(",r"skb_queue_tail\(",r"tx_data->dma",r"get_tx_buffer_desc"],before=18,after=30)
print("\n--- TX completion / reclaim / skb disposition path ---")
contexts(pci,[r"dma_unmap_single",r"skb_dequeue\(",r"dev_kfree_skb",r"ieee80211_tx_status",r"rtw_pci_free_tx_ring_skbs",r"rtw_pci_release_rsvd_page"],before=16,after=32)
print("\n--- TX callback and packet ownership in RTW88IEEE80211 ---")
contexts(files["ieee"],[
 r"RTW88IEEE80211::outputPacket",
 r"RTW88IEEE80211::outputPacketWithCompletion",
 r"RTW88IEEE80211::txDataFrame",
 r"RTW88IEEE80211::compat_tx_status",
 r"RTW88IEEE80211::txStatus",
 r"void rtw_tx|rtw_tx\(",
 r"kfree_skb\(",
 r"dev_kfree_skb"
],before=14,after=34,limit=100)
print("\n--- TX-related callback declarations and bindings ---")
for key in ["ieee","ieee_h","compat","compat_h"]:
 p=files[key]
 if not p.exists(): continue
 print("\n### "+key)
 contexts(p,[r"tx_status",r"rtw88_set_hw_callbacks",r"outputPacket",r"txDataFrame",r"txStatus",r"rtw_tx"],before=6,after=16,limit=80)
print("\n--- DMA compatibility and bounce-buffer semantics ---")
show(files["dma"],16,105,"dma-mapping.h")
show(files["hwops"],80,140,"RTW88HwOps.cpp DMA callbacks")
print("\n--- Native backend allocation/free and bounce map handling ---")
contexts(files["backend"],[
 r"RTW88WCLPCIBackend::allocCoherent",
 r"RTW88WCLPCIBackend::freeCoherent",
 r"RTW88WCLPCIBackend::freeCoherentByPhys",
 r"RTW88WCLPCIBackend::setBounceOrigVA",
 r"RTW88WCLPCIBackend::syncBounceForCpu",
 r"RTW88WCLPCIBackend::freeDMAList",
 r"RTW88WCLPCIBackend::setRadioRunning"
],before=8,after=34,limit=60)
print("\n--- Static TX ownership counts ---")
all_sources=[]
for label,root in [("RTW88",rtw),("COMPAT",src/"src/compat"),("KEXT",src/"src/kext")]:
 for base,dirs,names in os.walk(root):
  dirs[:]=[d for d in dirs if d not in {".git","build","DerivedData"} and not d.endswith(".dSYM")]
  for name in sorted(names):
   p=pathlib.Path(base)/name
   if p.suffix.lower() in {".c",".cc",".cpp",".h",".hpp"}: all_sources.append((label,p))
scan={
 "dma_map_single":r"\bdma_map_single\s*\(",
 "dma_unmap_single":r"\bdma_unmap_single\s*\(",
 "dma_sync_single_for_device":r"\bdma_sync_single_for_device\s*\(",
 "kfree_skb":r"\bkfree_skb\s*\(",
 "dev_kfree_skb_any":r"\bdev_kfree_skb_any\s*\(",
 "ieee80211_tx_status":r"\bieee80211_tx_status(_irqsafe)?\s*\(",
 "rtw88_set_hw_callbacks":r"\brtw88_set_hw_callbacks\s*\(",
}
for name,pattern in scan.items():
 rx=re.compile(pattern); rows=[]
 for label,p in all_sources:
  try: lines=p.read_text(errors="replace").splitlines()
  except OSError: continue
  for n,line in enumerate(lines,1):
   st=line.strip()
   if st.startswith(("//","*")): continue
   if rx.search(line): rows.append((label,p,n,st))
 print(name+"_CALL_SITES=%d"%len(rows))
 for label,p,n,line in rows[:100]:
  try: path=str(p.relative_to(src))
  except ValueError: path="../rtw88-stable/"+p.name
  print("  %s:%d | %s"%(path,n,line[:260]))
 if len(rows)>100: print("  TRUNCATED=%d"%(len(rows)-100))
print("\n--- TX lifecycle assertions and review gates ---")
ptext=pci.read_text(errors="replace")
htext=files["hwops"].read_text(errors="replace")
dtext=files["dma"].read_text(errors="replace")
btext=files["backend"].read_text(errors="replace")
print("TX_MAP_HAS_ERROR_CHECK="+str(bool(re.search(r"dma_map_single\s*\([^;]*DMA_TO_DEVICE\s*\)\s*;\s*if\s*\(\s*dma_mapping_error",ptext,re.S))))
print("TX_MAP_TO_DEVICE_PRESENT="+str(bool(re.search(r"dma_map_single\s*\([^;]*DMA_TO_DEVICE",ptext,re.S))))
print("TX_DEVICE_SYNC_CALL_PRESENT="+str(bool(re.search(r"dma_sync_single_for_device\([^;]*DMA_TO_DEVICE",ptext))))
print("COMPAT_DMA_MAP_COPIES_TO_DEVICE="+str(bool(re.search(r"if\s*\(dir\s*==\s*1\s*\|\|\s*dir\s*==\s*2\)\s*memcpy\s*\(bounce,\s*ptr,\s*size\)",htext))))
print("COMPAT_DMA_UNMAP_FREES_BY_PHYSICAL="+str("freeCoherentByPhys" in htext))
print("TX_COMPLETION_UNMAP_PRESENT="+str("dma_unmap_single" in ptext))
print("TX_UNMAP_BEFORE_PACKET_FREE_IN_RING_DRAIN="+str(bool(re.search(r"dma_unmap_single[\s\S]{0,180}(dev_kfree_skb|kfree_skb)",ptext))))
print("EMPTY_SYNC_FOR_DEVICE_CALLBACK="+str(bool(re.search(r"compat_dma_sync_dev\s*\([^)]*\)\s*\{\s*\}",htext,re.S))))
print("BACKEND_DMA_ALLOC_USES_PHYSICALLY_CONTIGUOUS_DESCRIPTOR="+str("kIOMemoryPhysicallyContiguous" in btext))
print("NOTE=Static source matches cannot prove runtime ordering, asynchronous exactly-once completion, or hardware-visible descriptor semantics.")
print("\n--- Explicit questions for follow-up ---")
questions=[
 "After TX skb_push, does every map failure path transfer or dispose of the skb exactly once?",
 "Does TX unmap use the same DMA address and original mapped length after any skb length mutation?",
 "Does every TX queue completion path unmap once before the skb is freed or reported?",
 "Can reset, timeout, queue-drain and device-removal paths race a hardware completion?",
 "Does the bounce-buffer mapping retain the original skb data pointer until unmap?",
 "Can the process-global DMA callback lease be cleared while TX descriptors remain active?",
 "Are beacon/reserved-page and H2C special TX queues paired with their own mapping lifetime?",
]
for i,q in enumerate(questions,1): print("OPEN_QUESTION_%02d=%s"%(i,q))
print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
PY

{
 echo
 echo "--- End Stage 35L ---"
 echo "ACTUAL_BUILD=NOT_RUN"
 echo "KEXT_INSTALL=NOT_RUN"
 echo "KEXT_LOAD=NOT_RUN"
 echo "HARDWARE_TEST=NOT_RUN"
} >> "$REPORT"

mkdir -p "$OUT/parts"
split -b 220k "$REPORT" "$OUT/parts/report-"
upload_file() {
 local file="$1" path="$2" msg="$3" payload="$4" response="$5" old put got
 old="$(gh api "repos/$REPO/contents/$path" --jq .sha 2>/dev/null || true)"
 python3 - "$file" "$old" "$msg" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,msg,dest=sys.argv[1:]
v={"message":msg,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha:v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
 if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
  echo "UPLOAD_FAILED_PATH=$path" >>"$UPLOAD_ERROR"
  echo "AUTH_ACCOUNT=$(gh api user --jq .login 2>&1 || true)" >>"$UPLOAD_ERROR"
  echo "REPO_PERMISSION=$(gh api "repos/$REPO" --jq '.full_name + " push=" + (.permissions.push|tostring)' 2>&1 || true)" >>"$UPLOAD_ERROR"
  return 1
 fi
 put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA: "+repr(v)[:700])
print(s)
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >>"$UPLOAD_ERROR"; return 1; }
 UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 35L\nRUN: %s\nPURPOSE: TX DMA mapping/submission/completion/unmap ownership lifecycle\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage35l/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage35L TX DMA lifecycle audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35l/$RUN/manifest.txt" "Add Stage35L manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35L_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35L_RUN=$RUN"
echo "STAGE35L_REPORT_PARTS=$COUNT"
echo "STAGE35L_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35l/$RUN"
