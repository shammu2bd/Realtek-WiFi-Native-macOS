#!/bin/bash
# Stage 89 V5 — consolidated remaining read-only ABI checks.
# Corrects V4: inspect SetServiceClass bodies and resolve vtable +0x218 correctly.
# No source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V4_RUN="run-20261104-100629-7f12523c2a64"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v5/$RUN"
REMOTE="Development/Logs/stage89-v5/$RUN"
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
 local name="$1" expected="$2" url="$3" actual
 curl -fsSLo "$OUT/$name" "$url"
 actual="$(blob "$OUT/$name")"
 [[ "$actual" == "$expected" ]] || fail "Pinned evidence mismatch: $name expected=$expected actual=$actual"
 echo "PIN_VERIFIED=$name SHA=$actual"
}
upload(){
 local f="$1" remote="$2" payload="$OUT/upload-payload.json" want got attempt
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V5 read-only service-class setter and vtable audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 echo "UPLOAD_START=$remote BYTES=$(wc -c < "$f" | tr -d ' ') EXPECTED_SHA=$want"
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote SHA=$got"; return 0; fi
  if ! gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt"; then
   echo "UPLOAD_RETRY=$remote ATTEMPT=$attempt ERROR=$(tr '\n' ' ' < "$OUT/upload-error.txt" | cut -c1-220)"
  fi
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote ATTEMPT=$attempt SHA=$got"; return 0; fi
  sleep 2
 done
 echo "UPLOAD_FAILED=$remote EXPECTED_SHA=$want ACTUAL_SHA=$got" >&2
 return 1
}
on_exit(){
 local rc=$?
 if [[ $rc -ne 0 ]]; then
  {
   echo "STAGE89_V5_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 80 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 grep awk sw_vers uname tee date tail xcrun; do command -v "$t" >/dev/null 2>&1 || fail "Missing required command: $t"; done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Project source or target BootKernelExtensions.kc is missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
echo "STAGE89_V5_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v4-audit-summary.txt c2e4b8e6a204b68913ef36413cd9a0485ff256ed "$BASE/stage89-v4/$V4_RUN/audit-summary.txt"
pin v4-candidate-symbols.txt 09bffceadec5d3eac9ce7d2f880c7bfdc8d5314b "$BASE/stage89-v4/$V4_RUN/kernel-service-class-symbol-candidates.txt"
pin v4-method-disassembly.txt fa567221390f1be3f7036a05b0febac177b3c66e "$BASE/stage89-v4/$V4_RUN/registration-path-method-disassembly.txt"
pin v4-vtable-crosswalk.txt 13d4499972ed3092bcb2127d29036706fca50765 "$BASE/stage89-v4/$V4_RUN/queue-vtable-crosswalk.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V4_RUN" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V4_RUN: (run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1] != sys.argv[2]: raise SystemExit("Refusing stale Stage89 chain: latest V4 run differs")
if "STAGE89_V4_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V4 REVIEW_REQUIRED checkpoint is absent")
if "STAGE89_V5_RUN:" in log: raise SystemExit("A Stage89 V5 checkpoint already exists; inspect it rather than duplicate")
print("PREDECESSOR_GATE=PASS V4_RUN="+runs[-1])
PY

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
rows=["STAGE89_V5_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): rows.append("MISMATCH="+k+" EXPECTED="+expected.get(k,"MISSING")+" ACTUAL="+actual.get(k,"MISSING"))
rows.append("RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
pathlib.Path(sys.argv[3]).write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Native source tree no longer matches Stage73; stop and review")
print("SOURCE_TREE_REVALIDATION=PASS FILES=91")
PY

python3 -u - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/evidence" "$SRC" "$OUT/stage88-wmm-table.txt" "$OUT" <<'PY'
import bisect,pathlib,re,struct,subprocess,sys
tools,bootkc,cache,objdump,evidence,src,wmm_path,out=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
print("KERNEL_COLLECTION_LOAD_BEGIN=YES",flush=True)
kc=KC(bootkc)
print("KERNEL_COLLECTION_LOAD_COMPLETE=YES SYMBOLS=%d FILESET_ENTRIES=%d"%(len(kc.addrs),len(kc.entries)),flush=True)
owners={"com.apple.iokit.IOSkywalkFamily","com.apple.iokit.IO80211Family"}
instruction_flags=0x80000000|0x00000400
entry_by_owner={e[0]:e for e in kc.entries}
code_sections={}; code_addresses={}
for owner in sorted(owners):
 entry=entry_by_owner.get(owner)
 if not entry: continue
 ranges=[]
 for cmd,p,_sz in kc._cmds(entry[2]):
  if cmd!=0x19: continue
  nsects=struct.unpack_from("<I",kc.d,p+64)[0]
  for i in range(nsects):
   q=p+72+i*80
   sn=kc.d[q:q+16].split(b"\0")[0].decode(errors="replace")
   gn=kc.d[q+16:q+32].split(b"\0")[0].decode(errors="replace")
   va,size=struct.unpack_from("<QQ",kc.d,q+32)
   flags=struct.unpack_from("<I",kc.d,q+64)[0]
   if size and flags&instruction_flags: ranges.append((sn,gn,va,va+size))
 code_sections[owner]=ranges; code_addresses[owner]=[]
 print("INSTRUCTION_SECTIONS OWNER=%s COUNT=%d"%(owner,len(ranges)),flush=True)
for i,a in enumerate(kc.addrs,1):
 owner=kc.sym_owner.get(a)
 if owner in code_sections and any(lo<=a<hi for _sn,_gn,lo,hi in code_sections[owner]):
  code_addresses[owner].append(a)
 if i%50000==0 or i==len(kc.addrs): print("SYMBOL_INDEX_PROGRESS=%d/%d"%(i,len(kc.addrs)),flush=True)
for owner in code_addresses: code_addresses[owner].sort()

pattern=re.compile(r"(service.?class|wmmsched|performCommand|registerInfraEthernetInterface|registerNetworkInterface|createWithQueues|initWithQueues|setQueueSet|getQueueSetNexusInfo|deregisterNetworkInterface|deleteLogicalLink)",re.I)
candidates=[]
for a in kc.addrs:
 owner=kc.sym_owner.get(a); name=kc.syms[a]
 if owner in owners and pattern.search(name):
  code=any(lo<=a<hi for _sn,_gn,lo,hi in code_sections.get(owner,[]))
  candidates.append((owner,a,[name],code))
candidates.sort(key=lambda x:(x[0],x[1]))
candidate_rows=["STAGE89_V5_SERVICE_CLASS_REGISTRATION_SYMBOL_INDEX"]
for owner,a,names,code in candidates:
 candidate_rows.append("SYMBOL=0x%016x OWNER=%s INSTRUCTION=%s NAME=%s"%(a,owner,"YES" if code else "NO",names[0]))
pathlib.Path(out,"service-class-registration-symbol-index.txt").write_text("\n".join(candidate_rows)+"\n")
print("MATCHED_SYMBOLS=%d"%len(candidates),flush=True)

wanted=re.compile(r"(_SetServiceClass|SetServiceClass|isWMMSchedModelCapable|getServiceClassIndex|getServiceClass|setQueueSet|createWithQueues|initWithQueues|registerNetworkInterface|registerInfraEthernetInterface|getQueueSetNexusInfo|deregisterNetworkInterface|deleteLogicalLink)",re.I)
selected=[]
for owner,a,names,code in candidates:
 if code and wanted.search(";".join(names)): selected.append((owner,a,names))
selected.sort(key=lambda x:(x[0],x[1]))
carved={}; methods={}; ev=pathlib.Path(evidence); ev.mkdir(parents=True,exist_ok=True)
for idx,(owner,a,names) in enumerate(selected,1):
 section=next(x for x in code_sections[owner] if x[2]<=a<x[3])
 _sn,_gn,_lo,sec_hi=section
 if owner not in carved:
  safe=re.sub(r"[^A-Za-z0-9_.-]+","_",owner)
  cp=pathlib.Path(cache)/(safe+".macho")
  kc.carve(owner,str(cp)); carved[owner]=cp
 addrs=code_addresses[owner]; j=bisect.bisect_right(addrs,a)
 nxt=addrs[j] if j<len(addrs) else None
 end=nxt if nxt and a<nxt<=min(a+0x10000,sec_hi) else min(a+0x6000,sec_hi)
 label=";".join(names)
 print("DISASSEMBLY_PROGRESS=%d/%d OWNER=%s ADDRESS=0x%x SYMBOL=%s"%(idx,len(selected),owner,a,label[:130]),flush=True)
 try:
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%a,"--stop-address=0x%x"%end,str(carved[owner])],capture_output=True,text=True,timeout=60)
 except subprocess.TimeoutExpired: raise SystemExit("llvm-objdump timeout at 0x%x %s"%(a,label))
 ins=[line.strip() for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line)]
 if p.returncode or not ins: raise SystemExit("Disassembly failed 0x%x %s rc=%d stderr=%s"%(a,label,p.returncode,p.stderr.strip()[:400]))
 safe=re.sub(r"[^A-Za-z0-9_.-]+","_",label[:110])
 fn=ev/("%s_0x%016x.txt"%(safe,a))
 fn.write_text("\n".join(ins)+"\n")
 methods[(owner,a)]={"names":names,"ins":ins,"path":fn}
