#!/bin/bash
# Stage 42 — audit Sequoia 24H32 Skywalk/BSD interface start, attach and teardown lifecycle.
# VERSION_MARKER: STAGE42_V1_20261102
# READ ONLY: no driver source edits, build, signing, install, Kext load or OpenCore changes.
set -Eeuo pipefail
echo "STAGE42_SCRIPT_VERSION=1"

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
RUN="run-$STAMP"
# Keep all run output inside the source project, not directly in Downloads.
OUT="$SOURCE_ROOT/run log/stage42/$RUN"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
REPORT="$OUT/report.txt"
UPLOAD_ERROR="$OUT/upload-error.txt"
mkdir -p "$TOOLS" "$CACHE"
trap 'rc=$?; trap - ERR; echo "STAGE42_ERROR=exit:$rc line:$LINENO" >&2; if [[ -f "$UPLOAD_ERROR" ]]; then tail -60 "$UPLOAD_ERROR" >&2; fi; exit "$rc"' ERR

for tool in curl gh python3 shasum split grep awk sw_vers uname xcrun kmutil file; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool"; exit 2; }
done
[[ -f "$SRC/Makefile" ]] || { echo "ERROR: Stage26 project not found at $SRC"; exit 3; }
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

# Download the same fileset-aware parser used in verified Stages 39–41.
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
 echo "========== STAGE 42: BSD INTERFACE START / STOP LIFECYCLE =========="
 echo "script_version=STAGE42_V1_20261102"
 echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
 echo "product_version=$OSVER"
 echo "build_version=$BUILD"
 echo "architecture=$ARCH"
 echo "source_root=$SOURCE_ROOT"
 echo "local_run_output=$OUT"
 echo "boot_kernel_collection=$BOOTKC"
 echo "llvm_objdump=$OBJDUMP"
 echo "upstream_toolkit=watchthelight-labs/WTLKcAbi"
 echo "upstream_commit=$UPSTREAM_COMMIT"
 echo "scope=exact 24H32 BSD interface init, attach, start, stop, free and network-interface preparation methods"
 echo "PREDECESSOR=Stage41 run-20261102-034341"
 echo "BUILD=NOT_RUN"
 echo "SOURCE_MODIFIED=NO"
 echo
 if [[ "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
   echo "WARNING: host differs from pinned target 24H32 x86_64; binary conclusions are provisional."
 fi
} > "$REPORT"
cat "$OUT/upstream-verification.txt" >> "$REPORT"

# Verify unchanged driver source against the fingerprints captured in Stage 41.
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

# Capture relevant source and headers for an implementation decision after the ABI audit.
python3 - "$SRC" <<'PY_SRC' >> "$REPORT"
import pathlib,sys
root=pathlib.Path(sys.argv[1])
files=[
 "src/kext/wcl24h32/RTW88WCLController.cpp",
 "src/kext/wcl24h32/RTW88WCLController.hpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp",
 "src/kext/RTW88WCLWorkQueue.cpp",
 "src/kext/RTW88WCLWorkQueue.hpp",
 "src/kext/wcl24h32/RTW88WCLPacketView.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.hpp",
]
print("\n--- Current native driver source snapshot (read-only) ---")
for rel in files:
 p=root/rel
 print("\n===== SOURCE_FILE %s ====="%rel)
 if not p.is_file():
  print("SOURCE_FILE_STATUS=NOT_PRESENT")
  continue
 data=p.read_text(errors="replace").splitlines()
 print("SOURCE_FILE_STATUS=PRESENT")
 print("SOURCE_FILE_LINES=%d"%len(data))
 for i,line in enumerate(data,1):
  print("%5d %s"%(i,line))
 print("===== END SOURCE_FILE %s ====="%rel)
PY_SRC

# Parse the fileset and disassemble exact lifecycle methods in their owning kext.
python3 - "$TOOLS" "$BOOTKC" "$CACHE" "$OBJDUMP" <<'PY' >> "$REPORT"
import os,pathlib,re,subprocess,sys
tools,kc_path,cache,objdump=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump
kc=KC(kc_path)
parser=disasm.Disassembler(kc,cache)
print("\n--- Kernel collection and fileset entries ---")
print("BOOTKC_SHA256="+kc.sha256())
print("FILESET_ENTRY_COUNT=%d"%len(kc.entries))

wanted=[
("IOSkywalkEthernetInterface.free","__ZN26IOSkywalkEthernetInterface4freeEv"),
("IO80211SkywalkInterface.start","__ZN23IO80211SkywalkInterface5startEP9IOService"),
("IO80211SkywalkInterface.stop","__ZN23IO80211SkywalkInterface4stopEP9IOService"),
("IO80211SkywalkInterface.free","__ZN23IO80211SkywalkInterface4freeEv"),
("IO80211InfraInterface.start","__ZN21IO80211InfraInterface5startEP9IOService"),
("IO80211InfraInterface.stop","__ZN21IO80211InfraInterface4stopEP9IOService"),
("IO80211InfraInterface.free","__ZN21IO80211InfraInterface4freeEv"),
("IO80211InfraInterface.initBSDInterfaceParameters","__ZN21IO80211InfraInterface26initBSDInterfaceParametersEP18ifnet_init_eparamsPP11sockaddr_dl"),
("IO80211SkywalkInterface.initBSDInterfaceParameters","__ZN23IO80211SkywalkInterface26initBSDInterfaceParametersEP18ifnet_init_eparamsPP11sockaddr_dl"),
("IOSkywalkEthernetInterface.initBSDInterfaceParameters","__ZN26IOSkywalkEthernetInterface26initBSDInterfaceParametersEP18ifnet_init_eparamsPP11sockaddr_dl"),
("IOSkywalkNetworkInterface.initBSDInterfaceParameters","__ZN25IOSkywalkNetworkInterface26initBSDInterfaceParametersEP18ifnet_init_eparamsPP11sockaddr_dl"),
("IOSkywalkNetworkInterface.prepareBSDInterface","__ZN25IOSkywalkNetworkInterface19prepareBSDInterfaceEP7__ifnetj"),
("IOSkywalkNetworkInterface.finalizeBSDInterface","__ZN25IOSkywalkNetworkInterface20finalizeBSDInterfaceEP7__ifnetj"),
("IOSkywalkNetworkInterface.stop","__ZN25IOSkywalkNetworkInterface4stopEP9IOService"),
("IOSkywalkNetworkInterface.free","__ZN25IOSkywalkNetworkInterface4freeEv"),
]
resolved=[]
print("\n--- Exact method resolution ---")
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
    segs=[s for s in kc.entry_segs.get(owner,[]) if s[1] <= va < s[1]+s[2] and (s[5]&4)]
    if not segs:
        print("EXECUTABLE_SEGMENT_%s=NOT_FOUND"%label)
        continue
    end=kc.next_sym(va) or (va+0x1000)
    if end<=va or end>va+0x3000:
        end=va+0x1000
        print("FUNCTION_RANGE_%s=BOUNDED_0x1000"%label)
    print("FUNCTION_RANGE_%s=0x%x..0x%x"%(label,va,end))
    resolved.append((label,sym,va,owner,end))

print("\n--- Relevant class vtables ---")
for cls in ["IOSkywalkNetworkInterface","IOSkywalkEthernetInterface","IO80211SkywalkInterface","IO80211InfraInterface"]:
    try:
        vt=kc.vtable(cls)
    except Exception as e:
        print("VTABLE_%s=ERROR:%s"%(cls,str(e)))
        continue
    if vt is None:
        print("VTABLE_%s=NOT_FOUND"%cls)
        continue
    print("VTABLE_%s_ENTRIES=%d"%(cls,len(vt)))
    for idx,(word,raw,tgt,name) in enumerate(vt):
        if idx < 4 or (idx % 4 == 0):
            print("VTABLE_SLOT class=%s offset=0x%x index=%d target=0x%x symbol=%s owner=%s"%(cls,idx*8,idx,tgt,name,kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"))

print("\n--- Fileset-aware method disassembly ---")
owners=sorted({item[3] for item in resolved})
for owner in owners:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    kc.carve(owner,str(carved))
    print("CARVED_OWNER=%s"%owner)
    print("CARVED_BYTES=%d"%carved.stat().st_size)
    print("CARVED_FILE_TYPE="+subprocess.run(["file",str(carved)],text=True,capture_output=True).stdout.strip())

for label,sym,va,owner,end in resolved:
    safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
    carved=pathlib.Path(cache)/(safe+".macho")
    print("\n=== METHOD %s ==="%label)
    print("SYMBOL=%s"%sym)
    print("ADDRESS=0x%x"%va)
    print("OWNER=%s"%owner)
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
            print(p.stderr[:3000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDERR_END"%idx)
        if p.stdout.strip():
            print("OBJDUMP_ATTEMPT_%d_STDOUT_BEGIN"%idx)
            print(p.stdout[:22000].rstrip())
            print("OBJDUMP_ATTEMPT_%d_STDOUT_END"%idx)
        if p.returncode==0 and parsed_addrs:
            print("METHOD_DISASSEMBLY_%s=PASS"%label)
            print("DETECTED_INSTRUCTION_LINES=%d"%len(parsed_addrs))
            success=True
            break
    if not success:
        print("METHOD_DISASSEMBLY_%s=REVIEW_REQUIRED"%label)
        print("DETECTED_INSTRUCTION_LINES=0")

print("\n--- Audit scope ---")
print("TARGET=24H32 BootKernelExtensions.kc fileset")
print("METHODS_REQUESTED=%d"%len(wanted))
print("METHODS_RESOLVED=%d"%len(resolved))
print("KERNEL_COLLECTION_OPEN_MODE=READ_ONLY")
PY

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
 echo "LOCAL_RUN_FOLDER=$OUT"
 echo "========== END STAGE 42 =========="
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
printf 'STAGE: 42\nRUN: %s\nPURPOSE: read-only native driver and 24H32 BSD interface start/stop lifecycle audit\nBUILD: NOT_RUN\nSOURCE_MODIFIED: NO\nUPSTREAM: watchthelight-labs/WTLKcAbi@%s\nLOCAL_OUTPUT: %s\n' "$RUN" "$UPSTREAM_COMMIT" "$OUT" > "$MANIFEST"
COUNT=0
for part in "$OUT"/parts/report-*; do
 [[ -f "$part" ]] || continue
 name="$(basename "$part").txt"
 remote="Development/Logs/stage42/$RUN/$name"
 upload_file "$part" "$remote" "Add Stage42 BSD lifecycle report $RUN/$name" "$OUT/upload.json" "$OUT/upload-response.json"
 printf '%s | github_blob=%s | bytes=%s | sha256=%s\n' "$remote" "$UPLOAD_SHA" "$(wc -c < "$part" | tr -d ' ')" "$(shasum -a 256 "$part" | awk '{print $1}')" >> "$MANIFEST"
 COUNT=$((COUNT+1))
done
[[ "$COUNT" -gt 0 ]]
upload_file "$MANIFEST" "Development/Logs/stage42/$RUN/manifest.txt" "Add Stage42 manifest $RUN" "$OUT/manifest.json" "$OUT/manifest-response.json"
echo "STAGE42_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE42_LOCAL_OUTPUT=$OUT"
echo "STAGE42_RUN=$RUN"
echo "STAGE42_REPORT_PARTS=$COUNT"
echo "STAGE42_LOG_URL=https://github.com/$REPO/tree/main/Development/Logs/stage42/$RUN"
