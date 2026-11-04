#!/bin/bash
# Stage 89 V3: complete queue-class service-class field writer and factory-overload audit.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail


REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V1_RUN="run-20261103-211403-2ef027376f6e"
V2_RUN="run-20261103-213108-8e983fbd890c"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v4/$RUN"
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
 local actual
 curl -fsSLo "$OUT/$1" "$3"
 actual="$(blob "$OUT/$1")"
 [[ "$actual" == "$2" ]] || fail "Pinned evidence mismatch: $1 | expected=$2 | actual=$actual | source=$3"
}
upload(){
 local f="$1" remote="$2" payload="$OUT/upload-payload.json" want got attempt
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage89 V4 registration/QueueSet service-class API audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 echo "UPLOAD_START=$remote BYTES=$(wc -c < "$f" | tr -d ' ') EXPECTED_SHA=$want"
 for attempt in 1 2 3; do
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote SHA=$got"; return 0; fi
  if ! gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt"; then
   echo "UPLOAD_PUT_RETRY=$remote ATTEMPT=$attempt ERROR=$(tr '\n' ' ' < "$OUT/upload-error.txt" | cut -c1-200)"
  fi
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote ATTEMPT=$attempt SHA=$got"; return 0; fi
  sleep 2
 done
 echo "UPLOAD_FAILED=$remote EXPECTED_SHA=$want ACTUAL_SHA=${got:-UNAVAILABLE}" >&2
 return 1
}

