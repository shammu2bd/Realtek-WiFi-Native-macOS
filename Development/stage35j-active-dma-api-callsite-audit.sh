#!/bin/bash
# Stage 35J — determine which DMA compatibility APIs are actually called by the native source set.
# Read-only source inspection; no compile, build, install, Kext load, or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35J-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35J_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split grep find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$RTW" ]] || { echo "ERROR: expected rtw88 source tree missing: $RTW"; exit 3; }
[[ -f "$SRC/src/compat/linux/dma-mapping.h" ]] || { echo "ERROR: DMA compatibility header missing"; exit 4; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 5; }

{
 echo "========== STAGE 35J: ACTIVE DMA API CALL-SITE AUDIT =========="
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "host=$(hostname 2>/dev/null || echo unknown)"
 echo "source_root=$SOURCE_ROOT"
 echo "rtw88_source=$RTW"
 echo "mode=read-only static call-site audit"
 echo
} > "$REPORT"

python3 - "$SRC" "$RTW" "$OUT" >> "$REPORT" <<'PY'
import hashlib,os,pathlib,re,sys
src,rtw,out=map(pathlib.Path,sys.argv[1:])
api=[
 "dma_alloc_coherent","dma_free_coherent",
 "dma_map_single","dma_unmap_single",
 "dma_sync_single_for_cpu","dma_sync_single_for_device",
 "dma_map_page","dma_unmap_page",
 "alloc_page","__free_page",
 "dma_set_mask_and_coherent","dma_set_mask","dma_set_coherent_mask",
 "dma_mapping_error"
]
roots=[("RTW88_DRIVER",rtw),("COMPAT",src/"src/compat"),("KEXT",src/"src/kext")]
files=[]
for label,root in roots:
 for base,dirs,names in os.walk(root):
  dirs[:]=sorted(d for d in dirs if d not in {".git","build","DerivedData"} and not d.endswith(".dSYM"))
  for name in sorted(names):
   p=pathlib.Path(base)/name
   if p.suffix.lower() in {".c",".cc",".cpp",".h",".hpp"} and p.name not in {"dma-mapping.h"}:
    files.append((label,p))
# Exclude known declarations/comments; retain all function call sites.
def function_hint(lines,idx):
 for j in range(idx,-1,-1):
  line=lines[j].strip()
  if not line or line.startswith(("//","*","#")): continue
  if "(" in line and (line.endswith("{") or line.endswith(")")) and not line.endswith(";"):
   return line[:180]
 return "context unavailable"
print("--- Source inventory ---")
for label,root in roots:
 count=0
 for _,p in files:
  try: p.relative_to(root); count+=1
  except ValueError: pass
 print("%s_ROOT=%s SOURCE_FILES=%d"%(label,root,count))
print("\n--- DMA API call-site counts (header definitions excluded) ---")
counts={a:[] for a in api}
token_re={a:re.compile(r"(?<![A-Za-z0-9_])"+re.escape(a)+r"\s*\(") for a in api}
for label,p in files:
 try: lines=p.read_text(errors="replace").splitlines()
 except OSError as e:
  print("READ_ERROR %s %s"%(p,e)); continue
 for idx,line in enumerate(lines):
  stripped=line.strip()
  if stripped.startswith(("//","*")): continue
  for a,rx in token_re.items():
   if rx.search(line):
    counts[a].append((label,p,idx+1,line.strip(),function_hint(lines,idx)))
for a in api:
 rows=counts[a]
 print("%s_CALL_SITES=%d"%(a,len(rows)))
 for label,p,n,line,fn in rows[:160]:
  try: rel=p.relative_to(src)
  except ValueError: rel=p
  print("  %s:%d | %s | %s"%(rel,n,fn,line[:260]))
 if len(rows)>160: print("  ... TRUNCATED remaining=%d"%(len(rows)-160))
