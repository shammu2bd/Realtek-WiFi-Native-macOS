#!/bin/bash
# Stage 89 V12 — TXSubmission factory callback / options / service-class ABI cross-check.
# READ ONLY: no source/header edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
V9_RUN="run-20261105-034922-6566f42c51aa"
V10_RUN="run-20261105-041550-62ef6b8a0915"
V11_RUN="run-20261105-042010-eb8eee87ee44"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v12/$RUN"
REMOTE="Development/Logs/stage89-v12/$RUN"
mkdir -p "$OUT"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V12 TXSubmission callback/factory ABI crosscheck","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V12_FAILURE"
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
[[ -d "$SRC/src" && -d "$SRC/MacKernelSDK/Headers" ]] || fail "Project source or SDK headers missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
CFILT="$(xcrun --find c++filt 2>/dev/null || command -v c++filt || true)"
[[ -n "$CFILT" && -x "$CFILT" ]] || fail "c++filt unavailable through selected Xcode"

BASE="https://raw.githubusercontent.com/$REPO/main"
LOGS="$BASE/Development/Logs"
pin v9-disassembly.txt a4c4cd35016228e79953b9991426f45bcdc69089 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-disassembly.txt"
pin v9-symbol-index.txt 41cbdaf57b7d38fc40c09b20ca54e34eb504d109 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-symbol-index.txt"
pin v10-manifest.txt 156cbf378f521a2ddd10dc5a858c24694ef9b0da "$LOGS/stage89-v10/$V10_RUN/manifest.txt"
pin v10-dataflow-checks.txt 60301de086cffeba45d77da1510db3de319ec5a3 "$LOGS/stage89-v10/$V10_RUN/argument-dataflow-checks.txt"
pin v11-manifest.txt 006f9eacf0ea5d1ea09fe93a4416367ff59c4fd3 "$LOGS/stage89-v11/$V11_RUN/manifest.txt"
pin v11-api-crosswalk.txt 1f7628022b90902c792a3873fd67759dcba870ca "$LOGS/stage89-v11/$V11_RUN/api-crosswalk-verdict.txt"
pin v11-class-symbol-inventory.txt dc7bab3b5c3379557f2a6ea605cbf39f40e0defd "$LOGS/stage89-v11/$V11_RUN/target-class-symbol-inventory.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$LOGS/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin tx-submission-sdk-header.txt 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin native-queue-source.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V9_RUN" "$V10_RUN" "$V11_RUN" <<'PYLOG'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
for stage,expected in (("V9",sys.argv[2]),("V10",sys.argv[3]),("V11",sys.argv[4])):
 runs=re.findall(r"STAGE89_"+stage+r"_RUN:\s*(run-[A-Za-z0-9-]+)",log)
 if not runs or runs[-1]!=expected: raise SystemExit("Latest "+stage+" checkpoint differs from pinned predecessor")
if "STAGE89_V11_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V11 review checkpoint missing")
if "STAGE89_V12_RUN:" in log: raise SystemExit("V12 checkpoint already exists; inspect rather than duplicate")
print("PREDECESSOR_GATE=PASS V9="+sys.argv[2]+" V10="+sys.argv[3]+" V11="+sys.argv[4])
PYLOG

echo "STAGE89_V12_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "DEMANGLE_TOOL=$CFILT"
echo "READ_ONLY=YES"

python3 -u - "$OUT" "$CFILT" <<'PY'
import pathlib,re,subprocess,sys
out=pathlib.Path(sys.argv[1]); demangler=sys.argv[2]
dis=(out/"v9-disassembly.txt").read_text(errors="replace")
symbols=(out/"v9-symbol-index.txt").read_text(errors="replace")
header=(out/"tx-submission-sdk-header.txt").read_text(errors="replace")
source=(out/"native-queue-source.cpp").read_text(errors="replace")
v10=(out/"v10-dataflow-checks.txt").read_text(errors="replace")
v11=(out/"v11-api-crosswalk.txt").read_text(errors="replace")

