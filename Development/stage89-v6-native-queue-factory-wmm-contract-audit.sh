#!/bin/bash
# Stage 89 V6 — native IOSkywalk queue factory / initializer / WMM contract audit.
# READ ONLY. No source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V5_RUN="run-20261104-121242-6638c95764ea"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v6/$RUN"
REMOTE="Development/Logs/stage89-v6/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache" "$OUT/evidence"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V6 native queue factory/WMM contract audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V6_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 70 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 grep awk sw_vers uname tee date tail xcrun; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Project source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
echo "STAGE89_V6_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v5-audit-summary.txt cd0025fa0e3167dbcd7b0b76e76adb487a34078d "$BASE/stage89-v5/$V5_RUN/audit-summary.txt"
pin v5-report.txt b995a1ed828da832cdaf851aefb17d849e9fd756 "$BASE/stage89-v5/$V5_RUN/report.txt"
pin v5-vtable-crosswalk.txt 0cc13cc2ec8ec30dcf44ad2ea1f7cdcfb548b9d3 "$BASE/stage89-v5/$V5_RUN/corrected-queue-vtable-crosswalk.txt"
pin v5-dispatch-sites.txt 3be04d97c33624292bb14540396b8b9a0d9ba789 "$BASE/stage89-v5/$V5_RUN/queueset-virtual-dispatch-sites.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
for item in \
 "tx-submission.h|18050629c5d2f07ccb5f38fcf5d571bd071f8464|IOSkywalkTxSubmissionQueue.h" \
 "tx-completion.h|5b3eae99ae8ded8022bc730dbc8e4ef1e6a491b8|IOSkywalkTxCompletionQueue.h" \
 "rx-submission.h|8b10f9bc9610a71912b1dc91fc6933c3e635a0d4|IOSkywalkRxSubmissionQueue.h" \
 "rx-completion.h|70f2858ddbb16185c674ccdf5366f20a8cb7a9b6|IOSkywalkRxCompletionQueue.h" \
 "packet-queue.h|5446ae0d0b47c5320e48152e354e6e7f089ff02e|IOSkywalkPacketQueue.h"; do
 IFS='|' read -r nm sha file <<< "$item"
 pin "$nm" "$sha" "https://raw.githubusercontent.com/$REPO/main/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/$file"
done
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Kernel collection parser hash mismatch"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V5_RUN" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V5_RUN: (run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]: raise SystemExit("Latest V5 predecessor missing or different")
if "STAGE89_V5_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V5 review checkpoint missing")
if "STAGE89_V6_RUN:" in log: raise SystemExit("Stage89 V6 checkpoint already exists; inspect existing run")
print("PREDECESSOR_GATE=PASS V5_RUN="+runs[-1])
PY

