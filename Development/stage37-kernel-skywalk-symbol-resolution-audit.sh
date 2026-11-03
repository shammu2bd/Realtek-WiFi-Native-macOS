#!/bin/bash
# Stage 37 — resolve 24H32 Skywalk method definitions across the installed kernel and KCs.
# VERSION_MARKER: STAGE37_V1_20261102
# READ ONLY: no driver source edits, build, signing, install, load, or OpenCore changes.
set -Eeuo pipefail
echo "STAGE37_SCRIPT_VERSION=1"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage37-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
CANDIDATES="$OUT/binary-candidates.txt"
mkdir -p "$OUT"
trap 'rc=$?; trap - ERR; echo "STAGE37_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

for tool in gh python3 shasum split find grep awk nm otool strings file sw_vers uname kmutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 project Makefile missing"; exit 3; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 4; }

BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
{
 echo "========== STAGE 37: KERNEL / SKYWALK SYMBOL RESOLUTION =========="
 echo "script_version=STAGE37_V1_20261102"
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "product_version=$OSVER"
 echo "build_version=$BUILD"
 echo "architecture=$ARCH"
 echo "source_root=$SOURCE_ROOT"
 echo "mode=read-only installed kernel and kernel collection symbol inspection"
 echo "PREDECESSOR=Stage36 run-20261102-021830"
 if [[ "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
   echo "WARNING: running host differs from pinned target; treat binary conclusions as provisional."
 fi
 echo
} > "$REPORT"

python3 - "$SRC" <<'PY' >> "$REPORT"
import hashlib,pathlib,sys
src=pathlib.Path(sys.argv[1])
expected={
"src/kext/RTW88WCLWorkQueue.cpp":"6ded9d08bf1e91aa26b393c9a8bea990ca8f64196f36a0553109ed61829d29e7",
"src/kext/RTW88WCLWorkQueue.hpp":"5cad32ee1bae3b40596a5757973689e2efa188347be753238ca44cb8583db41c",
"src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
"src/kext/wcl24h32/RTW88WCLController.cpp":"2c67658a50b40ec65cc400fbc7f13295d054e95a039aaf7060a65457c6087059",
"src/kext/wcl24h32/RTW88WCLController.hpp":"740115d9d5db50517d365e523174c17385c587eaabd45bafbeba2521edacb6ee",
"src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"20f8fcf3be99c797a28df29612a765a1b6d362dbc032e6045a7113d7f2ec82e1",
"src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4",
"src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp":"c9fcc397927c0c0dbb8b034f264b34d13eb5fd77db5470e105ab068ebc89082d",
"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp":"9ee96d066731bad2844daaae2a117b77fc6b140de7601f1fe4797256a33014fd",
"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp":"78af90d3d96c84afa83ae5aa04604d0d442f3055cbf505f2144bcaa197c213d0",
"src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp":"e1a66ffeaba3d71f4c4ef4ca5d0068de146a11cd8d98ea825920b45ce5079b7d",
"src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp":"6d97498a2a4a581be48607cab7de7c53bcc98c62c27a8c440ddfdcd0cac1e9da",
}
bad=[]
print("--- Source continuity ---")
for rel,want in expected.items():
 p=src/rel
 if not p.is_file():
  print("SOURCE_MISSING="+rel);bad.append(rel);continue
 got=hashlib.sha256(p.read_bytes()).hexdigest()
 ok=got==want
 print("SOURCE_FINGERPRINT_%s=%s"%( "MATCH" if ok else "DIFF",rel))
 if not ok: bad.append(rel)
print("AUDITED_SOURCE_FINGERPRINTS=%d"%len(expected))
print("SOURCE_FINGERPRINT_CONTINUITY="+("PASS" if not bad else "REVIEW_REQUIRED"))
PY

: > "$CANDIDATES"
for root in /System/Library/Kernels /System/Library/KernelCollections /System/Library/PrelinkedKernels; do
 [[ -d "$root" ]] || continue
 find "$root" -maxdepth 5 -type f \( -name 'kernel' -o -name 'kernel.*' -o -name 'prelinkedkernel' -o -name '*.kc' \) -print 2>/dev/null >> "$CANDIDATES" || true
done
sort -u "$CANDIDATES" -o "$CANDIDATES"

# C++ mangled names are exact evidence keys; all nm occurrences are classified
# as definitions or imports instead of selecting arbitrary trailing tokens.
python3 - "$CANDIDATES" "$OUT" "$REPORT" <<'PY' >> "$REPORT"
import pathlib,subprocess,sys,os
candidate_file,out,report=map(pathlib.Path,sys.argv[1:])
symbols={
"initRegistrationInfo":"__ZN26IOSkywalkEthernetInterface20initRegistrationInfoEPNS_16RegistrationInfoEjm",
"registerEthernetInterface.queue_array":"__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j",
"registerEthernetInterface.logical_link":"__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS7_j",
"deregisterEthernetInterface":"__ZN26IOSkywalkEthernetInterface27deregisterEthernetInterfaceEj",
"IO80211InfraInterface.registerInfraEthernetInterface":"__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_",
}
candidates=[pathlib.Path(x) for x in candidate_file.read_text().splitlines() if x]
print("--- Kernel and KernelCollection candidates ---")
print("BINARY_CANDIDATE_COUNT=%d"%len(candidates))
rows=[]
for n,p in enumerate(candidates,1):
 try:
  info=subprocess.run(["file",str(p)],text=True,capture_output=True).stdout.strip()
 except Exception as e:
  print("FILE_INFO_ERROR=%s:%s"%(p,e));continue
 if "Mach-O" not in info or "x86_64" not in info:
  continue
 print("BINARY_CANDIDATE=%s"%p)
 print("BINARY_FILE=%s"%info)
 nmout=out/("nm-exact-%d.txt"%n)
 proc=subprocess.run(["nm","-arch","x86_64","-m",str(p)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 nmout.write_text(proc.stdout)
 print("NM_EXIT=%d NM_BYTES=%d"%(proc.returncode,len(proc.stdout)))
 for label,mangled in symbols.items():
  matches=[line.strip() for line in proc.stdout.splitlines() if mangled in line]
  if not matches:
   print("SYMBOL_%s=NOT_FOUND_IN_THIS_BINARY"%label)
   continue
  for j,line in enumerate(matches[:8],1):
   undefined="(undefined)" in line or "dynamically looked up" in line
   state="IMPORT_OR_UNRESOLVED" if undefined else "DEFINED_OR_LOCAL"
   print("SYMBOL_%s_%d=%s | %s"%(label,j,state,line[:1000]))
   if not undefined:
    rows.append((label,mangled,p,n,line))
print("--- Targeted disassembly of defined methods only ---")
for label,mangled,p,n,line in rows:
 safe="".join(c if c.isalnum() else "_" for c in label)
 dst=out/("disasm-%d-%s.txt"%(n,safe))
 # nm prints two leading underscores for Itanium C++ symbols on Darwin.
 sym=mangled
 proc=subprocess.run(["otool","-arch","x86_64","-tvV","-p",sym,str(p)],
                     text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 dst.write_text(proc.stdout)
 body=[x for x in proc.stdout.splitlines() if x.strip() and "section" not in x and p.name not in x]
 print("DISASM_%s_EXIT=%d BYTES=%d INSTRUCTION_LINES=%d"%(label,proc.returncode,len(proc.stdout),len(body)))
 for x in proc.stdout.splitlines()[:140]: print(x)
if not rows:
 print("NO_EXACT_SKYWALK_METHOD_DEFINITIONS_FOUND_IN_SCANNED_KERNEL_IMAGES=YES")
PY

{
 echo
 echo "--- Loaded system networking families ---"
 kmutil showloaded --list-only 2>&1 | grep -E -i 'IO80211Family|IOSkywalkFamily|IONetworkingFamily' | head -80 || true
 echo
 echo "--- Previous Stage36 evidence requiring resolution ---"
 echo "STAGE36_FOUND_REGISTER_INFRA_WRAPPER_DEFINED_IN_BOOT_KC=YES"
 echo "STAGE36_FOUND_REGISTER_ETHERNET_INTERFACE_AS_DYNAMIC_IMPORT=YES"
 echo "STAGE36_FOUND_INIT_REGISTRATION_INFO_AS_DYNAMIC_IMPORT=YES"
 echo "STAGE36_DEREGISTER_DISASSEMBLY_WAS_NOT_VALIDATED=YES"
 echo
 echo "--- Safety boundary ---"
 echo "SOURCE_TREE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "CODESIGN=NOT_RUN"
 echo "KEXT_INSTALL=NOT_RUN"
 echo "KEXT_LOAD=NOT_RUN"
 echo "OPENCORE_MODIFIED=NO"
 echo "HARDWARE_TEST=NOT_RUN"
 echo "IMPLEMENTATION_AUTHORIZED_BY_THIS_STAGE=NO"
 echo "========== END STAGE 37 =========="
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
  echo "UPLOAD_FAILED_PATH=$path" >> "$UPLOAD_ERROR";return 1
 fi
 put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s:raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >> "$UPLOAD_ERROR";return 1; }
 UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 37\nRUN: %s\nPURPOSE: exact kernel and kernel-collection Skywalk symbol resolution\nBUILD: NOT_RUN\nSOURCE_MODIFIED: NO\n' "$RUN" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage37/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage37 kernel symbol report $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage37/$RUN/manifest.txt" "Add Stage37 manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE37_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE37_RUN=$RUN"
echo "STAGE37_REPORT_PARTS=$COUNT"
echo "STAGE37_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage37/$RUN"
