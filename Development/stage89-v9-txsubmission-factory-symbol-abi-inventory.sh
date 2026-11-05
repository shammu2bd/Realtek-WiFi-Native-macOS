#!/bin/bash
# Stage 89 V9 — target TXSubmission factory symbol and ABI inventory.
# READ ONLY: no driver edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V7_RUN="run-20261105-023512-10ebb15d9bfe"
V8_RUN="run-20261105-032654-18c31a821dd4"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v9/$RUN"
REMOTE="Development/Logs/stage89-v9/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache" "$OUT/evidence"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PYBLOB'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest())
PYBLOB
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
 python3 - "$f" "$payload" <<'PYUPLOAD'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V9 TXSubmission target symbol/ABI inventory","content":base64.b64encode(p.read_bytes()).decode()}))
PYUPLOAD
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote SHA=$got"; return 0; fi
  gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt" || true
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
   echo "STAGE89_V9_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 80 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail xcrun; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Project source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
CFILT="$(xcrun --find c++filt 2>/dev/null || command -v c++filt || true)"
echo "STAGE89_V9_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"
if [[ -n "$CFILT" ]]; then echo "DEMANGLE_TOOL=$CFILT"; else echo "DEMANGLE_TOOL=UNAVAILABLE_RAW_MANGLED_NAMES_ONLY"; fi

BASE="https://raw.githubusercontent.com/$REPO/main"
LOGS="$BASE/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v7-audit-summary.txt e9a647b037109777f9fb5bcb7784a746ddb6314e "$LOGS/stage89-v7/$V7_RUN/audit-summary.txt"
pin v7-queue-role-analysis.txt bb728a438802938a9a07f1f997978c7fa76aa19f "$LOGS/stage89-v7/$V7_RUN/queue-role-wmm-cardinality-analysis.txt"
pin v8-audit-summary.txt 7738c65dcbd1fa63830ac66551587b00c8e39e8a "$LOGS/stage89-v8/$V8_RUN/audit-summary.txt"
pin v8-factory-crosswalk.txt db42517c32cacca0fc69c057e838add9c6a7ca5b "$LOGS/stage89-v8/$V8_RUN/tx-factory-header-target-abi-crosscheck.txt"
pin v8-report.txt d5c46c7a1bbac8c558a77c6f574b26b60fda62e3 "$LOGS/stage89-v8/$V8_RUN/report.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$LOGS/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin tx-submission-header.txt 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin native-queue-source.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Kernel collection parser hash mismatch"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V7_RUN" "$V8_RUN" <<'PYLOG'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
v7=re.findall(r"STAGE89_V7_RUN:\s*(run-[A-Za-z0-9-]+)",log)
v8=re.findall(r"STAGE89_V8_RUN:\s*(run-[A-Za-z0-9-]+)",log)
if not v7 or v7[-1]!=sys.argv[2]: raise SystemExit("Latest V7 checkpoint differs from pinned predecessor")
if not v8 or v8[-1]!=sys.argv[3]: raise SystemExit("Latest V8 checkpoint differs from pinned predecessor")
if "STAGE89_V8_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V8 REVIEW_REQUIRED checkpoint missing")
if "STAGE89_V9_RUN:" in log: raise SystemExit("V9 checkpoint already exists; inspect it rather than duplicating")
print("PREDECESSOR_GATE=PASS V7="+v7[-1]+" V8="+v8[-1])
PYLOG