method_index=["STAGE89_V5_METHOD_INDEX","METHODS_DISASSEMBLED=%d"%len(methods)]
for (owner,a),m in methods.items(): method_index.append("METHOD=0x%016x OWNER=%s NAME=%s INSTRUCTIONS=%d"%(a,owner,";".join(m["names"]),len(m["ins"])))
pathlib.Path(out,"setter-registration-method-index.txt").write_text("\n".join(method_index)+"\n")
disassembly=["STAGE89_V5_SETTER_REGISTRATION_METHOD_DISASSEMBLY"]
for (owner,a),m in methods.items():
 disassembly.append("===== OWNER=%s ADDRESS=0x%016x SYMBOLS=%s ====="%(owner,a,";".join(m["names"])))
 disassembly.extend(m["ins"])
disassembly.append("METHODS_DISASSEMBLED="+str(len(methods)))
pathlib.Path(out,"setter-registration-method-disassembly.txt").write_text("\n".join(disassembly)+"\n")

setter_methods=[(o,a,m) for (o,a),m in methods.items() if re.search(r"_SetServiceClass",";".join(m["names"]),re.I)]
call_rows=["STAGE89_V5_SET_SERVICE_CLASS_DIRECT_CALL_TRACE","SETTER_METHOD_BODIES=%d"%len(setter_methods)]
field_rows=["STAGE89_V5_QUEUE_SERVICE_CLASS_FIELD_ACCESS_SCAN","FIELD_OFFSET=0xb8","GETTER_SYMBOL=__ZNK20IOSkywalkPacketQueue15getServiceClassEv"]
setter_field_writes=[]
for owner,a,m in setter_methods:
 call_rows.append("SETTER_BODY OWNER=%s ADDRESS=0x%x NAME=%s"%(owner,a,";".join(m["names"])))
 for line in m["ins"]:
  cm=re.search(r"\bcall\s+0x([0-9a-fA-F]+)",line)
  if cm:
   target=int(cm.group(1),16); nm=kc.syms.get(target) or kc.symname(target) or "UNRESOLVED"; to=kc.sym_owner.get(target) or "OWNER_UNRESOLVED"
   call_rows.append("DIRECT_CALL FROM=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s INSN=%s"%(a,target,to,nm,line))
  if re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",line,re.I):
   field_rows.append("SETTER_FIELD_REFERENCE METHOD=0x%x %s"%(a,line))
   if re.search(r"\b(?:mov|movabs|or|and|xor|add|sub|inc|dec|xchg)\s+[^,]*ptr\s+\[[^\]]+\+\s*0xb8\]\s*,",line,re.I):
    setter_field_writes.append((a,line)); field_rows.append("SETTER_FIELD_WRITE METHOD=0x%x %s"%(a,line))
