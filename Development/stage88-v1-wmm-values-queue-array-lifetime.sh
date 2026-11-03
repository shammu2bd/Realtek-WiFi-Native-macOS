#!/bin/bash
# Stage 88 V1 — WMM numeric table decode and four-queue pointer-array lifetime audit.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage88/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){
  python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){
  curl -fsSLo "$OUT/$1" "$3"
  local got
  got="$(blob "$OUT/$1")"
  [[ "$got" == "$2" ]] || fail "GitHub evidence pin mismatch: $1 got=$got expected=$2"
}
upload(){
  local f="$1" p="$2" j="$OUT/up-$(basename "$f").json" want put got
  want="$(blob "$f")"
  python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "message":"Add Stage88 WMM numeric and queue-array lifetime audit",
    "content":base64.b64encode(p.read_bytes()).decode()
}))
PY
  gh api --method PUT "repos/$REPO/contents/$p" --input "$j" > "$OUT/up-response.json"
  put="$(python3 - "$OUT/up-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
  got="$(gh api "repos/$REPO/contents/$p" -q .sha)"
  [[ "$put" == "$want" && "$got" == "$want" ]] || fail "GitHub readback mismatch: $p"
}
on_exit(){
  local rc=$?
  if (( rc != 0 )); then
    {
      echo "STAGE=88"
      echo "VERSION=STAGE88_V1_20261103"
      echo "RUN=$RUN"
      echo "EXIT_CODE=$rc"
      echo "SOURCE_MODIFIED=NO"
      echo "BUILD=NOT_RUN"
      echo "INSTALL=NOT_RUN"
      echo "LOAD=NOT_RUN"
      echo "OPENCORE_CHANGE=NONE"
      tail -n 180 "$OUT/console-output.log"
    } > "$OUT/failure-report.txt"
    if gh auth status >/dev/null 2>&1; then
      python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PYFAIL'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "message":"Stage88 failure report",
    "content":base64.b64encode(p.read_bytes()).decode()
}))
PYFAIL
      gh api --method PUT "repos/$REPO/contents/Development/Logs/stage88/$RUN/failure-report.txt" \
        --input "$OUT/failure.json" >/dev/null 2>&1 || true
    fi
  fi
}
trap on_exit EXIT

for t in curl gh python3 grep awk sw_vers uname tee date tail basename sed cut; do
  command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"
done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Stage26 source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || \
  fail "target must be macOS 15.8.1/24H32/x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin stage62-method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700 \
  "$BASE/stage62/run-20261102-161032-d54adc732d87/method-disassembly.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df \
  "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin stage85-wmm-predicate-disassembly.txt df766c24934be990085b893f9c8db204c17db839 \
  "$BASE/stage85/run-20261102-194932-c74efe86b7a2/wmm-predicate-disassembly.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || \
  fail "Pinned kernel collection parser mismatch"

# Require the latest published Stage87 V2 evidence before Stage88 proceeds.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/stage87-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE87_RUN: (run-[A-Za-z0-9-]+)",s)
versions=re.findall(r"STAGE87_VERSION: (STAGE87_V2_20261103)",s)
if not runs or not versions:
    raise SystemExit("Latest Stage87 V2 entry not found in Development/output.log")
open(sys.argv[2],"w").write(runs[-1])
PY
S87="$(cat "$OUT/stage87-run.txt")"
curl -fsSLo "$OUT/stage87-manifest.txt" "$BASE/stage87/$S87/manifest.txt"
S87_MANIFEST_SHA="$(gh api "repos/$REPO/contents/Development/Logs/stage87/$S87/manifest.txt" -q .sha)"
[[ "$(blob "$OUT/stage87-manifest.txt")" == "$S87_MANIFEST_SHA" ]] || fail "Stage87 manifest SHA mismatch"
grep -q '^VERSION=STAGE87_V2_20261103$' "$OUT/stage87-manifest.txt" || fail "Stage87 V2 required"
S87_SUMMARY_SHA="$(awk -F'|' '$1=="ARTIFACT"&&$2=="audit-summary.txt"{print $3}' "$OUT/stage87-manifest.txt")"
[[ -n "$S87_SUMMARY_SHA" ]] || fail "Stage87 manifest missing audit-summary.txt"
curl -fsSLo "$OUT/stage87-audit-summary.txt" "$BASE/stage87/$S87/audit-summary.txt"
[[ "$(blob "$OUT/stage87-audit-summary.txt")" == "$S87_SUMMARY_SHA" ]] || fail "Stage87 audit-summary SHA mismatch"
grep -q '^RESULT=PASS$' "$OUT/stage87-audit-summary.txt" || fail "Stage87 predecessor is not PASS"