# Revalidate the source code identity and extract the actual source queue construction model.
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" "$OUT/source-queue-construction-model.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); expected={}
for line in pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
rows=["STAGE89_V6_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual),"RESULT="+("PASS" if ok else "REVIEW_REQUIRED")]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): rows.append("MISMATCH="+k)
pathlib.Path(sys.argv[3]).write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Source tree differs from Stage73 baseline")
cpp=src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
text=cpp.read_text(errors="replace")
out=[
 "STAGE89_V6_NATIVE_SOURCE_QUEUE_CONSTRUCTION_MODEL",
 "SOURCE_FILE=src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
 "SOURCE_SHA256="+hashlib.sha256(cpp.read_bytes()).hexdigest()
]
for method in ["IOSkywalkTxSubmissionQueue::withPoolAndServiceClass","IOSkywalkTxSubmissionQueue::withPool","IOSkywalkTxCompletionQueue::withPool","IOSkywalkRxSubmissionQueue::withPool","IOSkywalkRxCompletionQueue::withPool"]:
 out.append("CALL_COUNT|"+method+"|"+str(text.count(method)))
for i,line in enumerate(text.splitlines(),1):
 if "withPool" in line or "_txSubmission" in line or "_txCompletion" in line or "_rxSubmission" in line or "_rxCompletion" in line or "registerNetworkInterface" in line:
  out.append("SOURCE_LINE|%d|%s"%(i,line.strip()))
out.append("WMM_FACTORY_CURRENTLY_USED="+("YES" if "withPoolAndServiceClass" in text else "NO"))
out.append("NATIVE_TX_SUBMISSION_FACTORY_CALLS="+str(text.count("IOSkywalkTxSubmissionQueue::withPool(")+text.count("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(")))
pathlib.Path(sys.argv[4]).write_text("\n".join(out)+"\n")
if not ok: raise SystemExit("Source baseline mismatch")
print("SOURCE_TREE_REVALIDATION=PASS FILES=91")
print("SOURCE_QUEUE_MODEL_CAPTURED=YES")
PY

python3 -u - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/evidence" "$OUT" "$SRC" "$OUT/stage88-wmm-table.txt" <<'PY'
import bisect,pathlib,re,struct,subprocess,sys
tools,bootkc,cache,objdump,evidence,out,src,wmm_path=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
print("KERNEL_COLLECTION_LOAD_BEGIN=YES",flush=True)
kc=KC(bootkc)
print("KERNEL_COLLECTION_LOAD_COMPLETE=YES SYMBOLS=%d FILESET_ENTRIES=%d"%(len(kc.addrs),len(kc.entries)),flush=True)
owner="com.apple.iokit.IOSkywalkFamily"
entry=next((e for e in kc.entries if e[0]==owner),None)
if not entry: raise SystemExit("IOSkywalkFamily fileset entry missing")
ranges=[]
for cmd,p,_sz in kc._cmds(entry[2]):
 if cmd!=0x19: continue
 n=struct.unpack_from("<I",kc.d,p+64)[0]
 for i in range(n):
  q=p+72+i*80
  sn=kc.d[q:q+16].split(b"\0")[0].decode(errors="replace")
  gn=kc.d[q+16:q+32].split(b"\0")[0].decode(errors="replace")
  va,size=struct.unpack_from("<QQ",kc.d,q+32)
  flags=struct.unpack_from("<I",kc.d,q+64)[0]
  if size and flags&(0x80000000|0x400): ranges.append((sn,gn,va,va+size))
def iscode(a): return any(lo<=a<hi for _sn,_gn,lo,hi in ranges)
addresses=[a for a in kc.addrs if kc.sym_owner.get(a)==owner and iscode(a)]
print("IOSKYWALK_INSTRUCTION_SYMBOLS=%d"%len(addresses),flush=True)
classes=["IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"]
tokens=re.compile(r"(performCommand|withPool|initWithPool|isWMMSchedModelCapable|createWithQueues|initWithQueues|getServiceClass)")
selected=[]
for a in addresses:
 name=kc.syms[a]
 if any((""+c) in name for c in classes) and tokens.search(name):
  selected.append((a,name))
selected.sort()
# Explicitly include the queue-set contract methods.
for name in [
 "__ZN17IOSkywalkQueueSet14initWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE",
 "__ZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuem",
 "__ZN17IOSkywalkQueueSet16createWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE"
]:
 a=kc.find(name)
 if a and iscode(a) and (a,name) not in selected: selected.append((a,name))
selected.sort()
print("NATIVE_QUEUE_METHODS_SELECTED=%d"%len(selected),flush=True)
cp=pathlib.Path(cache)/"IOSkywalkFamily.macho"
kc.carve(owner,str(cp))
bodies={}
for i,(a,name) in enumerate(selected,1):
 end=kc.next_sym(a)
 sec=next((s for s in ranges if s[2]<=a<s[3]),None)
 if not sec: continue
 hi=sec[3]
 stop=end if end and a<end<=min(a+0x18000,hi) else min(a+0x8000,hi)
 print("DISASSEMBLY_PROGRESS=%d/%d ADDRESS=0x%x SYMBOL=%s"%(i,len(selected),a,name[:150]),flush=True)
 try:
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%a,"--stop-address=0x%x"%stop,str(cp)],capture_output=True,text=True,timeout=60)
 except subprocess.TimeoutExpired: raise SystemExit("Disassembly timeout: "+name)
 ins=[x.strip() for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
 if p.returncode or not ins: raise SystemExit("Disassembly failed: "+name+" "+p.stderr[:300])
 bodies[name]=(a,ins)
 fn=pathlib.Path(evidence)/(re.sub(r"[^A-Za-z0-9_.-]+","_",name[:110])+"_"+("%016x"%a)+".txt")
 fn.write_text("\n".join(ins)+"\n")
allrows=["STAGE89_V6_NATIVE_QUEUE_FACTORY_AND_WMM_METHOD_DISASSEMBLY"]
for name,(a,ins) in bodies.items():
 allrows.append("===== ADDRESS=0x%016x SYMBOL=%s ====="%(a,name)); allrows.extend(ins)
allrows.append("METHODS_DISASSEMBLED="+str(len(bodies)))
pathlib.Path(out,"native-queue-method-disassembly.txt").write_text("\n".join(allrows)+"\n")
index=["STAGE89_V6_NATIVE_QUEUE_METHOD_INDEX","METHODS_DISASSEMBLED="+str(len(bodies))]
for name,(a,ins) in bodies.items(): index.append("METHOD=0x%016x INSTRUCTIONS=%d SYMBOL=%s"%(a,len(ins),name))
pathlib.Path(out,"native-queue-method-index.txt").write_text("\n".join(index)+"\n")

# Summarize which factory/init functions exist, where mServiceClass is written,
# and which native performCommand implementations receive the QueueSet query.
facts=["STAGE89_V6_NATIVE_QUEUE_FACTORY_AND_PERFORMCOMMAND_FACTS"]
for cls in classes[1:]:
 related=[n for n in bodies if cls in n]
 facts.append("CLASS="+cls+" CAPTURED_METHODS="+str(len(related)))
 for n in related:
  a,ins=bodies[n]
  if "withPoolAndServiceClass" in n or "withPool" in n or "initWithPool" in n or "performCommand" in n:
   facts.append("METHOD="+n+" ADDRESS=0x%x"%a)
   for x in ins:
    if re.search(r"\[[a-z0-9]+\s*\+\s*0xb8\]",x,re.I) or re.search(r"\b(?:mov|cmp|test|and|or)\s+(?:e|r)[a-z0-9]+,\s*0x10000",x,re.I) or "0x10000" in x:
     facts.append("RELEVANT_INSN="+x)
for queue_method in ["__ZN17IOSkywalkQueueSet14initWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE","__ZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuem"]:
 if queue_method in bodies:
  a,ins=bodies[queue_method]
  facts.append("QUEUESET_METHOD="+queue_method)
  for x in ins:
   if "0x218" in x or "0x10000" in x or "getServiceClass" in x or "0x3" in x or "0x4" in x:
    facts.append("QUEUESET_INSN="+x)
pathlib.Path(out,"native-queue-factory-performcommand-facts.txt").write_text("\n".join(facts)+"\n")

# Verify WMM table bytes in the target kernel collection.
wmm=pathlib.Path(wmm_path).read_text(errors="replace")
ma=re.search(r"^TABLE_ADDRESS=(0x[0-9a-fA-F]+)$",wmm,re.M)
mb=re.search(r"^TABLE_BYTES=([0-9a-fA-F]+)$",wmm,re.M)
if not ma or not mb: raise SystemExit("Pinned WMM table evidence incomplete")
addr=int(ma.group(1),16); actual=kc.read(addr,16)
if actual is None or actual.hex()!=mb.group(1).lower(): raise SystemExit("Target kernel WMM constant table changed")
pathlib.Path(out,"target-kernel-wmm-revalidation.txt").write_text(
 "STAGE89_V6_TARGET_WMM_REVALIDATION\nTABLE_ADDRESS=0x%x\nEXPECTED_BYTES=%s\nACTUAL_BYTES=%s\nRESULT=PASS\n"%(addr,mb.group(1).lower(),actual.hex()))

# Queue vtable class/slot mapping is cross-checked again for native queue classes.
vt=["STAGE89_V6_NATIVE_QUEUE_VTABLE_PERFORMCOMMAND_CROSSWALK","OBJECT_VPTR_OFFSET=0x218","RAW_ZTV_INDEX=69"]
for cls in classes:
 for i,raw,tgt,name in (kc.vtable(cls) or []):
  if i==69:
   vt.append("CLASS=%s RAW_INDEX=69 OBJECT_VPTR_OFFSET=0x218 TARGET=0x%x NAME=%s"%(cls,tgt,name))
pathlib.Path(out,"native-queue-vtable-crosswalk.txt").write_text("\n".join(vt)+"\n")

print("TARGET_WMM_TABLE_REVALIDATION=PASS",flush=True)
print("STAGE89_V6_KERNEL_AUDIT_COMPLETE=YES",flush=True)
PY

# Assess exact source queue counts, explicit service-class factory usage and
# whether the target class implementation provides proof for the native path.
python3 - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
src=pathlib.Path(out/"source-queue-construction-model.txt").read_text()
dis=pathlib.Path(out/"native-queue-method-disassembly.txt").read_text(errors="replace")
facts=pathlib.Path(out/"native-queue-factory-performcommand-facts.txt").read_text(errors="replace")
classes=["IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue"]
for c in classes:
 if c not in dis: raise SystemExit("Required native queue class has no captured method evidence: "+c)
has_factory="withPoolAndServiceClass" in dis
has_tx_init=bool(re.search(r"IOSkywalkTxSubmissionQueue.*initWithPool",dis))
has_tx_write=bool(re.search(r"mov\s+dword ptr \[[a-z0-9]+ \+ 0xb8\],",dis))
perform_count=len(re.findall(r"IOSkywalk(?:TxSubmission|TxCompletion|RxSubmission|RxCompletion)Queue.*performCommand",dis))
summary=[
 "STAGE89_V6_NATIVE_QUEUE_FACTORY_WMM_CONTRACT_AUDIT",
 "VERSION=STAGE89_V6_20261104",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "TARGET_KERNEL_WMM_TABLE_REVALIDATION=PASS",
 "NATIVE_QUEUE_CLASSES_CAPTURED=4",
 "NATIVE_QUEUE_METHODS_DISASSEMBLED=YES",
 "TX_WITH_POOL_AND_SERVICE_CLASS_SYMBOL_PRESENT="+("YES" if has_factory else "NO_IN_CAPTURED_METHODS"),
 "TX_SUBMISSION_INIT_METHOD_PRESENT="+("YES" if has_tx_init else "NO_IN_CAPTURED_METHODS"),
 "TX_SUBMISSION_0xB8_WRITER_SEEN="+("YES" if has_tx_write else "NOT_DETECTED_BY_SIMPLE_SCAN"),
 "NATIVE_QUEUE_PERFORMCOMMAND_METHODS_IN_DISASSEMBLY="+str(perform_count),
 "SOURCE_CURRENTLY_USES_EXPLICIT_TX_SERVICE_CLASS_FACTORY="+("YES" if "WMM_FACTORY_CURRENTLY_USED=YES" in src else "NO"),
 "SOURCE_CURRENTLY_HAS_ONE_TX_SUBMISSION_OBJECT="+("YES" if "NATIVE_TX_SUBMISSION_FACTORY_CALLS=1" in src else "CHECK_SOURCE_MODEL"),
 "FOUR_QUEUE_ROLE_AND_WMM_CARDINALITY_MODEL=REQUIRES_REVIEW",
 "FOUR_QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
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
 "NEXT=Interpret native performCommand results together with QueueSet initWithQueues cardinality and WMM predicate. Only then decide the required number and type of queue objects; do not change source in this audit."
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V6 — NATIVE QUEUE FACTORY / WMM CONTRACT AUDIT ==========",
 *summary,"",
 "CURRENT SOURCE QUEUE MODEL:",src,"",
 "NATIVE QUEUE FACTORY / PERFORMCOMMAND FACTS:",facts,"",
 "NATIVE QUEUE METHOD INDEX:",(out/"native-queue-method-index.txt").read_text(),"",
 "INTERPRETATION:",
 "Stage V5 directly observed SetServiceClass writes in IOUserNetworkTxSubmissionQueue implementations, but the native driver uses IOSkywalkTxSubmissionQueue and the IOSkywalk* queue family. These are not conflated.",
 "Stage V6 records the native queue factory, initWithPool and performCommand implementations so that the WMM predicate can be interpreted for the actual classes used by the driver.",
 "The existing source presently creates one each of TX submission, TX completion, RX submission and RX completion. That observed source layout is not, by itself, proof it meets QueueSet WMM scheduling cardinality.",
 "",
 "SAFETY:",
 "No source file changed. No build, signing, install, load, hardware test, SIP/NVRAM change or OpenCore modification."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("STAGE89_V6_RESULT=REVIEW_REQUIRED")
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V6 — NATIVE QUEUE FACTORY / WMM CONTRACT AUDIT ==========
STAGE89_V6_RUN: $RUN
STAGE89_V6_VERSION: STAGE89_V6_20261104
STAGE89_V6_PREDECESSOR: $V5_RUN
STAGE89_V6_SOURCE_TREE_REVALIDATION: PASS
STAGE89_V6_TARGET_KERNEL_WMM_REVALIDATION: PASS
STAGE89_V6_NATIVE_QUEUE_METHOD_AUDIT: COMPLETE
STAGE89_V6_FOUR_QUEUE_ROLE_AND_WMM_CARDINALITY: REQUIRES_REVIEW
STAGE89_V6_POINTER_ARRAY: NOT_IMPLEMENTED
STAGE89_V6_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V6_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V6_SOURCE_MODIFIED: NO
STAGE89_V6_BUILD: NOT_RUN
STAGE89_V6_SIGNING: NOT_RUN
STAGE89_V6_INSTALL: NOT_RUN
STAGE89_V6_LOAD: NOT_RUN
STAGE89_V6_OPENCORE_CHANGE: NONE
STAGE89_V6_RESULT: REVIEW_REQUIRED
STAGE89_V6_ACTIVATION_GATE: BLOCKED
STAGE89_V6_LOGS: $REMOTE/
EOF
python3 - "$OUT" <<'PY'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=[
 "source-tree-revalidation.txt","source-queue-construction-model.txt",
 "native-queue-method-index.txt","native-queue-method-disassembly.txt",
 "native-queue-factory-performcommand-facts.txt","native-queue-vtable-crosswalk.txt",
 "target-kernel-wmm-revalidation.txt","audit-summary.txt","report.txt","checkpoint-block.txt"
]
rows=["STAGE89_V6_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(out/n).read_bytes()
 rows.append("ARTIFACT|%s|%s|%d"%(n,hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest(),len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PY
for f in \
 "$OUT/source-tree-revalidation.txt" \
 "$OUT/source-queue-construction-model.txt" \
 "$OUT/native-queue-method-index.txt" \
 "$OUT/native-queue-method-disassembly.txt" \
 "$OUT/native-queue-factory-performcommand-facts.txt" \
 "$OUT/native-queue-vtable-crosswalk.txt" \
 "$OUT/target-kernel-wmm-revalidation.txt" \
 "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PY'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V6_RUN:" in old: raise SystemExit("V6 history already exists; refusing duplicate append")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V6 native queue factory/WMM audit","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
PY
LOG_WANT="$(blob "$OUT/output-updated.txt")"
LOG_OK=NO
for attempt in 1 2 3 4; do
 if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-update-response.json" 2> "$OUT/output-update-error.txt"; then echo "CANONICAL_LOG_UPDATE_ATTEMPT=$attempt"; fi
 LOG_GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 if [[ "$LOG_GOT" == "$LOG_WANT" ]]; then LOG_OK=YES; break; fi
 sleep 2
done
[[ "$LOG_OK" == "YES" ]] || fail "Canonical Development/output.log SHA verification failed"
echo "CANONICAL_LOG_VERIFIED=YES SHA=$LOG_GOT"
echo "STAGE89_V6_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
