#!/bin/bash
# Stage 60 — 24H32 Itanium vtable address-point / QueueSet dispatch audit.
# VERSION_MARKER: STAGE60_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, OpenCore, SIP or NVRAM changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE60_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE59_RUN="run-20261102-144540-b7f7850cbe02"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage60/$RUN"
TOOLS="$OUT/tools"; PREV59="$OUT/stage59-evidence"; CACHE="$OUT/kc-cache"
mkdir -p "$TOOLS" "$PREV59" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE60_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }
for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found through selected Xcode"
curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
python3 - "$TOOLS/kcfile.py" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
got=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
want="5d31e8a73e5cb175851e7407529456f223683589"
print("PINNED_KCFILE_GIT_BLOB_SHA="+got)
if got!=want: raise SystemExit("Pinned WTLKcAbi parser mismatch")
PY

# Verify all Stage59 evidence by Git blob SHA before using it as predecessor.
while IFS=' ' read -r name want; do
 [[ -n "$name" ]] || continue
 curl -fsSLo "$PREV59/$name" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage59/$STAGE59_RUN/$name"
 got="$(python3 - "$PREV59/$name" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
)"
 [[ "$got" == "$want" ]] || fail "Stage59 evidence SHA mismatch: $name"
 echo "STAGE59_EVIDENCE_VERIFIED=$name SHA=$got"
done <<'EOF'
audit-summary.txt 6e1d2c7e0795e306a1b43a9dc87f4952feff2d9d
class-method-discovery.txt a99be9e70a99fd1edecd1ff01f55429e6bde4e54
manifest.txt 4ff216e9bf8f83adc63927e46294f6c1b3065fdc
method-disassembly.txt ca403941a820013d1d04108f487c2a310126e5ee
method-status.txt 82bb50c4eefb0b2064fef5f71b8d557231f749a2
native-queue-registration-bodies.txt 258b809ec08de662279791a9179ceb96cfef29c5
packet-queue-vtable-windows.txt ba8d30304114a09eb7a7d665a666f593fb7e5d2b
queueset-indirect-callsite-context.txt 2757b5728e02a9304f6dcd21000e9e58dfb2eac3
registration-dispatch-contract-matrix.txt 798f06e4b302d4badd2b902d1de5107cdb5f8007
report.txt f286918f9a369bc8a07ece93a1924584b6545fb0
sdk-packet-queue-contracts.txt eca0f0e3908ab257f596789854c2ab5cc8820024
source-contract-inventory.txt b1bef23d9e685944a79c3316200d15e22d798e2a
source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
EOF

python3 - "$TOOLS" "$BOOTKC" "$SRC" "$PREV59" "$OUT" "$CACHE" "$OBJDUMP" "$OSVER" "$BUILD" "$ARCH" "$RUN" <<'PY3'
import re,sys,pathlib,subprocess
tools,bootkc,src,prev,out,cache,objdump,osver,build,arch,run=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
srcp=pathlib.Path(src); prevp=pathlib.Path(prev); outp=pathlib.Path(out); cachep=pathlib.Path(cache)
classes=("IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue")
kc=KC(bootkc); issues=[]; targets={}; dis=[]; status=[]; vtlines=[]
ctx=(prevp/"queueset-indirect-callsite-context.txt").read_text(errors="replace")
call_count=len(re.findall(r"call\s+qword ptr \[rax \+ 0x218\]",ctx))
call_checks={
 "CALLSITE_COUNT":call_count==2,
 "COMMAND_0x10000":len(re.findall(r"mov\s+esi,\s*0x10000",ctx))==2,
 "DATA_POINTER":len(re.findall(r"lea\s+rdx,\s*\[rbp\s*-\s*0x58\]",ctx))==2,
 "DATA_SIZE_0x10":len(re.findall(r"mov\s+ecx,\s*0x10",ctx))==2}
for k,v in call_checks.items():
 print(k+"="+("PASS" if v else "FAIL"))
 if not v: issues.append(k+"_FAILED")