on_exit(){
 local rc=$?
 if [[ $rc -ne 0 ]]; then
  {
   echo "STAGE89_V4_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 60 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then
   upload "$OUT/failure-report.txt" "Development/Logs/stage89-v4/$RUN/failure-report.txt" || true
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

# Pin and verify the immediately preceding V3G result, earlier QueueSet contract,
# WMM table, immutable source baseline, parser and the two relevant SDK headers.
pin v3g-audit-summary.txt 2604feb2bc3e8afbab3c04c91aabb539b35d412e "$BASE/stage89-v3g/run-20261104-095346-ff21baeb0c03/audit-summary.txt"
pin stage62-method-status.txt f0d6e3bdfbc265453ed21e17df397f392f825625 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-status.txt"
pin stage62-queueset-crosswalk.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51 "$BASE/stage62/run-20261102-161032-d54adc732d87/queueset-info-word-crosswalk.txt"
pin stage62-logical-link-crosswalk.txt 71802f2540ca976ffe5fe0b43b3f2b406fdb88fd "$BASE/stage62/run-20261102-161032-d54adc732d87/logical-link-info-crosswalk.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin sdk-network-interface.h 64502f9c9f27b9a10ff7c1f4f45b52787554f174 "https://raw.githubusercontent.com/$REPO/main/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkNetworkInterface.h"
pin sdk-packet-queue.h 5446ae0d0b47c5320e48152e354e6e7f089ff02e "https://raw.githubusercontent.com/$REPO/main/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"
[[ "$(blob "$SRC/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkNetworkInterface.h")" == "64502f9c9f27b9a10ff7c1f4f45b52787554f174" ]] || fail "Local IOSkywalkNetworkInterface.h differs from pinned GitHub header"
[[ "$(blob "$SRC/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacketQueue.h")" == "5446ae0d0b47c5320e48152e354e6e7f089ff02e" ]] || fail "Local IOSkywalkPacketQueue.h differs from pinned GitHub header"

# V4 is chained directly after the verified V3G run; refuse a stale predecessor.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V3G_RUN: (run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!="run-20261104-095346-ff21baeb0c03":
 raise SystemExit("Latest Stage89 V3G predecessor is missing or different")
if "STAGE89_V3G_RESULT: REVIEW_REQUIRED" not in log:
 raise SystemExit("V3G REVIEW_REQUIRED checkpoint not present in canonical log")
PY

# Revalidate all 91 source files against the immutable Stage73 baseline.
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
rows=["STAGE89_V4_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): rows.append("MISMATCH="+k+" EXPECTED="+expected.get(k,"MISSING")+" ACTUAL="+actual.get(k,"MISSING"))
rows.append("RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
pathlib.Path(sys.argv[3]).write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Source tree differs from pinned Stage73 baseline")
PY

# Scan the real 24H32 QueueSet / NetworkInterface path and related service-class
# symbols. All work is read-only; disassembly is restricted to instruction sections.
python3 -u - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/evidence" "$SRC" "$OUT/stage88-wmm-table.txt" "$OUT" <<'PY'
import bisect,pathlib,re,struct,subprocess,sys
tools,bootkc,cache,objdump,evidence,src,wmm_path,out=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
print("KERNEL_COLLECTION_LOAD_BEGIN=BootKernelExtensions.kc",flush=True)
kc=KC(bootkc)
print("KERNEL_COLLECTION_LOAD_COMPLETE=YES SYMBOLS=%d FILESET_ENTRIES=%d"%(len(kc.addrs),len(kc.entries)),flush=True)
owners={"com.apple.iokit.IOSkywalkFamily","com.apple.iokit.IO80211Family"}
instruction_flags=0x80000000|0x00000400
entry_by_owner={e[0]:e for e in kc.entries}
code_sections={}; code_addresses={}
for oi,owner in enumerate(kc.entry_segs,1):
 if owner not in owners: continue
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
   if size and (flags&instruction_flags): ranges.append((sn,gn,va,va+size))
 code_sections[owner]=ranges
 code_addresses[owner]=[]
 print("INSTRUCTION_SECTIONS OWNER=%s COUNT=%d"%(owner,len(ranges)),flush=True)
for i,a in enumerate(kc.addrs,1):
 owner=kc.sym_owner.get(a)
 if owner in code_sections and any(lo<=a<hi for _sn,_gn,lo,hi in code_sections[owner]):
  code_addresses[owner].append(a)
 if i%50000==0 or i==len(kc.addrs):
  print("SYMBOL_INDEX_PROGRESS=%d/%d"%(i,len(kc.addrs)),flush=True)
for owner in code_addresses: code_addresses[owner].sort()

# This list captures both named service-class APIs and the actual registration /
# QueueSet constructors, WMM predicate, queue back-reference and lifecycle methods.
pattern=re.compile(r"(service.?class|wmmsched|registernetworkinterface|registerinfraethernetinterface|createwithqueues|initwithqueues|setqueueset|getqueuesetnexusinfo|deregisternetworkinterface|deletelogicallink)",re.I)
candidates=[]; byaddr={}
for a in kc.addrs:
 name=kc.syms[a]; owner=kc.sym_owner.get(a)
 if owner in owners and pattern.search(name):
  byaddr.setdefault((owner,a),[]).append(name)
for (owner,a),names in sorted(byaddr.items(),key=lambda x:(x[0][0],x[0][1])):
 candidates.append((owner,a,names))
cand_rows=["STAGE89_V4_KERNEL_SERVICE_CLASS_AND_REGISTRATION_SYMBOL_CANDIDATES","OWNERS="+",".join(sorted(owners))]
for owner,a,names in candidates:
 is_code=any(lo<=a<hi for _sn,_gn,lo,hi in code_sections.get(owner,[]))
 cand_rows.append("SYMBOL=0x%016x OWNER=%s INSTRUCTION=%s NAMES=%s"%(a,owner,"YES" if is_code else "NO",";".join(names)))
pathlib.Path(out,"kernel-service-class-symbol-candidates.txt").write_text("\n".join(cand_rows)+"\n")
print("SERVICE_CLASS_REGISTRATION_SYMBOL_CANDIDATES=%d"%len(candidates),flush=True)

# Disassemble only selected entry points; method boundaries use the next symbol
# in the same instruction section. A 60-second timeout prevents silent hangs.
wanted=re.compile(r"(getServiceClassIndex|isWMMSchedModelCapable|registerNetworkInterface|registerInfraEthernetInterface|createWithQueues|initWithQueues|setQueueSet|getServiceClass|getQueueSetNexusInfo|deregisterNetworkInterface|deleteLogicalLink)",re.I)
selected=[]
for owner,a,names in candidates:
 if wanted.search(";".join(names)) and any(lo<=a<hi for _sn,_gn,lo,hi in code_sections.get(owner,[])):
  selected.append((owner,a,names))
carved={}; methods={}; ev=pathlib.Path(evidence); ev.mkdir(parents=True,exist_ok=True)
for idx,(owner,a,names) in enumerate(selected,1):
 section=next(x for x in code_sections[owner] if x[2]<=a<x[3])
 sn,gn,sec_lo,sec_hi=section
 if owner not in carved:
  safe=re.sub(r"[^A-Za-z0-9_.-]+","_",owner)
  cp=pathlib.Path(cache)/(safe+".macho")
  kc.carve(owner,str(cp)); carved[owner]=cp
 addrs=code_addresses[owner]; j=bisect.bisect_right(addrs,a)
 nxt=addrs[j] if j<len(addrs) else None
 end=nxt if nxt and a<nxt<=min(a+0x10000,sec_hi) else min(a+0x5000,sec_hi)
 label=";".join(names)
 print("DISASSEMBLY_PROGRESS=%d/%d OWNER=%s ADDRESS=0x%x SYMBOL=%s"%(idx,len(selected),owner,a,label[:100]),flush=True)
 try:
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%a,"--stop-address=0x%x"%end,str(carved[owner])],capture_output=True,text=True,timeout=60)
 except subprocess.TimeoutExpired:
  raise SystemExit("llvm-objdump timed out after 60 seconds at 0x%x %s"%(a,label))
 ins=[line.strip() for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line)]
 if p.returncode or not ins:
  raise SystemExit("Disassembly failed 0x%x %s rc=%d stderr=%s"%(a,label,p.returncode,p.stderr.strip()[:400]))
 safe=re.sub(r"[^A-Za-z0-9_.-]+","_",label[:90])
 fn=ev/("%s_0x%016x.txt"%(safe,a))
 fn.write_text("\n".join(ins)+"\n")
 methods[(owner,a)]={"names":names,"ins":ins,"path":fn,"section":section}
method_rows=["STAGE89_V4_QUEUESET_REGISTRATION_METHOD_INDEX","METHODS_DISASSEMBLED=%d"%len(methods)]
for (owner,a),m in methods.items():
 method_rows.append("METHOD=0x%016x OWNER=%s NAMES=%s INSTRUCTIONS=%d"%(a,owner,";".join(m["names"]),len(m["ins"])))
pathlib.Path(out,"registration-method-index.txt").write_text("\n".join(method_rows)+"\n")

# Preserve every selected instruction stream in one compact, uploadable evidence file.
disassembly_rows=["STAGE89_V4_REGISTRATION_QUEUESET_METHOD_DISASSEMBLY"]
for (owner,a),m in methods.items():
 disassembly_rows.append("===== OWNER=%s ADDRESS=0x%016x SYMBOLS=%s ====="%(owner,a,";".join(m["names"])))
 disassembly_rows.extend(m["ins"])
disassembly_rows.append("METHODS_DISASSEMBLED="+str(len(methods)))
pathlib.Path(out,"registration-path-method-disassembly.txt").write_text("\n".join(disassembly_rows)+"\n")


# Capture the PacketQueue vtable slot used by QueueSet::initWithQueues
# (0x218-byte slot = index 67) to classify its indirect queue command.
vt_rows=["STAGE89_V4_PACKET_QUEUE_VTABLE_SLOT_CROSSWALK"]
vt=kc.vtable("IOSkywalkPacketQueue") or []
for i,raw,tgt,name in vt:
 if i in (67,):
  vt_rows.append("SLOT_INDEX=%d SLOT_OFFSET=0x%x RAW=0x%x TARGET=0x%x NAME=%s"%(i,i*8,raw,tgt,name))
pathlib.Path(out,"queue-vtable-crosswalk.txt").write_text("\n".join(vt_rows)+"\n")

# Inventory public SDK declarations and source references without assuming that
# a header declaration implies a supported target-kernel implementation.
header_root=pathlib.Path(src)/"MacKernelSDK/Headers"
api_rows=["STAGE89_V4_SDK_SERVICE_CLASS_API_INVENTORY"]
api_hits=[]; setter_hits=[]
for p in sorted(header_root.rglob("*.h")):
 try: lines=p.read_text(errors="replace").splitlines()
 except OSError: continue
 for ln,line in enumerate(lines,1):
  if re.search(r"service.?class|wmm",line,re.I):
   row="%s:%d:%s"%(p.relative_to(src).as_posix(),ln,line.strip())
   api_hits.append(row)
   if re.search(r"\b(set|write|assign)\w*.*service.?class|service.?class.*\b(set|write|assign)\w*",line,re.I):
    setter_hits.append(row)
api_rows.extend(api_hits)
api_rows.append("PUBLIC_SERVICE_CLASS_SETTER_DECLARATION_HITS=%d"%len(setter_hits))
pathlib.Path(out,"sdk-service-class-api-inventory.txt").write_text("\n".join(api_rows)+"\n")

source_rows=["STAGE89_V4_DRIVER_SOURCE_SERVICE_CLASS_API_INVENTORY"]
source_hits=[]
for p in sorted((pathlib.Path(src)/"src").rglob("*")):
 if not p.is_file() or p.suffix.lower() not in {".cpp",".cc",".c",".mm",".h",".hpp"}: continue
 try: lines=p.read_text(errors="replace").splitlines()
 except OSError: continue
 for ln,line in enumerate(lines,1):
  if re.search(r"service.?class|mServiceClass|setServiceClass",line,re.I):
   source_hits.append("%s:%d:%s"%(p.relative_to(src).as_posix(),ln,line.strip()))
source_rows.extend(source_hits)
pathlib.Path(out,"source-service-class-api-inventory.txt").write_text("\n".join(source_rows)+"\n")

# Analyze relevant method bodies for direct service-class access or mutation.
refs=[]; writes=[]; method_facts=[]
for (owner,a),m in methods.items():
 names=";".join(m["names"])
 for line in m["ins"]:
  if re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",line,re.I):
   refs.append((owner,a,names,line))
   if re.search(r"\b(?:mov|movabs|or|and|xor|add|sub|inc|dec|xchg)\s+[^,]*ptr\s+\[[^\]]+\+\s*0xb8\]\s*,",line,re.I):
    writes.append((owner,a,names,line))
 if re.search(r"getServiceClassIndex",names,re.I):
  method_facts.append("GET_SERVICE_CLASS_INDEX_BODY=0x%x"%a)
 if re.search(r"isWMMSchedModelCapable",names,re.I):
  method_facts.append("WMM_PREDICATE_BODY=0x%x"%a)
 if re.search(r"initWithQueues",names,re.I):
  method_facts.append("QUEUESET_INIT_BODY=0x%x"%a)
write_rows=["STAGE89_V4_REGISTRATION_QUEUESET_SERVICE_CLASS_FIELD_REFERENCES","SELECTED_METHODS=%d"%len(methods)]
for x in refs: write_rows.append("FIELD_REFERENCE OWNER=%s METHOD=0x%x SYMBOL=%s %s"%x)
for x in writes: write_rows.append("FIELD_WRITE OWNER=%s METHOD=0x%x SYMBOL=%s %s"%x)
write_rows.extend(method_facts)
pathlib.Path(out,"registration-path-field-access-scan.txt").write_text("\n".join(write_rows)+"\n")

def body_for(fragment):
 hits=[m for (_o,_a),m in methods.items() if any(fragment.lower() in n.lower() for n in m["names"])]
 return hits
wmm_methods=body_for("isWMMSchedModelCapable")
index_methods=body_for("getServiceClassIndex")
qinit_methods=body_for("initWithQueues")
reg_methods=body_for("registerNetworkInterface")
direct_getter_in_wmm=any(any("getServiceClass" in line for line in m["ins"]) for m in wmm_methods)
wmm_text="\n".join(line for m in wmm_methods for line in m["ins"])
wmm_values=pathlib.Path(wmm_path).read_text(errors="replace")
required=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm_text,re.M)
all_wmm=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm_values,re.M)
named_mutators=[(o,a,n) for o,a,n in candidates if re.search(r"(set.*service.?class|service.?class.*set)", ";".join(n),re.I)]
queue_set_writer=any(re.search(r"IOSkywalkQueueSet",x[2]) for x in writes)
registration_writer=any(re.search(r"NetworkInterface|InfraInterface",x[2]) for x in writes)
selected_mutator=bool(named_mutators or queue_set_writer or registration_writer or setter_hits)

