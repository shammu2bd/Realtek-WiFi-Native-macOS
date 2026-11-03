#!/bin/bash
# Stage 61 — 24H32 queue descriptor classification record / QueueSet grouping audit.
# VERSION_MARKER: STAGE61_V1_20261102
# READ ONLY: no driver edits, build, signing, install/load, OpenCore, SIP or NVRAM changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE61_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE60_RUN="run-20261102-150246-056583bdc528"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage61/$RUN"
TOOLS="$OUT/tools"; PREV60="$OUT/stage60-evidence"; CACHE="$OUT/kc-cache"
mkdir -p "$TOOLS" "$PREV60" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE61_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }
for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
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

# Verify each Stage60 predecessor artifact by Git blob SHA.
while IFS=' ' read -r name want; do
 [[ -n "$name" ]] || continue
 curl -fsSLo "$PREV60/$name" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage60/$STAGE60_RUN/$name"
 got="$(python3 - "$PREV60/$name" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
)"
 [[ "$got" == "$want" ]] || fail "Stage60 evidence SHA mismatch: $name expected=$want actual=$got"
 echo "STAGE60_EVIDENCE_VERIFIED=$name SHA=$got"
done <<'EOF'
audit-summary.txt 99bc1dc068cb6a9a92039e4a3af0870c1bb638f7
callsite-signature-crosswalk.txt 2467e56e6698eefa564f3f62e0569aef61ae5ca7
manifest.txt 11d7c2f8337fa97bc1e134a06c17a9fd03ec9ebd
method-status.txt 5f058a920aec69301092d088dbcb47c2b06efabd
performcommand-disassembly.txt 463338108805e1128ad14c1ae68f0d9baf7c2298
report.txt 9bfd762a0e340914b06836e1dbdac4c9136886f2
sdk-performcommand-contracts.txt fd693c606fb06343183f163b7c7d06b71ec166f2
source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
vtable-prefix-addresspoint.txt 504840c41e4431c3ec909d7fc3bb181fdcbe89bc
EOF

python3 - "$TOOLS" "$BOOTKC" "$PREV60" "$OUT" "$CACHE" "$OBJDUMP" "$OSVER" "$BUILD" "$ARCH" "$RUN" <<'PY3'
import re,sys,pathlib,struct,subprocess
tools,bootkc,prev,out,cache,objdump,osver,build,arch,run=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
prevp=pathlib.Path(prev); outp=pathlib.Path(out); cachep=pathlib.Path(cache)
kc=KC(bootkc)
issues=[]; dis_lines=[]; statuses=[]; source_fp=(prevp/"source-fingerprint.txt").read_text(errors="replace")
fp_pass=source_fp.count("RESULT=MATCH")==3 and "STAGE43_SOURCE_CONTINUITY=PASS" in source_fp
if not fp_pass: issues.append("STAGE43_SOURCE_FINGERPRINT_FAIL")

def resolve_method(cls, pattern):
 hits=[(va,nm) for va,nm in kc.methods(cls) if re.search(pattern,nm)]
 if len(hits)!=1: raise RuntimeError("Expected exactly one method %s / %s; found %d"%(cls,pattern,len(hits)))
 va,nm=hits[0]; owner=kc.owner(va) or kc.sym_owner.get(va)
 if not owner or owner!=kc.sym_owner.get(va): raise RuntimeError("Method owner validation failed "+nm)
 return va,nm,owner

owners={}; method_text={}
def disassemble(cls, pattern):
 va,nm,owner=resolve_method(cls,pattern)
 if owner not in owners:
  carved=cachep/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
  kc.carve(owner,str(carved)); owners[owner]=carved
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,
                   "--stop-address=0x%x"%end,str(owners[owner])],text=True,capture_output=True)
 count=sum(1 for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x))
 ok=p.returncode==0 and count>0
 statuses.append("METHOD_STATUS class=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(
  cls,nm,va,owner,count,"PASS" if ok else "FAIL"))
 if not ok: issues.append("DISASSEMBLY_FAILED_"+cls+"_"+pattern)
 method_text[cls]=p.stdout
 dis_lines.extend(["\n===== METHOD class=%s symbol=%s address=0x%x owner=%s ====="%(cls,nm,va,owner),
                   "OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,count),
                   "DISASSEMBLY_BEGIN",p.stdout[:70000].rstrip(),"DISASSEMBLY_END"])
 return va,nm,owner,p.stdout

