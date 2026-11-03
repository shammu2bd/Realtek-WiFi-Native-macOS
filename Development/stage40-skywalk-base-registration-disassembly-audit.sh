#!/bin/bash
# Stage 40 — fileset-aware disassembly of exact 24H32 Skywalk methods.
# VERSION_MARKER: STAGE40_V2_20261102
# READ ONLY: no driver source edits, build, signing, install, Kext load or OpenCore changes.
set -Eeuo pipefail
echo "STAGE40_SCRIPT_VERSION=2"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
OUT="$SOURCE_ROOT/run log/stage40/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$TOOLS" "$CACHE"
trap 'rc=$?; trap - ERR; echo "STAGE40_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

for tool in curl gh python3 shasum split grep awk sw_vers uname xcrun kmutil file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 project not found"; exit 3; }
[[ -f "$BOOTKC" ]] || { echo "ERROR: BootKernelExtensions.kc not found"; exit 4; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 5; }

BUILD="$(sw_vers -buildVersion 2>/dev/null || echo UNKNOWN)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo UNKNOWN)"
ARCH="$(uname -m 2>/dev/null || echo UNKNOWN)"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
if [[ -z "$OBJDUMP" || ! -x "$OBJDUMP" ]]; then
  echo "ERROR: llvm-objdump not found through Xcode"; exit 6
fi
export LLVM_OBJDUMP="$OBJDUMP"

