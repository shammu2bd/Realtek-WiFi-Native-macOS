#!/bin/bash
# Stage 89 V1: inspect target 24H32 queue service-class constructors before adding a registration pointer array.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache" "$OUT/evidence"
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
 [[ "$(blob "$OUT/$1")" == "$2" ]] || fail "Pinned GitHub evidence mismatch: $1"
}
upload(){
 local f="$1" remote="$2" payload="$OUT/upload-payload.json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({
 "message":"Add Stage89 queue service-class constructor audit",
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
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
 python3 - "$OUT/output-current.json" "$OUT/output-new.log" "$OUT/output-payload.json" "$RUN" "$OUT/audit-summary.txt" <<'PY'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1]))
old=base64.b64decode(obj["content"])
run=sys.argv[4]
if ("STAGE89_RUN: "+run) in old.decode(errors="replace"):
 raise SystemExit("Stage89 run already logged")
summary=pathlib.Path(sys.argv[5]).read_text(errors="replace")
def field(key):
 for line in summary.splitlines():
  if line.startswith(key+"="): return line.split("=",1)[1]
 return "NOT_REPORTED"
entry=(
"\n========== STAGE 89 SERVICE-CLASS CONSTRUCTOR AUDIT ==========\n"
"STAGE89_RUN: "+run+"\n"
"STAGE89_VERSION: STAGE89_V1_20261104\n"
"STAGE89_PHASE: QUEUE_SERVICE_CLASS_CONSTRUCTOR_ABI_REVIEW\n"
"STAGE89_AUDIT_COLLECTION: "+field("AUDIT_COLLECTION")+"\n"
"STAGE89_RESULT: REVIEW_REQUIRED_PENDING_METHOD_SEMANTIC_REVIEW\n"
"STAGE89_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"ACTIVATION_GATE: BLOCKED — service-class assignment, four-pointer array and registration remain unimplemented\n"
"STAGE89_LOGS: Development/Logs/stage89/"+run+"/\n"
"===============================================================\n"
).encode()
new=old.rstrip()+entry
pathlib.Path(sys.argv[2]).write_bytes(new)
pathlib.Path(sys.argv[3]).write_text(json.dumps({
 "message":"Append Stage89 service-class constructor audit",
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
on_exit(){
 local rc=$?
 if (( rc != 0 )); then
  {
   echo "STAGE=89"
   echo "VERSION=STAGE89_V1_20261104"
   echo "RUN=$RUN"
   echo "EXIT_CODE=$rc"
   echo "SOURCE_MODIFIED=NO"
   echo "BUILD=NOT_RUN"
   echo "INSTALL=NOT_RUN"
   echo "LOAD=NOT_RUN"
   echo "OPENCORE_CHANGE=NONE"
   tail -n 160 "$OUT/console-output.log"
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then
   upload "$OUT/failure-report.txt" "Development/Logs/stage89/$RUN/failure-report.txt" || true
  fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 grep awk sw_vers uname tee date tail basename sed cut xcrun find; do
 command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"
done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Stage26 source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin stage88-manifest.txt b8396ad69aa40f1c1464dfb535117df45ca1c45f "$BASE/stage88/run-20261102-205135-b4f4ddc49298/manifest.txt"
pin stage88-summary.txt e0471ea2473b7f48b90a4f473bf3c2b695b601d9 "$BASE/stage88/run-20261102-205135-b4f4ddc49298/audit-summary.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage88-array-lifetime.txt 394c0ed715d6d219ae3e9990fab26ed0d2d49054 "$BASE/stage88/run-20261102-205135-b4f4ddc49298/queue-array-lifetime-abi.txt"
pin stage88-constraints.txt 754f3b979d7384b50ba158a45456ae7db6b39de5 "$BASE/stage88/run-20261102-205135-b4f4ddc49298/registration-plan-constraints.txt"
pin stage80-crosswalk.txt 423dd2db9e87f579e157294eb7da1131af0de873 "$BASE/stage80/run-20261102-185641-e10688bb526c/queue-constructor-and-typecode-crosswalk.txt"
pin stage61-descriptor-matrix.txt 04c68bd635f16bc7a51615031f8950d620ba0818 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queue-descriptor-record-matrix.txt"
pin stage61-classification-tables.txt 7b017c03a4f008ba017a0f40d557132a3f623f2f "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queueset-classification-jump-tables.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"

# Verify that the exact Stage88 V1 run remains the latest completed predecessor.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$OUT/stage88-preflight.txt" "$OUT/stage88-summary.txt" <<'PY'
import base64,json,pathlib,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE88_RUN: (run-[A-Za-z0-9-]+)",log)
versions=re.findall(r"STAGE88_VERSION: (STAGE88_V1_20261103)",log)
summary=pathlib.Path(sys.argv[3]).read_text(errors="replace")
if not runs or not versions or runs[-1]!="run-20261102-205135-b4f4ddc49298":
 raise SystemExit("Latest Stage88 V1 predecessor does not match the pinned run")
if "RESULT=PASS" not in summary or "ACTIVATION_GATE=BLOCKED" not in summary:
 raise SystemExit("Stage88 predecessor audit was not PASS/BLOCKED")
pathlib.Path(sys.argv[2]).write_text("STAGE88_RUN="+runs[-1]+"\nSTAGE88_VERSION=STAGE88_V1_20261103\nSTAGE88_RESULT=PASS\n")
PY

# Compare all current C/C++ driver files to the Stage73 SHA-256 baseline and inventory public API asymmetry.
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" \
 "$OUT/service-class-api-matrix.txt" "$OUT/four-queue-array-plan.txt" \
 "$OUT/stage88-wmm-table.txt" "$OUT/stage80-crosswalk.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1])
fp=pathlib.Path(sys.argv[2]).read_text(errors="replace")
reval=pathlib.Path(sys.argv[3])
api_out=pathlib.Path(sys.argv[4])
plan_out=pathlib.Path(sys.argv[5])
wmm=pathlib.Path(sys.argv[6]).read_text(errors="replace")
cross=pathlib.Path(sys.argv[7]).read_text(errors="replace")
expected={}
for line in fp.splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
source_ok=(len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and
 all(expected[k]==actual[k] for k in expected))
rr=["STAGE89_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING"); b=actual.get(rel,"MISSING")
 if a!=b: rr.append("MISMATCH="+rel+" EXPECTED="+a+" ACTUAL="+b)
rr.append("RESULT="+("PASS" if source_ok else "REVIEW_REQUIRED"))
reval.write_text("\n".join(rr)+"\n")
if not source_ok: raise SystemExit("Current driver source differs from Stage73/Stage88 baseline")

hdir=src/"MacKernelSDK/Headers/IOKit/skywalk"
base=(hdir/"IOSkywalkPacketQueue.h").read_text(errors="replace")
txs=(hdir/"IOSkywalkTxSubmissionQueue.h").read_text(errors="replace")
txc=(hdir/"IOSkywalkTxCompletionQueue.h").read_text(errors="replace")
rxs=(hdir/"IOSkywalkRxSubmissionQueue.h").read_text(errors="replace")
rxc=(hdir/"IOSkywalkRxCompletionQueue.h").read_text(errors="replace")
cpp=(src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text(errors="replace")
hpp=(src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp").read_text(errors="replace")
def sig(text,pat):
 m=re.search(pat,text,re.S)
 return m.group(0).replace("\n"," ").strip() if m else "NOT_FOUND"
roles=[
("_txSubmission","IOSkywalkTxSubmissionQueue",1),
("_txCompletion","IOSkywalkTxCompletionQueue",2),
("_rxSubmission","IOSkywalkRxSubmissionQueue",3),
("_rxCompletion","IOSkywalkRxCompletionQueue",4)]
calls={}
call_rows=[]
for member,klass,code in roles:
 m=re.search(r"\b"+re.escape(member)+r"\s*=\s*"+re.escape(klass)+r"::(withPool(?:AndServiceClass)?)\s*\((.*?)\);",cpp,re.S)
 if m:
  calls[member]=(m.group(1)," ".join(m.group(2).split()))
  call_rows.append("QUEUE="+member+" CLASS="+klass+" TYPECODE="+str(code)+" FACTORY="+m.group(1)+" ARGUMENTS="+calls[member][1]+" RESULT=FOUND")
 else:
  calls[member]=None
  call_rows.append("QUEUE="+member+" CLASS="+klass+" TYPECODE="+str(code)+" FACTORY=NOT_FOUND RESULT=REVIEW_REQUIRED")
values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
translation_units=[]
registration_hits=[]
for p in src.rglob("*"):
 if p.is_file() and p.suffix.lower() in {".cpp",".cc",".mm"}:
  raw=p.read_text(errors="replace")
  code=re.sub(r"/\*.*?\*/",lambda m:"\n"*m.group(0).count("\n"),raw,flags=re.S)
  code=re.sub(r"//[^\n]*","",code)
  code=re.sub(r'"(?:\\.|[^"\\])*"','""',code)
  code=re.sub(r"'(?:\\.|[^'\\])*'","''",code)
  translation_units.append(p)
  for name in ("registerInfraEthernetInterface","registerNetworkInterface","registerEthernetInterface"):
   for m in re.finditer(r"\b"+name+r"\s*\(",code):
    registration_hits.append(p.relative_to(src).as_posix()+":"+str(code.count("\n",0,m.start())+1)+":"+name)
checks={
"BASE_QUEUE_GET_SERVICE_CLASS_DECLARED":"getServiceClass()" in base,
"BASE_QUEUE_SERVICE_CLASS_MEMBER_DECLARED":"mServiceClass" in base,
"TX_SUBMISSION_EXPLICIT_SERVICE_CLASS_FACTORY":"withPoolAndServiceClass" in txs and "kern_packet_svc_class_t serviceClass" in txs,
"TX_COMPLETION_FACTORY_HAS_NO_SERVICE_CLASS_PARAMETER":"withPool(" in txc and "kern_packet_svc_class_t serviceClass" not in txc,
"RX_SUBMISSION_EXPLICIT_SERVICE_CLASS_PARAMETER":"kern_packet_svc_class_t serviceClass" in rxs,
"RX_COMPLETION_FACTORY_HAS_NO_SERVICE_CLASS_PARAMETER":"withPool(" in rxc and "kern_packet_svc_class_t serviceClass" not in rxc,
"FOUR_QUEUE_FACTORIES_FOUND":all(calls[x] is not None for x,_,_ in roles),
"TYPECODE_CROSSWALK_1_TO_4_REVALIDATED":all(x in cross for x in ["TYPE_CODE=1 TX submission","TYPE_CODE=2 TX completion","TYPE_CODE=3 RX submission","TYPE_CODE=4 RX completion"]),
"WMM_TABLE_HAS_FOUR_DISTINCT_VALUES":len(values)==4 and len(set(values))==4,
"NO_DIRECT_PRIVATE_SERVICE_CLASS_FIELD_WRITE":not bool(re.search(r"(?:->|\.)\s*mServiceClass\s*=",cpp+hpp)),
"NO_NATIVE_REGISTRATION_CALL":len(registration_hits)==0,
}
lines=[
"STAGE89_QUEUE_SERVICE_CLASS_API_MATRIX",
"TARGET=macOS_15.8.1_24H32_x86_64",
"BASE_GETTER_SIGNATURE="+sig(base,r"kern_packet_svc_class_t\s+getServiceClass\s*\([^;]*;"),
"BASE_MEMBER_DECLARATION="+sig(base,r"kern_packet_svc_class_t\s+mServiceClass\s*;"),
"TX_SUBMISSION_SERVICE_CLASS_FACTORY="+sig(txs,r"static IOSkywalkTxSubmissionQueue\s*\*\s*withPoolAndServiceClass\s*\([^;]*;"),
"TX_COMPLETION_FACTORY="+sig(txc,r"static IOSkywalkTxCompletionQueue\s*\*\s*withPool\s*\([^;]*;"),
"RX_SUBMISSION_FACTORY="+sig(rxs,r"static IOSkywalkRxSubmissionQueue\s*\*\s*withPool\s*\([^;]*;"),
"RX_COMPLETION_FACTORY="+sig(rxc,r"static IOSkywalkRxCompletionQueue\s*\*\s*withPool\s*\([^;]*;"),
"CURRENT_SOURCE_TX_SUBMISSION_CALL="+str(calls["_txSubmission"]),
"CURRENT_SOURCE_TX_COMPLETION_CALL="+str(calls["_txCompletion"]),
"CURRENT_SOURCE_RX_SUBMISSION_CALL="+str(calls["_rxSubmission"]),
"CURRENT_SOURCE_RX_COMPLETION_CALL="+str(calls["_rxCompletion"]),
"CURRENT_SOURCE_RX_SUBMISSION_SERVICE_CLASS="+(re.search(r"static_cast<kern_packet_svc_class_t>\(([^)]+)\)",calls["_rxSubmission"][1]).group(1) if calls["_rxSubmission"] and re.search(r"static_cast<kern_packet_svc_class_t>\(([^)]+)\)",calls["_rxSubmission"][1]) else "NOT_FOUND"),
"WMM_REQUIRED_VALUES="+(",".join(values) if len(values)==4 else "UNRESOLVED")]
"IMPLEMENTATION_TRANSLATION_UNITS_SCANNED="+str(len(translation_units)),
"REGISTRATION_CALL_LIKE_HITS="+(";".join(registration_hits) if registration_hits else "NONE")]
lines.extend(call_rows)
for name,ok in checks.items(): lines.append("CHECK="+name+" RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
api_out.write_text("\n".join(lines)+"\n")
plan=[
"STAGE89_FOUR_QUEUE_ARRAY_PRECONSTRUCTION_PLAN",
"QUEUE_COUNT=4",
"QUEUE_ROLES=TX_SUBMISSION,TX_COMPLETION,RX_SUBMISSION,RX_COMPLETION",
"APPLE_TYPECODES=1,2,3,4",
"ARRAY_ORDER=DETERMINISTIC_TYPECODE_ORDER; QUEUESET CLASSIFIES BY QUERIED TYPECODE; NO REQUIRED ORDINAL ORDER WAS PROVEN",
"ARRAY_LIFETIME=CALLER STORAGE MUST REMAIN VALID THROUGH SYNCHRONOUS REGISTER CALL RETURN",
"QUEUESET_LIFETIME=QUEUESET COPIES POINTERS AND RETAINS QUEUE OBJECTS AFTER SUCCESSFUL INITIALIZATION",
"WMM_GATE=EXACTLY_ONE_QUEUE_FOR_EACH_OF_FOUR_NUMERIC_SERVICE_CLASS_VALUES",
"WMM_VALUES="+(",".join(values) if len(values)==4 else "UNRESOLVED"),
"SERVICE_CLASS_ASSIGNMENT=NOT_YET_PROVEN_FOR_ALL_FOUR_QUEUE CLASSES",
"POINTER_ARRAY_IMPLEMENTATION=DEFERRED_PENDING_TARGET_INITIALIZER_REVIEW",
"PRIVATE_FIELD_WRITES=NOT_AUTHORIZED",
"NATIVE_REGISTRATION_CALL=ABSENT",
"ACTIVATION_GATE=BLOCKED"]
plan_out.write_text("\n".join(plan)+"\n")
PY

# Capture actual 24H32 getter and queue factory/initializer method bodies from the kernel collection.
python3 - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/evidence" <<'PY'
import pathlib,re,subprocess,sys
tools,bootkc,cache,objdump,evidence=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
kc=KC(bootkc)
expected_owner="com.apple.iokit.IOSkywalkFamily"
cache=pathlib.Path(cache); evidence=pathlib.Path(evidence)
method_dir=evidence/"queue-methods"; method_dir.mkdir(parents=True,exist_ok=True)
targets=[
("IOSkywalkPacketQueue","getServiceClass"),
("IOSkywalkPacketQueue","initWithPool"),
("IOSkywalkTxSubmissionQueue","withPool"),
("IOSkywalkTxSubmissionQueue","withPoolAndServiceClass"),
("IOSkywalkTxSubmissionQueue","initWithPool"),
("IOSkywalkTxCompletionQueue","withPool"),
("IOSkywalkTxCompletionQueue","initWithPool"),
("IOSkywalkRxSubmissionQueue","withPool"),
("IOSkywalkRxSubmissionQueue","initWithPool"),
("IOSkywalkRxCompletionQueue","withPool"),
("IOSkywalkRxCompletionQueue","initWithPool")]
inventory=["STAGE89_24H32_QUEUE_SERVICE_CLASS_METHOD_INVENTORY","TARGET=macOS_15.8.1_24H32_x86_64"]
carved={}
combined=["STAGE89_EXACT_QUEUE_SERVICE_CLASS_CONSTRUCTOR_DISASSEMBLY","TARGET=macOS_15.8.1_24H32_x86_64","SOURCE=BootKernelExtensions.kc"]
count=0; getter=0; ok=True
for cls,fragment in targets:
 found={}
 for va,nm in kc.methods(cls):
  if fragment in nm:
   owner=kc.owner(va) or kc.sym_owner.get(va)
   found.setdefault(va,[]).append((nm,owner))
 if not found:
  inventory.append("CLASS="+cls+" METHOD="+fragment+" STATUS=NOT_FOUND")
  ok=False
  continue
 for va,pairs in sorted(found.items()):
  names=[x[0] for x in pairs]; owner=pairs[0][1]
  if owner!=expected_owner:
   inventory.append("CLASS="+cls+" METHOD="+fragment+" ADDRESS=0x%x OWNER="%va+str(owner)+" STATUS=OWNER_REVIEW")
   ok=False
   continue
  if owner not in carved:
   path=cache/"ioskywalk-family.macho"
   kc.carve(owner,str(path))
   carved[owner]=path
  nxt=kc.next_sym(va)
  end=nxt if nxt and va<nxt<=va+0x10000 else va+0x2000
  proc=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn",
   "--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],
   capture_output=True,text=True)
  ins=[x for x in proc.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
  safe=proc.returncode==0 and len(ins)>0
  safe_name=re.sub(r"[^A-Za-z0-9_.-]+","_",cls+"_"+fragment)
  path=method_dir/(safe_name+"_0x%x.txt"%va)
  path.write_text("CLASS="+cls+"\nMETHOD_FRAGMENT="+fragment+"\nSYMBOLS="+",".join(names)+
   "\nADDRESS=0x%x"%va+"\nOWNER="+str(owner)+"\nINSTRUCTIONS="+str(len(ins))+
   "\nDISASSEMBLY_BEGIN\n"+proc.stdout.rstrip()+"\nDISASSEMBLY_END\n")
  inventory.append("CLASS="+cls+" METHOD="+fragment+" ADDRESS=0x%x"%va+
   " OWNER="+str(owner)+" SYMBOL_ALIASES="+str(len(names))+
   " INSTRUCTIONS="+str(len(ins))+" STATUS="+("CAPTURED" if safe else "DISASSEMBLY_FAILED"))
  combined.extend(["","===== "+path.name+" =====",path.read_text(errors="replace")])
  count+=1
  if fragment=="getServiceClass": getter+=1
  if not safe: ok=False
inventory.extend(["METHOD_BODIES_CAPTURED="+str(count),"GET_SERVICE_CLASS_GETTER_BODIES="+str(getter),
 "RESULT="+("PASS" if ok and getter>=1 else "REVIEW_REQUIRED")])
(evidence/"queue-method-index.txt").write_text("\n".join(inventory)+"\n")
(evidence/"queue-service-class-method-disassembly.txt").write_text("\n".join(combined)+"\n")
print("Captured",count,"method bodies; getter bodies:",getter)
if not ok or getter<1: print("REVIEW_REQUIRED: missing or failed method capture")
PY

# Summarize the audit but leave Stage 89 open until the method bodies are reviewed.
python3 - "$OUT" "$RUN" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1]); run=sys.argv[2]
api=(out/"service-class-api-matrix.txt").read_text(errors="replace")
idx=(out/"evidence/queue-method-index.txt").read_text(errors="replace")
reval=(out/"source-tree-revalidation.txt").read_text(errors="replace")
wmm=(out/"stage88-wmm-table.txt").read_text(errors="replace")
values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
checks=re.findall(r"^CHECK=.* RESULT=(PASS|REVIEW_REQUIRED)$",api,re.M)
getter=re.search(r"GET_SERVICE_CLASS_GETTER_BODIES=(\d+)",idx)
method_ok=("RESULT=PASS" in idx and getter is not None and int(getter.group(1))>=1)
source_ok="RESULT=PASS" in reval
api_ok=bool(checks) and all(x=="PASS" for x in checks)
summary=[
"STAGE89_24H32_QUEUE_SERVICE_CLASS_CONSTRUCTOR_AUDIT",
"VERSION=STAGE89_V1_20261104",
"RUN="+run,
"TARGET=macOS_15.8.1_24H32_x86_64",
"STAGE88_PREDECESSOR=PASS",
"SOURCE_TREE_REVALIDATION="+("PASS" if source_ok else "REVIEW_REQUIRED"),
"SERVICE_CLASS_API_MATRIX="+("PASS" if api_ok else "REVIEW_REQUIRED"),
"QUEUE_METHOD_DISASSEMBLY="+("CAPTURED" if method_ok else "REVIEW_REQUIRED"),
"METHOD_BODIES_CAPTURED="+re.search(r"METHOD_BODIES_CAPTURED=(\d+)",idx).group(1) if re.search(r"METHOD_BODIES_CAPTURED=(\d+)",idx) else "METHOD_BODIES_CAPTURED=0",
"GET_SERVICE_CLASS_GETTER_BODIES="+(getter.group(1) if getter else "0"),
"WMM_PREDICATE_RULE=EXACTLY_ONE_QUEUE_FOR_EACH_OF_FOUR_VALUES",
"WMM_NUMERIC_VALUES="+(",".join(values) if len(values)==4 else "UNRESOLVED"),
"CURRENT_SOURCE_QUEUE_ARRAY=NOT_IMPLEMENTED",
"NATIVE_REGISTRATION_CALLS=0",
"CALLBACK_HANDOFFS_STILL_MISSING=4",
"SERVICE_CLASS_ASSIGNMENT=REQUIRES_SEMANTIC_REVIEW_OF_CAPTURED_24H32_METHODS",
"POINTER_ARRAY_IMPLEMENTATION=DEFERRED_UNTIL_ALL_FOUR_SERVICE_CLASS_VALUES_ARE_PROVEN",
"PRIVATE_mServiceClass_FIELD_WRITE=NOT_PERMITTED_BY_THIS_STAGE",
"IMPLEMENTATION_AUTHORIZED=NO",
"SOURCE_MODIFIED=NO",
"BUILD=NOT_RUN",
"INSTALL=NOT_RUN",
"LOAD=NOT_RUN",
"OPENCORE_CHANGE=NONE",
"AUDIT_COLLECTION="+("PASS" if source_ok and api_ok and method_ok else "REVIEW_REQUIRED"),
"RESULT=REVIEW_REQUIRED",
"ACTIVATION_GATE=BLOCKED",
"NEXT=Review constructor/default service-class assignments, then implement the typed four-pointer array and host tests only after mapping is evidence-backed."]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(out/"report.txt").write_text("\n".join([
"========== STAGE 89 QUEUE SERVICE-CLASS CONSTRUCTOR AUDIT ==========",
*summary,
"",
"The WMM predicate reads getServiceClass() independently of the queue typecode. Typecode identifies queue role; service-class satisfies a separate one-of-each WMM gate.",
"This run captures the actual 24H32 getter and queue factory/initializer methods. It does not infer missing field values from the numeric WMM table and does not write private fields.",
"Pointer-array materialization is intentionally deferred until the captured constructor methods are semantically reviewed. The native interface start path remains fail-closed.",
"========== END STAGE 89 V1 =========="
])+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=89"
 echo "VERSION=STAGE89_V1_20261104"
 echo "RUN=$RUN"
 echo "TARGET=15.8.1/24H32/x86_64"
 echo "PREDECESSOR=Stage88 run-20261102-205135-b4f4ddc49298"
 echo "PHASE=QUEUE_SERVICE_CLASS_CONSTRUCTOR_ABI_REVIEW"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "INSTALL=NOT_RUN"
 echo "LOAD=NOT_RUN"
 echo "OPENCORE_CHANGE=NONE"
 echo "ACTIVATION_GATE=BLOCKED"
} > "$MAN"
while IFS= read -r f; do
 [[ -f "$f" ]] || continue
 rel="$(printf '%s' "$f" | sed "s#^$OUT/##")"
 echo "ARTIFACT|$rel|$(blob "$f")" >> "$MAN"
done < <(find "$OUT/evidence" -type f | sort)
for f in "$OUT/source-tree-revalidation.txt" "$OUT/service-class-api-matrix.txt" "$OUT/four-queue-array-plan.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$MAN"; do
 upload "$f" "Development/Logs/stage89/$RUN/$(basename "$f")"
done
while IFS= read -r f; do
 rel="$(printf '%s' "$f" | sed "s#^$OUT/##")"
 upload "$f" "Development/Logs/stage89/$RUN/$rel"
done < <(find "$OUT/evidence" -type f | sort)

append_log
echo "STAGE89_RESULT=REVIEW_REQUIRED"
echo "STAGE89_AUDIT_COLLECTION=$(grep '^AUDIT_COLLECTION=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE89_RUN=$RUN"
echo "STAGE89_LOGS=https://github.com/$REPO/tree/main/Development/Logs/stage89/$RUN"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
echo "Review uploaded method bodies before the Stage89 implementation patch."
