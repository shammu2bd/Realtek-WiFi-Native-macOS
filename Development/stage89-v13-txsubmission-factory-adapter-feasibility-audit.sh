#!/bin/bash
# Stage89 V13 — TX submission factory adapter feasibility audit.
# READ ONLY: no source/header edits, build, signing, install/load, hardware test, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v13/$RUN"
REMOTE="Development/Logs/stage89-v13/$RUN"
V12_RUN="run-20261105-043238-9923f409a010"
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
 local n="$1" sha="$2" url="$3" actual
 curl -fsSLo "$OUT/$n" "$url"
 actual="$(blob "$OUT/$n")"
 [[ "$actual" == "$sha" ]] || fail "Pinned artifact mismatch: $n expected=$sha actual=$actual"
 echo "PIN_VERIFIED=$n SHA=$actual"
}
upload(){
 local f="$1" dest="$2" payload="$OUT/payload.json" want got attempt
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PYUPLOAD'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V13 TX factory adapter feasibility audit","content":base64.b64encode(p.read_bytes()).decode()}))
PYUPLOAD
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$dest" -q .sha 2>/dev/null || true)"
  [[ "$got" == "$want" ]] && { echo "UPLOAD_VERIFIED=$dest SHA=$got"; return 0; }
  gh api --method PUT "repos/$REPO/contents/$dest" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt" || true
  got="$(gh api "repos/$REPO/contents/$dest" -q .sha 2>/dev/null || true)"
  [[ "$got" == "$want" ]] && { echo "UPLOAD_VERIFIED=$dest ATTEMPT=$attempt SHA=$got"; return 0; }
  sleep 2
 done
 echo "UPLOAD_FAILED=$dest EXPECTED=$want ACTUAL=$got" >&2
 return 1
}
on_exit(){
 local rc=$?
 if [[ $rc -ne 0 ]]; then
  {
   echo "STAGE89_V13_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 100 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  gh auth status >/dev/null 2>&1 && upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true
 fi
}
trap on_exit EXIT
for t in curl gh python3 sw_vers uname tee date tail; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "Expected project source tree missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be Sequoia 15.8.1 (24H32) x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main"
LOGS="$BASE/Development/Logs"
pin v12-crosswalk.txt 5c1afc5bd220a8da52e9dc9d6bfed6b7b8da6831 "$LOGS/stage89-v12/$V12_RUN/callback-factory-api-crosswalk.txt"
pin v12-checks.txt 2862e6afedb4675de0484065d0cded7b15b10625 "$LOGS/stage89-v12/$V12_RUN/callback-abi-checks.txt"
pin v12-summary.txt cfbfb24f1ef06870f9ab20e49889ffc816a2a1be "$LOGS/stage89-v12/$V12_RUN/audit-summary.txt"
pin sdk-header.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin source.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/preflight.json"
python3 - "$OUT/preflight.json" "$V12_RUN" <<'PREFLIGHT'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
matches=re.findall(r"STAGE89_V12_RUN:\s*(run-[A-Za-z0-9-]+)",log)
if not matches or matches[-1]!=sys.argv[2]:
 raise SystemExit("Latest V12 checkpoint does not match pinned predecessor")
if "STAGE89_V13_RUN:" in log:
 raise SystemExit("V13 checkpoint already exists; inspect it instead of duplicating")
print("PREDECESSOR_GATE=PASS")
PREFLIGHT
echo "STAGE89_V13_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V13_FACTORY_ADAPTER_FEASIBILITY"
echo "READ_ONLY=YES"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
python3 -u - "$OUT" <<'PY'
import pathlib,re,sys,hashlib
out=pathlib.Path(sys.argv[1])
cross=(out/"v12-crosswalk.txt").read_text(errors="replace")
checks=(out/"v12-checks.txt").read_text(errors="replace")
summary=(out/"v12-summary.txt").read_text(errors="replace")
header=(out/"sdk-header.h").read_text(errors="replace")
source=(out/"source.cpp").read_text(errors="replace")
checks_map={}
def add(k,v): checks_map[k]=bool(v)
add("v12_predecessor_direct_sdk_mapping_not_found","SDK_TO_TARGET_DIRECT_OVERLOAD_MAPPING=NOT_FOUND" in cross)
add("v12_target_main_factory_has_trailing_service_class","TARGET_MAIN_EXTRA_STACK_U32S=2 (options then serviceClass)" in cross and "TARGET_MAIN_SERVICECLASS_ARGUMENT=FORWARDED_AS_EDX_TO_INIT" in cross)
add("sdk_withpool_query_action_declared",bool(re.search(r"withPool\s*\([^;]*IOSkywalkQueryFreeSpaceHandler[^;]*IOSkywalkTxSubmissionQueueAction[^;]*IOOptionBits\s+options",header,re.S)))
add("sdk_withpool_action_only_declared",bool(re.search(r"withPool\s*\([^;]*IOSkywalkTxSubmissionQueueAction[^;]*IOOptionBits\s+options",header,re.S)))
add("sdk_named_serviceclass_factory_declared","withPoolAndServiceClass" in header)
add("sdk_query_action_factory_order_places_serviceclass_before_owner",bool(re.search(r"withPoolAndServiceClass\s*\(\s*IOSkywalkPacketBufferPool\s*\*\s*pool\s*,\s*UInt32\s+capacity\s*,\s*UInt32\s+queueId\s*,\s*kern_packet_svc_class_t\s+serviceClass\s*,\s*OSObject\s*\*\s*owner",header,re.S)))
add("target_primary_factory_order_places_owner_before_handlers","TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in cross)
add("current_source_uses_action_only_factory",bool(re.search(r"IOSkywalkTxSubmissionQueue::withPool\s*\(\s*_txPool\s*,\s*kQueueCapacity\s*,\s*0\s*,\s*this\s*,\s*&RTW88WCLSkywalkQueues::txSubmissionAction",source,re.S)))
add("current_source_does_not_call_named_serviceclass_factory","withPoolAndServiceClass" not in source)
add("current_source_does_not_directly_call_private_factory_symbol","0xffffff8002983ff0" not in source and "withPoolServiceClassAdapter" not in source)
add("no_verified_serviceclass_setter_in_sdk_surface",not bool(re.search(r"(setServiceClass|set.*ServiceClass)\s*\(",header,re.I)))
add("v12_source_was_readonly_and_unbuilt","SOURCE_MODIFIED=NO" in summary and "BUILD=NOT_RUN" in summary and "INSTALL=NOT_RUN" in summary and "LOAD=NOT_RUN" in summary)
add("source_has_single_tx_submission_member",source.count("_txSubmission")>=4 and "IOSkywalkTxSubmissionQueue::withPool(" in source)
passed=sum(checks_map.values())
(out/"adapter-feasibility-checks.txt").write_text(
 "STAGE89_V13_ADAPTER_FEASIBILITY_CHECKS\n"+
 "\n".join(k+"="+("PASS" if v else "FAIL") for k,v in checks_map.items())+
 "\nCHECK_COUNT="+str(len(checks_map))+"\nCHECKS_PASSED="+str(passed)+"\n")
verdict=[
 "STAGE89_V13_TXSUBMISSION_FACTORY_ADAPTER_FEASIBILITY",
 "SDK_DECLARATIONS=PUBLIC_WITHPOOL_QUERY_ACTION_AND_ACTION_ONLY; PUBLIC_WITHPOOLANDSERVICECLASS",
 "TARGET_PRIMARY_FACTORY=WITHPOOL_QUERY_ACTION_PLUS_TRAILING_OPTIONS_AND_SERVICECLASS",
 "ABI_ORDER_CONFLICT=SDK_NAMED_SERVICECLASS_OVERLOAD_PLACES_SERVICECLASS_BEFORE_OWNER; TARGET_PRIMARY_FACTORY_PLACES_SERVICECLASS_AFTER_OPTIONS",
 "SYMBOL_MAPPING=NO_DIRECT_SDK_DECLARATION_TO_TARGET_PRIMARY_FACTORY_MAPPING",
 "CURRENT_SOURCE_PATH=ACTION_ONLY_WITHPOOL; TARGET_DEFAULT_SERVICE_CLASS=0xffffffff",
 "SAFE_EXISTING_SDK_ADAPTER=NOT_ESTABLISHED",
 "REINTERPRETING_SDK_WITHPOOL_AS_PRIVATE_TARGET_SIGNATURE=UNSAFE_UNPROVEN",
 "CALLING_PRIVATE_MANGLED_SYMBOL_OR_GUESSED_OVERLOAD=REJECTED",
 "WRITING_PRIVATE_QUEUE_SERVICECLASS_FIELD=REJECTED",
 "MUTABLE_CALLBACK_WRAPPER=NOT_A_PUBLIC_SDK_MATCH",
 "ADAPTER_FEASIBILITY=BLOCKED_PENDING_SEPARATE_ABI_REVIEW_AND_IMPLEMENTATION_AUTHORIZATION",
 "RECOMMENDED_NEXT=REVIEW_EXACT_TARGET_FACTORY_CALLING_CONVENTION_AND_ANY_PUBLIC_SYMBOL_THUNK; OTHERWISE REQUIRE A SEPARATELY AUTHORIZED HEADER/ABI ADAPTER CHANGE",
 "NO_SOURCE_OR_HEADER_MODIFICATION=YES",
 "NO_BUILD_SIGN_INSTALL_LOAD_OR_OPENCORE_CHANGE=YES"
]
(out/"adapter-feasibility-verdict.txt").write_text("\n".join(verdict)+"\n")
report=[
 "========== STAGE 89 V13 — TX SUBMISSION FACTORY ADAPTER FEASIBILITY ==========",
 "RUN="+out.name,
 "TARGET=macOS Sequoia 15.8.1 (24H32), x86_64, Intel Hackintosh, PCIe RTL8821CE",
 "SCOPE=Read-only assessment of whether the audited target TX submission factory can be called safely through the existing SDK declarations.",
 "CHECK_COUNT="+str(len(checks_map)),
 "CHECKS_PASSED="+str(passed),
 "",
 "FINDINGS:",
 "1. The SDK exposes a query-handler/action withPool overload whose declared argument list ends with options, and a named withPoolAndServiceClass overload that places serviceClass before owner.",
 "2. The target primary factory evidence from V12 has the order pool, capacity, queueId, owner, queryHandler, action, refCon, options, serviceClass. This is not the same C++ declaration/mangled overload as either SDK declaration.",
 "3. The existing source calls the action-only SDK withPool overload. The audited target action-only wrapper supplies service class 0xffffffff, which does not satisfy the four WMM class requirement.",
 "4. The alternate mutable-packet callback wrapper is not declared by the SDK action typedef. Its option-bit behavior does not make it a safe substitute.",
 "5. No source-level adapter using only the existing SDK declarations is established by the pinned evidence. A cast, guessed private declaration, raw mangled-symbol call or private field write is not accepted as a safe adapter.",
 "",
 "DECISION:",
 "ADAPTER_FEASIBILITY=BLOCKED_PENDING_SEPARATE_ABI_REVIEW_AND_IMPLEMENTATION_AUTHORIZATION",
 "This is not permission to edit the SDK header or driver source. A follow-up must either prove an existing public thunk with exact symbol/calling convention or obtain explicit authorization for a separately reviewed ABI adapter.",
 "",
 "STAGE89 REMAINS OPEN:",
 "Four distinct TX submission queues, one per audited WMM class, and a stable ordered four-pointer array with count/uniqueness/order/lifetime tests are still absent. Native registration remains absent. Four callback handoffs remain incomplete. Stage90 is not unlocked.",
 "",
 "SAFETY:",
 "Source/header modification=NONE; build=NOT_RUN; signing=NOT_RUN; install=NOT_RUN; load=NOT_RUN; hardware test=NOT_RUN; OpenCore/SIP/NVRAM changes=NONE; known-good legacy kext/everyday EFI untouched."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
(out/"checkpoint-block.txt").write_text(
"========== STAGE 89 V13 — TX FACTORY ADAPTER FEASIBILITY ==========\n"+
"STAGE89_V13_RUN: "+out.name+"\n"+
"STAGE89_V13_VERSION: STAGE89_V13_FACTORY_ADAPTER_FEASIBILITY\n"+
"STAGE89_V13_PREDECESSOR: run-20261105-043238-9923f409a010\n"+
"STAGE89_V13_EVIDENCE_PINS: PASS\n"+
"STAGE89_V13_CHECKS_PASSED: "+str(passed)+"/"+str(len(checks_map))+"\n"+
"STAGE89_V13_ADAPTER_FEASIBILITY: BLOCKED_PENDING_SEPARATE_ABI_REVIEW_AND_IMPLEMENTATION_AUTHORIZATION\n"+
"STAGE89_V13_SOURCE_MODIFIED: NO\n"+
"STAGE89_V13_BUILD: NOT_RUN\n"+
"STAGE89_V13_SIGNING: NOT_RUN\n"+
"STAGE89_V13_INSTALL: NOT_RUN\n"+
"STAGE89_V13_LOAD: NOT_RUN\n"+
"STAGE89_V13_OPENCORE_CHANGE: NONE\n"+
"STAGE89_V13_RESULT: REVIEW_REQUIRED\n"+
"STAGE89_V13_ACTIVATION_GATE: BLOCKED\n"+
"STAGE89_V13_LOGS: "+ "Development/Logs/stage89-v13/"+out.name+"/\n")
print("STAGE89_V13_RESULT=REVIEW_REQUIRED",flush=True)
PY
python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["adapter-feasibility-checks.txt","adapter-feasibility-verdict.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V13_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST
for f in "$OUT/adapter-feasibility-checks.txt" "$OUT/adapter-feasibility-verdict.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub upload/readback failed: $(basename "$f")"
done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V13_RUN:" in old: raise SystemExit("V13 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V13 TX factory adapter feasibility audit","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
echo "STAGE89_V13_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
