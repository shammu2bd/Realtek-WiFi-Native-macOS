#!/bin/bash
# Stage 35K — trace RX DMA allocation, map, device/CPU sync, reuse, unmap and teardown.
# Read-only static source audit. No build, install, Kext load, or OpenCore edits.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RTW="$SRC/../rtw88-stable/drivers/net/wireless/realtek/rtw88"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35K-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35K_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split grep find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$RTW/pci.c" ]] || { echo "ERROR: expected RTW88 PCI driver source missing: $RTW/pci.c"; exit 3; }
[[ -f "$SRC/src/compat/linux/dma-mapping.h" ]] || { echo "ERROR: DMA compatibility header missing"; exit 4; }
[[ -f "$SRC/src/kext/wcl24h32/RTW88WCLPCIBackend.cpp" ]] || { echo "ERROR: native PCI backend source missing"; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 6; }

{
 echo "========== STAGE 35K: RX DMA LIFECYCLE AUDIT =========="
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
pci=rtw/"pci.c"
dma=src/"src/compat/linux/dma-mapping.h"
hw=src/"src/kext/RTW88HwOps.cpp"
backend=src/"src/kext/wcl24h32/RTW88WCLPCIBackend.cpp"
compat=src/"src/compat/rtw88_compat.c"
api=[
 "dma_alloc_coherent","dma_free_coherent","dma_map_single","dma_unmap_single",
 "dma_sync_single_for_cpu","dma_sync_single_for_device","dma_mapping_error"
]
roots=[("RTW88_DRIVER",rtw),("COMPAT",src/"src/compat"),("NATIVE_KEXT",src/"src/kext")]
source_files=[]
for label,root in roots:
 for base,dirs,names in os.walk(root):
  dirs[:]=sorted(d for d in dirs if d not in {".git","build","DerivedData"} and not d.endswith(".dSYM"))
  for name in sorted(names):
   p=pathlib.Path(base)/name
   if p.suffix.lower() in {".c",".cc",".cpp",".h",".hpp"} and p.name!="dma-mapping.h":
    source_files.append((label,p))
def rel(p):
 try: return str(p.relative_to(src))
 except ValueError: return str(p.relative_to(rtw.parent.parent.parent.parent.parent)) if str(p).startswith(str(rtw)) else str(p)
def show(p,lo,hi,label=None):
 lines=p.read_text(errors="replace").splitlines()
 lo=max(1,lo); hi=min(len(lines),hi)
 print("\n[%s lines %d-%d]"%((label or str(p)),lo,hi))
 for n in range(lo,hi+1): print("%4d %s"%(n,lines[n-1]))
 print("[END %s]"%(label or str(p)))
print("--- Source snapshot hashes ---")
for p in [pci,dma,hw,backend,compat,rtw/"pci.h"]:
 if p.exists():
  raw=p.read_bytes()
  print("SOURCE path=%s bytes=%d sha256=%s"%(rel(p),len(raw),hashlib.sha256(raw).hexdigest()))
 else: print("MISSING_SOURCE="+str(p))
print("\n--- Driver and helper DMA API call-site inventory ---")
rx={a:re.compile(r"(?<![A-Za-z0-9_])"+re.escape(a)+r"\s*\(") for a in api}
calls={a:[] for a in api}
for label,p in source_files:
 try: lines=p.read_text(errors="replace").splitlines()
 except OSError as e:
  print("READ_ERROR %s %s"%(p,e)); continue
 for n,line in enumerate(lines,1):
  stripped=line.strip()
  if stripped.startswith(("//","*")): continue
  for a,pat in rx.items():
   if pat.search(line):
    calls[a].append((label,p,n,line.strip()))
for a in api:
 print("%s_TOTAL=%d"%(a,len(calls[a])))
 for label,p,n,line in calls[a]:
  print("  %s:%d | %s"%(rel(p),n,line[:300]))
print("\n--- RX ring source: allocation, map and initial device sync ---")
lines=pci.read_text(errors="replace").splitlines()
for term in ["dma_map_single","dma_sync_single_for_device","dma_sync_single_for_cpu","dma_unmap_single","dma_alloc_coherent","dma_free_coherent"]:
 idx=[i for i,l in enumerate(lines) if term in l]
 print("%s_OCCURRENCES=%d"%(term,len(idx)))
 for i in idx:
  # Report 20 lines before and 26 after each call; merge overlap lightly.
  show(pci,i+1-20,i+1+26,"pci.c around "+term+" at "+str(i+1))
print("\n--- PCI RX/TX descriptor and buffer ownership context ---")
terms=re.compile(r"rx_ring|RX_BUF|dma_addr_t|\.dma\b|->dma\b|rx_buf|rx_skb|skb_queue|struct rtw_pci")
hits=[]
for i,line in enumerate(lines):
 if terms.search(line): hits.append(i)
# Keep a bounded set of unique context windows, prioritizing RX and ring setup/release functions.
windows=[]
for i in hits:
 lo=max(0,i-5); hi=min(len(lines),i+8)
 if windows and lo<=windows[-1][1]+2: windows[-1]=(windows[-1][0],max(windows[-1][1],hi))
 else: windows.append((lo,hi))
print("PCI_DESCRIPTOR_CONTEXT_WINDOWS=%d"%len(windows))
for lo,hi in windows:
 show(pci,lo+1,hi,"pci.c RX/TX descriptor context")
print("\n--- DMA compatibility helper behavior ---")
show(dma,1,145,"dma-mapping.h")
print("\n--- Shared DMA callback implementation ---")
show(hw,1,150,"RTW88HwOps.cpp")
print("\n--- Native backend DMA allocation, bounce, sync and release ---")
blines=backend.read_text(errors="replace").splitlines()
for term in ["allocCoherent","freeCoherent","freeCoherentByPhys","setBounceOrigVA","syncBounceForCpu","drainPendingFree","releaseDMAEntries","freeDMAList"]:
 idx=[i for i,l in enumerate(blines) if term in l and ("::"+term in l or term+"(" in l)]
 for i in idx:
  show(backend,i+1-5,i+1+48,"RTW88WCLPCIBackend.cpp around "+term)
print("\n--- Compatibility runtime globals and lifecycle ---")
if compat.exists():
 clines=compat.read_text(errors="replace").splitlines()
 for i,line in enumerate(clines):
  if re.search(r"rtw88_dma_ops|rtw88_compat_init|rtw88_compat_exit",line):
   show(compat,i+1-8,i+1+18,"rtw88_compat.c global/runtime context")
print("\n--- DMA direction and semantic checks ---")
dtext=dma.read_text(errors="replace")
htext=hw.read_text(errors="replace")
btext=backend.read_text(errors="replace")
for name in ["DMA_FROM_DEVICE","DMA_TO_DEVICE","DMA_BIDIRECTIONAL"]:
 m=re.search(r"^#define\s+"+name+r"\s+(.+)$",dtext,re.M)
 print(name+"_VALUE="+(m.group(1).strip() if m else "NOT_FOUND"))
print("RX_DMA_MAP_CALLS="+str(sum(1 for label,p,n,line in calls["dma_map_single"] if p==pci and "DMA_FROM_DEVICE" in pci.read_text(errors="replace").splitlines()[n-1])))
print("DEVICE_SYNC_CALLS="+str(len(calls["dma_sync_single_for_device"])))
print("CPU_SYNC_CALLS="+str(len(calls["dma_sync_single_for_cpu"])))
print("UNMAP_CALLS="+str(len(calls["dma_unmap_single"])))
print("EMPTY_DEVICE_SYNC_CALLBACK="+str(bool(re.search(r"compat_dma_sync_dev\s*\([^)]*\)\s*\{\s*\}",htext,re.S))))
print("CPU_SYNC_USES_BOUNCE_COPY="+str("syncBounceForCpu" in htext))
print("NATIVE_BACKEND_USES_PHYSICAL_BUFFER_DESCRIPTOR="+str("IOBufferMemoryDescriptor::inTaskWithPhysicalMask" in btext))
print("NATIVE_BACKEND_DEVICE_SYNC_METHOD_PRESENT="+str(bool(re.search(r"syncBounceForDevice|sync.*ForDevice",btext,re.I))))
print("NOTE=Call-site counts are static references; they do not prove runtime execution or every control-flow path.")
print("\n--- RX DMA questions requiring resolution ---")
questions=[
 "Does every RX buffer receive a valid backend-created physical mapping before descriptors are published?",
 "Does the initial DMA_FROM_DEVICE device-sync require any copy, or only cache/device visibility?",
 "After RX completion, does sync-for-CPU copy only the completed length and use the matching buffer identity?",
 "Before the buffer is reposted, is a device-sync/cache operation required by this platform's DMA mapping contract?",
 "Are map failure, partial ring allocation and teardown paths paired with exactly one unmap/free?",
 "Can IRQ, NAPI/poll and reset/removal paths race the DMA entry list or bounce original pointer?",
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
 echo "--- End Stage 35K ---"
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
printf 'STAGE: 35K\nRUN: %s\nPURPOSE: RX DMA allocation/map/sync/reuse/unmap lifecycle\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage35k/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage35K RX DMA lifecycle audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35k/$RUN/manifest.txt" "Add Stage35K manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35K_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35K_RUN=$RUN"
echo "STAGE35K_REPORT_PARTS=$COUNT"
echo "STAGE35K_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35k/$RUN"