qva,qnm,qowner,qasm=disassemble("IOSkywalkQueueSet",r"14initWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE")
queue_classes=[
 ("IOSkywalkTxSubmissionQueue",1,"TX_SUBMISSION",0x20,0x60),
 ("IOSkywalkTxCompletionQueue",2,"TX_COMPLETION",0x28,0x68),
 ("IOSkywalkRxSubmissionQueue",3,"RX_SUBMISSION",0x30,0x70),
 ("IOSkywalkRxCompletionQueue",4,"RX_COMPLETION",0x38,0x78)]
bodies={}
for cls,kind,label,array_off,count_off in queue_classes:
 va,nm,owner,asm=disassemble(cls,r"14performCommandEjPvm")
 bodies[cls]=asm

# Stage60's parser correction must remain true: object vptr + 0x218 == _ZTV + 0x228 == index 69.
vtable_rows=["STAGE61_QUEUE_VTABLE_ADDRESS_POINT_RECHECK"]
for cls,kind,label,array_off,count_off in queue_classes:
 vt=kc.vtable(cls)
 if vt is None or len(vt)<=69:
  issues.append("VTABLE_INDEX69_MISSING_"+cls); continue
 _,_,target,symbol=vt[69]
 if "performCommand" not in symbol: issues.append("VTABLE_INDEX69_TARGET_MISMATCH_"+cls)
 vtable_rows.append("CLASS=%s TYPE_CODE=%d INDEX69_TARGET=%s RESULT=%s"%(cls,kind,symbol,"PASS" if "performCommand" in symbol else "FAIL"))

# Decode both relative jump tables in IOSkywalkQueueSet::initWithQueues.
# The first counts queue objects by returned type code; the second selects the
# corresponding per-type queue array when attaching them to this QueueSet.
table_refs={}
for line in qasm.splitlines():
 if "lea" in line and "##" in line and "+0x386>" in line:
  m=re.search(r"##\s*(0x[0-9a-fA-F]+)",line)
  if m: table_refs["count"]=int(m.group(1),16)
 if "lea" in line and "##" in line and "+0x396>" in line:
  m=re.search(r"##\s*(0x[0-9a-fA-F]+)",line)
  if m: table_refs["attach"]=int(m.group(1),16)
if set(table_refs)!={"count","attach"}: issues.append("QUEUESET_RELATIVE_JUMP_TABLE_REFERENCES_NOT_FOUND")

def decode_table(label,base,expected):
 raw=kc.read(base,16)
 if raw is None or len(raw)!=16:
  issues.append("JUMP_TABLE_READ_FAILED_"+label); return []
 rels=list(struct.unpack("<4i",raw))
 targets=[base+x for x in rels]
 offsets=[x-qva for x in targets]
 ok=offsets==expected
 if not ok: issues.append("JUMP_TABLE_TARGET_OFFSETS_MISMATCH_"+label)
 return list(zip(range(1,5),rels,targets,offsets,["PASS" if ok else "REVIEW_REQUIRED"]*4))
expected_count=[0xd7,0xc7,0xcd,0xd3]
expected_attach=[0x29f,0x2ea,0x2c0,0x2d4]
count_rows=decode_table("count",table_refs["count"],expected_count) if "count" in table_refs else []
attach_rows=decode_table("attach",table_refs["attach"],expected_attach) if "attach" in table_refs else []

# Check the exact queue-descriptor stores in the four concrete performCommand bodies.
# QueueSet zeroes the two qwords at [rbp-0x58] and [rbp-0x50] before every query;
# that establishes the default zero value for fields not explicitly written.
record_specs=[
 ("IOSkywalkTxSubmissionQueue",1,"TX_SUBMISSION",True,"dword"),
 ("IOSkywalkTxCompletionQueue",2,"TX_COMPLETION",False,"qword"),
 ("IOSkywalkRxSubmissionQueue",3,"RX_SUBMISSION",False,"qword"),
 ("IOSkywalkRxCompletionQueue",4,"RX_COMPLETION",True,"dword")]