# Run the ABI, source ownership and WMM constant audits against the pinned 24H32 files.
python3 - "$OUT/tools" "$BOOTKC" "$SRC" "$OUT/stage73-source-fingerprint.txt" \
  "$OUT/stage62-method-disassembly.txt" "$OUT/stage85-wmm-predicate-disassembly.txt" \
  "$OUT/kc-cache" "$OBJDUMP" "$OUT" "$RUN" "$S87" <<'PY'
import hashlib,pathlib,re,struct,sys
tools,bootkc,src_arg,fp_arg,stage62_arg,stage85_arg,cache_arg,objdump,out_arg,run,stage87=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC

src=pathlib.Path(src_arg)
out=pathlib.Path(out_arg)
fp=pathlib.Path(fp_arg).read_text(errors="replace")
stage62=pathlib.Path(stage62_arg).read_text(errors="replace")
stage85=pathlib.Path(stage85_arg).read_text(errors="replace")

expected={}
for line in fp.splitlines():
    m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
    if m:
        expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
source_ok=(len(expected)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected))
reval=[
    "STAGE88_SOURCE_TREE_REVALIDATION",
    "EXPECTED_FILES=%d"%len(expected),
    "ACTUAL_FILES=%d"%len(actual),
    "RESULT="+("PASS" if source_ok else "REVIEW_REQUIRED")
]
for rel in sorted(set(expected)|set(actual)):
    a=expected.get(rel,"MISSING")
    b=actual.get(rel,"MISSING")
    if a!=b:
        reval.append("MISMATCH="+rel+" EXPECTED="+a+" ACTUAL="+b)
(out/"source-tree-revalidation.txt").write_text("\n".join(reval)+"\n")

def get_method(label):
    for m in re.finditer(r"^===== METHOD .*?label="+re.escape(label)+r".*?$",stage62,re.M):
        start=m.start()
        end=stage62.find("DISASSEMBLY_END",m.end())
        if end<0:
            continue
        return stage62[start:end+len("DISASSEMBLY_END")]
    return ""