python3 -u - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$CFILT" "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/tx-submission-header.txt" "$OUT/native-queue-source.cpp" "$OUT" <<'PY'
import hashlib,pathlib,re,struct,subprocess,sys
tools,bootkc,cache,objdump,demangler,src_path,fingerprint,header_path,source_path,out_path=sys.argv[1:]
out=pathlib.Path(out_path); src=pathlib.Path(src_path)
expected={}
for line in pathlib.Path(fingerprint).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
tree_ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
tree_rows=["STAGE89_V9_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual),"RESULT="+("PASS" if tree_ok else "REVIEW_REQUIRED")]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): tree_rows.append("MISMATCH="+k)
(out/"source-tree-revalidation.txt").write_text("\n".join(tree_rows)+"\n")
if not tree_ok: raise SystemExit("Native source tree differs from Stage73 baseline")

sys.path.insert(0,tools)
from kcfile import KC
print("KERNEL_COLLECTION_LOAD_BEGIN=YES",flush=True)
kc=KC(bootkc)
owner="com.apple.iokit.IOSkywalkFamily"
entry=next((e for e in kc.entries if e[0]==owner),None)
if not entry: raise SystemExit("IOSkywalkFamily fileset entry missing")
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
  if size and flags&(0x80000000|0x400): ranges.append((sn,gn,va,va+size))
def iscode(a): return any(lo<=a<hi for _sn,_gn,lo,hi in ranges)
addresses=sorted(a for a in kc.addrs if kc.sym_owner.get(a)==owner and iscode(a))
print("KERNEL_COLLECTION_LOAD_COMPLETE=YES SYMBOLS=%d IOSKYWALK_CODE_SYMBOLS=%d FILESET_ENTRIES=%d"%(len(kc.addrs),len(addresses),len(kc.entries)),flush=True)

prefix="__ZN26IOSkywalkTxSubmissionQueue"
token=re.compile(r"(?:withPool|initWithPool)")
selected=[]
for a in addresses:
 name=kc.syms[a]
 if name.startswith(prefix) and token.search(name):
  selected.append((a,name))
selected.sort()
if not selected: raise SystemExit("No TXSubmission withPool/initWithPool target symbols found")

carved=pathlib.Path(cache)/"IOSkywalkFamily.macho"
kc.carve(owner,str(carved))
demangled={}
def demangle(name):
 if not demangler: return "DEMANGLE_UNAVAILABLE"
 arg=name[1:] if name.startswith("_") else name
 try:
  p=subprocess.run([demangler,arg],capture_output=True,text=True,timeout=10)
  return p.stdout.strip() if p.returncode==0 and p.stdout.strip() else "DEMANGLE_FAILED:"+p.stderr.strip()[:160]
 except Exception as e: return "DEMANGLE_FAILED:"+str(e)
method_bodies={}
for i,(a,name) in enumerate(selected,1):
 end=kc.next_sym(a)
 sec=next((x for x in ranges if x[2]<=a<x[3]),None)
 if not sec: continue
 stop=end if end and a<end<=min(a+0x18000,sec[3]) else min(a+0x10000,sec[3])
 print("DISASSEMBLY_PROGRESS=%d/%d ADDRESS=0x%x SYMBOL=%s"%(i,len(selected),a,name),flush=True)
 try:
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%a,"--stop-address=0x%x"%stop,str(carved)],capture_output=True,text=True,timeout=60)
 except subprocess.TimeoutExpired: raise SystemExit("llvm-objdump timeout for "+name)
 ins=[x.strip() for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
 if p.returncode or not ins: raise SystemExit("Disassembly failed for "+name+" "+p.stderr[:300])
 method_bodies[(a,name)]=ins
 demangled[name]=demangle(name)

symbol_rows=[
 "STAGE89_V9_TARGET_TXSUBMISSION_FACTORY_SYMBOL_INDEX",
 "IOSKYWALK_SYMBOL_OWNER="+owner,
 "TXSUBMISSION_METHOD_SYMBOL_COUNT="+str(len(selected)),
 "DEMANGLE_TOOL="+(demangler or "UNAVAILABLE")
]
for a,name in selected:
 symbol_rows.append("ADDRESS=0x%016x MANGLED=%s"%(a,name))
 symbol_rows.append("DEMANGLED="+demangled[name])
pathlib.Path(out/"target-txsubmission-factory-symbol-index.txt").write_text("\n".join(symbol_rows)+"\n")

dis_rows=["STAGE89_V9_TARGET_TXSUBMISSION_FACTORY_METHOD_DISASSEMBLY"]
for (a,name),ins in method_bodies.items():
 dis_rows.append("===== ADDRESS=0x%016x SYMBOL=%s ====="%(a,name))
 dis_rows.append("DEMANGLED="+demangled[name])
 dis_rows.extend(ins)
pathlib.Path(out/"target-txsubmission-factory-disassembly.txt").write_text("\n".join(dis_rows)+"\n")

header=pathlib.Path(header_path).read_text(errors="replace")
source=pathlib.Path(source_path).read_text(errors="replace")
factory_lines=[x.strip() for x in header.splitlines() if "static IOSkywalkTxSubmissionQueue *" in x]
init_lines=[x.strip() for x in header.splitlines() if "virtual bool initWithPool" in x]
exact_prefix="__ZN26IOSkywalkTxSubmissionQueue23withPoolAndServiceClassE"
exact_named=[(a,n) for a,n in selected if n.startswith(exact_prefix)]
factory_methods=[(a,n,ins) for (a,n),ins in method_bodies.items() if re.search(r"Queue8withPool",n) and not re.search(r"Queue12initWithPool",n)]
init_methods=[(a,n,ins) for (a,n),ins in method_bodies.items() if "initWithPool" in n]
source_match=re.search(r"IOSkywalkTxSubmissionQueue::withPool\s*\((.*?)\);",source,re.S)
source_call=source_match.group(1) if source_match else ""
source_action_only=bool(source_match and "txSubmissionAction" in source_call and "QueryFreeSpace" not in source_call)
source_explicit="IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(" in source
factory_rows=[]
for a,n,ins in factory_methods:
 text_ins="\n".join(ins)
 factory_rows.append({
  "address":a,"name":n,"demangled":demangled[n],"instructions":ins,
  "push_minus_one":bool(re.search(r"\bpush\s+-0x1",text_ins)),
  "extra_stack_u32":bool(re.search(r"\bmov\s+(?:e|r)[a-z0-9]+d?, dword ptr \[rbp \+ 0x20\]",text_ins)),
  "calls_internal":re.findall(r"\bcall\s+(0x[0-9a-fA-F]+)",text_ins)
 })
init_rows=[]
for a,n,ins in init_methods:
 text_ins="\n".join(ins)
 init_rows.append({
  "address":a,"name":n,"demangled":demangled[n],
  "stores_0xb8":bool(re.search(r"\bmov\s+dword ptr \[[a-z0-9]+\s*\+\s*0xb8\],",text_ins)),
  "registers": [x for x in ins if re.search(r"\b(?:mov|cmp|test)\s+(?:r15d|edx|ecx|r8d|r9d)",x)]
 })
factory_cross=[
 "STAGE89_V9_TX_FACTORY_SYMBOL_AND_DECLARATION_CROSSWALK",
 "HEADER_STATIC_FACTORY_DECLARATIONS="+str(len(factory_lines)),
 *["HEADER_FACTORY="+x for x in factory_lines],
 "HEADER_INIT_DECLARATIONS="+str(len(init_lines)),
 *["HEADER_INIT="+x for x in init_lines],
 "TARGET_FACTORY_METHODS="+str(len(factory_rows)),
 *["TARGET_FACTORY_ADDRESS=0x%x SYMBOL=%s"%(x["address"],x["name"]) for x in factory_rows],
 "TARGET_EXACT_NAMED_WITHPOOLANDSERVICECLASS_SYMBOLS="+str(len(exact_named)),
 "CURRENT_SOURCE_CALL_IS_ACTION_ONLY="+("YES" if source_action_only else "NO_OR_UNPARSED"),
 "CURRENT_SOURCE_CALL_USES_EXPLICIT_SERVICECLASS_FACTORY="+("YES" if source_explicit else "NO"),
 "TARGET_INIT_METHODS="+str(len(init_rows)),
 *["TARGET_INIT_ADDRESS=0x%x SYMBOL=%s STORES_0xB8=%s"%(x["address"],x["name"],"YES" if x["stores_0xb8"] else "NO") for x in init_rows]
]
for x in factory_rows:
 factory_cross.append("FACTORY_METHOD=0x%x DEMANGLED=%s"%(x["address"],x["demangled"]))
 factory_cross.append("FACTORY_PUSH_MINUS_ONE="+("YES" if x["push_minus_one"] else "NO"))
 factory_cross.append("FACTORY_LOADS_FINAL_STACK_U32="+("YES" if x["extra_stack_u32"] else "NO"))
 factory_cross.append("FACTORY_DIRECT_CALL_TARGETS="+",".join(x["calls_internal"]))
for x in init_rows:
 factory_cross.append("INIT_METHOD=0x%x DEMANGLED=%s"%(x["address"],x["demangled"]))
 factory_cross.append("INIT_WRITES_M_SERVICE_CLASS_OFFSET_0xB8="+("YES" if x["stores_0xb8"] else "NO"))
 factory_cross.extend(["INIT_REGISTER_EVIDENCE="+z for z in x["registers"]])
pathlib.Path(out/"tx-factory-symbol-demangle-crosswalk.txt").write_text("\n".join(factory_cross)+"\n")

# Target factory calls the initializer through object-vptr +0x2a8. Under the Itanium
# primary address point rule this is raw __ZTV index 87.
vt_rows=["STAGE89_V9_TXSUBMISSION_INIT_VTABLE_SLOT_AUDIT","OBJECT_VPTR_CALL_OFFSET=0x2a8","RAW_ZTV_INDEX=87"]
init_addrs={x["address"] for x in init_rows}
vt=kc.vtable("IOSkywalkTxSubmissionQueue") or []
slot87=[]
for i,raw,target,name in vt:
 if i==87:
  slot87.append((target,name))
  vt_rows.append("RAW_INDEX=87 RAW=0x%x TARGET=0x%x NAME=%s"%(raw,target,name))
vt_rows.append("TX_INIT_METHOD_ADDRESSES="+",".join("0x%x"%x for x in sorted(init_addrs)))
vt_rows.append("SLOT_87_TARGET_IS_CAPTURED_TX_INIT="+("YES" if any(t in init_addrs for t,_ in slot87) else "NO_OR_NOT_PROVEN"))
pathlib.Path(out/"tx-init-vtable-call-abi.txt").write_text("\n".join(vt_rows)+"\n")

summary=[
 "STAGE89_V9_TARGET_TXSUBMISSION_FACTORY_SYMBOL_ABI_INVENTORY",
 "VERSION=STAGE89_V9_20261105",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "TXSUBMISSION_FACTORY_SYMBOLS_CAPTURED="+str(len(factory_rows)),
 "TXSUBMISSION_INIT_SYMBOLS_CAPTURED="+str(len(init_rows)),
 "EXACT_WITHPOOLANDSERVICECLASS_TARGET_SYMBOLS="+str(len(exact_named)),
 "CURRENT_SOURCE_ACTION_ONLY_FACTORY_CALL="+("YES" if source_action_only else "NOT_PROVEN"),
 "CURRENT_SOURCE_DEFAULT_CLASS_PATH="+("0xffffffff (from V8 action-only wrapper proof)" if source_action_only else "NOT_PROVEN"),
 "TARGET_INIT_WRITES_SERVICE_CLASS_OFFSET_0xB8="+("YES" if any(x["stores_0xb8"] for x in init_rows) else "NOT_PROVEN"),
 "TX_INIT_VTABLE_SLOT_87="+("MATCH" if any(t in init_addrs for t,_ in slot87) else "NOT_PROVEN"),
 "SDK_EXPLICIT_FACTORY_PUBLIC_DECLARATION_COUNT="+str(sum("withPoolAndServiceClass" in x for x in factory_lines)),
 "SDK_TO_TARGET_EXPLICIT_FACTORY_SYMBOL_MAPPING="+("FOUND_EXACT_SYMBOL" if exact_named else "NOT_PROVEN"),
 "SDK_INIT_DECLARATION_COUNT="+str(len(init_lines)),
 "QUEUESET_WMM_ROLE_1_REQUIRES_FOUR_TX_SUBMISSION_QUEUES=YES",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1",
 "QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
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
 "NEXT=Review the complete target TX factory symbol/index/disassembly crosswalk. Do not guess a factory overload or alter the current SDK header; decide exact target-to-public API mapping and queue-role counts before Stage89 implementation."
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V9 — TARGET TXSUBMISSION FACTORY SYMBOL / ABI INVENTORY ==========",
 *summary,"",
 "TARGET SYMBOL INDEX AND DEMANGLED SIGNATURES:",
 *symbol_rows,"",
 "TX FACTORY / HEADER CROSSWALK:",
 *factory_cross,"",
 "INIT VTABLE SLOT:",
 *vt_rows,"",
 "CURRENT SOURCE FACTORY CALL:",
 source_call,
 "",
 "INTERPRETATION:",
 "This audit enumerates every IOSkywalkFamily instruction-section symbol whose exact class name is IOSkywalkTxSubmissionQueue and whose method name is withPool or initWithPool. It records raw mangled names, demangled prototypes when c++filt is available, every selected factory/init body, the service-class field writer, and the TXSubmission vtable slot used by the factory's virtual initializer call.",
 "A public SDK declaration named withPoolAndServiceClass is not accepted as a target implementation unless its exact target symbol or an independently proven wrapper mapping is found. A withPool overload with an extra UInt32 is recorded by its actual target signature and register flow; its extra parameter is not assigned a semantic name from its C++ symbol alone.",
 "The current source remains on its action-only withPool call. This read-only stage does not replace the header, change the factory call, construct extra TX queues or register queues.",
 "",
 "SAFETY:",
 "No source file changed. No build, signing, install, load, hardware test, SIP/NVRAM or OpenCore modification occurred."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("TXSUBMISSION_FACTORY_SYMBOLS_CAPTURED=%d"%len(factory_rows),flush=True)
print("TXSUBMISSION_INIT_SYMBOLS_CAPTURED=%d"%len(init_rows),flush=True)
print("EXACT_WITHPOOLANDSERVICECLASS_TARGET_SYMBOLS=%d"%len(exact_named),flush=True)
print("TX_INIT_VTABLE_SLOT_87_MATCH=%s"%("YES" if any(t in init_addrs for t,_ in slot87) else "NO_OR_NOT_PROVEN"),flush=True)
print("STAGE89_V9_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V9 — TARGET TXSUBMISSION FACTORY SYMBOL / ABI INVENTORY ==========
STAGE89_V9_RUN: $RUN
STAGE89_V9_VERSION: STAGE89_V9_20261105
STAGE89_V9_PREDECESSOR: $V8_RUN
STAGE89_V9_SOURCE_TREE_REVALIDATION: PASS
STAGE89_V9_SCOPE: ALL_IOSKYWALK_TXSUBMISSION_WITHPOOL_AND_INITWITHPOOL_TARGET_SYMBOLS
STAGE89_V9_FACTORY_SYMBOL_ABI_INVENTORY: CAPTURED
STAGE89_V9_EXPLICIT_FACTORY_MAPPING: REVIEW_REQUIRED
STAGE89_V9_CURRENT_SOURCE_FACTORY_CALL: ACTION_ONLY_WITHPOOL
STAGE89_V9_CURRENT_TX_CLASS_DEFAULT: 0xffffffff
STAGE89_V9_WMM_ROLE_1_QUEUE_REQUIREMENT: FOUR_TX_SUBMISSION_QUEUES
STAGE89_V9_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1
STAGE89_V9_QUEUE_ARRAY: NOT_IMPLEMENTED
STAGE89_V9_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V9_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V9_SOURCE_MODIFIED: NO
STAGE89_V9_BUILD: NOT_RUN
STAGE89_V9_SIGNING: NOT_RUN
STAGE89_V9_INSTALL: NOT_RUN
STAGE89_V9_LOAD: NOT_RUN
STAGE89_V9_OPENCORE_CHANGE: NONE
STAGE89_V9_RESULT: REVIEW_REQUIRED
STAGE89_V9_ACTIVATION_GATE: BLOCKED
STAGE89_V9_LOGS: $REMOTE/
EOF

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=[
 "source-tree-revalidation.txt",
 "target-txsubmission-factory-symbol-index.txt",
 "target-txsubmission-factory-disassembly.txt",
 "tx-factory-symbol-demangle-crosswalk.txt",
 "tx-init-vtable-call-abi.txt",
 "audit-summary.txt","report.txt","checkpoint-block.txt"
]
rows=["STAGE89_V9_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST

for f in \
 "$OUT/source-tree-revalidation.txt" \
 "$OUT/target-txsubmission-factory-symbol-index.txt" \
 "$OUT/target-txsubmission-factory-disassembly.txt" \
 "$OUT/tx-factory-symbol-demangle-crosswalk.txt" \
 "$OUT/tx-init-vtable-call-abi.txt" \
 "$OUT/audit-summary.txt" "$OUT/report.txt" \
 "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V9_RUN:" in old: raise SystemExit("V9 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V9 target TXSubmission factory symbol/ABI inventory","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
PYOUT
LOG_WANT="$(blob "$OUT/output-updated.txt")"
LOG_OK=NO
for attempt in 1 2 3 4; do
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-update-response.json" 2> "$OUT/output-update-error.txt" || true
 LOG_GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 if [[ "$LOG_GOT" == "$LOG_WANT" ]]; then LOG_OK=YES; break; fi
 sleep 2
done
[[ "$LOG_OK" == "YES" ]] || fail "Canonical Development/output.log SHA readback failed"
echo "CANONICAL_LOG_VERIFIED=YES SHA=$LOG_GOT"
echo "STAGE89_V9_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
