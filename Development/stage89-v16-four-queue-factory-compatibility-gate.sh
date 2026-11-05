#!/bin/bash
# AUTO_SAFE_READ_ONLY=YES
# AUTO_SCOPE=STAGE89_AUDIT
# Stage89 V16 — four-TX-queue factory/API compatibility gate.
# Read-only source and evidence audit. No source edits or runtime activation.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Developer/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v16/$RUN"
REMOTE="Development/Logs/stage89-v16/$RUN"
PREDECESSOR="run-20261105-051755-b866b1583b4d"
BASE="https://raw.githubusercontent.com/$REPO/main"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "STAGE89_V16_ERROR=$*" >&2; exit 2; }
blob(){
 python3 - "$1" <<'PYBLOB'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PYBLOB
}
pin(){
 local name="$1" want="$2" url="$3" got
 curl -fsSLo "$OUT/$name" "$url" || fail "download failed: $name"
 got="$(blob "$OUT/$name")"
 [[ "$got" == "$want" ]] || fail "pinned evidence mismatch $name expected=$want actual=$got"
 echo "PIN_VERIFIED=$name SHA=$got"
}
upload(){
 local file="$1" dest="$2" payload="$OUT/upload-payload.json" want got attempt
 want="$(blob "$file")"
 python3 - "$file" "$payload" <<'PYUPLOAD'
import base64,json,pathlib,sys
pathlib.Path(sys.argv[2]).write_text(json.dumps({
 "message":"Stage89 V16 four-queue factory/API compatibility audit",
 "content":base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode("ascii")
}))
PYUPLOAD
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$dest?ref=main" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then
   echo "UPLOAD_VERIFIED=$dest SHA=$got"
   return 0
  fi
  gh api --method PUT "repos/$REPO/contents/$dest" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt" || true
  got="$(gh api "repos/$REPO/contents/$dest?ref=main" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then
   echo "UPLOAD_VERIFIED=$dest ATTEMPT=$attempt SHA=$got"
   return 0
  fi
  sleep 2
 done
 echo "UPLOAD_FAILED=$dest EXPECTED=$want ACTUAL=$got" >&2
 return 1
}
append_checkpoint(){
 local block="$OUT/checkpoint-block.txt" payload="$OUT/output-log-update.json"
 gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$OUT/output-log-before.json"
 python3 - "$OUT/output-log-before.json" "$block" "$payload" "$RUN" <<'PYAPPEND'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1]))
old=base64.b64decode(obj["content"])
run=sys.argv[4]
if b"STAGE89_V16_RUN:" in old:
    raise SystemExit("V16 checkpoint already exists; refusing duplicate append")
add=pathlib.Path(sys.argv[2]).read_bytes()
new=old.rstrip()+b"\n\n"+add
pathlib.Path(sys.argv[3]).write_text(json.dumps({
 "message":"Record Stage89 V16 four-queue factory/API compatibility audit",
 "content":base64.b64encode(new).decode("ascii"),
 "sha":obj["sha"],"branch":"main"
}))
PYAPPEND
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$payload" > "$OUT/output-log-update-response.json"
 gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$OUT/output-log-after.json"
 python3 - "$OUT/output-log-after.json" "$RUN" <<'PYVERIFY'
import base64,json,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
if "STAGE89_V16_RUN: "+sys.argv[2] not in s:
    raise SystemExit("Canonical output.log read-after-write check failed")