queue_init=get_method("queueset_init")
queue_free=get_method("queueset_free")
logical_init=get_method("logical_link_init")
logical_free=get_method("logical_link_free")
array_reg=get_method("queue_array_registration")
abi_checks={
    "REGISTRATION_WRAPPER_TESTS_WMM_BEFORE_QUEUESET_CREATE":
        ("isWMMSchedModelCapable" in array_reg and "createWithQueues" in array_reg and
         array_reg.find("isWMMSchedModelCapable") < array_reg.find("createWithQueues")),
    "QUEUESET_INIT_READS_INPUT_POINTER_ARRAY":
        bool(re.search(r"mov\s+rdi,\s*qword ptr \[rbx \+ 8\*r15\]",queue_init,re.I)),
    "QUEUESET_INIT_STORES_COUNT_IN_OBJECT":
        bool(re.search(r"mov\s+qword ptr \[rdi \+ 0x58\],\s*rdx",queue_init,re.I)),
    "QUEUESET_INIT_ALLOCATES_INTERNAL_QUEUE_POINTER_STORAGE":
        bool(re.search(r"mov\s+qword ptr \[r14 \+ 0x18\],\s*rax",queue_init,re.I)),
    "QUEUESET_INIT_COPIES_QUEUE_POINTERS_INTO_INTERNAL_STORAGE":
        bool(re.search(r"mov\s+qword ptr \[rax \+ 8\*r12\],\s*r13",queue_init,re.I)),
    "QUEUESET_INIT_DOES_NOT_STORE_CALLER_ARRAY_BASE_POINTER":
        not bool(re.search(r"mov\s+qword ptr \[r14 \+ [^\]]+\],\s*rbx",queue_init,re.I)),
    "QUEUESET_INIT_RETAINS_QUEUE_OBJECTS":
        bool(re.search(r"call\s+qword ptr \[rax \+ 0x20\]",queue_init,re.I)),
    "QUEUESET_FREE_CLEARS_BACKREFERENCE_AND_RELEASES_QUEUE":
        ("setQueueSetEP17IOSkywalkQueueSet" in queue_free and
         bool(re.search(r"call\s+qword ptr \[rax \+ 0x28\]",queue_free,re.I))),
    "QUEUESET_FREE_DEALLOCATES_INTERNAL_QUEUE_STORAGE":
        bool(re.search(r"mov\s+qword ptr \[rbx \+ 0x18\],\s*r15",queue_free,re.I)),
    "LOGICALLINK_INIT_ALLOCATES_OWN_QUEUESET_POINTER_STORAGE":
        bool(re.search(r"mov\s+qword ptr \[rbx \+ 0x10\],\s*rax",logical_init,re.I)),
    "LOGICALLINK_INIT_RETAINS_QUEUESET_OBJECTS":
        bool(re.search(r"call\s+qword ptr \[rax \+ 0x20\]",logical_init,re.I)),
    "LOGICALLINK_FREE_RELEASES_QUEUESET_OBJECTS":
        bool(re.search(r"call\s+qword ptr \[rax \+ 0x28\]",logical_free,re.I)),
}
abi_ok=all(abi_checks.values())
abi_lines=[
    "STAGE88_QUEUE_ARRAY_LIFETIME_ABI",
    "TARGET=macOS_15.8.1_24H32_x86_64",
    "SOURCE=PINNED_STAGE62_METHOD_DISASSEMBLY",
    "SOURCE_SHA1=af5d43e7d7371910b8e65829309ef6b7b52ea700",
]
for k,v in abi_checks.items():
    abi_lines.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
abi_lines += [
    "",
    "INTERPRETATION=The generic registration wrapper first calls the WMM predicate and then QueueSet creation with the same queue-array pointer and count.",
    "INTERPRETATION=QueueSet initialization iterates the caller array, allocates its own pointer storage, copies queue object pointers into that storage and retains the queue objects.",
    "INTERPRETATION=QueueSet teardown walks its internally owned queue-pointer storage, clears each queue's QueueSet back-reference, releases each queue and deallocates the internal storage.",
    "INTERPRETATION=LogicalLink similarly allocates its own QueueSet pointer storage, retains QueueSet objects and releases them during teardown.",
    "RAW_INPUT_ARRAY_LIFETIME=REQUIRED_THROUGH_SYNCHRONOUS_REGISTER_CALL; NO_RAW_ARRAY_POINTER_STORE_FOUND_IN_QUEUESET_INIT",
    "STACK_ARRAY_COMPATIBILITY=SUPPORTED_BY_CAPTURED_CALL_AND_COPY_FLOW, provided the array remains alive until registerNetworkInterface returns",
    "QUEUE_OBJECT_LIFETIME=OBJECTS_MUST_REMAIN_VALID_DURING_REGISTRATION; THE_QUEUESET_RETAINS_THEM_AFTER_SUCCESSFUL_INITIALIZATION",
    "CAUTION=This does not remove the driver's responsibility to keep its own queue references, handle registration failure, and stop callbacks before releasing queue objects."
]
(out/"queue-array-lifetime-abi.txt").write_text("\n".join(abi_lines)+"\n")

# Decode the compiler-emitted four-element WMM AC table from the owning kernel-collection Mach-O.
kc=KC(bootkc)
method_symbol="__ZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuem"
table_symbol="__ZZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuemE5wmmAC"
method_va=kc.find(method_symbol)
table_va=kc.find(table_symbol)
expected_table_va=0xffffff80029a6e40
owner=kc.owner(table_va) if table_va else None
table_bytes=None
if table_va and owner in kc.entry_segs:
    for seg in kc.entry_segs[owner]:
        _name,vm,vmsize,fileoff,filesize,_prot,_owner=seg
        if vm <= table_va and table_va+16 <= vm+filesize:
            off=fileoff+(table_va-vm)
            table_bytes=bytes(kc.d[off:off+16])
            break
