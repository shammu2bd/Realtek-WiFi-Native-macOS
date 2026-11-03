#!/bin/bash
# Stage 89 V2: trace the 24H32 queue service-class field from getter/defaults through constructors.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

# Syntax-check every embedded Python block before using the target machine or GitHub.
python3 - "$0" <<'PY'
import ast, pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
blocks = []
i = 0
while i < len(lines):
    if re.search(r"<<'PY'\s*$", lines[i]):
        start = i + 1
        j = start
        while j < len(lines) and lines[j] != "PY":
            j += 1
        if j >= len(lines):
            raise SystemExit("ERROR: unterminated Python here-document near shell line %d" % (i + 1))
        blocks.append((i + 1, "\n".join(lines[start:j])))
        i = j
    i += 1
for line_no, source in blocks:
    try:
        ast.parse(source, filename="Stage89 V2 Python block near shell line %d" % line_no)
    except SyntaxError as exc:
        raise SystemExit("ERROR: embedded Python syntax error near shell line %d: %s" % (line_no, exc))
print("PREFLIGHT: embedded Python syntax PASS (%d blocks)" % len(blocks))
PY

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V1_RUN="run-20261103-211403-2ef027376f6e"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v2/$RUN"
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
 [[ "$(blob "$OUT/$1")" == "$2" ]] || fail "Pinned evidence mismatch: $1"
}
upload(){
 local f="$1" remote="$2" payload="$OUT/upload-payload.json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({
 "message":"Add Stage89 V2 constructor field and argument-flow audit",
 "content":base64.b64encode(p.read_bytes()).decode()
}))
PY
 gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json"
 put="$(python3 - "$OUT/upload-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$remote" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "GitHub readback mismatch: $remote"
}
append_log(){
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
 python3 - "$OUT/output-before.json" "$OUT/output-new.log" "$OUT/output-payload.json" "$RUN" "$V1_RUN" "$OUT/audit-summary.txt" <<'PY'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1]))
old=base64.b64decode(obj["content"])
run=sys.argv[4]
v1=sys.argv[5]
log=old.decode(errors="replace")
if ("STAGE89_V2_RUN: "+run) in log:
 raise SystemExit("Stage89 V2 run already exists in Development/output.log")
if ("STAGE89_RUN: "+v1) not in log:
 raise SystemExit("Pinned Stage89 V1 predecessor is not present in Development/output.log")
summary=pathlib.Path(sys.argv[6]).read_text(errors="replace")
def field(key):
 for line in summary.splitlines():
  if line.startswith(key+"="): return line.split("=",1)[1]
 return "NOT_REPORTED"
entry=(
"\n========== STAGE 89 V2 CONSTRUCTOR FIELD / ARGUMENT-FLOW AUDIT ==========\n"
"STAGE89_V2_RUN: "+run+"\n"
"STAGE89_V2_VERSION: STAGE89_V2_20261104\n"
"STAGE89_V1_PREDECESSOR: "+v1+"\n"
"GETTER_FIELD_OFFSET: "+field("GETTER_FIELD_OFFSET")+"\n"
"BASE_DEFAULT_SERVICE_CLASS: "+field("BASE_DEFAULT_SERVICE_CLASS")+"\n"
"TX_SUBMISSION_FIELD_WRITE: "+field("TX_SUBMISSION_FIELD_WRITE")+"\n"
"TX_COMPLETION_FIELD_WRITE: "+field("TX_COMPLETION_FIELD_WRITE")+"\n"
"RX_SUBMISSION_FIELD_WRITE: "+field("RX_SUBMISSION_FIELD_WRITE")+"\n"
"RX_COMPLETION_FIELD_WRITE: "+field("RX_COMPLETION_FIELD_WRITE")+"\n"
"SERVICE_CLASS_SETTER_SYMBOLS: "+field("SERVICE_CLASS_SETTER_SYMBOLS")+"\n"
"SERVICE_CLASS_MAPPING: "+field("SERVICE_CLASS_MAPPING")+"\n"
"STAGE89_V2_RESULT: "+field("RESULT")+"\n"
"SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"ACTIVATION_GATE: BLOCKED — no fully proven one-of-each WMM service-class mapping or native registration\n"
"STAGE89_V2_LOGS: Development/Logs/stage89-v2/"+run+"/\n"
"==========================================================================\n"
).encode()
new=old.rstrip()+entry
pathlib.Path(sys.argv[2]).write_bytes(new)
pathlib.Path(sys.argv[3]).write_text(json.dumps({
 "message":"Append Stage89 V2 constructor field and argument-flow audit",
 "sha":obj["sha"],
 "content":base64.b64encode(new).decode()
}))
PY
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
 local put want got
 put="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 want="$(blob "$OUT/output-new.log")"
 got="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "Development/output.log readback SHA mismatch"
}

