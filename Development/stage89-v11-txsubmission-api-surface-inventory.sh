#!/bin/bash
# Stage 89 V11 — full project SDK/source + target-kernel TXSubmission API-surface inventory.
# READ ONLY: no source/header edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
V9_RUN="run-20261105-034922-6566f42c51aa"
V10_RUN="run-20261105-041550-62ef6b8a0915"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v11/$RUN"
REMOTE="Development/Logs/stage89-v11/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){
 python3 - "$1" <<'PYBLOB'
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V11 TXSubmission API surface inventory","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V11_FAILURE"
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
[[ -d "$SRC/src" && -d "$SRC/MacKernelSDK/Headers" && -f "$BOOTKC" ]] || fail "Project source, MacKernelSDK headers or target kernel collection missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
CFILT="$(xcrun --find c++filt 2>/dev/null || command -v c++filt || true)"

BASE="https://raw.githubusercontent.com/$REPO/main"
LOGS="$BASE/Development/Logs"
TOOLS="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
pin v9-manifest.txt 2a9bcb8389eee070619efea5d2ddbb785a5907f8 "$LOGS/stage89-v9/$V9_RUN/manifest.txt"
pin v9-symbol-index.txt 41cbdaf57b7d38fc40c09b20ca54e34eb504d109 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-symbol-index.txt"
pin v9-crosswalk.txt f6b797a210f37a1d4335dc6fe81ae68c17df4a71 "$LOGS/stage89-v9/$V9_RUN/tx-factory-symbol-demangle-crosswalk.txt"
pin v10-manifest.txt 156cbf378f521a2ddd10dc5a858c24694ef9b0da "$LOGS/stage89-v10/$V10_RUN/manifest.txt"
pin v10-dataflow-checks.txt 60301de086cffeba45d77da1510db3de319ec5a3 "$LOGS/stage89-v10/$V10_RUN/argument-dataflow-checks.txt"
pin v10-sdk-crosswalk.txt 7b21f9fe951b6e47b01afa6c32b5d3a331edd603 "$LOGS/stage89-v10/$V10_RUN/sdk-target-api-crosswalk.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$LOGS/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
curl -fsSLo "$OUT/tools/kcfile.py" "$TOOLS/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Kernel collection parser hash mismatch"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V9_RUN" "$V10_RUN" <<'PYLOG'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
for stage,expected in (("V9",sys.argv[2]),("V10",sys.argv[3])):
 runs=re.findall(r"STAGE89_"+stage+r"_RUN:\s*(run-[A-Za-z0-9-]+)",log)
 if not runs or runs[-1]!=expected: raise SystemExit("Latest "+stage+" checkpoint differs from pinned predecessor")
if "STAGE89_V10_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V10 review checkpoint missing")
if "STAGE89_V11_RUN:" in log: raise SystemExit("V11 checkpoint already exists; inspect rather than duplicate")
print("PREDECESSOR_GATE=PASS V9="+sys.argv[2]+" V10="+sys.argv[3])
PYLOG
echo "STAGE89_V11_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"
if [[ -n "$CFILT" ]]; then echo "DEMANGLE_TOOL=$CFILT"; fi