table_ok=(method_va==0xffffff800298ac44 and table_va==expected_table_va and
          owner=="com.apple.iokit.IOSkywalkFamily" and table_bytes is not None and len(table_bytes)==16)
values=struct.unpack("<4I",table_bytes) if table_ok else ()
if table_ok:
    table_ok=(len(set(values))==4)
table_rows=[
    "STAGE88_WMM_SERVICE_CLASS_NUMERIC_TABLE",
    "TARGET=macOS_15.8.1_24H32_x86_64",
    "METHOD_SYMBOL="+method_symbol,
    "METHOD_ADDRESS="+("0x%016x"%method_va if method_va else "NOT_FOUND"),
    "TABLE_SYMBOL="+table_symbol,
    "TABLE_ADDRESS="+("0x%016x"%table_va if table_va else "NOT_FOUND"),
    "TABLE_EXPECTED_ADDRESS=0x%016x"%expected_table_va,
    "MACHO_OWNER="+str(owner),
    "TABLE_BYTES="+(table_bytes.hex() if table_bytes else "UNREADABLE"),
    "ENTRY_WIDTH=4_BYTES_LITTLE_ENDIAN",
    "ENTRY_COUNT=4",
]
if values:
    for i,v in enumerate(values):
        table_rows.append("WMM_SERVICE_CLASS_%d=0x%08x (%u)"%(i,v,v))
    table_rows.append("UNIQUE_VALUES="+("YES" if len(set(values))==4 else "NO"))
    table_rows.append("SYMBOLIC_ENUM_NAMES=NOT_INFERRED_FROM_NUMERIC_TABLE")
else:
    table_rows.append("WMM_SERVICE_CLASS_VALUES=UNRESOLVED")
table_rows.append("RESULT="+("PASS" if table_ok else "REVIEW_REQUIRED"))
(out/"wmm-service-class-table.txt").write_text("\n".join(table_rows)+"\n")

# Inspect ownership and construction/teardown of the four existing driver queue objects.
queue_cpp=src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
queue_hpp=src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
queue_files_ok=queue_cpp.is_file() and queue_hpp.is_file()
members=["_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"]
ownership=[
    "STAGE88_DRIVER_QUEUE_OWNERSHIP_INVENTORY",
    "CPP_FILE="+queue_cpp.relative_to(src).as_posix(),
    "HPP_FILE="+queue_hpp.relative_to(src).as_posix(),
    "SOURCE_FILES_SCANNED=%d"%len(files),
]
member_pass={}
all_text={}
for p in files:
    try:
        all_text[p.relative_to(src).as_posix()]=p.read_text(errors="replace").splitlines()
    except Exception:
        all_text[p.relative_to(src).as_posix()]=[]
for member in members:
    hits=[]
    declarations=[]
    factory=[]
    release=[]
    clear=[]
    for rel,lines in all_text.items():
        for i,line in enumerate(lines):
            if member not in line:
                continue
            item="%s:%d:%s"%(rel,i+1,line.strip())
            hits.append(item)
            if re.search(r"\b"+re.escape(member)+r"\s*=\s*nullptr",line):
                clear.append(item)
            if re.search(r"\b"+re.escape(member)+r"\s*=\s*IOSkywalk\w+::withPool\s*\(",line):
                factory.append(item)
            if re.search(r"\b"+re.escape(member)+r"\s*->\s*release\s*\(",line):
                release.append(item)
            if re.search(r"\bIOSkywalk\w+\s*\*\s*"+re.escape(member)+r"\b",line):
                declarations.append(item)
    ownership += [
        "",
        "MEMBER="+member,
        "REFERENCE_COUNT=%d"%len(hits),
        "DECLARATION_COUNT=%d"%len(declarations),
        "FACTORY_ASSIGNMENT_COUNT=%d"%len(factory),
        "RELEASE_CALL_COUNT=%d"%len(release),
        "NULL_CLEAR_COUNT=%d"%len(clear),
        "DECLARATIONS:",*(declarations or ["NONE"]),
        "FACTORY_ASSIGNMENTS:",*(factory or ["NONE"]),
        "RELEASE_CALLS:",*(release or ["NONE"]),
        "NULL_CLEARS:",*(clear or ["NONE"]),
        "ALL_REFERENCES:",*(hits or ["NONE"])
    ]
    member_pass[member]=(len(declarations)>=1 and len(factory)>=1 and len(release)>=1 and len(clear)>=1)

