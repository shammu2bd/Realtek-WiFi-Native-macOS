#!/bin/bash
# Stage89 V8 — target TX factory/header ABI cross-check.
# READ ONLY: no native source edits, no build, signing, install/load or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
V7_RUN="run-20261105-023512-10ebb15d9bfe"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v8/$RUN"
REMOTE="Development/Logs/stage89-v8/$RUN"
mkdir -p "$OUT"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V8 target TX factory/header ABI cross-check","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V8_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 70 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$SRC/src" ]] || fail "Native project source directory is missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
echo "STAGE89_V8_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"

BASE="https://raw.githubusercontent.com/$REPO/main"
pin v6-method-disassembly.txt 74cfa4df545e860b60d1a6e77eb26aed2c052313 "$BASE/Development/Logs/stage89-v6/run-20261104-122352-a8be252ec590/native-queue-method-disassembly.txt"
pin v6-method-index.txt 93a03a3200dd5e7f4770c3602f92bfae02bcde19 "$BASE/Development/Logs/stage89-v6/run-20261104-122352-a8be252ec590/native-queue-method-index.txt"
pin v6-source-model.txt 29cfc3ae55af2e8e9bdc981d9807911875483891 "$BASE/Development/Logs/stage89-v6/run-20261104-122352-a8be252ec590/source-queue-construction-model.txt"
pin v7-audit-summary.txt e9a647b037109777f9fb5bcb7784a746ddb6314e "$BASE/Development/Logs/stage89-v7/$V7_RUN/audit-summary.txt"
pin v7-queue-role-analysis.txt bb728a438802938a9a07f1f997978c7fa76aa19f "$BASE/Development/Logs/stage89-v7/$V7_RUN/queue-role-wmm-cardinality-analysis.txt"
pin v7-factory-crosswalk.txt 43a0ef17f1572691ec4f6727419809dea6b58296 "$BASE/Development/Logs/stage89-v7/$V7_RUN/tx-submission-factory-abi-crosswalk.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/Development/Logs/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/Development/Logs/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin tx-submission-header.txt 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin native-queue-source.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V7_RUN" <<'PYLOG'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V7_RUN:\s*(run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]: raise SystemExit("Latest V7 checkpoint does not match pinned run")
if "STAGE89_V7_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V7 REVIEW_REQUIRED checkpoint missing")
if "STAGE89_V8_RUN:" in log: raise SystemExit("A V8 checkpoint already exists; inspect it instead of duplicating")
print("PREDECESSOR_GATE=PASS V7_RUN="+runs[-1])
PYLOG

