#!/bin/bash
# Stage 35I — trace native controller -> PCI backend -> RTW88 core -> DMA callbacks.
# Read-only source/artifact inspection. No build, install, load, or OpenCore edits.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage35I-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; echo "STAGE35I_ERROR=exit:$rc line:$LINENO" >&2; [[ -f "$UPLOAD_ERROR" ]] && tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR

for tool in gh python3 shasum split nm file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -d "$SRC/src/kext/wcl24h32" ]] || { echo "ERROR: expected Stage26 WCL source folder missing"; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated. Run gh auth login."; exit 4; }

{
 echo "========== STAGE 35I: NATIVE BACKEND / DMA INITIALIZATION TRACE =========="
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "host=$(hostname 2>/dev/null || echo unknown)"
 echo "source_root=$SOURCE_ROOT"
 echo "mode=read-only source and existing artifact inspection"
 echo
} > "$REPORT"

python3 - "$SRC" "$OUT" >> "$REPORT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
src,out=map(pathlib.Path,sys.argv[1:])
files=[
 "Makefile",
 "src/kext/RTW88HwOps.cpp",
 "src/kext/RTW88HwOps.hpp",
 "src/kext/RTW88IEEE80211.cpp",
 "src/kext/RTW88IEEE80211.hpp",
 "src/kext/RTL88WiFi.cpp",
 "src/kext/RTL88WiFi.hpp",
 "src/kext/wcl24h32/RTW88WCLController.cpp",
 "src/kext/wcl24h32/RTW88WCLController.hpp",
 "src/kext/wcl24h32/RTW88WCLPCIBackend.cpp",
 "src/kext/wcl24h32/RTW88WCLPCIBackend.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/compat/linux/dma-mapping.h",
 "src/compat/linux/pci.h",
]
print("--- Source snapshots ---")
for rel in files:
 p=src/rel
 if not p.exists():
  print("MISSING_SOURCE="+rel); continue
 raw=p.read_bytes()
 print("SOURCE path=%s bytes=%d sha256=%s"%(rel,len(raw),hashlib.sha256(raw).hexdigest()))
print("\n--- Lifecycle and DMA function map (line-numbered matches) ---")
rx=re.compile(r"\b(start|stop|free|teardown|init|probe|attach|detach|create|setupInterrupt|handleInterrupt|allocate|deallocate|allocCoherent|freeCoherent|map_single|unmap_single|sync_single|set_dma_ops|dma_set_mask|dma_alloc_coherent|dma_map_single|dma_unmap_single|rtw88_dma_ops|_dma_ops|RTW88IEEE80211::create|RTW88IEEE80211::init)\b|rtw88_dma_ops|_dma_ops")
for rel in files:
 p=src/rel
 if not p.is_file() or p.suffix not in {".cpp",".hpp",".h"}: continue
 lines=p.read_text(errors="replace").splitlines()
 for n,line in enumerate(lines,1):
  if rx.search(line):
   print("%s:%d:%s"%(rel,n,line.strip()[:320]))
print("\n--- Native-to-legacy coupling references ---")
refs=("RTW88PCIDevice","RTW88IEEE80211::create","RTW88IEEE80211::init","rtw88_dma_ops","_dma_ops","g_pci_dev_instance")
for rel in files:
 p=src/rel
 if not p.is_file() or p.suffix not in {".cpp",".hpp",".h"}: continue
 lines=p.read_text(errors="replace").splitlines()
 for n,line in enumerate(lines,1):
  if any(x in line for x in refs):
   print("%s:%d:%s"%(rel,n,line.strip()[:360]))
print("\n--- Critical source excerpts ---")
ranges={
 "src/kext/RTW88HwOps.cpp":[(1,230)],
 "src/kext/RTW88IEEE80211.cpp":[(1,35),(520,660)],
 "src/kext/wcl24h32/RTW88WCLController.cpp":[(1,260),(260,520)],
 "src/kext/wcl24h32/RTW88WCLPCIBackend.cpp":[(1,310),(310,540)],
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":[(1,260)],
 "src/compat/linux/dma-mapping.h":[(1,170)],
 "src/kext/RTL88WiFi.cpp":[(220,275),(480,535),(760,815)],
}
for rel,spans in ranges.items():
 p=src/rel
 print("\n### "+rel)
 if not p.exists(): print("MISSING"); continue
 lines=p.read_text(errors="replace").splitlines()
 for lo,hi in spans:
  if lo>len(lines): continue
  print("[lines %d-%d]"%(lo,min(hi,len(lines))))
  for n in range(lo,min(hi,len(lines))+1):
   print("%4d %s"%(n,lines[n-1]))
print("\n--- Makefile native and legacy source/object lists ---")
mk=(src/"Makefile").read_text(errors="replace").splitlines()
for n,line in enumerate(mk,1):
 if any(x in line for x in ("KEXT_SRCS :=","AIRPORT_KEXT_SRCS :=","AIRPORT_KEXT_OBJS :=","NATIVE_CORE_SRCS :=","NATIVE_CORE_OBJS :=","NATIVE_ALL_OBJS :=","WCL24H32_PCI_BACKEND_OBJ :=","rtl88wifi-native:","NATIVE_OUT_BIN):")):
  print("%d:%s"%(n,line.strip()))
print("\n--- Existing object and binary symbol audit (may be stale) ---")
artifacts=[
 "build/native/RTW88IEEE80211.o",
 "build/native/RTW88HwOps.o",
 "build/wcl24h32/RTW88WCLController.o",
 "build/wcl24h32/RTW88WCLPCIBackend.o",
 "build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative",
]
for rel in artifacts:
 p=src/rel
 print("ARTIFACT path=%s exists=%s"%(rel,p.exists()))
 if not p.exists(): continue
 raw=p.read_bytes(); st=p.stat()
 print(" bytes=%d mtime_epoch=%d sha256=%s"%(len(raw),int(st.st_mtime),hashlib.sha256(raw).hexdigest()))
 try:
  fr=subprocess.run(["file",str(p)],capture_output=True,text=True,timeout=10)
  print(" file="+(fr.stdout.strip() or fr.stderr.strip()))
 except Exception as e: print(" file_error="+str(e))
 try:
  nm=subprocess.run(["nm","-u",str(p)],capture_output=True,text=True,timeout=25)
  print(" nm_undefined_exit=%d"%nm.returncode)
  selected=[x for x in nm.stdout.splitlines() if re.search(r"RTW88PCIDevice|RTW88IEEE80211|dma_ops|rtw88_dma|pci_io|IOInterruptEventSource|RTW88WCL",x,re.I)]
  print(" selected_undefined_symbol_count=%d"%len(selected))
  for x in selected[:250]: print(" U "+x[:400])
  if nm.returncode: print(" nm_error="+nm.stderr[:800])
 except Exception as e: print(" nm_error="+str(e))
 try:
  nm=subprocess.run(["nm","-g",str(p)],capture_output=True,text=True,timeout=25)
  selected=[x for x in nm.stdout.splitlines() if re.search(r"RTW88PCIDevice|RTW88IEEE80211|dma_ops|rtw88_dma|pci_io|RTW88WCL",x,re.I)]
  print(" selected_defined_or_global_symbol_count=%d"%len(selected))
  for x in selected[:250]: print(" G "+x[:400])
 except Exception as e: print(" nm_global_error="+str(e))
print("\n--- Safety boundary ---")
print("SOURCE_TREE_MODIFIED=NO")
print("BUILD=NOT_RUN")
print("INSTALL=NOT_RUN")
print("LOAD=NOT_RUN")
print("OPENCORE_MODIFIED=NO")
PY

{
 echo
 echo "--- End Stage 35I ---"
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
printf 'STAGE: 35I\nRUN: %s\nPURPOSE: native controller PCI DMA initialization trace\n' "$RUN" >"$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage35i/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage35I native backend DMA trace $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c <"$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >>"$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage35i/$RUN/manifest.txt" "Add Stage35I manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE35I_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE35I_RUN=$RUN"
echo "STAGE35I_REPORT_PARTS=$COUNT"
echo "STAGE35I_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage35i/$RUN"