if queue_files_ok:
    for p in [queue_hpp,queue_cpp]:
        lines=p.read_text(errors="replace").splitlines()
        ownership += ["", "===== NUMBERED SOURCE: "+p.relative_to(src).as_posix()+" ====="]
        for i,line in enumerate(lines,1):
            ownership.append("%04d %s"%(i,line))
else:
    ownership.append("REQUIRED_QUEUE_SOURCE_FILES=NOT_FOUND")
(out/"driver-queue-ownership-inventory.txt").write_text("\n".join(ownership)+"\n")

# Re-scan source for any real pointer-array declaration or registration-call implementation.
pointer_hits=[]
registration_hits=[]
for p in files:
    rel=p.relative_to(src).as_posix()
    text=p.read_text(errors="replace")
    clean=re.sub(r"/\*.*?\*/",lambda m:"\n"*m.group(0).count("\n"),text,flags=re.S)
    clean=re.sub(r"//[^\n]*","",clean)
    clean=re.sub(r'"(?:\\.|[^"\\])*"','""',clean)
    clean=re.sub(r"'(?:\\.|[^'\\])*'","''",clean)
    for m in re.finditer(r"\bIOSkywalkPacketQueue\s*\*+\s*[A-Za-z_]\w*\s*\[\s*\d*\s*\]",clean):
        pointer_hits.append("%s:%d:%s"%(rel,clean.count("\n",0,m.start())+1,m.group(0)))
    if p.suffix.lower() in {".cpp",".cc",".mm"}:
        for name in ["registerNetworkInterface","registerInfraEthernetInterface","registerEthernetInterface"]:
            for m in re.finditer(r"\b"+name+r"\s*\(",clean):
                end=m.end()
                depth=1
                while end<len(clean) and depth:
                    if clean[end]=="(": depth+=1
                    elif clean[end]==")": depth-=1
                    end+=1
                tail=end
                while tail<len(clean) and clean[tail].isspace():
                    tail+=1
                if depth==0 and tail<len(clean) and clean[tail]==";":
                    registration_hits.append("%s:%d:%s"%(rel,clean.count("\n",0,m.start())+1,name))
source_lines=[
    "STAGE88_QUEUE_ARRAY_AND_REGISTRATION_SOURCE_SCAN",
    "POINTER_ARRAY_DECLARATIONS=%d"%len(pointer_hits),
    *(pointer_hits or ["NONE_FOUND"]),
    "NATIVE_REGISTRATION_CALLS=%d"%len(registration_hits),
    *(registration_hits or ["NONE_FOUND"])
]
(out/"queue-array-source-scan.txt").write_text("\n".join(source_lines)+"\n")