if not setter_methods: call_rows.append("SETTER_BODY_DISASSEMBLY=NONE")
call_rows.append("NOTE=Indirect RPC/vtable calls are separately identified and are not assumed to mutate queue fields.")
pathlib.Path(out,"set-service-class-call-trace.txt").write_text("\n".join(call_rows)+"\n")
for (owner,a),m in methods.items():
 for line in m["ins"]:
  if re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",line,re.I):
   field_rows.append("METHOD_FIELD_REFERENCE OWNER=%s METHOD=0x%x NAME=%s INSN=%s"%(owner,a,";".join(m["names"]),line))
pathlib.Path(out,"queue-service-class-field-access-scan.txt").write_text("\n".join(field_rows)+"\n")

classes=kc.classes()
queue_classes=sorted(c for c in classes if re.match(r"^(?:IOSkywalk|IOUserNetwork).*Queue",c))
explicit=["IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"]
ordered=[]
for c in explicit+queue_classes:
 if c not in ordered: ordered.append(c)
vt_rows=[
 "STAGE89_V5_CORRECTED_QUEUE_VTABLE_CROSSWALK",
 "VTABLE_SYMBOL_BASE_TO_OBJECT_VPTR_ADDRESS_POINT_BIAS=0x10",
 "OBJECT_CALL_OFFSET=0x218",
 "CORRESPONDING_RAW_ZTV_TABLE_INDEX=69",
 "FORMULA=raw_index=(object_vptr_offset/8)+2",
 "CAPTURED_RAW_ZTV_INDICES=67,68,69,70,71,72"
]
table_hits=0
for cls in ordered:
 vt=kc.vtable(cls) or []
 if not vt: continue
 table_hits+=1; vt_rows.append("===== CLASS=%s VTABLE_ENTRIES=%d ====="%(cls,len(vt)))
 for i,raw,tgt,name in vt:
  if i in (67,68,69,70,71,72):
   obj_off=(i-2)*8
   vt_rows.append("RAW_INDEX=%d RAW_OFFSET=0x%x OBJECT_VPTR_OFFSET=0x%x RAW=0x%x TARGET=0x%x NAME=%s%s"%(i,i*8,obj_off,raw,tgt,name," <-- CALL +0x218" if obj_off==0x218 else ""))