record_rows=[]
for cls,kind,label,writes_capacity,store_width in record_specs:
 a=bodies[cls].lower()
 pat_type=r"mov\s+"+store_width+r"\s+ptr\s+\[rdx\],\s*0x%x"%kind
 has_type=bool(re.search(pat_type,a))
 has_capacity=bool(re.search(r"mov\s+dword\s+ptr\s+\[rdx\s*\+\s*0x4\],\s*eax",a))
 has_pool=bool(re.search(r"mov\s+qword\s+ptr\s+\[rdx\s*\+\s*0x8\],\s*rax",a))
 if not has_type: issues.append("DESCRIPTOR_TYPE_STORE_MISSING_"+cls)
 if has_capacity!=writes_capacity: issues.append("DESCRIPTOR_CAPACITY_WRITE_MISMATCH_"+cls)
 if not has_pool: issues.append("DESCRIPTOR_POOL_POINTER_STORE_MISSING_"+cls)
 record_rows.append("TYPE_CODE=%d CLASS=%s LABEL=%s TYPE_STORE=%s CAPACITY_FIELD=%s POOL_POINTER_AT_PLUS_8=%s RESULT=%s"%(
  kind,cls,label,"PASS" if has_type else "FAIL",
  "explicit queue capacity" if has_capacity else "zero-initialized (not written by override)",
  "PASS" if has_pool else "FAIL","PASS" if has_type and has_capacity==writes_capacity and has_pool else "FAIL"))

# Verify QuerySet's two code paths initialize all 16 descriptor bytes and call
# performCommand with the 0x10-byte size. The record is {u32 type,u32 capacity,u64 pool}.
zero_a=qasm.count("mov\tqword ptr [rbp - 0x50], r13")
zero_b=qasm.count("mov\tqword ptr [rbp - 0x58], r13")
zero_c=qasm.count("mov\tqword ptr [rbp - 0x50], rax")
zero_d=qasm.count("mov\tqword ptr [rbp - 0x58], rax")
call_cmd=qasm.count("mov\tesi, 0x10000")
call_len=qasm.count("mov\tecx, 0x10")
call_query=qasm.count("call\tqword ptr [rax + 0x218]")
caller_init_ok=(zero_a>=1 and zero_b>=1 and zero_c>=1 and zero_d>=1 and call_cmd==2 and call_len==2 and call_query==2)
if not caller_init_ok: issues.append("QUEUESET_DESCRIPTOR_CALLER_INIT_OR_CALL_CONTRACT_FAILED")

# Queue type codes are 1..4 and both switch tables are expected to route each
# code to four distinct count/array buckets. Report exact signed offsets and
# stable QueueSet member offsets for manual review.
jump_lines=["STAGE61_QUEUESET_QUEUE_KIND_JUMP_TABLES",
 "QUEUESET_INIT_SYMBOL_ADDRESS=0x%x"%qva,
 "COUNT_TABLE_BASE="+("0x%x"%table_refs["count"] if "count" in table_refs else "NOT_FOUND"),
 "ATTACH_TABLE_BASE="+("0x%x"%table_refs["attach"] if "attach" in table_refs else "NOT_FOUND"),
 "COUNT_TABLE_EXPECTED_RELATIVE_TARGET_OFFSETS="+",".join(hex(x) for x in expected_count),
 "ATTACH_TABLE_EXPECTED_RELATIVE_TARGET_OFFSETS="+",".join(hex(x) for x in expected_attach)]
for label,rows in (("COUNT",count_rows),("ATTACH",attach_rows)):
 for code,rel,target,offset,result in rows:
  jump_lines.append("%s_CASE=%d REL=%d TARGET=0x%x METHOD_OFFSET=0x%x RESULT=%s"%(label,code,rel,target,offset,result))
for cls,kind,label,array_off,count_off in queue_classes:
 jump_lines.append("QUEUE_KIND=%d CLASS=%s ARRAY_MEMBER_OFFSET=0x%x COUNT_MEMBER_OFFSET=0x%x"%(
  kind,cls,array_off,count_off))