# Pin and verify the two audited upstream Python files by their GitHub blob IDs.
curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" > "$OUT/upstream-verification.txt" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={
 "kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
 "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9",
}
for name,want in expected.items():
    data=(root/name).read_bytes()
    got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
    print("UPSTREAM_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
    print("UPSTREAM_GIT_BLOB_SHA_%s=%s"%(name,got))
    if got!=want: raise SystemExit("Pinned upstream file verification failed: "+name)
PY

{
 echo "========== STAGE 40: FILESET-AWARE SKYWALK DISASSEMBLY =========="
 echo "script_version=STAGE40_V1_20261102"
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "product_version=$OSVER"
 echo "build_version=$BUILD"
 echo "architecture=$ARCH"
 echo "source_root=$SOURCE_ROOT"
 echo "boot_kernel_collection=$BOOTKC"
 echo "llvm_objdump=$OBJDUMP"
 echo "upstream_toolkit=watchthelight-labs/WTLKcAbi"
 echo "upstream_commit=$UPSTREAM_COMMIT"
 echo "upstream_scope=kcfile.py and disasm.py only; standard-library Python; read-only KC mmap plus temporary carved images"
 echo "PREDECESSOR=Stage39 run-20261102-032235"
 echo
 if [[ "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
   echo "WARNING: host differs from pinned target 24H32 x86_64; treat binary conclusions as provisional."
 fi
} > "$REPORT"
cat "$OUT/upstream-verification.txt" >> "$REPORT"

# Source continuity is checked without changing the project tree.
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
    print("SOURCE_FINGERPRINT_%s=%s"%("MATCH" if ok else "DIFF",rel))
    if not ok: bad.append(rel)
print("AUDITED_SOURCE_FINGERPRINTS=%d"%len(expected))
print("SOURCE_FINGERPRINT_CONTINUITY="+("PASS" if not bad else "REVIEW_REQUIRED"))
PY

# Parse the fileset, resolve the owners of the exact symbols, carve each owning kext
# image with the pinned reader, and ask llvm-objdump for only the bounded function range.
python3 - "$TOOLS" "$BOOTKC" "$CACHE" "$OBJDUMP" <<'PY' >> "$REPORT"
import os,pathlib,re,subprocess,sys,traceback
tools,kc_path,cache,objdump=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
import disasm

os.environ["LLVM_OBJDUMP"]=objdump
print("\n--- Fileset parser and kernel collection identity ---")
print("PYTHON_VERSION="+sys.version.split()[0])
print("OBJDUMP_VERSION="+subprocess.run([objdump,"--version"],text=True,capture_output=True).stdout.splitlines()[0])
kc=KC(kc_path)
parser=disasm.Disassembler(kc,cache)
print("BOOTKC_SHA256="+kc.sha256())
print("FILESET_ENTRY_COUNT=%d"%len(kc.entries))
for bid,vm,fo in kc.entries:
    if any(key in bid.lower() for key in ("skywalk","80211")):
        print("RELEVANT_FILESET_ENTRY=%s vmaddr=0x%x fileoff=0x%x"%(bid,vm,fo))

wanted=[
("initRegistrationInfo","__ZN26IOSkywalkEthernetInterface20initRegistrationInfoEPNS_16RegistrationInfoEjm"),
("registerEthernetInterface.queue_array","__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j"),
("registerEthernetInterface.logical_link","__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS7_j"),
("deregisterEthernetInterface","__ZN26IOSkywalkEthernetInterface27deregisterEthernetInterfaceEj"),
("IO80211InfraInterface.registerInfraEthernetInterface","__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_"),
("IOSkywalkEthernetInterface.copyRegistrationInfo","__ZN26IOSkywalkEthernetInterface20copyRegistrationInfoEPKNS_16RegistrationInfoE"),
("IOSkywalkNetworkInterface.registerNetworkInterface.queue_array","__ZN25IOSkywalkNetworkInterface24registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j"),
("IOSkywalkNetworkInterface.deregisterNetworkInterface","__ZN25IOSkywalkNetworkInterface26deregisterNetworkInterfaceEj"),
]
resolved=[]
owners=set()
print("\n--- Exact symbol resolution and fileset ownership ---")
for label,sym in wanted:
    va=kc.find(sym)
    if va is None:
        print("SYMBOL_%s=NOT_FOUND"%label)
        continue
    owner=kc.owner(va)
    sym_owner=kc.sym_owner.get(va)
    print("SYMBOL_%s=0x%x"%(label,va))
    print("SYMBOL_NAME_%s=%s"%(label,sym))
    print("SYMBOL_FILES_OWNER_%s=%s"%(label,sym_owner or "UNKNOWN"))
    print("ADDRESS_FILES_OWNER_%s=%s"%(label,owner or "UNKNOWN"))
    if not owner or not sym_owner or owner!=sym_owner:
        print("OWNER_VALIDATION_%s=FAIL"%label)
        continue
    segs=[s for s in kc.entry_segs.get(owner,[]) if s[1] <= va < s[1]+s[2]]
    if not segs:
        print("EXECUTABLE_SEGMENT_%s=NOT_FOUND"%label)
        continue
    seg=segs[0]
    print("SEGMENT_%s=%s vmaddr=0x%x vmsize=0x%x fileoff=0x%x filesize=0x%x initprot=0x%x"%(label,seg[0],seg[1],seg[2],seg[3],seg[4],seg[5]))
    if not (seg[5]&4):
        print("EXECUTABLE_SEGMENT_%s=NO_EXECUTE_PERMISSION"%label)
        continue
    end=kc.next_sym(va) or (va+0x400)
    if end<=va: end=va+0x400
    cap=va+0x1000
    if end>cap:
        end=cap
        print("FUNCTION_RANGE_%s=CAP_0x1000"%label)
    print("FUNCTION_RANGE_%s=0x%x..0x%x"%(label,va,end))
    resolved.append((label,sym,va,owner,end))
    owners.add(owner)

print("\n--- Bounded disassembly from carved fileset entries ---")
if not resolved:
    print("NO_METHODS_READY_FOR_DISASSEMBLY=YES")
for owner in sorted(owners):
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    kc.carve(owner,str(carved))
    print("CARVED_OWNER=%s"%owner)
    print("CARVED_PATH=%s"%carved)
    print("CARVED_BYTES=%d"%carved.stat().st_size)
    print("CARVED_FILE_TYPE="+subprocess.run(["file",str(carved)],text=True,capture_output=True).stdout.strip())

for label,sym,va,owner,end in resolved:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    print("\n=== METHOD %s ==="%label)
    print("SYMBOL=%s"%sym)
    print("ADDRESS=0x%x"%va)
    print("OWNER=%s"%owner)
    print("IMAGE=%s"%carved)
    print("RANGE=0x%x..0x%x"%(va,end))
    attempts=[
      ["-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
      ["-d","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
      ["-d","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
    ]
    success=False
    for idx,args in enumerate(attempts,1):
        p=subprocess.run([objdump]+args,text=True,capture_output=True)
        parsed_addrs,parsed_ins=parser._parse(p.stdout)
        print("OBJDUMP_ATTEMPT_%d_EXIT=%d"%(idx,p.returncode))
        print("OBJDUMP_ATTEMPT_%d_INSTRUCTIONS=%d"%(idx,len(parsed_addrs)))
        if p.stderr.strip():
            print("OBJDUMP_ATTEMPT_%d_STDERR_BEGIN"%idx)
            print(p.stderr[:5000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDERR_END"%idx)
        if p.stdout.strip():
            print("OBJDUMP_ATTEMPT_%d_STDOUT_BEGIN"%idx)
            print(p.stdout[:24000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDOUT_END"%idx)
        if p.returncode==0 and parsed_addrs:
            print("METHOD_DISASSEMBLY_%s=PASS"%label)
            print("DETECTED_INSTRUCTION_LINES=%d"%len(parsed_addrs))
            success=True
            break
    if not success:
        print("METHOD_DISASSEMBLY_%s=REVIEW_REQUIRED"%label)
        print("DETECTED_INSTRUCTION_LINES=0")

print("\n--- Scope note ---")
print("KC_READER_SOURCE=WTLKcAbi pinned commit "+os.environ.get("STAGE40_UPSTREAM_COMMIT","cea28a5297633118177cee6a75e86d8bc57f1960"))
print("FILESYSTEM_EFFECTS=only temporary tool files, report and carved images in this Stage39 run directory")
PY

# The carved Mach-O files can be large; remove them after the report has captured
# their owner, size, and disassembly. Keep the pinned scripts and report for audit.
rm -rf "$CACHE"

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
 echo "SYSTEM_FILES_MODIFIED=NO"
 echo "========== END STAGE 40 =========="
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
printf 'STAGE: 40\nRUN: %s\nPURPOSE: fileset-aware disassembly of exact 24H32 Skywalk methods\nBUILD: NOT_RUN\nSOURCE_MODIFIED: NO\nUPSTREAM: watchthelight-labs/WTLKcAbi@%s\n' "$RUN" "$UPSTREAM_COMMIT" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage40/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage39 fileset-aware disassembly report $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage40/$RUN/manifest.txt" "Add Stage40 manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE40_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE40_LOCAL_OUTPUT=$OUT"
echo "STAGE40_RUN=$RUN"
echo "STAGE40_REPORT_PARTS=$COUNT"
echo "STAGE40_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage40/$RUN"