pathlib.Path(out,"corrected-queue-vtable-crosswalk.txt").write_text("\n".join(vt_rows)+"\n")

dispatch_rows=["STAGE89_V5_QUEUESET_VIRTUAL_DISPATCH_SITES","OBJECT_VPTR_OFFSET=0x218","RAW_ZTV_INDEX=69"]
dispatch_hits=0
for (owner,a),m in methods.items():
 if any(re.search(r"(isWMMSchedModelCapable|initWithQueues)",n,re.I) for n in m["names"]):
  for i,line in enumerate(m["ins"]):
   if re.search(r"\[\s*[a-z0-9]+\s*\+\s*0x218\s*\]",line,re.I):
    dispatch_hits+=1
    dispatch_rows.append("===== OWNER=%s METHOD=0x%x NAME=%s ====="%(owner,a,";".join(m["names"])))
    dispatch_rows.extend(m["ins"][max(0,i-5):min(len(m["ins"]),i+7)])
dispatch_rows.append("DISPATCH_SITE_COUNT="+str(dispatch_hits))
pathlib.Path(out,"queueset-virtual-dispatch-sites.txt").write_text("\n".join(dispatch_rows)+"\n")

wmm_text=pathlib.Path(wmm_path).read_text(errors="replace")
m=re.search(r"^TABLE_ADDRESS=(0x[0-9a-fA-F]+)$",wmm_text,re.M)
expected_bytes=re.search(r"^TABLE_BYTES=([0-9a-fA-F]+)$",wmm_text,re.M)
expected_values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm_text,re.M)
if not m or not expected_bytes: raise SystemExit("Pinned Stage88 WMM evidence is incomplete")
table_addr=int(m.group(1),16); actual=kc.read(table_addr,16)
if actual is None or len(actual)!=16: raise SystemExit("Could not read target WMM table bytes")
wmm_rows=[
 "STAGE89_V5_TARGET_KERNEL_WMM_TABLE_REVALIDATION",
 "TABLE_ADDRESS=0x%x"%table_addr,
 "EXPECTED_BYTES="+expected_bytes.group(1).lower(),
 "ACTUAL_BYTES="+actual.hex(),
 "EXPECTED_VALUES="+",".join(expected_values),
 "RESULT="+("PASS" if actual.hex()==expected_bytes.group(1).lower() else "REVIEW_REQUIRED")
]
pathlib.Path(out,"target-kernel-wmm-table-revalidation.txt").write_text("\n".join(wmm_rows)+"\n")
if actual.hex()!=expected_bytes.group(1).lower(): raise SystemExit("Target WMM table differs from pinned Stage88 evidence")