print("CANONICAL_OUTPUT_LOG_READBACK=PASS")
PYVERIFY
}
on_exit(){
 local rc=$?
 if [[ "$rc" -ne 0 ]]; then
  {
   echo "STAGE89_V16_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   tail -100 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
   upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true
  fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail; do command -v "$t" >/dev/null 2>&1 || fail "missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "expected project tree missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication unavailable"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be Sequoia 15.8.1 (24H32) x86_64"

pin source-queues.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
pin source-queues.hpp 1059a4a06d52d28ee7fa7fe17970b618db0faabd "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
pin sdk-tx-submission.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin sdk-tx-completion.h 5b3eae99ae8ded8022bc730dbc8e4ef1e6a491b8 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxCompletionQueue.h"
pin sdk-rx-submission.h 8b10f9bc9610a71912b1dc91fc6933c3e635a0d4 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkRxSubmissionQueue.h"
pin sdk-rx-completion.h 70f2858ddbb16185c674ccdf5366f20a8cb7a9b6 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkRxCompletionQueue.h"
pin v6-method-index.txt 93a03a3200dd5e7f4770c3602f92bfae02bcde19 "$BASE/Development/Logs/stage89-v6/run-20261104-122352-a8be252ec590/native-queue-method-index.txt"
pin v6-factory-facts.txt 4eb4433d8ec67dee4ccaab9860ec7448b7c38ddb "$BASE/Development/Logs/stage89-v6/run-20261104-122352-a8be252ec590/native-queue-factory-performcommand-facts.txt"
pin v12-factory-crosswalk.txt 5c1afc5bd220a8da52e9dc9d6bfed6b7b8da6831 "$BASE/Development/Logs/stage89-v12/run-20261105-043238-9923f409a010/callback-factory-api-crosswalk.txt"
pin v15-queue-inventory.txt aa5ed15566deebd6bfe780f7655f081852973252 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/queue-construction-inventory.txt"
pin v15-ownership-audit.txt c178cc420e81eba32a46b0a920f2d5354459f3ba "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/ownership-lifetime-audit.txt"
pin v15-pointer-contract.txt 89b8d0df989de5abe85fc2ecf168359aabe76b91 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/pointer-array-test-contract.txt"

python3 - "$OUT" <<'PYAUDIT'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
cpp=(p/"source-queues.cpp").read_text()
hpp=(p/"source-queues.hpp").read_text()
tx=(p/"sdk-tx-submission.h").read_text()
tc=(p/"sdk-tx-completion.h").read_text()
rx=(p/"sdk-rx-submission.h").read_text()
rc=(p/"sdk-rx-completion.h").read_text()
idx=(p/"v6-method-index.txt").read_text()
facts=(p/"v6-factory-facts.txt").read_text()
cross=(p/"v12-factory-crosswalk.txt").read_text()
inv=(p/"v15-queue-inventory.txt").read_text()
own=(p/"v15-ownership-audit.txt").read_text()
contract=(p/"v15-pointer-contract.txt").read_text()

checks={
 "source_has_one_tx_submission_member":hpp.count("IOSkywalkTxSubmissionQueue *_txSubmission")==1,
 "source_has_one_tx_submission_factory_assignment":cpp.count("_txSubmission = IOSkywalkTxSubmissionQueue::withPool(")==1,
 "current_tx_submission_factory_is_action_only_withpool":"_txSubmission = IOSkywalkTxSubmissionQueue::withPool(" in cpp and "withPoolAndServiceClass" not in cpp,
 "tx_sdk_declares_named_explicit_serviceclass_factory":"withPoolAndServiceClass(" in tx and "kern_packet_svc_class_t serviceClass" in tx,
 "tx_sdk_explicit_factory_places_serviceclass_before_owner":bool(re.search(r"withPoolAndServiceClass\s*\([^;]*UInt32 capacity,\s*UInt32 queueId,\s*kern_packet_svc_class_t serviceClass,\s*OSObject \* owner",tx,re.S)),
 "tx_sdk_also_declares_action_only_withpool":"withPool( IOSkywalkPacketBufferPool * pool, UInt32 capacity, UInt32 queueId, OSObject * owner, IOSkywalkTxSubmissionQueueAction action" in tx,
 "tx_completion_sdk_has_no_serviceclass_constructor_arg":"withPool(" in tc and "kern_packet_svc_class_t" not in tc,
 "rx_submission_sdk_has_explicit_serviceclass_constructor_arg":"kern_packet_svc_class_t serviceClass" in rx,
 "rx_completion_sdk_has_no_serviceclass_constructor_arg":"withPool(" in rc and "kern_packet_svc_class_t" not in rc,
 "target_index_contains_tx_main_factory":"IOSkywalkTxSubmissionQueue8withPool" in idx,
 "target_index_has_no_named_explicit_factory_symbol":"IOSkywalkTxSubmissionQueue23withPoolAndServiceClass" not in idx,
 "target_index_inventories_action_only_wrapper":"IOSkywalkTxSubmissionQueue8withPool" in idx and "IOSkywalkTxSubmissionQueue12initWithPool" in idx,
 "target_action_only_default_sentinel_documented":"TARGET_ACTION_ONLY_SERVICE_CLASS_DEFAULT=0xffffffff" in cross,
 "v12_crosswalk_records_sdk_target_mapping_not_found":"DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND" in cross,
 "v12_crosswalk_records_main_target_arg_order":"TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in cross,
 "v12_crosswalk_records_explicit_sdk_arg_order":"SDK_NAMED_WITHPOOLANDSERVICECLASS_ORDER=pool,capacity,queueId,serviceClass,owner,queryHandler,action,refCon,options" in cross,
 "v15_inventory_proves_no_tx_array_and_no_registration":"no_four_entry_tx_submission_pointer_array=PASS" in inv and "no_registration_call_in_current_source=PASS" in inv,
 "v15_inventory_proves_one_base_tx_submission_queue":"one_factory_assignment_for__txSubmission=PASS" in inv,
 "wmm_requires_exact_four_distinct_values":"four_distinct_wmm_values=PASS" in own and "0x00100080,0x00000000,0x00380100,0x00400180" in contract,
 "four_pointer_test_contract_still_design_only":"STATUS=DESIGN_ONLY_NOT_IMPLEMENTED" in contract,
 "registration_remains_absent_in_source":not re.search(r"registerEthernetInterface\\s*\\(",re.sub(r"/\\*.*?\\*/|//[^\\n]*","",cpp,flags=re.S)),
 "four_callback_entrypoints_remain_fail_closed":"callback_acceptance_is_currently_fail_closed=PASS" in inv
}
lines=["STAGE89_V16_FACTORY_COMPATIBILITY_CHECKS"]
for k,v in checks.items(): lines.append(k+"="+("PASS" if v else "FAIL"))
lines += ["CHECK_COUNT="+str(len(checks)),"CHECKS_PASSED="+str(sum(checks.values())),"CHECKS_FAILED="+str(len(checks)-sum(checks.values()))]
(p/"factory-compatibility-checks.txt").write_text("\n".join(lines)+"\n")

matrix="""STAGE89_V16_SERVICE_CLASS_CONSTRUCTOR_MATRIX
ROLE_1_TX_SUBMISSION:
  SDK_NAMED_FACTORY=withPoolAndServiceClass(pool,capacity,queueId,serviceClass,owner,handler,action,refCon,options)
  TARGET_EXACT_NAMED_SYMBOL=NOT_FOUND_IN_CAPTURED_24H32_METHOD_INDEX
  TARGET_PRIMARY_WITHPOOL=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass
  SDK_TO_TARGET_DIRECT_MAPPING=NOT_PROVEN
  CURRENT_SOURCE_CALL=ACTION_ONLY_WITHPOOL
  CURRENT_SOURCE_SERVICE_CLASS=0xffffffff_DEFAULT_SENTINEL
  SAFE_FOUR_CLASS_CONSTRUCTION=BLOCKED
ROLE_2_TX_COMPLETION:
  SDK_FACTORY=withPool(pool,capacity,queueId,owner,action,refCon,options)
  EXPLICIT_SERVICE_CLASS_ARGUMENT=NOT_DECLARED
  NOTE=Not the QueueSet role-1 WMM array
ROLE_3_RX_SUBMISSION:
  SDK_FACTORY=withPool(pool,capacity,queueId,serviceClass,owner,action,refCon,options)
  EXPLICIT_SERVICE_CLASS_ARGUMENT=DECLARED
  NOTE=Role-3 queue; do not substitute it for role-1 TX queues
ROLE_4_RX_COMPLETION:
  SDK_FACTORY=withPool(pool,capacity,queueId,owner,action,refCon,options)
  EXPLICIT_SERVICE_CLASS_ARGUMENT=NOT_DECLARED
  NOTE=Not the QueueSet role-1 WMM array
WMM_ROLE_1_REQUIREMENT=FOUR_DISTINCT_TX_SUBMISSION_QUEUES
WMM_VALUES=0x00100080,0x00000000,0x00380100,0x00400180
"""
(p/"service-class-constructor-matrix.txt").write_text(matrix)

gate="""STAGE89_V16_FOUR_QUEUE_CONSTRUCTION_GATE
CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1
REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4
SDK_NAMED_SERVICECLASS_FACTORY=DECLARED
TARGET_EXACT_NAMED_SERVICECLASS_FACTORY=NOT_FOUND_IN_CAPTURED_SYMBOL_INDEX
TARGET_MAIN_FACTORY_EXTRA_ARGUMENT=SERVICE_CLASS_AFTER_OPTIONS
SDK_NAMED_FACTORY_ARGUMENT_POSITION=SERVICE_CLASS_BEFORE_OWNER
DIRECT_ABI_ADAPTER=NOT_PROVEN
ACTION_ONLY_DEFAULT_SERVICE_CLASS=0xffffffff
PRIVATE_FIELD_WRITE=PROHIBITED
GUESSED_OVERLOAD_OR_ARGUMENT_REORDER=PROHIBITED
STABLE_FOUR_POINTER_ARRAY=NOT_IMPLEMENTED
EXECUTABLE_POINTER_ARRAY_TESTS=NOT_IMPLEMENTED
NATIVE_REGISTRATION_CALLS=0
DECISION=DO_NOT_CONSTRUCT_FOUR_QUEUES_UNTIL_A_SEPARATELY_REVIEWED_PUBLIC_OR_VERIFIED_TARGET_ABI_PATH_EXISTS
SOURCE_MODIFIED=NO
BUILD=NOT_RUN
SIGNING=NOT_RUN
INSTALL=NOT_RUN
LOAD=NOT_RUN
HARDWARE_TEST=NOT_RUN
OPENCORE_CHANGE=NONE
STAGE89_EXIT=NOT_MET
ACTIVATION_GATE=BLOCKED
"""
(p/"four-queue-construction-gate.txt").write_text(gate)

passed=sum(checks.values())
report="\n".join([
 "========== STAGE 89 V16 — FOUR-QUEUE FACTORY/API COMPATIBILITY GATE ==========",
 "RUN="+p.name,
 "PREDECESSOR=run-20261105-051755-b866b1583b4d",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "AUDIT_CHECKS_PASSED="+str(passed)+"/"+str(len(checks)),
 "SOURCE_TREE_FINGERPRINTS=PASS",
 "SDK_TARGET_SERVICECLASS_FACTORY_MAPPING=NOT_PROVEN",
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT=1",
 "REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4",
 "FOUR_QUEUE_CONSTRUCTION=BLOCKED_PENDING_VERIFIED_FACTORY_ABI",
 "STABLE_FOUR_POINTER_ARRAY=NOT_IMPLEMENTED",
 "EXECUTABLE_POINTER_ARRAY_TESTS=NOT_IMPLEMENTED",
 "REGISTRATION_CALLS=0",
 "CALLBACK_HANDOFFS=FAIL_CLOSED",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "SIGNING=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "HARDWARE_TEST=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "STAGE89_EXIT=NOT_MET",
 "ACTIVATION_GATE=BLOCKED",
])+"\n"
(p/"report.txt").write_text(report)
if not all(checks.values()):
    raise SystemExit("One or more compatibility predicates failed; see report artifacts")
print("FACTORY_COMPATIBILITY_CHECKS_PASSED="+str(passed)+"/"+str(len(checks)))
PYAUDIT

{
 echo "========== STAGE 89 V16 — FOUR-QUEUE FACTORY/API COMPATIBILITY GATE =========="
 echo "STAGE89_V16_RUN: $RUN"
 echo "STAGE89_V16_VERSION: STAGE89_V16_FOUR_QUEUE_FACTORY_COMPATIBILITY_GATE"
 echo "STAGE89_V16_PREDECESSOR: $PREDECESSOR"
 echo "STAGE89_V16_SOURCE_TREE_REVALIDATION: PASS"
 echo "STAGE89_V16_FACTORY_COMPATIBILITY_CHECKS: $(grep '^CHECKS_PASSED=' "$OUT/factory-compatibility-checks.txt" | cut -d= -f2)/$(grep '^CHECK_COUNT=' "$OUT/factory-compatibility-checks.txt" | cut -d= -f2)"
 echo "STAGE89_V16_SDK_TARGET_SERVICECLASS_FACTORY_MAPPING: NOT_PROVEN"
 echo "STAGE89_V16_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1"
 echo "STAGE89_V16_REQUIRED_TX_SUBMISSION_QUEUE_COUNT: 4"
 echo "STAGE89_V16_FOUR_QUEUE_CONSTRUCTION: BLOCKED_PENDING_VERIFIED_FACTORY_ABI"
 echo "STAGE89_V16_STABLE_POINTER_ARRAY: NOT_IMPLEMENTED"
 echo "STAGE89_V16_REGISTRATION_CALLS: 0"
 echo "STAGE89_V16_SOURCE_MODIFIED: NO"
 echo "STAGE89_V16_BUILD: NOT_RUN"
 echo "STAGE89_V16_SIGNING: NOT_RUN"
 echo "STAGE89_V16_INSTALL: NOT_RUN"
 echo "STAGE89_V16_LOAD: NOT_RUN"
 echo "STAGE89_V16_OPENCORE_CHANGE: NONE"
 echo "STAGE89_V16_RESULT: REVIEW_REQUIRED"
 echo "STAGE89_V16_ACTIVATION_GATE: BLOCKED"
 echo "STAGE89_V16_LOGS: $REMOTE/"
 echo "========================================================================"
} > "$OUT/checkpoint-block.txt"

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
names=["factory-compatibility-checks.txt","service-class-constructor-matrix.txt","four-queue-construction-gate.txt","report.txt","checkpoint-block.txt"]
lines=["STAGE89_V16_MANIFEST","RUN="+p.name,"PREDECESSOR=run-20261105-051755-b866b1583b4d","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(p/n).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 lines.append("ARTIFACT|"+n+"|"+sha+"|"+str(len(b)))
(p/"manifest.txt").write_text("\n".join(lines)+"\n")
PYMANIFEST

echo "STAGE89_V16_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V16_FOUR_QUEUE_FACTORY_COMPATIBILITY_GATE"
echo "READ_ONLY=YES"
for f in factory-compatibility-checks.txt service-class-constructor-matrix.txt four-queue-construction-gate.txt report.txt checkpoint-block.txt manifest.txt; do
 upload "$OUT/$f" "$REMOTE/$f"
done
append_checkpoint
echo "STAGE89_V16_RESULT=REVIEW_REQUIRED"
echo "CANONICAL_HISTORY_UPDATE=PASS"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