print("\n--- Helper implementation and fallback risks ---")
dma=src/"src/compat/linux/dma-mapping.h"
lines=dma.read_text(errors="replace").splitlines()
for lo,hi in [(16,103),(105,140)]:
 print("[dma-mapping.h lines %d-%d]"%(lo,min(hi,len(lines))))
 for n in range(lo,min(hi,len(lines))+1): print("%4d %s"%(n,lines[n-1]))
hw=src/"src/kext/RTW88HwOps.cpp"
lines=hw.read_text(errors="replace").splitlines()
print("\n[RTW88HwOps.cpp DMA/PCI callback block]")
for n,line in enumerate(lines,1):
 if n>=55: print("%4d %s"%(n,line))
print("\n--- Native backend DMA allocation/sync implementation ---")
backend=src/"src/kext/wcl24h32/RTW88WCLPCIBackend.cpp"
lines=backend.read_text(errors="replace").splitlines()
patterns=re.compile(r"RTW88WCLPCIBackend::(allocCoherent|freeCoherent|freeCoherentByPhys|setBounceOrigVA|syncBounceForCpu|drainPendingFree|releaseDMAEntries|handleInterrupt)|IOBufferMemoryDescriptor|prepare\(|complete\(|getPhysicalSegment|IODirection|dma_addr")
for n,line in enumerate(lines,1):
 if patterns.search(line):
  lo=max(1,n-8); hi=min(len(lines),n+40)
  print("\n[backend lines %d-%d]"%(lo,hi))
  for j in range(lo,hi+1): print("%4d %s"%(j,lines[j-1]))
print("\n--- Global DMA/PCI table ownership ---")
for rel in ["src/kext/RTW88HwOps.cpp","src/kext/wcl24h32/RTW88WCLPCIBackend.cpp","src/compat/rtw88_compat.c","src/compat/rtw88_compat.h"]:
 p=src/rel
 if not p.exists(): continue
 ls=p.read_text(errors="replace").splitlines()
 for n,line in enumerate(ls,1):
  if re.search(r"g_pci_dev_instance|rtw88_dma_ops\s*=|rtw88_pci_io_ops\s*=|__atomic_compare_exchange|_dma_ops|_pci_io_ops",line):
   print("%s:%d:%s"%(rel,n,line.strip()[:280]))
print("\n--- Call-site risk assessment ---")
for a in ["dma_sync_single_for_device","dma_map_page","dma_unmap_page","alloc_page","dma_set_mask_and_coherent","dma_set_mask","dma_set_coherent_mask","dma_mapping_error"]:
 rows=counts[a]
 print("%s=%s"%(a,"PRESENT" if rows else "NO_DRIVER_OR_COMPAT_CALLSITE_FOUND"))
print("SYNC_FOR_DEVICE_CALLBACK_IMPLEMENTATION=compat_dma_sync_dev is empty in RTW88HwOps.cpp (inspect every call-site above)")
print("DMA_PAGE_IMPLEMENTATION=dma_map_page returns struct page phys; alloc_page assigns phys from CPU virtual pointer")
print("DMA_MASK_IMPLEMENTATION=dma_set_mask* helpers return success without checking capability")
print("FALLBACK_IMPLEMENTATION=dma_alloc_coherent/dma_map_single cast CPU virtual pointers when rtw88_dma_ops callback is missing")
print("SCOPE=static call-site scan of rtw88 stable driver, compat, and kext C/C++ headers/sources; no runtime proof")
print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
PY

{
 echo
 echo "--- End Stage 35J ---"
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
printf 'STAGE: 35J\nRUN: %s\nPURPOSE: audit active DMA API call sites and callback coverage\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage35j/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage35J DMA call-site audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35j/$RUN/manifest.txt" "Add Stage35J manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35J_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35J_RUN=$RUN"
echo "STAGE35J_REPORT_PARTS=$COUNT"
echo "STAGE35J_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35j/$RUN"