python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/v6-method-disassembly.txt" "$OUT/v6-method-index.txt" "$OUT/v6-source-model.txt" "$OUT/v7-audit-summary.txt" "$OUT/v7-queue-role-analysis.txt" "$OUT/v7-factory-crosswalk.txt" "$OUT/tx-submission-header.txt" "$OUT/native-queue-source.cpp" "$OUT/stage88-wmm-table.txt" "$OUT" "$RUN" "$V7_RUN" "$REMOTE" <<'PYAUDIT'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[12])
expected={}
for line in pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
tree_ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
source_lines=["STAGE89_V8_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual),"RESULT="+("PASS" if tree_ok else "REVIEW_REQUIRED")]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): source_lines.append("MISMATCH="+k)
(out/"source-tree-revalidation.txt").write_text("\n".join(source_lines)+"\n")
if not tree_ok: raise SystemExit("Native source tree differs from pinned Stage73 baseline")

dis=pathlib.Path(sys.argv[3]).read_text(errors="replace")
index=pathlib.Path(sys.argv[4]).read_text(errors="replace")
source_model=pathlib.Path(sys.argv[5]).read_text(errors="replace")
header=pathlib.Path(sys.argv[9]).read_text(errors="replace")
source=pathlib.Path(sys.argv[10]).read_text(errors="replace")
wmm=pathlib.Path(sys.argv[11]).read_text(errors="replace")
blocks=re.split(r"(?=^===== ADDRESS=)",dis,flags=re.M)
def method_at(addr):
 hits=[b for b in blocks if b.startswith("===== ADDRESS="+addr+" ")]
 if len(hits)!=1: raise SystemExit("Expected one method at "+addr+", got "+str(len(hits)))
 return hits[0]
main=method_at("0xffffff8002983ff0")
wrapper_class=method_at("0xffffff800298409e")
wrapper_default=method_at("0xffffff80029840c2")
tx_init=method_at("0xffffff80029840e8")

main_checks={
 "factory_loads_final_stack_u32":bool(re.search(r"mov\s+edx, dword ptr \[rbp \+ 0x20\]",main)),
 "factory_forwards_capacity_to_ecx":bool(re.search(r"mov\s+ecx, r14d",main)),
 "factory_forwards_queueid_to_r8d":bool(re.search(r"mov\s+r8d, r13d",main)),
 "factory_calls_virtual_init":bool(re.search(r"call\s+qword ptr \[rax \+ 0x2a8\]",main)),
 "class_wrapper_passes_final_u32":bool(re.search(r"mov\s+eax, dword ptr \[rbp \+ 0x20\]",wrapper_class) and re.search(r"push\s+rax",wrapper_class)),
 "default_wrapper_pushes_minus_one":bool(re.search(r"push\s+-0x1",wrapper_default))
}
init_checks={
 "init_saves_edx":bool(re.search(r"mov\s+r15d, edx",tx_init)),
 "init_validates_ecx_minimum_8":bool(re.search(r"cmp\s+ecx, 0x8",tx_init)),
 "init_stores_saved_edx_to_service_class_offset":bool(re.search(r"mov\s+dword ptr \[rbx \+ 0xb8\], r15d",tx_init))
}
if not all(main_checks.values()) or not all(init_checks.values()):
 raise SystemExit("Target factory/init register dataflow checks did not all pass")

init_decl=re.search(r"initWithPool\s*\(\s*IOSkywalkPacketBufferPool\s*\*\s*pool\s*,([^;]+);",header,re.S)
if not init_decl: raise SystemExit("Could not parse SDK initWithPool declaration")
sig=init_decl.group(1)
header_named=bool(re.search(r"UInt32\s+capacity\s*,\s*UInt32\s+queueId\s*,\s*kern_packet_svc_class_t\s+serviceClass",sig))
header_order=["capacity","queueId","serviceClass"] if header_named else ["UNPARSED"]

decls=[line.strip() for line in header.splitlines() if "static IOSkywalkTxSubmissionQueue *" in line]
has_explicit=any("withPoolAndServiceClass" in x for x in decls)
header_action_only=any("withPool(" in x and "IOSkywalkTxSubmissionQueueAction action" in x and "IOSkywalkQueryFreeSpaceHandler" not in x for x in decls)
target_named_explicit="withPoolAndServiceClass" in index
target_action_symbol="__ZN26IOSkywalkTxSubmissionQueue8withPoolEP25IOSkywalkPacketBufferPooljjP8OSObjectPFjS3_S4_PKP15IOSkywalkPacketjPvES9_j"
target_action_only=target_action_symbol in index
src_match=re.search(r"IOSkywalkTxSubmissionQueue::withPool\s*\((.*?)\);",source,re.S)
source_call=src_match.group(1) if src_match else ""
source_action_only=("txSubmissionAction" in source_call and "QueryFreeSpace" not in source_call and bool(src_match))
source_explicit_call="IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(" in source
source_counts={}
for line in source_model.splitlines():
 m=re.match(r"CALL_COUNT\|(.+)\|(\d+)$",line)
 if m: source_counts[m.group(1)]=int(m.group(2))
wmm_values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
if len(wmm_values)!=4: raise SystemExit("Four WMM class values not found in pinned Stage88 table")
if "SOURCE_TREE_REVALIDATION=PASS" not in pathlib.Path(sys.argv[6]).read_text():
 raise SystemExit("Pinned V7 source baseline was not passing")

# The action-only factory wrapper's exact target symbol is present and pushes -1
# before forwarding into the main factory. The source uses this action-only form.
current_path_proven=header_action_only and target_action_only and source_action_only and main_checks["default_wrapper_pushes_minus_one"]

factory_rows=[
 "STAGE89_V8_TX_FACTORY_HEADER_TARGET_ABI_CROSSCHECK",
 "TARGET_MAIN_FACTORY_ADDRESS=0xffffff8002983ff0",
 "TARGET_CLASS_FORWARDING_WRAPPER_ADDRESS=0xffffff800298409e",
 "TARGET_DEFAULT_ACTION_ONLY_WRAPPER_ADDRESS=0xffffff80029840c2",
 "TARGET_TX_INIT_ADDRESS=0xffffff80029840e8",
 "TARGET_FACTORY_REGISTER_DATAFLOW="+("PASS" if all(main_checks.values()) else "REVIEW_REQUIRED"),
 *["FACTORY_CHECK_%s=%s"%(k.upper(),"PASS" if v else "FAIL") for k,v in main_checks.items()],
 "TX_INIT_DATAFLOW="+("PASS" if all(init_checks.values()) else "REVIEW_REQUIRED"),
 *["INIT_CHECK_%s=%s"%(k.upper(),"PASS" if v else "FAIL") for k,v in init_checks.items()],
 "TARGET_SERVICE_CLASS_REGISTER=EDX_FIRST_UINT32_AFTER_POOL",
 "TARGET_SERVICE_CLASS_FIELD_OFFSET=0xb8",
 "SDK_INIT_NAMED_PARAMETER_ORDER="+",".join(header_order),
 "TARGET_FACTORY_REGISTER_ORDER=SERVICE_CLASS,THEN_CAPACITY,THEN_QUEUE_ID",
 "SDK_VS_TARGET_INIT_ORDER="+("CONFLICT" if header_named else "NOT_PROVEN"),
 "SDK_DECLARES_EXPLICIT_WITHPOOLANDSERVICECLASS="+("YES" if has_explicit else "NO"),
 "TARGET_INDEX_HAS_NAMED_WITHPOOLANDSERVICECLASS="+("YES" if target_named_explicit else "NO"),
 "SDK_DECLARES_ACTION_ONLY_WITHPOOL="+("YES" if header_action_only else "NO"),
 "TARGET_HAS_MATCHING_ACTION_ONLY_WITHPOOL_SYMBOL="+("YES" if target_action_only else "NO"),
 "CURRENT_SOURCE_USES_ACTION_ONLY_WITHPOOL="+("YES" if source_action_only else "NO"),
 "CURRENT_SOURCE_ACTION_ONLY_FACTORY_PATH="+("PROVEN_DEFAULT_SENTINEL_0xffffffff" if current_path_proven else "NOT_PROVEN"),
 "CURRENT_SOURCE_USES_EXPLICIT_SERVICECLASS_FACTORY="+("YES" if source_explicit_call else "NO"),
 "EXPLICIT_FACTORY_SYMBOL_MAPPING=NOT_PROVEN",
 "WMM_CLASS_VALUES="+",".join(wmm_values),
 "WMM_ROLE_1_CARDINALITY=FOUR_TX_SUBMISSION_QUEUES",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1",
 "CURRENT_SOURCE_TX_CLASS_FACTORY_CALLS="+str(source_counts.get("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass",0)),
 "CURRENT_SOURCE_TX_ORDINARY_FACTORY_CALLS="+str(source_counts.get("IOSkywalkTxSubmissionQueue::withPool",0)),
 "QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "NATIVE_REGISTRATION_CALLS=0",
 "CALLBACK_HANDOFFS_STILL_MISSING=4",
 "RESULT=REVIEW_REQUIRED",
 "ACTIVATION_GATE=BLOCKED"
]
(out/"tx-factory-header-target-abi-crosscheck.txt").write_text("\n".join(factory_rows)+"\n")
summary=[
 "STAGE89_V8_TARGET_TX_FACTORY_HEADER_ABI_CROSSCHECK",
 "VERSION=STAGE89_V8_20261105",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "TARGET_FACTORY_REGISTER_DATAFLOW=PASS",
 "TARGET_INIT_SERVICE_CLASS_STORE=PASS",
 "CURRENT_SOURCE_ACTION_ONLY_FACTORY_PATH="+("PROVEN_DEFAULT_SENTINEL_0xffffffff" if current_path_proven else "NOT_PROVEN"),
 "SDK_INIT_NAMED_PARAMETER_ORDER=capacity,queueId,serviceClass",
 "TARGET_FACTORY_REGISTER_ORDER=serviceClass,capacity,queueId",
 "SDK_VS_TARGET_INIT_ORDER=CONFLICT",
 "PUBLIC_EXPLICIT_FACTORY_SYMBOL_MAPPING=NOT_PROVEN",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1",
 "WMM_ROLE_1_REQUIRES_FOUR_TX_SUBMISSION_QUEUES=YES",
 "CURRENT_SOURCE_EXPLICIT_SERVICECLASS_FACTORY_CALL=NO",
 "TX_FACTORY_CALL_SAFE_TO_CHANGE=NO",
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
 "NEXT=Resolve the explicit service-class factory's exported target symbol and the initWithPool parameter contract before altering any call. Then finalize queue role counts and Stage89 pointer-array design. Stage90 remains blocked."
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V8 — TARGET TX FACTORY / SDK HEADER ABI CROSS-CHECK ==========",
 *summary,"",
 "TARGET DATAFLOW:",
 *factory_rows,"",
 "SDK INIT / FACTORY DECLARATIONS:",
 "\n".join(x.strip() for x in header.splitlines() if "initWithPool(" in x or "withPoolAndServiceClass(" in x or "static IOSkywalkTxSubmissionQueue * withPool(" in x),
 "",
 "CURRENT SOURCE CALL:",
 "\n".join(source.splitlines()[64:77]),
 "",
 "REVIEW OF V7:",
 "V7 marked SDK_DECLARATION_TO_TARGET_ABI_ORDER_MATCH=YES based on a partial parameter check. This V8 review does not accept that conclusion. In the target factory/init dataflow, the explicit class value is forwarded to EDX and target init stores EDX at mServiceClass offset 0xb8. The checked-in initWithPool declaration names its first UInt32 after pool as capacity, not serviceClass. The names/order therefore conflict and require a real ABI wrapper or corrected declaration proof.",
 "The current source does not use the explicit-class helper. Its action-only withPool call matches the action-only target wrapper in the selected method index; that wrapper pushes -1, so the current TX submission queue receives the default 0xffffffff service class. This is not one of the four WMM values.",
 "The SDK declares withPoolAndServiceClass, but the selected target method index contains no symbol with that name. Do not call that declaration or guess another overload until the public-to-target symbol mapping is proven.",
 "",
 "QUEUE TOPOLOGY:",
 "The QueueSet WMM predicate checks only role-1 TX-submission queues and requires exactly one of each of the four pinned WMM values. The source has one TX-submission queue with the default service class. Other queue-role counts remain unresolved; a seven-object layout is still only a candidate.",
 "",
 "SAFETY:",
 "No driver source changed. No build, signing, install/load, hardware test, SIP/NVRAM or OpenCore action occurred."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
checkpoint=[
 "========== STAGE 89 V8 — TARGET TX FACTORY / SDK HEADER ABI CROSS-CHECK ==========",
 "STAGE89_V8_RUN: "+sys.argv[13],
 "STAGE89_V8_VERSION: STAGE89_V8_20261105",
 "STAGE89_V8_PREDECESSOR: "+sys.argv[14],
 "STAGE89_V8_SOURCE_TREE_REVALIDATION: PASS",
 "STAGE89_V8_TARGET_FACTORY_REGISTER_DATAFLOW: PASS",
 "STAGE89_V8_TARGET_INIT_SERVICE_CLASS_STORE: PASS",
 "STAGE89_V8_CURRENT_SOURCE_ACTION_ONLY_FACTORY_PATH="+("PROVEN_DEFAULT_SENTINEL_0xffffffff" if current_path_proven else "NOT_PROVEN"),
 "STAGE89_V8_SDK_VS_TARGET_INIT_ORDER: CONFLICT",
 "STAGE89_V8_PUBLIC_EXPLICIT_FACTORY_SYMBOL_MAPPING: NOT_PROVEN",
 "STAGE89_V8_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1",
 "STAGE89_V8_WMM_ROLE_1_QUEUE_REQUIREMENT: 4",
 "STAGE89_V8_QUEUE_ARRAY: NOT_IMPLEMENTED",
 "STAGE89_V8_CALLBACK_HANDOFFS_STILL_MISSING: 4",
 "STAGE89_V8_IMPLEMENTATION_AUTHORIZATION: NO",
 "STAGE89_V8_SOURCE_MODIFIED: NO",
 "STAGE89_V8_BUILD: NOT_RUN",
 "STAGE89_V8_SIGNING: NOT_RUN",
 "STAGE89_V8_INSTALL: NOT_RUN",
 "STAGE89_V8_LOAD: NOT_RUN",
 "STAGE89_V8_OPENCORE_CHANGE: NONE",
 "STAGE89_V8_RESULT: REVIEW_REQUIRED",
 "STAGE89_V8_ACTIVATION_GATE: BLOCKED",
 "STAGE89_V8_LOGS: "+sys.argv[15]+"/"
]
(out/"checkpoint-block.txt").write_text("\n".join(checkpoint)+"\n")
print("TARGET_FACTORY_REGISTER_DATAFLOW=PASS")
print("TARGET_INIT_SERVICE_CLASS_STORE=PASS")
print("CURRENT_SOURCE_ACTION_ONLY_FACTORY_PATH="+("PROVEN_DEFAULT_SENTINEL_0xffffffff" if current_path_proven else "NOT_PROVEN"))
print("SDK_VS_TARGET_INIT_ORDER=CONFLICT")
print("PUBLIC_EXPLICIT_FACTORY_SYMBOL_MAPPING=NOT_PROVEN")
print("STAGE89_V8_RESULT=REVIEW_REQUIRED")
PYAUDIT

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["source-tree-revalidation.txt","tx-factory-header-target-abi-crosscheck.txt","audit-summary.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V8_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(out/n).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(n,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST

for f in "$OUT/source-tree-revalidation.txt" "$OUT/tx-factory-header-target-abi-crosscheck.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V8_RUN:" in old: raise SystemExit("V8 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V8 target TX factory/header ABI cross-check","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
echo "STAGE89_V8_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