vtlines=["STAGE60_VTABLE_ADDRESS_POINT_EVIDENCE",
 "PARSER=WTLKcAbi KC.vtable() reads complete _ZTV symbol from offset zero",
 "ITANIUM_PRIMARY_ADDRESS_POINT=_ZTV+0x10 (two 8-byte prefix entries)",
 "QUEUESET [object_vptr+0x218] => [_ZTV+0x228] => KC parser index 69",
 "KC index 67 (_ZTV+0x218) maps to object_vptr+0x208, not +0x218"]
for cls in classes:
 sym="__ZTV%d%s"%(len(cls),cls); vt=kc.vtable(cls)
 if kc.find(sym) is None or vt is None or len(vt)<=69:
  issues.append("VTABLE_MISSING_OR_SHORT_"+cls); continue
 for i in (0,1):
  idx,raw,tgt,nm=vt[i]
  vtlines.append("PREFIX class=%s index=%d raw=0x%x target=0x%x symbol=%s"%(cls,idx,raw,tgt,nm))
 for idx in (67,69):
  _,raw,tgt,nm=vt[idx]; owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
  vtlines.append("SLOT class=%s index=%d symbol_offset=0x%x object_vptr_offset=0x%x target=0x%x owner=%s symbol=%s"%(cls,idx,idx*8,idx*8-0x10,tgt,owner,nm))
 _,_,free_tgt,free_nm=vt[67]; _,_,cmd_tgt,cmd_nm=vt[69]
 if "getFreeSpace" not in free_nm: issues.append("INDEX67_NOT_GETFREESPACE_"+cls)
 if "performCommand" not in cmd_nm: issues.append("INDEX69_NOT_PERFORMCOMMAND_"+cls)
 owner=kc.owner(cmd_tgt) or kc.sym_owner.get(cmd_tgt)
 if not owner or owner!=kc.sym_owner.get(cmd_tgt): issues.append("OWNER_MISMATCH_"+cls); continue
 targets[cls]=(cmd_tgt,cmd_nm,owner)

# Base SDK declaration is authoritative for the virtual member signature;
# concrete override symbols are independently checked by vtable target names.
sdkp=srcp/"MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h"
sdkbody=sdkp.read_text(errors="replace") if sdkp.is_file() else ""
proto="virtual IOReturn performCommand( UInt32 command, void * data, size_t dataSize )"
sdkok=proto in sdkbody
if not sdkok: issues.append("SDK_BASE_PERFORMCOMMAND_PROTOTYPE_MISSING")
(outp/"sdk-performcommand-contracts.txt").write_text(
 "STAGE60_SDK_PERFORMCOMMAND_CONTRACT\nHEADER=MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h\n"+
 "PROTOTYPE="+proto+"\nRESULT="+("PASS" if sdkok else "FAIL")+"\n"+
 "CONCRETE_OVERRIDES=verified independently from each queue-class vtable target and mangled method symbol\n")