summary=[
 "STAGE89_V4_QUEUESET_REGISTRATION_SERVICE_CLASS_ASSIGNMENT_AUDIT",
 "VERSION=STAGE89_V4_20261104",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "V3G_PREDECESSOR=run-20261104-095346-ff21baeb0c03",
 "KERNEL_SERVICE_CLASS_REGISTRATION_SYMBOL_CANDIDATES="+str(len(candidates)),
 "SELECTED_METHODS_DISASSEMBLED="+str(len(methods)),
 "WMM_PREDICATE_METHOD="+("FOUND" if wmm_methods else "NOT_FOUND"),
 "NETWORK_GET_SERVICE_CLASS_INDEX_METHOD="+("FOUND" if index_methods else "NOT_FOUND"),
 "QUEUESET_INIT_METHOD="+("FOUND" if qinit_methods else "NOT_FOUND"),
 "NETWORK_REGISTRATION_OVERLOADS_DISASSEMBLED="+str(len(reg_methods)),
 "WMM_PREDICATE_DIRECT_GET_SERVICE_CLASS_REFERENCE="+("FOUND" if direct_getter_in_wmm else "NOT_FOUND_IN_DIRECT_SYMBOL_TEXT"),
 "WMM_REQUIRED_VALUES="+(",".join(all_wmm) if all_wmm else "NOT_FOUND"),
 "WMM_CONSTANTS_IN_PREDICATE_INSTRUCTIONS="+(",".join(required) if required else "NOT_FOUND"),
 "SERVICE_CLASS_FIELD_REFERENCES_IN_SELECTED_METHODS="+str(len(refs)),
 "SERVICE_CLASS_FIELD_WRITES_IN_SELECTED_METHODS="+str(len(writes)),
 "NAMED_SERVICE_CLASS_MUTATOR_SYMBOLS="+str(len(named_mutators)),
 "PUBLIC_SDK_SERVICE_CLASS_SETTER_DECLARATIONS="+str(len(setter_hits)),
 "DRIVER_SOURCE_SERVICE_CLASS_REFERENCES="+str(len(source_hits)),
 "QUEUESET_SERVICE_CLASS_ASSIGNMENT_PATH="+("CANDIDATE_FOUND_REQUIRES_REVIEW" if selected_mutator else "NOT_PROVEN"),
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
 "NEXT=Review the captured QueueSet WMM predicate, getServiceClassIndex body and vtable dispatch. Do not construct the queue array or call registration until the assignment path is proven."
]
pathlib.Path(out,"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V4 QUEUESET / REGISTRATION SERVICE-CLASS ASSIGNMENT AUDIT ==========",
 *summary,
 "",
 "QUEUESET AND NETWORK REGISTRATION METHOD INDEX:",
 *method_rows,
 "",
 "SDK DECLARATION INVENTORY:",
 *api_rows,
 "",
 "DRIVER SOURCE INVENTORY:",
 *source_rows,
 "",
 "SERVICE-CLASS FIELD ACCESS SCAN:",
 *write_rows,
 "",
 "This stage inspects Apple registration/QueueSet methods and known SDK declarations; a getter/index helper is not treated as a setter.",
 "A missing named setter is not by itself proof that no private indirect path exists. Inspect the captured WMM predicate and QueueSet control flow before changing source.",
 "No source was changed and no queue array or registration call was implemented.",
 "========== END STAGE 89 V4 =========="
]
pathlib.Path(out,"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary),flush=True)
PY

# Archive all per-run evidence with SHA-verified uploads.
FILES=(
 "source-tree-revalidation.txt"
 "kernel-service-class-symbol-candidates.txt"
 "registration-method-index.txt"
 "registration-path-method-disassembly.txt"
 "registration-path-field-access-scan.txt"
 "sdk-service-class-api-inventory.txt"
 "source-service-class-api-inventory.txt"
 "queue-vtable-crosswalk.txt"
 "audit-summary.txt"
 "report.txt"
)
for f in "${FILES[@]}"; do
 upload "$OUT/$f" "Development/Logs/stage89-v4/$RUN/$f" || fail "GitHub archive failed for $f"
done

python3 - "$OUT" "${FILES[@]}" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
rows=["STAGE89_V4_MANIFEST","RUN="+root.name,"TARGET=15.8.1/24H32/x86_64","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","ACTIVATION_GATE=BLOCKED"]
for name in sys.argv[2:]:
 p=root/name; b=p.read_bytes()
 rows.append("ARTIFACT|"+name+"|"+hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()+"|"+str(len(b)))
(root/"manifest.txt").write_text("\n".join(rows)+"\n")
PY
upload "$OUT/manifest.txt" "Development/Logs/stage89-v4/$RUN/manifest.txt" || fail "GitHub manifest upload failed"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/output-new.log" "$OUT/output-payload.json" "$RUN" "$OUT/audit-summary.txt" <<'PY'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1]))
old=base64.b64decode(obj["content"]).decode(errors="replace")
run=sys.argv[4]; marker="STAGE89_V4_RUN: "+run
if marker not in old:
 summary=pathlib.Path(sys.argv[5]).read_text(errors="replace")
 def val(k):
  for line in summary.splitlines():
   if line.startswith(k+"="): return line.split("=",1)[1]
  return "NOT_REPORTED"
 entry=(
 "\n========== STAGE 89 V4 QUEUESET / REGISTRATION SERVICE-CLASS ASSIGNMENT AUDIT ==========\n"
 +marker+"\n"
 "STAGE89_V4_VERSION: STAGE89_V4_20261104\n"
 "SOURCE_TREE_REVALIDATION: "+val("SOURCE_TREE_REVALIDATION")+"\n"
 "KERNEL_SERVICE_CLASS_REGISTRATION_SYMBOL_CANDIDATES: "+val("KERNEL_SERVICE_CLASS_REGISTRATION_SYMBOL_CANDIDATES")+"\n"
 "SELECTED_METHODS_DISASSEMBLED: "+val("SELECTED_METHODS_DISASSEMBLED")+"\n"
 "WMM_PREDICATE_METHOD: "+val("WMM_PREDICATE_METHOD")+"\n"
 "NETWORK_GET_SERVICE_CLASS_INDEX_METHOD: "+val("NETWORK_GET_SERVICE_CLASS_INDEX_METHOD")+"\n"
 "QUEUESET_INIT_METHOD: "+val("QUEUESET_INIT_METHOD")+"\n"
 "SERVICE_CLASS_FIELD_WRITES_IN_SELECTED_METHODS: "+val("SERVICE_CLASS_FIELD_WRITES_IN_SELECTED_METHODS")+"\n"
 "NAMED_SERVICE_CLASS_MUTATOR_SYMBOLS: "+val("NAMED_SERVICE_CLASS_MUTATOR_SYMBOLS")+"\n"
 "PUBLIC_SDK_SERVICE_CLASS_SETTER_DECLARATIONS: "+val("PUBLIC_SDK_SERVICE_CLASS_SETTER_DECLARATIONS")+"\n"
 "QUEUESET_SERVICE_CLASS_ASSIGNMENT_PATH: "+val("QUEUESET_SERVICE_CLASS_ASSIGNMENT_PATH")+"\n"
 "FOUR_QUEUE_WMM_MAPPING: NOT_PROVEN\n"
 "STAGE89_V4_RESULT: "+val("RESULT")+"\n"
 "SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
 "ACTIVATION_GATE: BLOCKED\n"
 "STAGE89_V4_LOGS: Development/Logs/stage89-v4/"+run+"/\n"
 "=========================================================================\n"
 )
 old=old.rstrip()+entry
pathlib.Path(sys.argv[2]).write_text(old)
pathlib.Path(sys.argv[3]).write_text(json.dumps({"message":"Append Stage89 V4 QueueSet and registration service-class API audit","sha":obj["sha"],"content":base64.b64encode(old.encode()).decode()}))
PY
WANT="$(blob "$OUT/output-new.log")"
GOT=""
for attempt in 1 2 3; do
 echo "OUTPUT_LOG_UPDATE_ATTEMPT=$attempt EXPECTED_SHA=$WANT"
 if ! gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json" 2> "$OUT/output-put-error.txt"; then
  echo "OUTPUT_LOG_PUT_RETRY=$attempt ERROR=$(tr '\n' ' ' < "$OUT/output-put-error.txt" | cut -c1-200)"
 fi
 GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 [[ "$GOT" == "$WANT" ]] && break
 sleep 2
done
[[ "$GOT" == "$WANT" ]] || fail "Development/output.log SHA readback mismatch | expected=$WANT | actual=${GOT:-UNAVAILABLE}"
echo "OUTPUT_LOG_VERIFIED=YES SHA=$GOT"
echo "STAGE89_V4_RUN=$RUN"
echo "STAGE89_V4_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2-)"
echo "GITHUB_LOG_DIR=Development/Logs/stage89-v4/$RUN/"
echo "CANONICAL_LOG=Development/output.log"
echo "SOURCE_MODIFIED=NO | BUILD=NOT_RUN | INSTALL=NOT_RUN | LOAD=NOT_RUN | OPENCORE_CHANGE=NONE"
echo "ACTIVATION_GATE=BLOCKED"