driver_ownership_ok=queue_files_ok and all(member_pass.values()) and source_ok
numeric_ok=table_ok
all_ok=source_ok and queue_files_ok and abi_ok and numeric_ok and driver_ownership_ok
summary=[
    "STAGE88_24H32_WMM_VALUES_AND_QUEUE_ARRAY_LIFETIME_AUDIT",
    "TARGET=macOS_15.8.1_24H32_x86_64",
    "STAGE87_PREDECESSOR="+stage87,
    "STAGE87_PREDECESSOR_RESULT=PASS",
    "SOURCE_TREE_REVALIDATION="+("PASS" if source_ok else "REVIEW_REQUIRED"),
    "WMM_TABLE_SYMBOL="+table_symbol,
    "WMM_TABLE_ADDRESS="+("0x%016x"%table_va if table_va else "NOT_FOUND"),
    "WMM_NUMERIC_VALUES="+(",".join("0x%08x"%v for v in values) if values else "UNRESOLVED"),
    "WMM_TABLE_DECODE="+("PASS" if numeric_ok else "REVIEW_REQUIRED"),
    "WMM_SYMBOLIC_ENUM_NAMES=NOT_INFERRED",
    "QUEUESET_INPUT_ARRAY_COPIED_TO_INTERNAL_STORAGE="+("YES" if abi_checks["QUEUESET_INIT_COPIES_QUEUE_POINTERS_INTO_INTERNAL_STORAGE"] else "NOT_PROVEN"),
    "QUEUESET_RETAINS_QUEUE_OBJECTS="+("YES" if abi_checks["QUEUESET_INIT_RETAINS_QUEUE_OBJECTS"] else "NOT_PROVEN"),
    "QUEUESET_TEARDOWN_RELEASES_QUEUE_OBJECTS="+("YES" if abi_checks["QUEUESET_FREE_CLEARS_BACKREFERENCE_AND_RELEASES_QUEUE"] else "NOT_PROVEN"),
    "RAW_ARRAY_POINTER_RETAINED_BY_QUEUESET=NO_EVIDENCE_FOUND_IN_INIT_METHOD" if abi_ok else "RAW_ARRAY_POINTER_RETAINED_BY_QUEUESET=NOT_PROVEN",
    "STACK_ARRAY_FOR_SYNCHRONOUS_REGISTRATION="+("ABI_SUPPORTED" if abi_ok else "REQUIRES_REVIEW"),
    "DRIVER_QUEUE_MEMBER_OWNERSHIP="+("FACTORY_AND_RELEASE_PATHS_FOUND" if driver_ownership_ok else "REVIEW_REQUIRED"),
    "DRIVER_QUEUE_POINTER_ARRAY="+("NOT_IMPLEMENTED" if len(pointer_hits)==0 else "CANDIDATE_FOUND"),
    "DRIVER_NATIVE_REGISTRATION_CALLS="+str(len(registration_hits)),
    "CALLBACK_HANDOFFS_STILL_MISSING=4",
    "CALLBACK_HANDOFF_1=TX_submission_to_adapter",
    "CALLBACK_HANDOFF_2=TX_completion_to_drain",
    "CALLBACK_HANDOFF_3=RX_submission_to_refill",
    "CALLBACK_HANDOFF_4=RX_completion_to_controller_delivery",
    "IMPLEMENTATION_AUTHORIZED=NO",
    "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
    "RESULT="+("PASS" if all_ok else "REVIEW_REQUIRED"),
    "ACTIVATION_GATE=BLOCKED"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(out/"registration-plan-constraints.txt").write_text("\n".join([
    "STAGE88_REGISTRATION_IMPLEMENTATION_CONSTRAINTS",
    "1. The caller must provide four valid, non-null queue objects and a count matching the supplied array.",
    "2. Each queue must report one of the four decoded WMM service-class values; the WMM predicate accepts exactly one of each value.",
    "3. The pointer-array memory must remain valid through the full synchronous registration call because the wrapper traverses it for WMM checking and QueueSet creation.",
    "4. The captured QueueSet initializer copies queue pointers into its own allocated storage and retains the queue objects; it does not store the caller array base pointer.",
    "5. Keep driver-side references until registration has completed and teardown has detached callbacks and released the queue objects safely.",
    "6. On partial construction or registration failure, unwind only objects whose ownership was successfully established; do not double-release objects retained by Apple QueueSet ownership.",
    "7. QueueSet teardown clears per-queue back-references, releases retained queues and frees its internal pointer storage; coordinate driver teardown with this lifecycle.",
    "8. Preserve separate TX submission, TX completion, RX submission and RX completion queue roles; the Apple QueueSet classifies supplied queues by performCommand typecode.",
    "9. Do not proceed to build or activation from this audit alone: native registration and all four TX/RX callback handoffs remain absent.",
    "WMM_NUMERIC_VALUES="+(",".join("0x%08x"%v for v in values) if values else "UNRESOLVED"),
    "WMM_SYMBOLIC_ENUM_NAMES=NOT_INFERRED",
    "SOURCE_MODIFIED=NO"
])+"\n")
(out/"report.txt").write_text("\n".join([
    "========== STAGE 88 WMM VALUES / QUEUE ARRAY LIFETIME ==========",
    "VERSION=STAGE88_V1_20261103",
    "RUN="+run,
    "TARGET=macOS_15.8.1_24H32_x86_64",
    *summary,
    "INTERPRETATION=This stage decodes the actual 24H32 WMM values and determines the source-array and queue-object lifetime contract from pinned Apple method bodies. It does not implement registration or callbacks.",
    "NEXT_GATE=Use the decoded service-class values and ownership rules to design the driver's four-queue array and registration-failure/teardown path; then audit all four callback handoffs before a build.",
    "========== END STAGE 88 =========="
])+"\n")
print("\n".join(summary))
PY

# Publish all artifacts, then append and verify the central progress log.
MAN="$OUT/manifest.txt"
{
  echo "STAGE=88"
  echo "VERSION=STAGE88_V1_20261103"
  echo "RUN=$RUN"
  echo "TARGET=15.8.1/24H32/x86_64"
  echo "PREDECESSOR=Stage87"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "OPENCORE_CHANGE=NONE"
  echo "ACTIVATION_GATE=BLOCKED"
} > "$MAN"
for f in \
  "$OUT/audit-summary.txt" \
  "$OUT/source-tree-revalidation.txt" \
  "$OUT/wmm-service-class-table.txt" \
  "$OUT/queue-array-lifetime-abi.txt" \
  "$OUT/driver-queue-ownership-inventory.txt" \
  "$OUT/queue-array-source-scan.txt" \
  "$OUT/registration-plan-constraints.txt" \
  "$OUT/report.txt"; do
  echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"
done
for f in \
  "$OUT/audit-summary.txt" \
  "$OUT/source-tree-revalidation.txt" \
  "$OUT/wmm-service-class-table.txt" \
  "$OUT/queue-array-lifetime-abi.txt" \
  "$OUT/driver-queue-ownership-inventory.txt" \
  "$OUT/queue-array-source-scan.txt" \
  "$OUT/registration-plan-constraints.txt" \
  "$OUT/report.txt" \
  "$MAN"; do
  upload "$f" "Development/Logs/stage88/$RUN/$(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/output-payload.json" "$RUN" "$OUT/audit-summary.txt" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]))
