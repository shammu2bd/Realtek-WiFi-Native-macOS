#!/bin/bash
# Stage 38 — address-bounded disassembly of exact 24H32 Skywalk methods.
# VERSION_MARKER: STAGE38_V1_20261102
# READ ONLY: no source edits, build, signing, install, Kext load or OpenCore changes.
set -Eeuo pipefail
echo "STAGE38_SCRIPT_VERSION=1"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage38-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
NMLOG="$OUT/boot-kc-nm.txt"
SYMBOLS="$OUT/defined-symbols.tsv"
mkdir -p "$OUT"
trap 'rc=$?; trap - ERR; echo "STAGE38_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

for tool in gh python3 shasum split grep awk nm otool file sw_vers uname xcrun kmutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 project not found"; exit 3; }
[[ -f "$BOOTKC" ]] || { echo "ERROR: BootKernelExtensions.kc not found at $BOOTKC"; exit 4; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 5; }

BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
if [[ -z "$OBJDUMP" || ! -x "$OBJDUMP" ]]; then
  OBJDUMP="$(command -v llvm-objdump 2>/dev/null || true)"
fi

{
 echo "========== STAGE 38: SKYWALK METHOD DISASSEMBLY AUDIT =========="
 echo "script_version=STAGE38_V1_20261102"
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "product_version=$OSVER"
 echo "build_version=$BUILD"
 echo "architecture=$ARCH"
 echo "source_root=$SOURCE_ROOT"
 echo "boot_kernel_collection=$BOOTKC"
 echo "llvm_objdump=${OBJDUMP:-NOT_FOUND}"
 echo "mode=read-only address-bounded x86_64 Mach-O disassembly"
 echo "PREDECESSOR=Stage37 run-20261102-022215"
 echo
 if [[ "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
   echo "WARNING: host differs from target 24H32 x86_64; treat disassembly as provisional."
 fi
} > "$REPORT"

# Keep source continuity guard in the report; this stage does not edit the tree.
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
for rel,want in expected.items():
 p=src/rel
 got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 ok=got==want
 print("SOURCE_FINGERPRINT_%s=%s"%( "MATCH" if ok else "DIFF",rel))
 if not ok:bad.append(rel)
print("AUDITED_SOURCE_FINGERPRINTS=%d"%len(expected))
print("SOURCE_FINGERPRINT_CONTINUITY="+("PASS" if not bad else "REVIEW_REQUIRED"))
PY

nm -arch x86_64 -m "$BOOTKC" > "$NMLOG" 2>&1
python3 - "$NMLOG" "$SYMBOLS" <<'PY'
import pathlib,re,sys
nm=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
out=pathlib.Path(sys.argv[2])
wanted={
"initRegistrationInfo":"__ZN26IOSkywalkEthernetInterface20initRegistrationInfoEPNS_16RegistrationInfoEjm",
"registerEthernetInterface.queue_array":"__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j",
"registerEthernetInterface.logical_link":"__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS7_j",
"deregisterEthernetInterface":"__ZN26IOSkywalkEthernetInterface27deregisterEthernetInterfaceEj",
"IO80211InfraInterface.registerInfraEthernetInterface":"__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_",
}
rows=[]
for label,sym in wanted.items():
 matches=[line.strip() for line in nm if sym in line]
 defined=[]
 for line in matches:
  if "(undefined)" in line or "dynamically looked up" in line:continue
  m=re.match(r"^([0-9a-fA-F]+)\s+\(__(?:TEXT|DATA),__[^)]+\)\s+.*?\s(\S+)$",line)
  if m:
   defined.append((int(m.group(1),16),line))
 for addr,line in defined:
  rows.append((label,addr,sym,line))
 if not defined:
  print("NO_DEFINITION:"+label,file=sys.stderr)
rows.sort(key=lambda x:x[1])
out.write_text("".join("%s\t%x\t%s\t%s\n"%(a,b,c,d) for a,b,c,d in rows))
if not rows:
 raise SystemExit("No exact defined 24H32 Skywalk method symbols recovered")
PY

{
 echo
 echo "--- Exact definitions recovered from BootKernelExtensions.kc ---"
 echo "NM_OUTPUT_BYTES=$(wc -c < "$NMLOG" | tr -d ' ')"
 cat "$SYMBOLS"
 echo
 echo "--- Bounded instruction disassembly ---"
 if [[ -z "$OBJDUMP" || ! -x "$OBJDUMP" ]]; then
   echo "LLVM_OBJDUMP=NOT_FOUND"
   echo "OTool fallback will still be attempted by symbol name."
 fi
} >> "$REPORT"

while IFS=$'\t' read -r label addr mangled nmline; do
 [[ -n "$label" ]] || continue
 # Use a bounded 0x180-byte window to avoid dumping entire kernel text.
 STOP="$(python3 - "$addr" <<'PY'
import sys
print("%x"%(int(sys.argv[1],16)+0x180))
PY
)"
 SAFE="$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_')"
 DISLOG="$OUT/disasm-$SAFE.txt"
 OBJDUMP_RC=127
 if [[ -n "$OBJDUMP" && -x "$OBJDUMP" ]]; then
   set +e
   "$OBJDUMP" --macho --arch=x86_64 --disassemble --demangle \
      --full-leading-addr --start-address="0x$addr" --stop-address="0x$STOP" \
      "$BOOTKC" > "$DISLOG" 2>&1
   OBJDUMP_RC=$?
   set -e
 fi
 OTOOLLOG="$OUT/otool-$SAFE.txt"
 set +e
 otool -arch x86_64 -p "$mangled" -tV "$BOOTKC" > "$OTOOLLOG" 2>&1
 OTOOL_RC=$?
 set -e

 INSTRUCTIONS="$(python3 - "$DISLOG" "$OTOOLLOG" <<'PY'
import pathlib,re,sys
total=0
for f in sys.argv[1:]:
 p=pathlib.Path(f)
 if not p.is_file():continue
 lines=p.read_text(errors="replace").splitlines()
 total+=sum(bool(re.match(r"^\s*(?:0x)?[0-9a-fA-F]{8,16}:?\s+(?:[0-9a-fA-F]{2,8}\s+)+[a-zA-Z]",x)) for x in lines)
print(total)
PY
)"
 {
  echo
  echo "=== METHOD $label ==="
  echo "MANGLED=$mangled"
  echo "NM_DEFINITION=$nmline"
  echo "START_ADDRESS=0x$addr"
  echo "STOP_ADDRESS=0x$STOP"
  echo "LLVM_OBJDUMP_EXIT=$OBJDUMP_RC"
  echo "OTOOL_EXIT=$OTOOL_RC"
  echo "DETECTED_INSTRUCTION_LINES=$INSTRUCTIONS"
  echo "--- llvm-objdump output ---"
  if [[ -f "$DISLOG" ]]; then head -260 "$DISLOG"; fi
  echo "--- otool output ---"
  if [[ -f "$OTOOLLOG" ]]; then head -100 "$OTOOLLOG"; fi
 } >> "$REPORT"
done < "$SYMBOLS"

{
 echo
 echo "--- Runtime context ---"
 kmutil showloaded --list-only 2>&1 | grep -E -i 'IO80211Family|IOSkywalkFamily|IONetworkingFamily' | head -80 || true
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
 echo "========== END STAGE 38 =========="
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
v=json.load(open(sys.argv[1]));s=(v.get("content") or {}).get("sha")
if not s:raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
 got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
 [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >> "$UPLOAD_ERROR";return 1; }
 UPLOAD_SHA="$got"
}
MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 38\nRUN: %s\nPURPOSE: bounded disassembly of exact 24H32 Skywalk methods\nBUILD: NOT_RUN\nSOURCE_MODIFIED: NO\n' "$RUN" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage38/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage38 disassembly report $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage38/$RUN/manifest.txt" "Add Stage38 manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE38_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE38_RUN=$RUN"
echo "STAGE38_REPORT_PARTS=$COUNT"
echo "STAGE38_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage38/$RUN"
