#!/bin/bash
# Stage 36 — read-only 24H32 Skywalk registration and callback ABI evidence audit.
# VERSION_MARKER: STAGE36_V2_20261102
# No source edits, build, signing, installation, Kext load, or OpenCore changes.
set -Eeuo pipefail
echo "STAGE36_SCRIPT_VERSION=2"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
ABI="$SRC/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$HOME/Downloads/Stage36-$RUN"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$OUT"
trap 'rc=$?; trap - ERR; echo "STAGE36_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

for tool in gh python3 shasum split find grep awk nm otool strings file sw_vers uname xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 project Makefile missing: $SRC/Makefile"; exit 3; }
[[ -f "$ABI" ]] || { echo "ERROR: 24H32 ABI source missing"; exit 4; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 5; }

DEVELOPER_DIR="/Applications/Xcode_16.4.app/Contents/Developer"
[[ -d "$DEVELOPER_DIR" ]] || DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "$DEVELOPER_DIR" ]]; then export DEVELOPER_DIR; fi
SDKROOT="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"

{
  echo "========== STAGE 36: 24H32 SKYWALK REGISTRATION / CALLBACK ABI AUDIT =========="
  echo "script_version=STAGE36_V2_20261102"
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "product_version=$OSVER"
  echo "build_version=$BUILD"
  echo "architecture=$ARCH"
  echo "source_root=$SOURCE_ROOT"
  echo "developer_dir=${DEVELOPER_DIR:-NOT_FOUND}"
  echo "sdkroot=${SDKROOT:-NOT_FOUND}"
  echo "mode=read-only source + local kernel collection / kext symbol inspection"
  echo
  if [[ "$BUILD" != "24H32" ]]; then
    echo "WARNING: host build is not the pinned 24H32 build; binary conclusions must not be treated as target ABI evidence."
  fi
  if [[ "$ARCH" != "x86_64" ]]; then
    echo "WARNING: host architecture is not x86_64; Intel Hackintosh ABI inspection may be incomplete."
  fi
} > "$REPORT"

# Compare project fingerprints to Stage 35Q's audited tree. Only the ABI header
# should differ because Stage 35X2 added a narrowly scoped diagnostic pragma.
python3 - "$SRC" "$REPORT" <<'PY' >> "$REPORT"
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
print("--- Source fingerprint continuity from Stage35Q / Stage35X2 ---")
for rel,want in expected.items():
    p=src/rel
    if not p.is_file():
        print("SOURCE_MISSING=%s"%rel); bad.append(rel); continue
    got=hashlib.sha256(p.read_bytes()).hexdigest()
    state="MATCH" if got==want else "DIFF"
    print("SOURCE_FINGERPRINT_%s=%s expected=%s actual=%s"%(state,rel,want,got))
    if state!="MATCH": bad.append(rel)
print("AUDITED_SOURCE_FINGERPRINTS=%d"%len(expected))
print("SOURCE_FINGERPRINT_CONTINUITY="+("PASS" if not bad else "REVIEW_REQUIRED"))
PY

# Capture source declarations and live implementation seams without editing files.
python3 - "$SRC" <<'PY' >> "$REPORT"
import pathlib,sys
src=pathlib.Path(sys.argv[1])
ranges={
"src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":[(300,345),(390,465)],
"src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp":[(1,120)],
"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp":[(1,90)],
"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp":[(1,220)],
"src/kext/wcl24h32/RTW88WCLController.cpp":[(45,180),(185,265)],
"src/kext/wcl24h32/RTW88WCLController.hpp":[(20,125)],
"src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":[(220,310)],
"src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":[(250,290)],
"src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp":[(1,205)],
"src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp":[(1,95)],
"src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp":[(1,220)],
"src/kext/RTW88WCLWorkQueue.cpp":[(110,175)],
}
print("--- Focused source contract excerpts (line-numbered) ---")
for rel,spans in ranges.items():
    p=src/rel
    print("\n=== SOURCE %s exists=%s ==="%(rel,p.is_file()))
    if not p.is_file(): continue
    lines=p.read_text(errors="replace").splitlines()
    for lo,hi in spans:
        print("[lines %d-%d]"%(lo,min(hi,len(lines))))
        for i in range(lo-1,min(hi,len(lines))):
            print("%5d %s"%(i+1,lines[i]))
PY