(outp/"queueset-classification-jump-tables.txt").write_text("\n".join(jump_lines)+"\n")
(outp/"queue-descriptor-record-matrix.txt").write_text("\n".join([
 "STAGE61_QUEUE_DESCRIPTOR_RECORD_LAYOUT",
 "CALL=performCommand(command=0x10000, data=descriptor, dataSize=0x10)",
 "RECORD_LAYOUT=uint32_t typeCode @ +0x00; uint32_t capacity @ +0x04; IOSkywalkPacketBufferPool* @ +0x08",
 "CALLER_ZEROES_ALL_16_BYTES_BEFORE_QUERY="+("PASS" if caller_init_ok else "FAIL"),
 "CALLSITE_COUNTS=command:%d size:%d dispatch:%d"%(call_cmd,call_len,call_query),
 "TYPE_CODES=1 TX submission; 2 TX completion; 3 RX submission; 4 RX completion",
 "CAPACITY=written by TX submission and RX completion; remains zero for TX completion and RX submission",
 "POOL_POINTER=all four concrete queue overrides write their associated pool at +0x08",
 "PRIVATE_QUEUESETINFO_ARGUMENT=distinct from this per-queue 16-byte query record",
 ""]+record_rows)+"\n")
(outp/"vtable-addresspoint-recheck.txt").write_text("\n".join(vtable_rows)+"\n")
(outp/"queueset-init-disassembly.txt").write_text(
 "STAGE61_QUEUESET_INITWITHQUEUES_DISASSEMBLY\n"+qasm[:70000].rstrip()+"\n")
(outp/"queue-command-method-disassembly.txt").write_text(
 "STAGE61_QUEUE_PERFORMCOMMAND_DISASSEMBLY\n"+"\n".join(dis_lines[5:])+"\n")
(outp/"method-status.txt").write_text("\n".join(statuses)+"\n")
(outp/"source-fingerprint.txt").write_text(source_fp)