old=base64.b64decode(o["content"])
summary=pathlib.Path(sys.argv[4]).read_text()
def get(k):
    for line in summary.splitlines():
        if line.startswith(k+"="):
            return line.split("=",1)[1]
    return "UNKNOWN"
entry=(
    "\n========== STAGE 88 WMM VALUES / QUEUE ARRAY LIFETIME ==========\n"
    "STAGE88_RUN: "+sys.argv[3]+"\n"
    "STAGE88_VERSION: STAGE88_V1_20261103\n"
    "STAGE88_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
    "WMM_TABLE_DECODE: "+get("WMM_TABLE_DECODE")+"\n"
    "QUEUE_ARRAY_LIFETIME: "+get("STACK_ARRAY_FOR_SYNCHRONOUS_REGISTRATION")+"\n"
    "DRIVER_QUEUE_POINTER_ARRAY: "+get("DRIVER_QUEUE_POINTER_ARRAY")+"\n"
    "ACTIVATION_GATE: BLOCKED\n"
    "STAGE88_LOGS: Development/Logs/stage88/"+sys.argv[3]+"/\n"
    "=================================================================\n"
).encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "message":"Append Stage88 WMM and queue-array lifetime audit",
    "sha":o["sha"],
    "content":base64.b64encode(old.rstrip()+entry).decode()
}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
put="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
got="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$put" == "$got" ]] || fail "Development/output.log readback mismatch"

echo "STAGE88_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE88_RUN=$RUN"
echo "STAGE88_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage88/$RUN"