# Identify local kernel collections and the family binaries if present.
CANDIDATES="$OUT/binary-candidates.txt"
: > "$CANDIDATES"
for root in \
  /System/Library/KernelCollections \
  /Library/Apple/System/Library/KernelCollections \
  /System/Library/Extensions \
  /Library/Apple/System/Library/Extensions; do
  [[ -d "$root" ]] || continue
  find "$root" -maxdepth 6 \( \
    -name 'BootKernelExtensions.kc' -o \
    -name 'SystemKernelExtensions.kc' -o \
    -name 'AuxiliaryKernelExtensions.kc' -o \
    -name 'IO80211Family' -o \
    -name 'IOSkywalkFamily' -o \
    -name 'IONetworkingFamily' \
  \) -type f -print 2>/dev/null >> "$CANDIDATES" || true
done
sort -u "$CANDIDATES" -o "$CANDIDATES"

{
  echo
  echo "--- Local kernel collection / networking family binary candidates ---"
  echo "BINARY_CANDIDATE_COUNT=$(wc -l < "$CANDIDATES" | tr -d ' ')"
  while IFS= read -r binary; do
    [[ -n "$binary" ]] || continue
    echo "BINARY_CANDIDATE=$binary"
    file "$binary" 2>&1 || true
    ls -ln "$binary" 2>&1 | awk '{print "BINARY_SIZE_BYTES="$5}'
  done < "$CANDIDATES"
} >> "$REPORT"

# Attempt symbol table inspection and narrow disassembly for exact ABI methods.
# Kernel collections may be stripped or unsupported by nm/otool; failures are
# recorded rather than interpreted as evidence that a method does not exist.
INDEX=0
while IFS= read -r binary; do
  [[ -n "$binary" ]] || continue
  INDEX=$((INDEX+1))
  NMLOG="$OUT/nm-$INDEX.txt"
  STRLOG="$OUT/strings-$INDEX.txt"
  nm -arch x86_64 -m "$binary" > "$NMLOG" 2>&1 || true
  strings -a "$binary" 2>/dev/null | grep -E -i \
    'registerEthernetInterface|deregisterEthernetInterface|initRegistrationInfo|createSkywalkInterface|IOSkywalk(Ethernet|Network)Interface|TxSubmissionQueue|TxCompletionQueue|RxSubmissionQueue|RxCompletionQueue' \
    | head -160 > "$STRLOG" || true
  {
    echo
    echo "--- Binary symbol/string evidence index=$INDEX path=$binary ---"
    echo "NM_OUTPUT_BYTES=$(wc -c < "$NMLOG" | tr -d ' ')"
    echo "NM_RELEVANT_SYMBOLS:"
    grep -E -i 'registerEthernetInterface|deregisterEthernetInterface|initRegistrationInfo|createSkywalkInterface|IOSkywalk(Ethernet|Network)Interface' "$NMLOG" | head -120 || true
    echo "STRINGS_RELEVANT:"
    cat "$STRLOG"
  } >> "$REPORT"

  for method in registerEthernetInterface deregisterEthernetInterface initRegistrationInfo; do
    symbol="$(awk -v method="$method" 'index($0, method) { print $NF; exit }' "$NMLOG" | sed 's/^_//')"
    [[ -n "$symbol" ]] || continue
    DISLOG="$OUT/disasm-$INDEX-$method.txt"
    otool -arch x86_64 -tvV -p "_$symbol" "$binary" > "$DISLOG" 2>&1 || \
      otool -arch x86_64 -tvV -p "$symbol" "$binary" > "$DISLOG" 2>&1 || true
    {
      echo
      echo "--- Narrow disassembly candidate: $method symbol=$symbol ---"
      head -180 "$DISLOG"
    } >> "$REPORT"
  done
done < "$CANDIDATES"