python3 -u - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT" "$CFILT" <<'PY'
import hashlib,pathlib,re,struct,subprocess,sys
tools,bootkc,cache,src_root,fingerprint,out_path,demangler=sys.argv[1:]
out=pathlib.Path(out_path); root=pathlib.Path(src_root); driver=root.parent
exts={".cpp",".cc",".c",".mm",".h",".hpp",".hh"}
expected={}
for line in pathlib.Path(fingerprint).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
source_files=sorted(p for p in (root/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(root).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
tree_ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
tree_rows=["STAGE89_V11_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual),"RESULT="+("PASS" if tree_ok else "REVIEW_REQUIRED")]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): tree_rows.append("MISMATCH="+k)
(out/"source-tree-revalidation.txt").write_text("\n".join(tree_rows)+"\n")
if not tree_ok: raise SystemExit("Native source tree differs from the pinned Stage73 baseline")

# Inventory every project SDK/source file that can declare or reference this API.
scan_roots=[root/"MacKernelSDK"/"Headers",root/"src"]
surface_terms=re.compile(r"IOSkywalkTxSubmissionQueue|withPoolAndServiceClass|initWithPool|kern_packet_svc_class_t",re.I)
surface_rows=["STAGE89_V11_PROJECT_API_SURFACE_INDEX"]
header_decls=[]
matches=0
for base in scan_roots:
 for p in sorted(x for x in base.rglob("*") if x.is_file() and x.suffix.lower() in exts):
  try: lines=p.read_text(errors="replace").splitlines()
  except Exception: continue
  rel=p.relative_to(root).as_posix()
  for i,line in enumerate(lines):
   if not surface_terms.search(line): continue
   matches+=1
   surface_rows.append("%s:%d:%s"%(rel,i+1,line.strip()[:320]))
   if "withPool" in line or "initWithPool" in line:
    lo=max(0,i-1); hi=min(len(lines),i+3)
    block=" ".join(x.strip() for x in lines[lo:hi])
    if "withPool" in block or "initWithPool" in block:
     header_decls.append((rel,i+1,block[:900]))
(out/"sdk-api-surface-index.txt").write_text("\n".join(surface_rows)+"\n")

# Parse the exact target fileset symbols. Include all class-owned symbols, not only factories.
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
  va,size=struct.unpack_from("<QQ",kc.d,q+32)
  flags=struct.unpack_from("<I",kc.d,q+64)[0]
  if size and flags&(0x80000000|0x400): ranges.append((va,va+size))
def iscode(a): return any(lo<=a<hi for lo,hi in ranges)
prefix="__ZN26IOSkywalkTxSubmissionQueue"
all_class=[]
for a in sorted(kc.addrs):
 name=kc.syms.get(a,"")
 if name.startswith(prefix) and kc.sym_owner.get(a)==owner:
  all_class.append((a,name,iscode(a)))
if not all_class: raise SystemExit("No exact target IOSkywalkTxSubmissionQueue class symbols found")
all_global_names=[n for n in kc.syms.values() if "withPoolAndServiceClass" in n]
target_exact=[(a,n) for a,n,_ in all_class if "withPoolAndServiceClass" in n]
factory=[(a,n,code) for a,n,code in all_class if "withPool" in n and "initWithPool" not in n]
init=[(a,n,code) for a,n,code in all_class if "initWithPool" in n]

def demangle(name):
 if not demangler: return "DEMANGLE_UNAVAILABLE"
 arg=name[1:] if name.startswith("_") else name
 try:
  p=subprocess.run([demangler,arg],capture_output=True,text=True,timeout=8)
  return p.stdout.strip() if p.returncode==0 and p.stdout.strip() else "DEMANGLE_FAILED"
 except Exception: return "DEMANGLE_FAILED"

symbol_rows=[
 "STAGE89_V11_TARGET_TXSUBMISSION_CLASS_SYMBOL_INVENTORY",
 "FILESSET_OWNER="+owner,
 "CLASS_PREFIX="+prefix,
 "CLASS_SYMBOL_COUNT="+str(len(all_class)),
 "CLASS_CODE_SYMBOL_COUNT="+str(sum(1 for _,_,c in all_class if c)),
 "CLASS_FACTORY_WITHPOOL_COUNT="+str(len(factory)),
 "CLASS_INITWITHPOOL_COUNT="+str(len(init)),
 "CLASS_EXACT_WITHPOOLANDSERVICECLASS_COUNT="+str(len(target_exact)),
 "FILESSET_GLOBAL_WITHPOOLANDSERVICECLASS_SYMBOL_COUNT="+str(len(all_global_names)),
]
for a,n,code in all_class:
 symbol_rows.append("SYMBOL=0x%016x CODE=%s MANGLED=%s"%(a,"YES" if code else "NO",n))
 symbol_rows.append("DEMANGLED="+demangle(n))
(out/"target-class-symbol-inventory.txt").write_text("\n".join(symbol_rows)+"\n")

header_withpool=[x for x in header_decls if "withPool" in x[2]]
header_explicit=[x for x in header_decls if "withPoolAndServiceClass" in x[2]]
header_init=[x for x in header_decls if "initWithPool" in x[2]]
source_withpool=[]
for p in sorted((root/"src").rglob("*")):
 if p.is_file() and p.suffix.lower() in exts:
  txt=p.read_text(errors="replace")
  if "IOSkywalkTxSubmissionQueue::withPool" in txt or "IOSkywalkTxSubmissionQueue::withPoolAndServiceClass" in txt:
   source_withpool.append(p.relative_to(root).as_posix())
target_signature=next((n for _,n,_ in factory if n.endswith("jj") or n.endswith("jj")), "")
api_complete=not target_exact and len(header_explicit)==1 and len(header_withpool)>=1
cross=[
 "STAGE89_V11_PROJECT_SDK_TO_TARGET_API_CROSSWALK",
 "PROJECT_SURFACE_ROOTS=MacKernelSDK/Headers;src",
 "PROJECT_API_MATCH_LINES="+str(matches),
 "PROJECT_WITHPOOL_DECLARATION_CONTEXTS="+str(len(header_withpool)),
 "PROJECT_WITHPOOLANDSERVICECLASS_DECLARATION_CONTEXTS="+str(len(header_explicit)),
 "PROJECT_INITWITHPOOL_DECLARATION_CONTEXTS="+str(len(header_init)),
 "PROJECT_SOURCE_FILES_USING_TXSUBMISSION_STATIC_FACTORY="+str(len(source_withpool)),
 *["SOURCE_FACTORY_FILE="+x for x in source_withpool],
 "TARGET_CLASS_SYMBOLS="+str(len(all_class)),
 "TARGET_WITHPOOL_FACTORY_SYMBOLS="+str(len(factory)),
 "TARGET_INITWITHPOOL_SYMBOLS="+str(len(init)),
 "TARGET_EXACT_WITHPOOLANDSERVICECLASS_SYMBOLS="+str(len(target_exact)),
 "ANY_FILESSET_SYMBOL_WITHPOOLANDSERVICECLASS="+str(len(all_global_names)),
 "TARGET_API_DECLARATION_COVERAGE=INCOMPLETE" if api_complete else "TARGET_API_DECLARATION_COVERAGE=REVIEW_REQUIRED",
 "DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND",
 "SERVICE_CLASS_ARGUMENT_SEMANTICS=PROVEN_IN_V10",
 "SERVICE_CLASS_POSITION=TARGET_FACTORY_TRAILING_U32_AFTER_OPTIONS",
 "SDK_EXPLICIT_DECLARATION_POSITION=BEFORE_OWNER",
 "SOURCE_OR_HEADER_EDIT=NOT_AUTHORIZED",
 "IMPLEMENTATION_RECOMMENDATION=DO_NOT_GUESS_OR_EDIT"
]
for rel,ln,block in header_decls:
 cross.append("SDK_CONTEXT=%s:%d:%s"%(rel,ln,block))
(out/"api-crosswalk-verdict.txt").write_text("\n".join(cross)+"\n")

summary=[
 "STAGE89_V11_TXSUBMISSION_PROJECT_API_SURFACE_INVENTORY",
 "VERSION=STAGE89_V11_20261105",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "V9_V10_EVIDENCE_PINS=PASS",
 "SOURCE_TREE_REVALIDATION=PASS",
 "PROJECT_API_MATCH_LINES="+str(matches),
 "PROJECT_WITHPOOL_DECLARATION_CONTEXTS="+str(len(header_withpool)),
 "PROJECT_EXPLICIT_SERVICECLASS_DECLARATION_CONTEXTS="+str(len(header_explicit)),
 "TARGET_TXSUBMISSION_CLASS_SYMBOLS="+str(len(all_class)),
 "TARGET_TXSUBMISSION_FACTORY_SYMBOLS="+str(len(factory)),
 "TARGET_TXSUBMISSION_INIT_SYMBOLS="+str(len(init)),
 "TARGET_EXACT_WITHPOOLANDSERVICECLASS_SYMBOLS="+str(len(target_exact)),
 "FILESSET_GLOBAL_WITHPOOLANDSERVICECLASS_SYMBOLS="+str(len(all_global_names)),
 "DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND",
 "V10_TARGET_SERVICECLASS_DATAFLOW=PROVEN",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1",
 "FOUR_TX_SUBMISSION_QUEUES_REQUIRED=YES",
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
 "NEXT=Review the complete symbol and declaration inventories. If no matching declaration exists, keep Stage89 fail-closed and request explicit implementation authorization before designing a minimal ABI wrapper."
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V11 — TXSUBMISSION PROJECT API-SURFACE INVENTORY ==========",
 *summary,"",
 "SDK/SOURCE API SURFACE:",
 "The inventory scans every supported source/header file under MacKernelSDK/Headers and src for IOSkywalkTxSubmissionQueue, withPoolAndServiceClass, initWithPool and kern_packet_svc_class_t. It records matching source lines and declaration contexts.",
 "",
 "TARGET KERNEL CLASS SURFACE:",
 "The inventory enumerates every symbol owned by IOSkywalkTxSubmissionQueue in the IOSkywalkFamily fileset, not just withPool/initWithPool. It separately counts withPool factory methods, initWithPool methods and any exact withPoolAndServiceClass method, and records demangled forms when c++filt is available.",
 "",
 "INTERPRETATION:",
 "V10 established that the target withPool factory's trailing UInt32 becomes the service-class field. This V11 run checks whether the rest of the project already exposes a declaration matching that target ABI. It does not infer a declaration from the SDK method name, reorder arguments, or propose private object-field writes.",
 "",
 "REMAINING STAGE89 BLOCKERS:",
 "Four TX submission queues and their stable pointer array are not implemented or tested. Native queue registration remains absent and four callback handoffs remain incomplete. An API-surface inventory cannot satisfy the queue construction/lifetime exit criteria.",
 "",
 "SAFETY:",
 "Read-only source/header and target-kernel symbol inventory only. No source/header modification, build, signing, install, load, hardware test, SIP/NVRAM or OpenCore change."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("PROJECT_API_MATCH_LINES=%d"%matches,flush=True)
print("PROJECT_WITHPOOL_DECLARATIONS=%d"%len(header_withpool),flush=True)
print("PROJECT_EXPLICIT_SERVICECLASS_DECLARATIONS=%d"%len(header_explicit),flush=True)
print("TARGET_CLASS_SYMBOLS=%d"%len(all_class),flush=True)
print("TARGET_EXACT_WITHPOOLANDSERVICECLASS_SYMBOLS=%d"%len(target_exact),flush=True)
print("STAGE89_V11_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V11 — TXSUBMISSION PROJECT API-SURFACE INVENTORY ==========
STAGE89_V11_RUN: $RUN
STAGE89_V11_VERSION: STAGE89_V11_20261105
STAGE89_V11_PREDECESSOR: $V10_RUN
STAGE89_V11_V9_V10_EVIDENCE_PINS: PASS
STAGE89_V11_SOURCE_TREE_REVALIDATION: PASS
STAGE89_V11_API_SURFACE_INVENTORY: CAPTURED
STAGE89_V11_DIRECT_SDK_TO_TARGET_FACTORY_MAPPING: NOT_FOUND
STAGE89_V11_V10_SERVICECLASS_DATAFLOW: PROVEN
STAGE89_V11_FOUR_TX_SUBMISSION_QUEUES_REQUIRED: YES
STAGE89_V11_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1
STAGE89_V11_QUEUE_ARRAY: NOT_IMPLEMENTED
STAGE89_V11_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V11_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V11_SOURCE_MODIFIED: NO
STAGE89_V11_BUILD: NOT_RUN
STAGE89_V11_SIGNING: NOT_RUN
STAGE89_V11_INSTALL: NOT_RUN
STAGE89_V11_LOAD: NOT_RUN
STAGE89_V11_OPENCORE_CHANGE: NONE
STAGE89_V11_RESULT: REVIEW_REQUIRED
STAGE89_V11_ACTIVATION_GATE: BLOCKED
STAGE89_V11_LOGS: $REMOTE/
EOF

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["source-tree-revalidation.txt","sdk-api-surface-index.txt","target-class-symbol-inventory.txt","api-crosswalk-verdict.txt","audit-summary.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V11_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST

for f in "$OUT/source-tree-revalidation.txt" "$OUT/sdk-api-surface-index.txt" "$OUT/target-class-symbol-inventory.txt" "$OUT/api-crosswalk-verdict.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V11_RUN:" in old: raise SystemExit("V11 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V11 TXSubmission project API surface inventory","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
echo "STAGE89_V11_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