for t in curl gh python3 grep awk sw_vers uname tee date tail basename sed cut xcrun find; do
 command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"
done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "New project source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1/24H32/x86_64"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v1-audit-summary.txt a167f773612b3ecb7fba61f44700efdd3716050f "$BASE/stage89/$V1_RUN/audit-summary.txt"
pin v1-api-matrix.txt e820714bbf1de1b7429c21e11454bf2d0de0076b "$BASE/stage89/$V1_RUN/service-class-api-matrix.txt"
pin v1-method-index.txt 53b60a5cb4492fad0c6c649def8c2c2233ff4e3c "$BASE/stage89/$V1_RUN/evidence/queue-method-index.txt"
pin v1-method-disassembly.txt 0782e94785a02ea59bedc6b388f5e621a4a1364b "$BASE/stage89/$V1_RUN/evidence/queue-service-class-method-disassembly.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage80-crosswalk.txt 423dd2db9e87f579e157294eb7da1131af0de873 "$BASE/stage80/run-20261102-185641-e10688bb526c/queue-constructor-and-typecode-crosswalk.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"

# The exact Stage89 V1 run must remain the latest Stage89 V1 evidence in the canonical log.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V1_RUN" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_RUN: (run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]:
 raise SystemExit("Latest Stage89 V1 run does not match the pinned constructor evidence")
PY

# Revalidate the 91-file driver source baseline before analyzing constructor call sites.
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1])
expected={}
for line in pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
ok=(len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and
 all(expected[k]==actual[k] for k in expected))