{
  echo
  echo "--- Loaded kernel extensions / OS bundle presence ---"
  if command -v kmutil >/dev/null 2>&1; then
    kmutil showloaded --list-only 2>&1 | grep -E -i 'IO80211|Skywalk|IONetworking|com\.apple\.iokit' | head -100 || true
  else
    echo "KMUTIL_NOT_FOUND=YES"
  fi
  echo
  echo "--- Registration and packet-path gate audit ---"
  python3 - "$SRC" <<'PY'
import pathlib,re,sys
src=pathlib.Path(sys.argv[1])
def read(rel):
    p=src/rel
    return p.read_text(errors="replace") if p.is_file() else ""
abi=read("src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp")
queues=read("src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp")
controller=read("src/kext/wcl24h32/RTW88WCLController.cpp")
controller_h=read("src/kext/wcl24h32/RTW88WCLController.hpp")
infra=read("src/kext/wcl24h32/RTW88WCLInfraInterface.cpp")
reg=read("src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp")
adapter=read("src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp")
checks={
 "EXACT_INIT_REGISTRATION_INFO_SIGNATURE_PRESENT": "bool initRegistrationInfo(RegistrationInfo *, unsigned int, size_t)" in abi,
 "EXACT_QUEUE_ARRAY_REGISTRATION_OVERLOAD_PRESENT": "registerEthernetInterface(RegistrationInfo const *, IOSkywalkPacketQueue **," in abi,
 "EXACT_LOGICAL_LINK_REGISTRATION_OVERLOAD_PRESENT": "registerEthernetInterface(RegistrationInfo const *, IOSkywalkLogicalLink *," in abi,
 "DEREGISTER_ENTRYPOINT_PRESENT": "IOReturn deregisterEthernetInterface(unsigned int)" in abi,
 "REGISTRATION_INFO_PREPARE_CALLS_KERNEL_INIT": "initRegistrationInfo(info, 1, sizeof(_registrationInfo.bytes))" in infra,
 "REGISTRATION_INFO_BUILDER_NOT_CALLED_FROM_START": "prepareRegistrationInfo(" not in infra[infra.find("bool RTW88WCLInfraInterface::start"):infra.find("void RTW88WCLInfraInterface::stop")],
 "CONTROLLER_CURRENTLY_FAILS_PUBLICATION_CLOSED": "refusing publication until Skywalk datapath is ready" in controller,
 "CONTROLLER_CALLS_REGISTER_ETHERNET_INTERFACE": "registerEthernetInterface(" in controller,
 "FOUR_QUEUE_CALLBACKS_STILL_FAIL_CLOSED": all(re.search(r"\b"+n+r"\b[\s\S]{0,900}return static_cast<IOReturn>\(0\)",queues) for n in ["txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"]),
 "CONTROLLER_OWNS_TX_ADAPTER": "RTW88WCLSkywalkTxAdapter" in controller_h,
 "CONTROLLER_DRAINS_TX_COMPLETIONS": "drainCompletions(" in controller,
 "TX_COMPLETION_CALLBACK_SIGNALS_DEFERRED_WORK": any(x in adapter for x in ["signalWorkAvailable","thread_call_enter","runAction","queue_work","schedule_work"]),
 "REGISTRATION_INFO_USES_OPAQUE_0x130_BYTES": "constexpr size_t kSize = 0x130" in reg,
}
for k,v in checks.items(): print(k+"="+("YES" if v else "NO"))
print("QUEUE_REGISTRATION_API_IS_PRESENT_BUT_NOT_PROVEN_CALLABLE=YES")
print("PRIVATE_ARGUMENT_SEMANTICS_REQUIRE_BINARY_OR_AUTHORITATIVE_ABI_EVIDENCE=YES")
PY
  echo
  echo "--- Safety and conclusion boundary ---"
  echo "SOURCE_TREE_MODIFIED=NO"
  echo "COMPILE_OR_LINK_ATTEMPT=NOT_RUN"
  echo "CODESIGN=NOT_RUN"
  echo "KEXT_INSTALL=NOT_RUN"
  echo "KEXT_LOAD=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "HARDWARE_TEST=NOT_RUN"
  echo "IMPLEMENTATION_AUTHORIZED_BY_THIS_STAGE=NO"
  echo "========== END STAGE 36 =========="
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
if sha: v["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(v))
PY2
  if ! gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" >"$response" 2>"$UPLOAD_ERROR"; then
    echo "UPLOAD_FAILED_PATH=$path" >> "$UPLOAD_ERROR"; return 1
  fi
  put="$(python3 - "$response" <<'PY2'
import json,sys
v=json.load(open(sys.argv[1])); s=(v.get("content") or {}).get("sha")
if not s: raise SystemExit("Missing returned blob SHA")
print(s)
PY2
)"
  got="$(gh api "repos/$REPO/contents/$path" --jq .sha)"
  [[ "$put" == "$got" ]] || { echo "READBACK_SHA_MISMATCH=$path put=$put got=$got" >> "$UPLOAD_ERROR"; return 1; }
  UPLOAD_SHA="$got"
}

MANIFEST="$OUT/manifest.txt"
printf 'STAGE: 36\nRUN: %s\nPURPOSE: read-only 24H32 Skywalk registration and callback ABI evidence audit\nBUILD: NOT_RUN\nSOURCE_MODIFIED: NO\n' "$RUN" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
  [[ -f "$part" ]] || continue
  name="$(basename "$part").txt"
  remote="Development/Logs/stage36/$RUN/$name"
  upload_file "$part" "$remote" "Add Stage36 Skywalk ABI audit $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
  printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
  COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage36/$RUN/manifest.txt" "Add Stage36 manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE36_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE36_RUN=$RUN"
echo "STAGE36_REPORT_PARTS=$COUNT"
echo "STAGE36_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage36/$RUN"