summary=[
 "STAGE61_QUEUE_DESCRIPTOR_CLASSIFICATION_RECORD_AUDIT","TARGET=%s/%s/%s"%(osver,build,arch),
 "STAGE60_PREDECESSOR_EVIDENCE=9/9_PINS_PASS","STAGE43_SOURCE_CONTINUITY="+("PASS" if fp_pass else "FAIL"),
 "QUEUESET_INITWITHQUEUES_DISASSEMBLY="+("PASS" if qasm else "FAIL"),
 "PERFORMCOMMAND_METHODS_DISASSEMBLED=%d/4"%len(bodies),
 "QUEUESET_PERFORMCOMMAND_CALLS=%d"%call_query,
 "QUEUESET_QUERY_COMMAND=0x10000","QUEUESET_QUERY_RECORD_SIZE=0x10",
 "QUEUESET_RELATIVE_JUMP_TABLES="+("2/2_DECODED" if len(count_rows)==4 and len(attach_rows)==4 else "REVIEW_REQUIRED"),
 "QUEUE_DESCRIPTOR_TYPE_CODES=1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION",
 "QUEUE_DESCRIPTOR_LAYOUT=uint32_type+uint32_capacity+uint64_pool_pointer",
 "QUEUESET_ARRAY_MEMBER_OFFSETS=0x20,0x28,0x30,0x38",
 "QUEUESET_COUNT_MEMBER_OFFSETS=0x60,0x68,0x70,0x78",
 "NATIVE_REGISTRATION_AND_TX_RX_PACKET_OWNERSHIP=REMAIN_OPEN",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS" if not issues and caller_init_ok and len(bodies)==4 and len(count_rows)==4 and len(attach_rows)==4 else "REVIEW_REQUIRED")]
summary += ["ISSUE="+x for x in issues]
(outp/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 61 QUEUE DESCRIPTOR / QUEUESET CLASSIFICATION AUDIT ==========",
 "VERSION=STAGE61_V1_20261102","RUN="+run,"TARGET=%s/%s/%s"%(osver,build,arch),
 "PREDECESSOR=Stage60 V1 "+(prevp/"manifest.txt").read_text().split("RUN=")[1].splitlines()[0],
 "PURPOSE=decode QueueSet's 16-byte performCommand query record and four queue-kind dispatch/grouping tables",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 "FINDING=QueueSet queries each queue with command 0x10000 and a 16-byte output record.",
 "RECORD=uint32 type code at +0, uint32 capacity at +4, packet-buffer-pool pointer at +8.",
 "TYPE_CODES=1 TX submission; 2 TX completion; 3 RX submission; 4 RX completion.",
 "GROUPING=QueueSet uses the returned type code for four count buckets and then four per-kind queue arrays.",
 "PRIVATE_QUEUESETINFO=the QueueSetInfo_s init argument is separate; this stage does not invent its field layout.",
 "LIMIT=This is Apple 24H32 ABI observation, not an implementation plan or permission to register native queues.",
 "ACTIVATION_GATE=BLOCKED — interface registration, callback handoff, packet ownership and teardown integration remain open.",
 "SOURCE_TREE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN","========== END STAGE 61 =========="]
(outp/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if issues or not caller_init_ok or len(bodies)!=4 or len(count_rows)!=4 or len(attach_rows)!=4:
 raise SystemExit("Stage61 review required; inspect local evidence before proceeding")
PY3

cat "$OUT/audit-summary.txt"
echo
echo "Descriptor matrix: $OUT/queue-descriptor-record-matrix.txt"
echo "QueueSet jump tables: $OUT/queueset-classification-jump-tables.txt"
echo "QueueSet method: $OUT/queueset-init-disassembly.txt"
echo "Queue method disassembly: $OUT/queue-command-method-disassembly.txt"

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
obj={"message":"Add Stage61 read-only queue descriptor classification ABI audit","content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
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
 echo "STAGE=61"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only queue descriptor record layout and QueueSet classification/grouping audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage60 V1 $STAGE60_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
upload_artifact(){
 local file="$1" base group root
 base="$(basename "$file")"; group="Development/Logs/stage61/$RUN/$base"; root="Development/Logs/stage61-$RUN-$base"
 upload_one "$file" "$group" 0; upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/vtable-addresspoint-recheck.txt "$OUT"/queue-descriptor-record-matrix.txt "$OUT"/queueset-classification-jump-tables.txt "$OUT"/queueset-init-disassembly.txt "$OUT"/queue-command-method-disassembly.txt "$OUT"/method-status.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_artifact "$f"; else split -b 220k "$f" "$f.part-"; for part in "$f".part-*; do upload_artifact "$part"; done; fi
done
upload_one "$MAN" "Development/Logs/stage61/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage61-$RUN-manifest.txt" 0
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY7'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
old=base64.b64decode(json.load(open(remote))["content"])
entry=(
 "\n========== STAGE 61 QUEUE DESCRIPTOR / QUEUESET CLASSIFICATION AUDIT ==========\n"
 "STAGE61_RUN: %s\n"%run+
 "STAGE61_VERSION: %s\n"%version+
 "STAGE61_SCOPE: 24H32 performCommand 16-byte queue descriptor fields, queue-type IDs and QueueSet per-type arrays/counts\n"+
 "STAGE61_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — ABI grouping classified; native registration and TX/RX completion ownership remain open\n"+
 "STAGE61_LOGS: Development/Logs/stage61/%s/ and unique files directly under Development/Logs/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY7
upload_one "$OUT/output.log" "Development/output.log" 1
echo
echo "STAGE61_VERSION=$VERSION"
echo "STAGE61_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE61_RUN=$RUN"
echo "STAGE61_LOCAL_OUTPUT=$OUT"
echo "STAGE61_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage61/$RUN"
echo "STAGE61_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE61_SOURCE_MODIFIED=NO"
echo "STAGE61_BUILD=NOT_RUN"
echo "STAGE61_INSTALL=NOT_RUN"
echo "STAGE61_LOAD=NOT_RUN"
echo "STAGE61_OPENCORE_CHANGE=NONE"
echo "STAGE61_ACTIVATION_GATE=BLOCKED"