rows=["STAGE89_V2_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 if expected.get(rel)!=actual.get(rel):
  rows.append("MISMATCH="+rel+" EXPECTED="+expected.get(rel,"MISSING")+" ACTUAL="+actual.get(rel,"MISSING"))
rows.append("RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
pathlib.Path(sys.argv[3]).write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Local source tree does not match the pinned Stage73/Stage89 baseline")
PY

# Re-parse the local 24H32 kernel collection and inventory service-class-related methods.
python3 - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OUT/kernel-service-class-symbols.txt" <<'PY'
import pathlib,re,sys
tools,bootkc,cache,out=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
kc=KC(bootkc)
classes=["IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
         "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"]
rows=["STAGE89_V2_24H32_SERVICE_CLASS_SYMBOL_CATALOG","TARGET=macOS_15.8.1_24H32_x86_64"]
total=0
for cls in classes:
 rows.append("")
 rows.append("CLASS="+cls)
 found=[]
 for va,name in kc.methods(cls):
  low=name.lower()
  if ("serviceclass" in low or "service_class" in low or
      "withpool" in low or "initwithpool" in low or "service" in low):
   owner=kc.owner(va) or kc.sym_owner.get(va)
   found.append((va,name,owner))
 for va,name,owner in sorted(found):
  rows.append("ADDRESS=0x%016x SYMBOL=%s OWNER=%s"%(va,name,owner))
  total+=1
 service=[x for x in found if "serviceclass" in x[1].lower() or "service_class" in x[1].lower()]
 rows.append("SERVICE_CLASS_NAMED_METHODS="+str(len(service)))
 rows.append("SERVICE_CLASS_SETTER_CANDIDATES="+str(sum(1 for x in service if "set" in x[1].lower())))
rows += ["METHODS_RECORDED="+str(total),"RESULT=PASS"]
pathlib.Path(out).write_text("\n".join(rows)+"\n")
print("\n".join(rows))
PY

# Correlate getter/default/initializer stores and source factory calls without guessing any value.
python3 - "$OUT/v1-method-disassembly.txt" "$OUT/v1-api-matrix.txt" "$OUT/stage88-wmm-table.txt" "$OUT/stage80-crosswalk.txt" "$SRC" "$OUT/field-write-matrix.txt" "$OUT/audit-summary.txt" "$RUN" "$V1_RUN" <<'PY'
import pathlib,re,sys
disassembly,api_path,wmm_path,cross_path,src_path,matrix_path,summary_path,run,v1run=sys.argv[1:]
asm=pathlib.Path(disassembly).read_text(errors="replace")
api=pathlib.Path(api_path).read_text(errors="replace")
wmm=pathlib.Path(wmm_path).read_text(errors="replace")
cross=pathlib.Path(cross_path).read_text(errors="replace")
src=pathlib.Path(src_path)
def method(name):
 marker="===== "+name+" ====="
 pos=asm.find(marker)
 if pos<0: return ""
 end=asm.find("DISASSEMBLY_END",pos)
 return asm[pos:end+len("DISASSEMBLY_END")] if end>=0 else ""
names={
 "getter":"IOSkywalkPacketQueue_getServiceClass_0xffffff8002980bb0.txt",
 "base":"IOSkywalkPacketQueue_initWithPool_0xffffff8002980860.txt",
 "txs":"IOSkywalkTxSubmissionQueue_initWithPool_0xffffff80029840e8.txt",
 "txc":"IOSkywalkTxCompletionQueue_initWithPool_0xffffff8002989e96.txt",
 "rxs":"IOSkywalkRxSubmissionQueue_initWithPool_0xffffff80029857ee.txt",
 "rxc":"IOSkywalkRxCompletionQueue_initWithPool_0xffffff800298648a.txt",
 "txs_factory":"IOSkywalkTxSubmissionQueue_withPool_0xffffff8002983ff0.txt",
 "txc_factory":"IOSkywalkTxCompletionQueue_withPool_0xffffff8002989dec.txt",
 "rxs_factory":"IOSkywalkRxSubmissionQueue_withPool_0xffffff8002985724.txt",
 "rxc_factory":"IOSkywalkRxCompletionQueue_withPool_0xffffff80029863e0.txt"
}
methods={k:method(v) for k,v in names.items()}
missing=[k for k,v in methods.items() if not v]
if missing: raise SystemExit("Missing pinned method bodies: "+",".join(missing))
def instructions(body):
 return [x.strip() for x in body.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
def stores(body):
 return [x for x in instructions(body) if re.search(r"\bmov\s+dword ptr \[rbx \+ 0xb8\]",x)]
getter_ok=bool(re.search(r"mov\s+eax,\s*dword ptr \[rdi \+ 0xb8\]",methods["getter"]))
base_default=bool(re.search(r"mov\s+dword ptr \[rbx \+ 0xb8\],\s*0xffffffff",methods["base"]))
txs_store=stores(methods["txs"])
txc_store=stores(methods["txc"])
rxs_store=stores(methods["rxs"])
rxc_store=stores(methods["rxc"])
txs_origin=bool(txs_store and re.search(r"mov\s+r15d,\s*edx",methods["txs"]))
def api_call(key):
 m=re.search(r"^CURRENT_SOURCE_"+key+r"_CALL=(.*)$",api,re.M)
 return m.group(1) if m else "NOT_RECORDED"
calls={
 "TX_SUBMISSION":api_call("TX_SUBMISSION"),
 "TX_COMPLETION":api_call("TX_COMPLETION"),
 "RX_SUBMISSION":api_call("RX_SUBMISSION"),
 "RX_COMPLETION":api_call("RX_COMPLETION")
}
values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
source_cpp=(src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text(errors="replace")
no_source_field_write=not bool(re.search(r"(?:->|\.)\s*mServiceClass\s*=",source_cpp))
# Constructors are called through vtables; report observed field stores without claiming that a missing store proves every possible path.
checks={
 "GETTER_READS_FIELD_0XB8":getter_ok,
 "BASE_INIT_WRITES_0XFFFFFFFF_TO_0XB8":base_default,
 "TX_SUBMISSION_INIT_HAS_0XB8_FIELD_STORE":len(txs_store)==1,
 "TX_SUBMISSION_STORE_SOURCE_REGISTER_IDENTIFIED":txs_origin,
 "TX_COMPLETION_INIT_HAS_NO_0XB8_FIELD_STORE":len(txc_store)==0,
 "RX_SUBMISSION_INIT_HAS_NO_0XB8_FIELD_STORE":len(rxs_store)==0,
 "RX_COMPLETION_INIT_HAS_NO_0XB8_FIELD_STORE":len(rxc_store)==0,
 "FOUR_WMM_VALUES_PRESENT_AND_DISTINCT":len(values)==4 and len(set(values))==4,
 "SOURCE_DOES_NOT_DIRECTLY_WRITE_PRIVATE_FIELD":no_source_field_write,
 "ALL_FOUR_SOURCE_FACTORY_CALLS_FOUND":all(v!="NOT_RECORDED" for v in calls.values())
}
rows=[
 "STAGE89_V2_SERVICE_CLASS_FIELD_WRITE_MATRIX",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE89_V1_RUN="+v1run,
 "GETTER_FIELD_OFFSET=0xb8",
 "GETTER_READ_INSTRUCTION="+next((x for x in instructions(methods["getter"]) if "mov\teax" in x or "mov eax" in x),"NOT_FOUND"),
 "BASE_DEFAULT_SERVICE_CLASS=0xffffffff",
 "BASE_DEFAULT_STORE="+next((x for x in stores(methods["base"]) if "0xffffffff" in x),"NOT_FOUND"),
 "TX_SUBMISSION_FIELD_WRITE="+("; ".join(txs_store) if txs_store else "NONE"),
 "TX_SUBMISSION_WRITE_ORIGIN="+("incoming_EDX_first_numeric_argument_to_initWithPool" if txs_origin else "UNRESOLVED"),
 "TX_COMPLETION_FIELD_WRITE="+("; ".join(txc_store) if txc_store else "NONE_IN_CAPTURED_INIT"),
 "RX_SUBMISSION_FIELD_WRITE="+("; ".join(rxs_store) if rxs_store else "NONE_IN_CAPTURED_INIT"),
 "RX_COMPLETION_FIELD_WRITE="+("; ".join(rxc_store) if rxc_store else "NONE_IN_CAPTURED_INIT"),
 "TX_SUBMISSION_FACTORY_SOURCE_CALL="+calls["TX_SUBMISSION"],
 "TX_COMPLETION_FACTORY_SOURCE_CALL="+calls["TX_COMPLETION"],
 "RX_SUBMISSION_FACTORY_SOURCE_CALL="+calls["RX_SUBMISSION"],
 "RX_COMPLETION_FACTORY_SOURCE_CALL="+calls["RX_COMPLETION"],
 "WMM_REQUIRED_VALUES="+(",".join(values) if len(values)==4 else "UNRESOLVED"),
 "SOURCE_PRIVATE_FIELD_WRITE="+("NONE_FOUND" if no_source_field_write else "FOUND"),
 "SERVICE_CLASS_ASSIGNMENT=NOT_PROVEN_FOR_ALL_FOUR_QUEUES",
 "NOTE=The TX submission initializer's field store is fed from its incoming EDX register; public header parameter naming and factory wrapper argument flow still require semantic reconciliation.",
 "NOTE=The three captured completion/refill initializers show no write to offset 0xb8 after calling the base initializer; investigate alternate supported construction or setter paths before assigning values.",
 "NOTE=The base sentinel is not one of the four Stage88 WMM values and must not be treated as a valid WMM class."
]
for k,v in checks.items(): rows.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
pathlib.Path(matrix_path).write_text("\n".join(rows)+"\n")
summary=[
 "STAGE89_V2_CONSTRUCTOR_FIELD_AND_ARGUMENT_FLOW_AUDIT",
 "VERSION=STAGE89_V2_20261104",
 "RUN="+run,
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE89_V1_PREDECESSOR="+v1run,
 "SOURCE_TREE_REVALIDATION=PASS",
 "GETTER_FIELD_OFFSET="+("0xb8" if getter_ok else "UNRESOLVED"),
 "BASE_DEFAULT_SERVICE_CLASS="+("0xffffffff" if base_default else "UNRESOLVED"),
 "TX_SUBMISSION_FIELD_WRITE="+("FOUND" if txs_store else "NOT_FOUND"),
 "TX_COMPLETION_FIELD_WRITE="+("FOUND" if txc_store else "NOT_FOUND"),
 "RX_SUBMISSION_FIELD_WRITE="+("FOUND" if rxs_store else "NOT_FOUND"),
 "RX_COMPLETION_FIELD_WRITE="+("FOUND" if rxc_store else "NOT_FOUND"),
 "SERVICE_CLASS_SETTER_SYMBOLS=SEE_KERNEL_SERVICE_CLASS_SYMBOL_CATALOG",
 "SERVICE_CLASS_MAPPING=REVIEW_REQUIRED",
 "ALTERNATE_ASSIGNMENT_PATH=NOT_YET_PROVEN",
 "FOUR_QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "NATIVE_REGISTRATION_CALLS=0",
 "CALLBACK_HANDOFFS_STILL_MISSING=4",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "ACTIVATION_GATE=BLOCKED",
 "NEXT=Review service-class symbols and factory argument flow; do not implement the array until one valid class is proven for each queue."
]
pathlib.Path(summary_path).write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V2 CONSTRUCTOR FIELD / ARGUMENT-FLOW AUDIT ==========",
 *summary,
 "",
 "The getter and initializer stores are correlated from the captured 24H32 IOSkywalkFamily method bodies.",
 "A field write seen in one initializer is not assumed to prove the API's source-level parameter name. The factory-to-initializer argument chain must be independently reviewed.",
 "The four queue objects must each report one distinct Stage88 WMM service-class value. The base 0xffffffff sentinel is not accepted as one of those values.",
 "No private field is written, no registration is called, and the native start path remains fail-closed.",
 "========== END STAGE 89 V2 =========="
]
pathlib.Path(pathlib.Path(matrix_path).parent/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

# Add catalog findings to the summary and report, without promoting this audit to PASS.
python3 - "$OUT/audit-summary.txt" "$OUT/kernel-service-class-symbols.txt" "$OUT/audit-summary-v2.txt" <<'PY'
import pathlib,re,sys
summary=pathlib.Path(sys.argv[1]).read_text(errors="replace")
catalog=pathlib.Path(sys.argv[2]).read_text(errors="replace")
named=re.findall(r"SYMBOL=(\S+)",catalog)
setter=[x for x in named if "serviceclass" in x.lower() and "set" in x.lower()]
getter=[x for x in named if "serviceclass" in x.lower() and "get" in x.lower()]
summary=summary.replace("SERVICE_CLASS_SETTER_SYMBOLS=SEE_KERNEL_SERVICE_CLASS_SYMBOL_CATALOG",
 "SERVICE_CLASS_SETTER_SYMBOLS="+(";".join(setter) if setter else "NO_NAMED_SETTER_FOUND_IN_SCANNED_QUEUE_CLASSES"))
summary=summary.replace("SERVICE_CLASS_MAPPING=REVIEW_REQUIRED",
 "SERVICE_CLASS_MAPPING=REVIEW_REQUIRED; GETTERS="+str(len(getter))+"; SETTERS="+str(len(setter)))
pathlib.Path(sys.argv[3]).write_text(summary)
print("SERVICE_CLASS_GETTER_SYMBOLS="+str(getter))
print("SERVICE_CLASS_SETTER_SYMBOLS="+str(setter))
PY
mv "$OUT/audit-summary-v2.txt" "$OUT/audit-summary.txt"

# Rebuild report using the final summary.
python3 - "$OUT/audit-summary.txt" "$OUT/field-write-matrix.txt" "$OUT/kernel-service-class-symbols.txt" "$OUT/report.txt" <<'PY'
import pathlib,sys
summary=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
matrix=pathlib.Path(sys.argv[2]).read_text(errors="replace")
catalog=pathlib.Path(sys.argv[3]).read_text(errors="replace")
report=[
 "========== STAGE 89 V2 CONSTRUCTOR FIELD / ARGUMENT-FLOW AUDIT ==========",
 *summary,
 "",
 "FIELD WRITE MATRIX:",
 matrix,
 "",
 "SERVICE-CLASS SYMBOL CATALOG:",
 catalog,
 "",
 "The target getter reads offset 0xb8. The base initializer writes the 0xffffffff sentinel there. Only the TX submission initializer in the captured set shows a subsequent store to that field; the other three captured initializers show no such store.",
 "The TX submission store source register is identified, but its semantic parameter mapping through the static factory and public header remains under review. The Stage88 WMM predicate requires exactly one queue for each of the four decoded values.",
 "No private field is written, no registration is called, no build/install/load is performed, and OpenCore is untouched.",
 "========== END STAGE 89 V2 =========="
]
pathlib.Path(sys.argv[4]).write_text("\n".join(report)+"\n")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=89"
 echo "VERSION=STAGE89_V2_20261104"
 echo "RUN=$RUN"
 echo "TARGET=15.8.1/24H32/x86_64"
 echo "PREDECESSOR=Stage89 V1 $V1_RUN"
 echo "PHASE=SERVICE_CLASS_FIELD_WRITE_AND_ARGUMENT_FLOW"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "INSTALL=NOT_RUN"
 echo "LOAD=NOT_RUN"
 echo "OPENCORE_CHANGE=NONE"
 echo "ACTIVATION_GATE=BLOCKED"
} > "$MAN"
for f in "$OUT/source-tree-revalidation.txt" "$OUT/kernel-service-class-symbols.txt" "$OUT/field-write-matrix.txt" "$OUT/audit-summary.txt" "$OUT/report.txt"; do
 echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"
done

for f in "$OUT/source-tree-revalidation.txt" "$OUT/kernel-service-class-symbols.txt" "$OUT/field-write-matrix.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$MAN"; do
 upload "$f" "Development/Logs/stage89-v2/$RUN/$(basename "$f")"
done

append_log
echo "STAGE89_V2_RESULT=REVIEW_REQUIRED"
echo "STAGE89_V2_RUN=$RUN"
echo "STAGE89_V2_LOGS=https://github.com/$REPO/tree/main/Development/Logs/stage89-v2/$RUN"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