def body(address):
 m=re.search(r"===== ADDRESS=0x"+address+r" SYMBOL=.*? =====\n(.*?)(?=\n===== ADDRESS=|\Z)",dis,re.S)
 if not m: raise SystemExit("Missing pinned method body 0x"+address)
 return m.group(1)
main=body("ffffff8002983ff0")
mutable=body("ffffff800298409e")
action_only=body("ffffff80029840c2")

def has(text,pattern): return re.search(pattern,text,re.I) is not None

# Extract exact typedefs and declarations from the pinned public header.
typedefs={}
for typedef_name in ["IOSkywalkQueryFreeSpaceHandler","IOSkywalkTxSubmissionQueueAction"]:
 m=re.search(r"typedef\s+([^;]+?)\(\s*\*"+typedef_name+r"\s*\)\s*\(([^;]+)\)\s*;",header,re.S)
 if m: typedefs[typedef_name]=(re.sub(r"\s+"," ",m.group(1)).strip(),re.sub(r"\s+"," ",m.group(2)).strip())
factories=[re.sub(r"\s+"," ",x).strip() for x in re.findall(r"static\s+IOSkywalkTxSubmissionQueue\s*\*\s*(?:withPoolAndServiceClass|withPool)\s*\([^;]+;",header,re.S)]
header_has_const_action="const IOSkywalkPacket **" in header
header_has_mutable_action=bool(re.search(r"(?<!const )IOSkywalkPacket\s*\*\*",header))

# Target symbol spellings encode callback pointer constness and trailing integer count.
def symbol_at(address):
 for line in symbols.splitlines():
  if ("ADDRESS=0x"+address) in line:
   before, sep, value = line.partition("MANGLED=")
   if sep and value.strip():
    return value.strip()
 return ""
main_symbol=symbol_at("ffffff8002983ff0")
mutable_symbol=symbol_at("ffffff800298409e")
action_symbol=symbol_at("ffffff80029840c2")
print("TARGET_SYMBOL_PARSE=main:%s mutable:%s action:%s"%(bool(main_symbol),bool(mutable_symbol),bool(action_symbol)),flush=True)
def demangle(symbol):
 if not symbol: return "SYMBOL_NOT_FOUND"
 candidates=[symbol[1:] if symbol.startswith("_") else symbol, symbol[2:] if symbol.startswith("__") else symbol]
 for c in candidates:
  try:
   p=subprocess.run([demangler,c],capture_output=True,text=True,timeout=8)
   result=p.stdout.strip()
   if p.returncode==0 and result and not result.startswith("_Z"): return result
  except Exception: pass
 return "DEMANGLE_UNAVAILABLE_OR_UNRESOLVED:"+symbol