seen=set(); owners={}
for cls,(va,nm,owner) in targets.items():
 if va in seen: continue
 seen.add(va)
 if owner not in owners:
  carved=cachep/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
  kc.carve(owner,str(carved)); owners[owner]=carved
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(owners[owner])],text=True,capture_output=True)
 count=sum(1 for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x))
 ok=p.returncode==0 and count>0
 status.append("METHOD_STATUS class=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(cls,nm,va,owner,count,"PASS" if ok else "FAIL"))
 dis += ["\n===== METHOD class=%s symbol=%s address=0x%x owner=%s ====="%(cls,nm,va,owner),
         "OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,count),"DISASSEMBLY_BEGIN",
         p.stdout[:50000].rstrip(),"DISASSEMBLY_END"]
 if not ok: issues.append("DISASSEMBLY_FAILED_"+cls)

matrix=(prevp/"registration-dispatch-contract-matrix.txt").read_text(errors="replace")
for token in ("controller reaches registration API","infra start calls RegistrationInfo helper",
              "TX queue callback calls TX adapter","RX completion action submits packets to networking"):
 if token.lower() not in matrix.lower(): issues.append("PREDECESSOR_MATRIX_CHECK_MISSING_"+token)
fp=(prevp/"source-fingerprint.txt").read_text(errors="replace")
fp_pass=fp.count("RESULT=MATCH")==3 and "STAGE43_SOURCE_CONTINUITY=PASS" in fp
if not fp_pass: issues.append("STAGE43_SOURCE_FINGERPRINT_FAIL")

(outp/"vtable-prefix-addresspoint.txt").write_text("\n".join(vtlines)+"\n")
(outp/"callsite-signature-crosswalk.txt").write_text("\n".join([
 "STAGE60_QUEUESET_CALLSITE_TO_CXX_MEMBER_SIGNATURE",
 "CALLSITE_COUNT=%d"%call_count,
 "CALL_ARGS=RDI:this, RSI:command(0x10000), RDX:data pointer, RCX:dataSize(0x10)",
 "SDK_PROTOTYPE=performCommand(UInt32 command, void * data, size_t dataSize)",
 "RESOLUTION=[vptr+0x218] maps to _ZTV+0x228 / KC index 69 after the 0x10-byte prefix",
 "LIMIT=private semantic meaning of command 0x10000 and its 16-byte payload is not inferred"])+"\n"+
 "".join("TARGET class=%s address=0x%x owner=%s symbol=%s\n"%(c,a,o,n) for c,(a,n,o) in targets.items()))
(outp/"performcommand-disassembly.txt").write_text("STAGE60_PERFORMCOMMAND_DISASSEMBLY\n"+"\n".join(dis)+"\n")
(outp/"method-status.txt").write_text("\n".join(status)+"\n")
(outp/"source-fingerprint.txt").write_text(fp)
summary=[
 "STAGE60_ITANIUM_VTABLE_ADDRESS_POINT_AUDIT","TARGET=%s/%s/%s"%(osver,build,arch),
 "QUEUE_CLASSES_EXPECTED=5","QUEUE_CLASSES_RESOLVED=%d"%len(targets),"QUEUESET_CALLSITE_COUNT=%d"%call_count,
 "PRIMARY_VPTR_ADDRESS_POINT_PREFIX_BYTES=0x10","QUEUESET_VPTR_DISPLACEMENT=0x218",
 "CORRECTED_SYMBOL_RELATIVE_OFFSET=0x228","CORRECTED_KC_VTABLE_INDEX=69",
 "RESOLVED_METHOD=performCommand(UInt32, void *, size_t)",
 "SDK_BASE_PROTOTYPE="+("PASS" if sdkok else "FAIL"),
 "PERFORMCOMMAND_IMPLEMENTATIONS_DISASSEMBLED=%d"%len(status),
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if fp_pass else "FAIL"),
 "STAGE59_EVIDENCE_PINS=13/13_PASS",
 "STAGE59_INDEX_67_LABEL=CORRECTED (symbol-relative index, not object-vptr displacement)",
 "NATIVE_REGISTRATION_AND_TX_RX_GAPS=REMAIN_OPEN",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS_WITH_STAGE59_LABEL_CORRECTION" if not issues and len(targets)==5 and len(status)==5 else "REVIEW_REQUIRED")]
summary += ["ISSUE="+x for x in issues]
(outp/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 60 ITANIUM VTABLE ADDRESS-POINT / QUEUESET DISPATCH AUDIT ==========",
 "VERSION=STAGE60_V1_20261102","RUN="+run,"TARGET=%s/%s/%s"%(osver,build,arch),
 "PREDECESSOR=Stage59 V1 "+(prevp/"manifest.txt").read_text().split("RUN=")[1].splitlines()[0],
 "PURPOSE=resolve QueueSet [vptr+0x218] using the actual Itanium C++ vtable address point",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 "FINDING=Stage59 KC.vtable() indexes start at the _ZTV symbol and include its 0x10-byte ABI prefix.",
 "CORRECTION=QueueSet [vptr+0x218] resolves to _ZTV+0x228, KC parser index 69.",
 "TARGET=All five queue classes resolve index 69 to their performCommand(UInt32, void *, size_t) implementation.",
 "CALLSITE=Two calls pass command 0x10000, data pointer and size 0x10; registers match the public SDK prototype.",
 "LIMIT=The private semantic meaning of command 0x10000 and its 16-byte payload is not inferred.",
 "ACTIVATION_GATE=BLOCKED — interface registration, TX/RX callback handoff and completion ownership remain open.",
 "SOURCE_TREE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN","========== END STAGE 60 =========="]
(outp/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if issues or len(targets)!=5 or len(status)!=5 or not all("result=PASS" in x for x in status):
 raise SystemExit("Stage60 review required; do not proceed to implementation")
PY3

cat "$OUT/audit-summary.txt"
echo
echo "Vtable evidence: $OUT/vtable-prefix-addresspoint.txt"
echo "Dispatch/signature crosswalk: $OUT/callsite-signature-crosswalk.txt"
echo "performCommand disassembly: $OUT/performcommand-disassembly.txt"
echo "Method status: $OUT/method-status.txt"

github_sha(){ gh api "repos/$REPO/contents/$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true; }
blob_sha(){ python3 - "$1" <<'PY4'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY4
}
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" allow="$3" expected old payload response put got
 expected="$(blob_sha "$file")"; old="$(github_sha "$path")"
 if [[ "$allow" == 1 ]]; then
  [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND=$path" >> "$UPLOAD_ERROR"; return 1; }
 elif [[ -n "$old" ]]; then
  if [[ "$old" == "$expected" ]]; then echo "IDENTICAL_EXISTING=$path SHA=$old" >> "$OUT/upload-verification.txt"; return 0; fi
  echo "REFUSE_OVERWRITE_DIFFERENT_FILE=$path REMOTE=$old LOCAL=$expected" >> "$UPLOAD_ERROR"; return 1
 fi
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1)); payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$old" "$payload" <<'PY5'
import base64,json,pathlib,sys
f,sha,dst=sys.argv[1:]
obj={"message":"Add Stage60 read-only Itanium vtable address-point dispatch audit","content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY5
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY6'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY6
)"
 got="$(github_sha "$path")"
 [[ "$put" == "$got" && "$got" == "$expected" ]] || { echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1; }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
MAN="$OUT/manifest.txt"
{
 echo "STAGE=60"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only Itanium vtable address-point and QueueSet dispatch ABI correction"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage59 V1 $STAGE59_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
upload_artifact(){
 local file="$1" base group root
 base="$(basename "$file")"; group="Development/Logs/stage60/$RUN/$base"; root="Development/Logs/stage60-$RUN-$base"
 upload_one "$file" "$group" 0; upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/vtable-prefix-addresspoint.txt "$OUT"/sdk-performcommand-contracts.txt "$OUT"/callsite-signature-crosswalk.txt "$OUT"/performcommand-disassembly.txt "$OUT"/method-status.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_artifact "$f"; else split -b 220k "$f" "$f.part-"; for part in "$f".part-*; do upload_artifact "$part"; done; fi
done
upload_one "$MAN" "Development/Logs/stage60/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage60-$RUN-manifest.txt" 0
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY7'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 60 ITANIUM VTABLE ADDRESS-POINT / QUEUESET DISPATCH AUDIT ==========\n"
 "STAGE60_RUN: %s\n"%run+
 "STAGE60_VERSION: %s\n"%version+
 "STAGE60_SCOPE: 24H32 _ZTV prefix/address-point correction for QueueSet [vptr+0x218], performCommand ABI and implementation crosswalk\n"+
 "STAGE60_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — dispatch target resolved; native registration and TX/RX completion handoff remain open\n"+
 "STAGE60_LOGS: Development/Logs/stage60/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY7
upload_one "$OUT/output.log" "Development/output.log" 1
echo
echo "STAGE60_VERSION=$VERSION"
echo "STAGE60_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE60_RUN=$RUN"
echo "STAGE60_LOCAL_OUTPUT=$OUT"
echo "STAGE60_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage60/$RUN"
echo "STAGE60_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE60_SOURCE_MODIFIED=NO"
echo "STAGE60_BUILD=NOT_RUN"
echo "STAGE60_INSTALL=NOT_RUN"
echo "STAGE60_LOAD=NOT_RUN"
echo "STAGE60_OPENCORE_CHANGE=NONE"
echo "STAGE60_ACTIVATION_GATE=BLOCKED"