all_field_refs=sum(1 for line in field_rows if "FIELD_REFERENCE" in line)
setter_names=";".join(";".join(m["names"]) for _,_,m in setter_methods)
wmm_method=any(any("isWMMSchedModelCapable" in n for n in m["names"]) for m in methods.values())
qinit_method=any(any("initWithQueues" in n for n in m["names"]) for m in methods.values())
reg_method=any(any("registerNetworkInterface" in n or "registerInfraEthernetInterface" in n for n in m["names"]) for m in methods.values())
raw69_names=[line for line in vt_rows if "RAW_INDEX=69 " in line]
summary=[
 "STAGE89_V5_SERVICE_CLASS_SETTER_AND_VTABLE_DISPATCH_AUDIT",
 "VERSION=STAGE89_V5_20261104",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "V4_PREDECESSOR=run-20261104-100629-7f12523c2a64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "TARGET_KERNEL_WMM_TABLE_REVALIDATION=PASS",
 "SERVICE_CLASS_REGISTRATION_SYMBOLS="+str(len(candidates)),
 "SELECTED_METHODS_DISASSEMBLED="+str(len(methods)),
 "SET_SERVICE_CLASS_METHOD_BODIES_DISASSEMBLED="+str(len(setter_methods)),
 "SET_SERVICE_CLASS_METHOD_SYMBOLS="+(setter_names if setter_names else "NONE"),
 "SETTER_METHOD_DIRECT_FIELD_WRITES_AT_QUEUE_OFFSET_0xB8="+str(len(setter_field_writes)),
 "ALL_SELECTED_METHOD_FIELD_REFERENCES_AT_0xB8="+str(all_field_refs),
 "WMM_PREDICATE_METHOD="+("FOUND" if wmm_method else "NOT_FOUND"),
 "QUEUESET_INIT_METHOD="+("FOUND" if qinit_method else "NOT_FOUND"),
 "NETWORK_REGISTRATION_METHOD="+("FOUND" if reg_method else "NOT_FOUND"),
 "QUEUESET_OBJECT_VPTR_CALL_OFFSET_0x218=RAW_ZTV_INDEX_69",
 "QUEUE_VTABLES_FOUND="+str(table_hits),
 "QUEUESET_PLUS_0x218_DISPATCH_SITES="+str(dispatch_hits),
 "QUEUE_VTABLE_RAW_INDEX_69_MATCHES="+str(len(raw69_names)),
 "FOUR_QUEUE_WMM_MAPPING=NOT_PROVEN",
 "SERVICE_CLASS_ASSIGNMENT_PATH=NOT_PROVEN",
 "FOUR_QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "NATIVE_REGISTRATION_CALLS=0",
 "CALLBACK_HANDOFFS_STILL_MISSING=4",
 "IMPLEMENTATION_AUTHORIZATION=NO",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "SIGNING=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "ACTIVATION_GATE=BLOCKED",
 "NEXT=Review setter call traces and corrected vtable outputs. Do not create the queue array or call registration until all four service classes and ownership rules are proven."
]
pathlib.Path(out,"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V5 — REMAINING READ-ONLY SERVICE-CLASS AUDIT ==========",
 *summary,
 "",
 "V4 CORRECTIONS:",
 "1. V4 found six SetServiceClass names but did not disassemble those setter bodies. V5 disassembles them and resolves direct call targets where possible.",
 "2. The C++ vtable address point is __ZTV + 0x10. Therefore object-vptr offset +0x218 maps to raw __ZTV index 69, not raw index 67.",
 "3. The crosswalk records raw indices 67–72 for each available queue-class vtable and highlights the +0x218 target.",
 "",
 "SETTER CALL TRACE:", *call_rows,
 "",
 "QUEUE SERVICE-CLASS FIELD ACCESS:", *field_rows,
 "",
 "CORRECTED VTABLE CROSSWALK:", *vt_rows,
 "",
 "QUEUESET VIRTUAL DISPATCH:", *dispatch_rows,
 "",
 "TARGET KERNEL WMM TABLE:", *wmm_rows,
 "",
 "METHOD INDEX:", *method_index,
 "",
 "INTERPRETATION:",
 "A user-network SetServiceClass RPC method is not proof that IOSkywalkPacketQueue::mServiceClass at offset 0xb8 is written. The actual field writer or a verified factory/constructor argument must be demonstrated for every required queue class.",
 "A packet-level service-class API is not treated as a queue-object service-class setter.",
 "Vtable entries provide a static target mapping; the runtime target depends on the concrete queue subclass vptr.",
 "",
 "SAFETY:",
 "No source file changed. No build, signing, install, load, hardware test, SIP/NVRAM change or OpenCore modification was performed.",
 "The four-pointer array and registration call remain absent. Preserve the known-good legacy RTL88WiFi setup."
]
pathlib.Path(out,"report.txt").write_text("\n".join(report)+"\n")
print("SETTER_METHOD_BODIES_DISASSEMBLED=%d"%len(setter_methods),flush=True)
print("QUEUE_VTABLES_FOUND=%d"%table_hits,flush=True)
print("QUEUESET_PLUS_0x218_DISPATCH_SITES=%d"%dispatch_hits,flush=True)
print("STAGE89_V5_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V5 — SERVICE-CLASS SETTER / VTABLE DISPATCH AUDIT ==========
STAGE89_V5_RUN: $RUN
STAGE89_V5_VERSION: STAGE89_V5_20261104
STAGE89_V5_PREDECESSOR: $V4_RUN
STAGE89_V5_SOURCE_TREE_REVALIDATION: PASS
STAGE89_V5_TARGET_WMM_TABLE_REVALIDATION: PASS
STAGE89_V5_SETTER_AND_VTABLE_AUDIT: COMPLETE
STAGE89_V5_FOUR_QUEUE_WMM_MAPPING: NOT_PROVEN
STAGE89_V5_ASSIGNMENT_PATH: NOT_PROVEN
STAGE89_V5_POINTER_ARRAY: NOT_IMPLEMENTED
STAGE89_V5_NATIVE_REGISTRATION_CALLS: 0
STAGE89_V5_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V5_SOURCE_MODIFIED: NO
STAGE89_V5_BUILD: NOT_RUN
STAGE89_V5_SIGNING: NOT_RUN
STAGE89_V5_INSTALL: NOT_RUN
STAGE89_V5_LOAD: NOT_RUN
STAGE89_V5_OPENCORE_CHANGE: NONE
STAGE89_V5_RESULT: REVIEW_REQUIRED
STAGE89_V5_ACTIVATION_GATE: BLOCKED
STAGE89_V5_LOGS: $REMOTE/
EOF
python3 - "$OUT" <<'PY'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=[
 "source-tree-revalidation.txt","service-class-registration-symbol-index.txt",
 "setter-registration-method-index.txt","setter-registration-method-disassembly.txt",
 "set-service-class-call-trace.txt","queue-service-class-field-access-scan.txt",
 "corrected-queue-vtable-crosswalk.txt","queueset-virtual-dispatch-sites.txt",
 "target-kernel-wmm-table-revalidation.txt","audit-summary.txt","report.txt","checkpoint-block.txt"
]
rows=["STAGE89_V5_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PY

for f in \
 "$OUT/source-tree-revalidation.txt" \
 "$OUT/service-class-registration-symbol-index.txt" \
 "$OUT/setter-registration-method-index.txt" \
 "$OUT/setter-registration-method-disassembly.txt" \
 "$OUT/set-service-class-call-trace.txt" \
 "$OUT/queue-service-class-field-access-scan.txt" \
 "$OUT/corrected-queue-vtable-crosswalk.txt" \
 "$OUT/queueset-virtual-dispatch-sites.txt" \
 "$OUT/target-kernel-wmm-table-revalidation.txt" \
 "$OUT/audit-summary.txt" \
 "$OUT/report.txt" \
 "$OUT/checkpoint-block.txt" \
 "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PY'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
block=pathlib.Path(sys.argv[2]).read_text()
if "STAGE89_V5_RUN:" in old: raise SystemExit("Stage89 V5 history marker already exists; refusing duplicate append")
new=old.rstrip()+"\n\n"+block
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V5 read-only setter/vtable audit checkpoint","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
PY
LOG_WANT="$(blob "$OUT/output-updated.txt")"
LOG_OK=NO
for attempt in 1 2 3 4; do
 if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-update-response.json" 2> "$OUT/output-update-error.txt"; then echo "CANONICAL_LOG_UPDATE_ATTEMPT=$attempt"; fi
 LOG_GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 if [[ "$LOG_GOT" == "$LOG_WANT" ]]; then LOG_OK=YES; break; fi
 sleep 2
done
[[ "$LOG_OK" == "YES" ]] || fail "Canonical Development/output.log update failed SHA readback"
echo "CANONICAL_LOG_VERIFIED=YES SHA=$LOG_GOT"
echo "STAGE89_V5_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