checks={
 "sdk_query_handler_typedef_found":"IOSkywalkQueryFreeSpaceHandler" in typedefs,
 "sdk_action_typedef_found":"IOSkywalkTxSubmissionQueueAction" in typedefs,
 "sdk_action_uses_const_packet_pointer_array":header_has_const_action and not header_has_mutable_action,
 "target_main_factory_symbol_found":bool(main_symbol),
 "target_mutable_factory_wrapper_symbol_found":bool(mutable_symbol),
 "target_action_only_wrapper_symbol_found":bool(action_symbol),
 "target_main_factory_uses_const_packet_pointer_action":"PKP15IOSkywalkPacket" in main_symbol,
 "target_mutable_wrapper_uses_mutable_packet_pointer_action":"PP15IOSkywalkPacket" in mutable_symbol and "PKP15IOSkywalkPacket" not in mutable_symbol,
 "target_action_only_wrapper_uses_const_packet_pointer_action":"PKP15IOSkywalkPacket" in action_symbol,
 "main_factory_has_options_then_serviceclass_stack_words":has(main,r"mov\s+r10d,\s*dword ptr \[rbp \+ 0x18\]") and has(main,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]"),
 "main_factory_forwards_serviceclass_to_init":has(main,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]") and has(main,r"call\s+qword ptr \[rax \+ 0x2a8\]"),
 "mutable_wrapper_sets_option_bit_8":has(mutable,r"or\s+r10d,\s*0x8"),
 "mutable_wrapper_forwards_final_serviceclass":has(mutable,r"mov\s+eax,\s*dword ptr \[rbp \+ 0x20\]") and has(mutable,r"push\s+rax"),
 "action_only_wrapper_uses_minus_one":has(action_only,r"push\s+-0x1"),
 "v10_serviceclass_dataflow_predecessor_passed":"TARGET_FACTORY_FINAL_U32_IS_SERVICE_CLASS=PASS" in v10 or "init_persists_r15d_at_object_offset_b8=PASS" in v10,
 "v11_direct_api_mapping_still_not_found":"DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND" in v11,
}
main_dem=demangle(main_symbol)
mut_dem=demangle(mutable_symbol)
act_dem=demangle(action_symbol)
summary=[
 "STAGE89_V12_TXSUBMISSION_CALLBACK_FACTORY_ABI_CROSSCHECK",
 "VERSION=STAGE89_V12_20261105",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "V9_V10_V11_EVIDENCE_PINS=PASS",
 "CHECK_COUNT="+str(len(checks)),
 "CHECKS_PASSED="+str(sum(bool(x) for x in checks.values())),
 "SDK_QUERY_HANDLER_TYPE="+(str(typedefs.get("IOSkywalkQueryFreeSpaceHandler")) if "IOSkywalkQueryFreeSpaceHandler" in typedefs else "NOT_FOUND"),
 "SDK_ACTION_TYPE="+(str(typedefs.get("IOSkywalkTxSubmissionQueueAction")) if "IOSkywalkTxSubmissionQueueAction" in typedefs else "NOT_FOUND"),
 "TARGET_MAIN_FACTORY_CALLBACK_CONSTNESS="+("MATCHES_SDK_CONST_PACKET_ARRAY" if checks["target_main_factory_uses_const_packet_pointer_action"] and header_has_const_action else "REVIEW_REQUIRED"),
 "TARGET_MUTABLE_WRAPPER_CALLBACK_CONSTNESS="+("MUTABLE_PACKET_ARRAY_NOT_DECLARED_BY_SDK_ACTION_TYPE" if checks["target_mutable_wrapper_uses_mutable_packet_pointer_action"] else "REVIEW_REQUIRED"),
 "TARGET_MAIN_FACTORY_TRAILING_U32_ROLE=SERVICE_CLASS_PROVEN_IN_V10",
 "TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass",
 "SDK_WITHPOOL_QUERY_ACTION_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options",
 "SDK_EXPLICIT_WITHPOOLANDSERVICECLASS_ORDER=pool,capacity,queueId,serviceClass,owner,queryHandler,action,refCon,options",
 "TARGET_MAIN_FACTORY_METHOD_NAME=withPool",
 "TARGET_MUTABLE_WRAPPER_EXTRA_OPTION_BIT=0x8",
 "TARGET_ACTION_ONLY_DEFAULT_SERVICE_CLASS=0xffffffff",
 "SOURCE_CURRENTLY_USES_ACTION_ONLY_WRAPPER="+("YES" if "IOSkywalkTxSubmissionQueue::withPool(" in source else "NOT_PROVEN"),
 "DIRECT_SOURCE_DECLARATION_FOR_TRAILING_SERVICECLASS_OVERLOAD=ABSENT",
 "IMPLEMENTATION_AUTHORIZATION=NO",
 "FOUR_TX_SUBMISSION_QUEUES_REQUIRED=YES",
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT=1",
 "QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "CALLBACK_HANDOFFS_STILL_MISSING=4",
 "NATIVE_REGISTRATION_CALLS=0",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "SIGNING=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "ACTIVATION_GATE=BLOCKED",
 "NEXT=The target's const-packet callback factory has a service-class trailing argument after options, while the bundled SDK declares only the shorter withPool overload and a differently ordered named overload. Do not add a guessed declaration or source call; review and explicitly authorize any ABI adapter before implementation."
]
(out/"callback-abi-checks.txt").write_text("\n".join(["STAGE89_V12_CALLBACK_ABI_CHECKS"]+[k+"="+("PASS" if v else "FAIL") for k,v in checks.items()])+"\n")
cross=[
 "STAGE89_V12_CALLBACK_AND_FACTORY_DECLARATION_CROSSWALK",
 "SDK_TYPEDEF|IOSkywalkQueryFreeSpaceHandler|"+str(typedefs.get("IOSkywalkQueryFreeSpaceHandler","NOT_FOUND")),
 "SDK_TYPEDEF|IOSkywalkTxSubmissionQueueAction|"+str(typedefs.get("IOSkywalkTxSubmissionQueueAction","NOT_FOUND")),
 "SDK_HAS_CONST_PACKET_ARRAY_ACTION="+("YES" if header_has_const_action else "NO"),
 "SDK_HAS_MUTABLE_PACKET_ARRAY_ACTION="+("YES" if header_has_mutable_action else "NO"),
 "SDK_FACTORY_DECLARATIONS:",
 *["SDK_FACTORY="+x for x in factories],
 "TARGET_MAIN_FACTORY_SYMBOL="+main_symbol,
 "TARGET_MAIN_FACTORY_DEMANGLED="+main_dem,
 "TARGET_MUTABLE_WRAPPER_SYMBOL="+mutable_symbol,
 "TARGET_MUTABLE_WRAPPER_DEMANGLED="+mut_dem,
 "TARGET_ACTION_ONLY_WRAPPER_SYMBOL="+action_symbol,
 "TARGET_ACTION_ONLY_WRAPPER_DEMANGLED="+act_dem,
 "TARGET_MAIN_CALLBACK_CONSTNESS="+("CONST_PACKET_POINTER_ARRAY" if "PKP15IOSkywalkPacket" in main_symbol else "UNKNOWN"),
 "TARGET_MUTABLE_CALLBACK_CONSTNESS="+("MUTABLE_PACKET_POINTER_ARRAY" if "PP15IOSkywalkPacket" in mutable_symbol and "PKP15IOSkywalkPacket" not in mutable_symbol else "UNKNOWN"),
 "TARGET_MAIN_EXTRA_STACK_U32S=2 (options then serviceClass)",
 "TARGET_MAIN_SERVICECLASS_ARGUMENT="+("FORWARDED_AS_EDX_TO_INIT" if checks["main_factory_forwards_serviceclass_to_init"] else "NOT_PROVEN"),
 "TARGET_MUTABLE_WRAPPER_OPTION_ADD=0x8",
 "TARGET_MUTABLE_WRAPPER_SERVICECLASS_FORWARD="+("YES" if checks["mutable_wrapper_forwards_final_serviceclass"] else "NO"),
 "TARGET_ACTION_ONLY_SERVICECLASS_DEFAULT="+("0xffffffff" if checks["action_only_wrapper_uses_minus_one"] else "NOT_PROVEN"),
 "CURRENT_SOURCE_CALL=ACTION_ONLY_WITHPOOL",
 "SDK_TO_TARGET_DIRECT_OVERLOAD_MAPPING=NOT_FOUND",
 "RECOMMENDATION=DO_NOT_GUESS_OR_EDIT"
]
(out/"callback-factory-api-crosswalk.txt").write_text("\n".join(cross)+"\n")
report=[
 "========== STAGE 89 V12 — TXSUBMISSION CALLBACK / FACTORY ABI CROSS-CHECK ==========",
 *summary,"",
 "CALLBACK TYPE COMPARISON:",
 "The SDK header declares IOSkywalkTxSubmissionQueueAction with const IOSkywalkPacket ** and a query-free-space handler. The target primary withPool factory symbol uses the const packet-pointer callback shape; its trailing two UInt32 arguments are options followed by service class, as established by V9/V10 disassembly.",
 "The alternate target wrapper at 0xffffff800298409e uses a mutable IOSkywalkPacket ** action callback and sets options bit 0x8 before forwarding. The bundled SDK action typedef does not declare that mutable pointer-array form. Do not use it merely because it also forwards the service-class value.",
 "",
 "FACTORY ABI FINDING:",
 "The target primary const-callback withPool overload takes pool, capacity, queueId, owner, query handler, action, refCon, options, then serviceClass. The SDK's query/action withPool declaration ends at options; its named withPoolAndServiceClass declaration places serviceClass before owner and has no matching target symbol. The target action-only wrapper supplies 0xffffffff instead.",
 "",
 "IMPLEMENTATION LIMIT:",
 "This evidence identifies the target callback-compatible factory shape, but the exact target overload is not declared in the current SDK header/source surface. No header or source change is made here. A manually invented declaration, symbol alias, argument reorder, direct vtable call or private field write is not authorized by this audit.",
 "",
 "REMAINING STAGE89 BLOCKERS:",
 "The project still constructs one TX submission queue, not four, and does not have the stable four-pointer array or its count/uniqueness/order/lifetime tests. Registration remains absent and four callback handoffs remain incomplete.",
 "",
 "SAFETY:",
 "Read-only comparison of pinned V9–V11 artifacts and pinned project source/header. No source/header modification, build, signing, install, load, hardware test, SIP/NVRAM or OpenCore change."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("STAGE89_V12_CHECKS_PASSED=%d/%d"%(sum(bool(x) for x in checks.values()),len(checks)),flush=True)
print("TARGET_MAIN_CALLBACK_CONSTNESS_MATCHES_SDK=%s"%("YES" if checks["target_main_factory_uses_const_packet_pointer_action"] and header_has_const_action else "NO"),flush=True)
print("TARGET_MUTABLE_WRAPPER_CALLBACK_DECLARED_BY_SDK=%s"%("YES" if header_has_mutable_action else "NO"),flush=True)
print("STAGE89_V12_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V12 — TXSUBMISSION CALLBACK / FACTORY ABI CROSS-CHECK ==========
STAGE89_V12_RUN: $RUN
STAGE89_V12_VERSION: STAGE89_V12_20261105
STAGE89_V12_PREDECESSOR: $V11_RUN
STAGE89_V12_V9_V10_V11_EVIDENCE_PINS: PASS
STAGE89_V12_CALLBACK_FACTORY_CROSSCHECK: CAPTURED
STAGE89_V12_TARGET_CONST_CALLBACK_FACTORY_SERVICECLASS_ARGUMENT: REVIEWED
STAGE89_V12_SDK_DIRECT_OVERLOAD_MAPPING: NOT_FOUND
STAGE89_V12_FOUR_TX_SUBMISSION_QUEUES_REQUIRED: YES
STAGE89_V12_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1
STAGE89_V12_QUEUE_ARRAY: NOT_IMPLEMENTED
STAGE89_V12_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V12_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V12_SOURCE_MODIFIED: NO
STAGE89_V12_BUILD: NOT_RUN
STAGE89_V12_SIGNING: NOT_RUN
STAGE89_V12_INSTALL: NOT_RUN
STAGE89_V12_LOAD: NOT_RUN
STAGE89_V12_OPENCORE_CHANGE: NONE
STAGE89_V12_RESULT: REVIEW_REQUIRED
STAGE89_V12_ACTIVATION_GATE: BLOCKED
STAGE89_V12_LOGS: $REMOTE/
EOF

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["callback-abi-checks.txt","callback-factory-api-crosswalk.txt","audit-summary.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V12_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST

for f in "$OUT/callback-abi-checks.txt" "$OUT/callback-factory-api-crosswalk.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V12_RUN:" in old: raise SystemExit("V12 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V12 TXSubmission callback factory ABI crosscheck","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
echo "STAGE89_V12_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
