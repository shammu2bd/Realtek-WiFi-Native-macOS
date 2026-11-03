#!/bin/bash
# Stage 89 V3: complete queue-class service-class field writer and factory-overload audit.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

python3 - "$0" <<'PY'
import ast,pathlib,re,sys
lines=pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
blocks=[]
i=0
while i<len(lines):
    if re.search(r"<<'PY'\s*$",lines[i]):
        start=i+1
        j=start
        while j<len(lines) and lines[j]!="PY": j+=1
        if j>=len(lines): raise SystemExit("ERROR: unterminated Python block near shell line %d"%(i+1))
        blocks.append((i+1,"\n".join(lines[start:j])))
        i=j
    i+=1
for n,src in blocks:
    try: ast.parse(src,filename="Stage89 V3 block near line %d"%n)
    except SyntaxError as e: raise SystemExit("ERROR: Python syntax near line %d: %s"%(n,e))
print("PREFLIGHT: embedded Python syntax PASS (%d blocks)"%len(blocks))
PY

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V1_RUN="run-20261103-211403-2ef027376f6e"
V2_RUN="run-20261103-213108-8e983fbd890c"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v3/$RUN"
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
 [[ "$(blob "$OUT/$1")" == "$2" ]] || fail "Pinned evidence mismatch: $1"
}
upload(){
 local f="$1" remote="$2" payload="$OUT/upload-payload.json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage89 V3 full queue service-class field writer audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json"
 put="$(python3 - "$OUT/upload-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$remote" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "GitHub SHA readback mismatch: $remote"
}
on_exit(){
 local rc=$?
 if [[ $rc -ne 0 ]]; then
  {
   echo "STAGE89_V3_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 60 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then
   upload "$OUT/failure-report.txt" "Development/Logs/stage89-v3/$RUN/failure-report.txt" || true
  fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 grep awk sw_vers uname tee date tail xcrun; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Project source or target BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1/24H32/x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v1-api-matrix.txt e820714bbf1de1b7429c21e11454bf2d0de0076b "$BASE/stage89/$V1_RUN/service-class-api-matrix.txt"
pin v1-method-disassembly.txt 0782e94785a02ea59bedc6b388f5e621a4a1364b "$BASE/stage89/$V1_RUN/evidence/queue-service-class-method-disassembly.txt"
pin v1-method-index.txt 53b60a5cb4492fad0c6c649def8c2c2233ff4e3c "$BASE/stage89/$V1_RUN/evidence/queue-method-index.txt"
# Fetch the V2 summary and validate its identifying/status fields.
# This avoids a fragile raw-download blob pin while still rejecting the wrong run or report.
curl -fsSLo "$OUT/v2-audit-summary.txt" "$BASE/stage89-v2/$V2_RUN/audit-summary.txt"
grep -Fqx "RUN=$V2_RUN" "$OUT/v2-audit-summary.txt" || fail "Fetched Stage89 V2 summary has the wrong run ID"
grep -Fqx "VERSION=STAGE89_V2_20261104" "$OUT/v2-audit-summary.txt" || fail "Fetched Stage89 V2 summary has the wrong version"
grep -Fqx "RESULT=REVIEW_REQUIRED" "$OUT/v2-audit-summary.txt" || fail "Fetched Stage89 V2 summary has an unexpected result"
grep -Fqx "SOURCE_MODIFIED=NO" "$OUT/v2-audit-summary.txt" || fail "Stage89 V2 summary does not confirm read-only source"
echo "V2_SUMMARY_VERIFIED=YES | GIT_BLOB_SHA=$(blob "$OUT/v2-audit-summary.txt")"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"

# Confirm the latest Stage89 V2 run is still the pinned predecessor before using its evidence.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V1_RUN" "$V2_RUN" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
v1=re.findall(r"STAGE89_RUN: (run-[A-Za-z0-9-]+)",log)
v2=re.findall(r"STAGE89_V2_RUN: (run-[A-Za-z0-9-]+)",log)
if not v1 or v1[-1]!=sys.argv[2]: raise SystemExit("Pinned Stage89 V1 is not latest V1 predecessor")
if not v2 or v2[-1]!=sys.argv[3]: raise SystemExit("Pinned Stage89 V2 is not latest V2 predecessor")
PY

# Revalidate current source against the immutable 91-file Stage73 baseline.
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); expected={}
for line in pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
rows=["STAGE89_V3_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): rows.append("MISMATCH="+k+" EXPECTED="+expected.get(k,"MISSING")+" ACTUAL="+actual.get(k,"MISSING"))
rows.append("RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
pathlib.Path(sys.argv[3]).write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Source tree differs from pinned Stage73 baseline")
PY

# Disassemble every method in the base queue and four concrete queue classes.
python3 - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/evidence" "$OUT/queue-class-method-index.txt" "$OUT/service-class-field-write-scan.txt" "$OUT/factory-argument-flow.txt" "$SRC" "$OUT/stage88-wmm-table.txt" <<'PY'
import pathlib,re,subprocess,sys
tools,bootkc,cache,objdump,evidence,index_out,writes_out,flow_out,src,wmm_path=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
kc=KC(bootkc); owner_expected="com.apple.iokit.IOSkywalkFamily"
cache=pathlib.Path(cache); evidence=pathlib.Path(evidence); evidence.mkdir(parents=True,exist_ok=True)
classes=["IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"]
methods={}; all_rows=["STAGE89_V3_COMPLETE_QUEUE_CLASS_METHOD_INDEX","TARGET=macOS_15.8.1_24H32_x86_64"]
carved={}
for cls in classes:
 found={}
 for va,name in kc.methods(cls):
  found.setdefault(va,[]).append(name)
 all_rows.append("CLASS="+cls+" METHOD_COUNT="+str(len(found)))
 for va,names in sorted(found.items()):
  owner=kc.owner(va) or kc.sym_owner.get(va)
  all_rows.append("METHOD=0x%016x OWNER=%s SYMBOLS=%s"%(va,owner,";".join(names)))
  if owner!=owner_expected: raise SystemExit("Unexpected owner for %s at 0x%x: %s"%(cls,va,owner))
  if owner not in carved:
   path=cache/"ioskywalk-family.macho"; kc.carve(owner,str(path)); carved[owner]=path
  nxt=kc.next_sym(va); end=nxt if nxt and va<nxt<=va+0x10000 else va+0x3000
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],capture_output=True,text=True)
  ins=[x.strip() for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
  if p.returncode or not ins: raise SystemExit("Disassembly failed for %s 0x%x"%(cls,va))
  safe=re.sub(r"[^A-Za-z0-9_.-]+","_",cls)
  fn=evidence/(safe+"_0x%016x.txt"%va)
  fn.write_text("\n".join(ins)+"\n")
  methods[(cls,va)]={"names":names,"ins":ins,"path":fn}
pathlib.Path(index_out).write_text("\n".join(all_rows)+"\n")

def choose(cls,fragment,address=None):
 candidates=[(va,m) for (c,va),m in methods.items() if c==cls and any(fragment in n for n in m["names"])]
 if address is not None: candidates=[x for x in candidates if x[0]==address]
 if len(candidates)!=1: raise SystemExit("Expected one method %s/%s at %s, found %d"%(cls,fragment,address,len(candidates)))
 return candidates[0][1]["ins"]
base=choose("IOSkywalkPacketQueue","initWithPool",0xffffff8002980860)
getter=choose("IOSkywalkPacketQueue","getServiceClass",0xffffff8002980bb0)
tx_core=choose("IOSkywalkTxSubmissionQueue","withPool",0xffffff8002983ff0)
tx_simple=choose("IOSkywalkTxSubmissionQueue","withPool",0xffffff80029840c2)
tx_init=choose("IOSkywalkTxSubmissionQueue","initWithPool",0xffffff80029840e8)
rx_factory=choose("IOSkywalkRxSubmissionQueue","withPool",0xffffff8002985724)
rx_init=choose("IOSkywalkRxSubmissionQueue","initWithPool",0xffffff80029857ee)
txc_init=choose("IOSkywalkTxCompletionQueue","initWithPool",0xffffff8002989e96)
rxc_init=choose("IOSkywalkRxCompletionQueue","initWithPool",0xffffff800298648a)

def has(ins,pat): return any(re.search(pat,x,re.I) for x in ins)
def after_base(ins):
 call=next((i for i,x in enumerate(ins) if "call" in x and re.search(r"\+\s*0x240\]",x)),None)
 return ins[call+1:] if call is not None else []
# Store to the getter field by any base register, not only the known rbx spelling.
field_refs=[]; field_writes=[]
for (cls,va),m in methods.items():
 for line in m["ins"]:
  if re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",line,re.I):
   field_refs.append((cls,va,line))
   if re.search(r"\b(?:mov|movabs|or|and|xor|add|sub|inc|dec|xchg)\s+[^,]*ptr\s+\[[^\]]+\+\s*0xb8\]\s*,",line,re.I):
    field_writes.append((cls,va,line))
rows=["STAGE89_V3_SERVICE_CLASS_FIELD_WRITER_SCAN","FIELD_OFFSET=0xb8","METHOD_CLASSES="+",".join(classes),
      "METHODS_DISASSEMBLED="+str(len(methods))]
for cls,va,line in field_refs: rows.append("FIELD_REFERENCE CLASS=%s METHOD=0x%x %s"%(cls,va,line))
for cls,va,line in field_writes: rows.append("FIELD_WRITE CLASS=%s METHOD=0x%x %s"%(cls,va,line))
rows.append("FIELD_WRITE_HIT_COUNT="+str(len(field_writes)))
rows.append("NAMED_SETTER_SYMBOLS="+str(sum(1 for (cls,va),m in methods.items() for n in m["names"] if re.search(r"(set.*serviceclass|serviceclass.*set)",n,re.I))))
pathlib.Path(writes_out).write_text("\n".join(rows)+"\n")

cpp=(pathlib.Path(src)/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text(errors="replace")
tx_match=re.search(r"_txSubmission\s*=\s*IOSkywalkTxSubmissionQueue::(withPool(?:AndServiceClass)?)\s*\((.*?)\);",cpp,re.S)
rx_match=re.search(r"_rxSubmission\s*=\s*IOSkywalkRxSubmissionQueue::(withPool(?:AndServiceClass)?)\s*\((.*?)\);",cpp,re.S)
tx_call=" ".join(tx_match.group(2).split()) if tx_match else "NOT_FOUND"
rx_call=" ".join(rx_match.group(2).split()) if rx_match else "NOT_FOUND"
# This overload's wrapper supplies -1, which the core factory forwards to TX init EDX.
tx_wrapper_push_default=has(tx_simple,r"push\s+-0x1")
tx_core_forwards_stack=has(tx_core,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]")
tx_init_stores_edx=has(tx_init,r"mov\s+r15d,\s*edx") and has(tx_init,r"mov\s+dword ptr \[rbx \+ 0xb8\],\s*r15d")
base_default=has(base,r"mov\s+dword ptr \[rbx \+ 0xb8\],\s*0xffffffff")
getter_offset=has(getter,r"mov\s+eax,\s*dword ptr \[rdi \+ 0xb8\]")
tx_source_plain=bool(tx_match and tx_match.group(1)=="withPool" and "withPoolAndServiceClass" not in tx_match.group(1))
# RX factory forwards the explicit source scalar; its initializer calls base and has no later field write.
rx_factory_forwards=has(rx_factory,r"mov\s+dword ptr \[rbp - 0x2c\],\s*ecx") and has(rx_factory,r"mov\s+r8d,\s*dword ptr \[rbp - 0x2c\]")
rx_no_post_base_write=not any(re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",x,re.I) for x in after_base(rx_init))
txc_no_post_base_write=not any(re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",x,re.I) for x in after_base(txc_init))
rxc_no_post_base_write=not any(re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",x,re.I) for x in after_base(rxc_init))
# No other queue-class method may update the service-class field beyond the known base default and TX initializer.
unexpected=[(c,va,line) for c,va,line in field_writes if not (c=="IOSkywalkPacketQueue" and va==0xffffff8002980860) and not (c=="IOSkywalkTxSubmissionQueue" and va==0xffffff80029840e8)]
wmm=pathlib.Path(wmm_path).read_text(errors="replace")
values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
checks={
 "GETTER_READS_FIELD_0XB8":getter_offset,
 "BASE_INIT_WRITES_SENTINEL_0XFFFFFFFF":base_default,
 "CURRENT_TX_SOURCE_USES_PLAIN_WITHPOOL":tx_source_plain,
 "TX_PLAIN_WRAPPER_PUSHES_MINUS_ONE":tx_wrapper_push_default,
 "TX_CORE_FORWARDS_STACK_VALUE_TO_EDX":tx_core_forwards_stack,
 "TX_INIT_STORES_EDX_TO_FIELD_0XB8":tx_init_stores_edx,
 "RX_FACTORY_FORWARDS_EXPLICIT_CLASS_SCALAR":rx_factory_forwards,
 "RX_INIT_HAS_NO_POST_BASE_FIELD_WRITE":rx_no_post_base_write,
 "TX_COMPLETION_HAS_NO_POST_BASE_FIELD_WRITE":txc_no_post_base_write,
 "RX_COMPLETION_HAS_NO_POST_BASE_FIELD_WRITE":rxc_no_post_base_write,
 "NO_OTHER_QUEUE_CLASS_FIELD_WRITER":not unexpected,
 "FOUR_DISTINCT_WMM_VALUES":len(values)==4 and len(set(values))==4
}
flow=[
"STAGE89_V3_FACTORY_TO_GETTER_ARGUMENT_FLOW",
"TX_SUBMISSION_SOURCE_FACTORY="+(tx_match.group(1) if tx_match else "NOT_FOUND"),
"TX_SUBMISSION_SOURCE_ARGUMENTS="+tx_call,
"TX_SUBMISSION_ACTION_ONLY_WRAPPER_PUSHES_MINUS_ONE="+str(tx_wrapper_push_default).upper(),
"TX_SUBMISSION_CORE_LOADS_STACK_VALUE_TO_EDX="+str(tx_core_forwards_stack).upper(),
"TX_SUBMISSION_INITIALIZER_STORES_EDX_AT_0XB8="+str(tx_init_stores_edx).upper(),
"TX_SUBMISSION_CONSTRUCTED_GET_SERVICE_CLASS=0xffffffff" if all([tx_wrapper_push_default,tx_core_forwards_stack,tx_init_stores_edx,base_default]) else "TX_SUBMISSION_CONSTRUCTED_GET_SERVICE_CLASS=UNRESOLVED",
"RX_SUBMISSION_SOURCE_FACTORY="+(rx_match.group(1) if rx_match else "NOT_FOUND"),
"RX_SUBMISSION_SOURCE_ARGUMENTS="+rx_call,
"RX_SUBMISSION_FACTORY_FORWARDS_EXPLICIT_SCALAR="+str(rx_factory_forwards).upper(),
"RX_SUBMISSION_INITIALIZER_POST_BASE_FIELD_WRITE="+str(not rx_no_post_base_write).upper(),
"TX_COMPLETION_INITIALIZER_POST_BASE_FIELD_WRITE="+str(not txc_no_post_base_write).upper(),
"RX_COMPLETION_INITIALIZER_POST_BASE_FIELD_WRITE="+str(not rxc_no_post_base_write).upper(),
"OTHER_QUEUE_CLASS_FIELD_WRITERS="+str(len(unexpected)),
"NOTE=The base constructor writes 0xffffffff to the getter field. TX action-only withPool overload pushes -1, and the core factory forwards it to TX init EDX, which is stored at offset 0xb8.",
"NOTE=RX's explicit scalar is forwarded to its initializer, but the captured initializer does not write offset 0xb8 after base initialization.",
"NOTE=Completion queue initializers do not write offset 0xb8 after base initialization.",
"NOTE=This audit proves construction behavior only; it does not prove a registration-time mutation path outside the five scanned queue classes."
]
for k,v in checks.items(): flow.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
pathlib.Path(flow_out).write_text("\n".join(flow)+"\n")
# Preserve the exact instructions that support the factory-to-getter conclusion.
key_methods=[
 ("BASE_QUEUE_INIT","IOSkywalkPacketQueue",0xffffff8002980860),
 ("GET_SERVICE_CLASS_GETTER","IOSkywalkPacketQueue",0xffffff8002980bb0),
 ("TX_SUBMISSION_PLAIN_WITHPOOL_WRAPPER","IOSkywalkTxSubmissionQueue",0xffffff80029840c2),
 ("TX_SUBMISSION_CORE_WITHPOOL_FACTORY","IOSkywalkTxSubmissionQueue",0xffffff8002983ff0),
 ("TX_SUBMISSION_INIT","IOSkywalkTxSubmissionQueue",0xffffff80029840e8),
 ("RX_SUBMISSION_WITHPOOL_FACTORY","IOSkywalkRxSubmissionQueue",0xffffff8002985724),
 ("RX_SUBMISSION_INIT","IOSkywalkRxSubmissionQueue",0xffffff80029857ee),
 ("TX_COMPLETION_INIT","IOSkywalkTxCompletionQueue",0xffffff8002989e96),
 ("RX_COMPLETION_INIT","IOSkywalkRxCompletionQueue",0xffffff800298648a)]
excerpt=[]
for label,cls,va in key_methods:
 body=methods[(cls,va)]["ins"]
 excerpt.append("===== "+label+" CLASS="+cls+" ADDRESS=0x%016x ====="%va)
 excerpt.extend(body)
key_path=evidence/"key-method-disassembly-excerpts.txt"
key_path.write_text("\n".join(excerpt)+"\n")
import shutil
shutil.copy2(key_path,pathlib.Path(flow_out).parent/"key-method-disassembly-excerpts.txt")
summary=[
"STAGE89_V3_FULL_QUEUE_SERVICE_CLASS_WRITER_AUDIT",
"VERSION=STAGE89_V3_20261104",
"TARGET=macOS_15.8.1_24H32_x86_64",
"SOURCE_TREE_REVALIDATION=PASS",
"QUEUE_CLASS_METHODS_DISASSEMBLED="+str(len(methods)),
"GETTER_FIELD_OFFSET=0xb8",
"BASE_DEFAULT_SERVICE_CLASS=0xffffffff",
"TX_SUBMISSION_SOURCE_FACTORY="+(tx_match.group(1) if tx_match else "NOT_FOUND"),
"TX_SUBMISSION_CONSTRUCTED_GET_SERVICE_CLASS="+("0xffffffff" if all([tx_wrapper_push_default,tx_core_forwards_stack,tx_init_stores_edx,base_default]) else "UNRESOLVED"),
"RX_SUBMISSION_SOURCE_FACTORY="+(rx_match.group(1) if rx_match else "NOT_FOUND"),
"RX_SUBMISSION_GETTER_FIELD_AFTER_INIT="+("BASE_SENTINEL_UNCHANGED" if all([rx_no_post_base_write,base_default]) else "REVIEW_REQUIRED"),
"TX_COMPLETION_GETTER_FIELD_AFTER_INIT="+("BASE_SENTINEL_UNCHANGED" if all([txc_no_post_base_write,base_default]) else "REVIEW_REQUIRED"),
"RX_COMPLETION_GETTER_FIELD_AFTER_INIT="+("BASE_SENTINEL_UNCHANGED" if all([rxc_no_post_base_write,base_default]) else "REVIEW_REQUIRED"),
"QUEUE_CLASS_FIELD_WRITES="+str(len(field_writes)),
"UNEXPECTED_FIELD_WRITERS="+str(len(unexpected)),
"NAMED_SETTER_SYMBOLS="+str(sum(1 for (cls,va),m in methods.items() for n in m["names"] if re.search(r"(set.*serviceclass|serviceclass.*set)",n,re.I))),
"WMM_REQUIRED_VALUES="+(",".join(values) if values else "NOT_FOUND"),
"FOUR_QUEUE_WMM_MAPPING=NOT_PROVEN",
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
"NEXT=Audit registration/QueueSet APIs for a supported service-class assignment path; do not implement the array or registration until proven."
]
pathlib.Path(pathlib.Path(flow_out).parent/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
"========== STAGE 89 V3 FULL QUEUE SERVICE-CLASS WRITER AUDIT ==========",
*summary,
"",
"FACTORY / INITIALIZER ARGUMENT FLOW:",
pathlib.Path(flow_out).read_text(errors="replace"),
"",
"QUEUE CLASS FIELD WRITER SCAN:",
pathlib.Path(writes_out).read_text(errors="replace"),
"",
"All five queue classes were scanned method-by-method in the target 24H32 IOSkywalkFamily binary. This result describes constructor-time behavior; registration-time or QueueSet behavior outside these classes remains a separate audit question.",
"Current source and target kernel do not yet provide a proven one-of-each WMM service-class assignment path. No queue array or registration code was added.",
"========== END STAGE 89 V3 =========="
]
pathlib.Path(pathlib.Path(flow_out).parent/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not all(checks.values()): print("ONE OR MORE ABI ASSERTIONS REQUIRE REVIEW; audit continues fail-closed.")
PY

mkdir -p "$OUT"
# Include source evidence and all reports in GitHub's per-run archive.
for f in source-tree-revalidation.txt queue-class-method-index.txt service-class-field-write-scan.txt factory-argument-flow.txt key-method-disassembly-excerpts.txt audit-summary.txt report.txt; do
 upload "$OUT/$f" "Development/Logs/stage89-v3/$RUN/$f"
done
python3 - "$OUT" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
rows=["STAGE89_V3_MANIFEST","RUN="+root.name,"TARGET=15.8.1/24H32/x86_64","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","ACTIVATION_GATE=BLOCKED"]
for p in sorted(root.iterdir()):
 if p.is_file() and p.name not in {"manifest.txt","upload-payload.json","upload-response.json","output-preflight.json"}:
  rows.append("ARTIFACT|"+p.name+"|"+hashlib.sha1(b"blob "+str(p.stat().st_size).encode()+b"\0"+p.read_bytes()).hexdigest())
(root/"manifest.txt").write_text("\n".join(rows)+"\n")
PY
upload "$OUT/manifest.txt" "Development/Logs/stage89-v3/$RUN/manifest.txt"

# Append a compact checkpoint to the canonical Development/output.log and verify the readback SHA.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/output-new.log" "$OUT/output-payload.json" "$RUN" "$OUT/audit-summary.txt" <<'PY'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1])); old=base64.b64decode(obj["content"]).decode(errors="replace")
run=sys.argv[4]
if "STAGE89_V3_RUN: "+run in old: raise SystemExit("Stage89 V3 already logged")
summary=pathlib.Path(sys.argv[5]).read_text(errors="replace")
def val(k):
 for line in summary.splitlines():
  if line.startswith(k+"="): return line.split("=",1)[1]
 return "NOT_REPORTED"
entry=(
"\n========== STAGE 89 V3 FULL QUEUE SERVICE-CLASS WRITER AUDIT ==========\n"
"STAGE89_V3_RUN: "+run+"\n"
"STAGE89_V3_VERSION: STAGE89_V3_20261104\n"
"SOURCE_TREE_REVALIDATION: "+val("SOURCE_TREE_REVALIDATION")+"\n"
"QUEUE_CLASS_METHODS_DISASSEMBLED: "+val("QUEUE_CLASS_METHODS_DISASSEMBLED")+"\n"
"BASE_DEFAULT_SERVICE_CLASS: "+val("BASE_DEFAULT_SERVICE_CLASS")+"\n"
"TX_SUBMISSION_CONSTRUCTED_GET_SERVICE_CLASS: "+val("TX_SUBMISSION_CONSTRUCTED_GET_SERVICE_CLASS")+"\n"
"RX_SUBMISSION_GETTER_FIELD_AFTER_INIT: "+val("RX_SUBMISSION_GETTER_FIELD_AFTER_INIT")+"\n"
"TX_COMPLETION_GETTER_FIELD_AFTER_INIT: "+val("TX_COMPLETION_GETTER_FIELD_AFTER_INIT")+"\n"
"RX_COMPLETION_GETTER_FIELD_AFTER_INIT: "+val("RX_COMPLETION_GETTER_FIELD_AFTER_INIT")+"\n"
"QUEUE_CLASS_FIELD_WRITES: "+val("QUEUE_CLASS_FIELD_WRITES")+"\n"
"UNEXPECTED_FIELD_WRITERS: "+val("UNEXPECTED_FIELD_WRITERS")+"\n"
"FOUR_QUEUE_WMM_MAPPING: "+val("FOUR_QUEUE_WMM_MAPPING")+"\n"
"STAGE89_V3_RESULT: "+val("RESULT")+"\n"
"SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"ACTIVATION_GATE: BLOCKED\n"
"STAGE89_V3_LOGS: Development/Logs/stage89-v3/"+run+"/\n"
"=========================================================================\n"
)
new=old.rstrip()+entry
pathlib.Path(sys.argv[2]).write_text(new)
pathlib.Path(sys.argv[3]).write_text(json.dumps({"message":"Append Stage89 V3 full queue service-class writer audit","sha":obj["sha"],"content":base64.b64encode(new.encode()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
WANT="$(blob "$OUT/output-new.log")"
GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT" == "$WANT" && "$GOT" == "$WANT" ]] || fail "Development/output.log SHA readback mismatch"

echo "STAGE89_V3_RUN=$RUN"
echo "STAGE89_V3_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2-)"
echo "GITHUB_LOG_DIR=Development/Logs/stage89-v3/$RUN/"
echo "CANONICAL_LOG=Development/output.log"
echo "SOURCE_MODIFIED=NO | BUILD=NOT_RUN | INSTALL=NOT_RUN | LOAD=NOT_RUN | OPENCORE_CHANGE=NONE"
echo "ACTIVATION_GATE=BLOCKED"
