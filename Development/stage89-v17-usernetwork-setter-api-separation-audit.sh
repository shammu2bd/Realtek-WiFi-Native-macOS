#!/bin/bash
# AUTO_SAFE_READ_ONLY=YES
# AUTO_SCOPE=STAGE89_AUDIT
# Stage89 V17 — UserNetwork setter identity, native queue dispatch and API separation audit.
# Read-only. No source/header edits, build, signing, install/load, hardware or OpenCore action.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Developer/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v17/$RUN"
REMOTE="Development/Logs/stage89-v17/$RUN"
PREDECESSOR="run-20261105-065722-726c6e65856b"
BASE="https://raw.githubusercontent.com/$REPO/main"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "STAGE89_V17_ERROR=$*" >&2; exit 2; }
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
 "message":"Stage89 V17 UserNetwork setter/API separation audit",
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
if b"STAGE89_V17_RUN:" in old:
    raise SystemExit("V17 checkpoint already exists; refusing duplicate append")
if b"STAGE89_V16_RUN: run-20261105-065722-726c6e65856b" not in old:
    raise SystemExit("Pinned V16 predecessor is absent from canonical history")
new=old.rstrip()+b"\n\n"+pathlib.Path(sys.argv[2]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({
 "message":"Record Stage89 V17 UserNetwork setter/API separation audit",
 "content":base64.b64encode(new).decode("ascii"),
 "sha":obj["sha"],"branch":"main"
}))
PYAPPEND
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$payload" > "$OUT/output-log-update-response.json"
 gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$OUT/output-log-after.json"
 python3 - "$OUT/output-log-after.json" "$RUN" <<'PYVERIFY'
import base64,json,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
if "STAGE89_V17_RUN: "+sys.argv[2] not in s:
    raise SystemExit("Canonical output.log read-after-write verification failed")
print("CANONICAL_OUTPUT_LOG_READBACK=PASS")
PYVERIFY
}
on_exit(){
 local rc=$?
 if [[ "$rc" -ne 0 ]]; then
  {
   echo "STAGE89_V17_FAILURE"
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
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "expected project source tree missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication unavailable"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be Sequoia 15.8.1 (24H32) x86_64"

pin source-queues.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
pin source-queues.hpp 1059a4a06d52d28ee7fa7fe17970b618db0faabd "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
pin sdk-tx-submission.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin v2-service-class-symbols.txt 9c3b52a6336e0037b7752aeb580a8de4b894e297 "$BASE/Development/Logs/stage89-v2/run-20261103-212848-0667bb3e52a8/kernel-service-class-symbols.txt"
pin v4-service-class-candidates.txt 09bffceadec5d3eac9ce7d2f880c7bfdc8d5314b "$BASE/Development/Logs/stage89-v4/run-20261104-100629-7f12523c2a64/kernel-service-class-symbol-candidates.txt"
pin v5-field-access-scan.txt 28782aba00855d9e6125e38e41513af392e41d79 "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/queue-service-class-field-access-scan.txt"
pin v5-setter-call-trace.txt 2bc0f14b5dfffeaa26838eada4000d2523546c5c "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/set-service-class-call-trace.txt"
pin v5-method-index.txt aa4d43395dd53c8294d36ccfd5c87296f20a3eef "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/setter-registration-method-index.txt"
pin v5-setter-disassembly.txt ae6634a97d9ceeaa3227d9c37fe0fdaa2b87559e "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/setter-registration-method-disassembly.txt"
pin v5-native-vtable-crosswalk.txt 0cc13cc2ec8ec30dcf44ad2ea1f7cdcfb548b9d3 "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/corrected-queue-vtable-crosswalk.txt"
pin v5-queueset-dispatch.txt 3be04d97c33624292bb14540396b8b9a0d9ba789 "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/queueset-virtual-dispatch-sites.txt"
pin v5-symbol-index.txt 23f13846ee306fa37b50648d9d6fdc2f0ad768ca "$BASE/Development/Logs/stage89-v5/run-20261104-121242-6638c95764ea/service-class-registration-symbol-index.txt"
pin v12-factory-crosswalk.txt 5c1afc5bd220a8da52e9dc9d6bfed6b7b8da6831 "$BASE/Development/Logs/stage89-v12/run-20261105-043238-9923f409a010/callback-factory-api-crosswalk.txt"
pin v12-audit-summary.txt cfbfb24f1ef06870f9ab20e49889ffc816a2a1be "$BASE/Development/Logs/stage89-v12/run-20261105-043238-9923f409a010/audit-summary.txt"
pin v15-queue-inventory.txt aa5ed15566deebd6bfe780f7655f081852973252 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/queue-construction-inventory.txt"
pin v15-ownership-audit.txt c178cc420e81eba32a46b0a920f2d5354459f3ba "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/ownership-lifetime-audit.txt"
pin v15-pointer-contract.txt 89b8d0df989de5abe85fc2ecf168359aabe76b91 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/pointer-array-test-contract.txt"
pin v16-construction-gate.txt 8b7d9d3483c08eb72e9e7cbf586c5001a7c1842b "$BASE/Development/Logs/stage89-v16/run-20261105-065722-726c6e65856b/four-queue-construction-gate.txt"
pin v16-predicate-reconciliation.txt 532dcac6fa95361ac738398dbf3c45beb98523ee "$BASE/Development/Logs/stage89-v16/run-20261105-065722-726c6e65856b/predicate-reconciliation.txt"

python3 - "$OUT" <<'PYAUDIT'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
cpp=(p/"source-queues.cpp").read_text()
hpp=(p/"source-queues.hpp").read_text()
sdk=(p/"sdk-tx-submission.h").read_text()
v2=(p/"v2-service-class-symbols.txt").read_text()
v4=(p/"v4-service-class-candidates.txt").read_text()
field=(p/"v5-field-access-scan.txt").read_text()
trace=(p/"v5-setter-call-trace.txt").read_text()
index=(p/"v5-method-index.txt").read_text()
dis=(p/"v5-setter-disassembly.txt").read_text()
vt=(p/"v5-native-vtable-crosswalk.txt").read_text()
dispatch=(p/"v5-queueset-dispatch.txt").read_text()
symbols=(p/"v5-symbol-index.txt").read_text()
cross=(p/"v12-factory-crosswalk.txt").read_text()
v12=(p/"v12-audit-summary.txt").read_text()
inv=(p/"v15-queue-inventory.txt").read_text()
own=(p/"v15-ownership-audit.txt").read_text()
ptr=(p/"v15-pointer-contract.txt").read_text()
gate=(p/"v16-construction-gate.txt").read_text()
recon=(p/"v16-predicate-reconciliation.txt").read_text()

native_service_count=("CLASS=IOSkywalkTxSubmissionQueue\n" in v2 and
 "SERVICE_CLASS_NAMED_METHODS=0\nSERVICE_CLASS_SETTER_CANDIDATES=0\n\nCLASS=IOSkywalkTxCompletionQueue" in v2)
setter_rows=[x for x in index.splitlines() if x.startswith("METHOD=") and "SetServiceClass" in x]
impl_rows=[x for x in setter_rows if "_SetServiceClass_ImplEj" in x]
expected_impl={
 "__ZN36IOUserNetworkTxSubmissionQueueCompat21_SetServiceClass_ImplEj",
 "__ZN30IOUserNetworkTxSubmissionQueue21_SetServiceClass_ImplEj"
}
observed_impl=set()
for line in impl_rows:
 m=re.search(r"NAME=(\S+)",line)
 if m: observed_impl.add(m.group(1))
write_rows=[x for x in field.splitlines() if "SETTER_FIELD_WRITE" in x]
addr_to_method={}
for line in index.splitlines():
 m=re.match(r"METHOD=(0x[0-9a-fA-F]+) OWNER=(\S+) NAME=(\S+)",line)
 if m: addr_to_method[m.group(1).lower()]=(m.group(2),m.group(3))
write_classes=[]
write_names=[]
for line in write_rows:
 m=re.search(r"METHOD=(0x[0-9a-fA-F]+)",line)
 if m and m.group(1).lower() in addr_to_method:
  owner,name=addr_to_method[m.group(1).lower()]
  write_classes.append(owner);write_names.append(name)
native_slot69=("CLASS=IOSkywalkTxSubmissionQueue VTABLE_ENTRIES=100" in vt and "NAME=__ZN26IOSkywalkTxSubmissionQueue14performCommandEjPvm <-- CALL +0x218" in vt)
user_slot69=("CLASS=IOUserNetworkTxSubmissionQueue VTABLE_ENTRIES=93" in vt and "NAME=__ZN30IOUserNetworkTxSubmissionQueue14performCommandEjPvm <-- CALL +0x218" in vt)
uncommented=cpp.replace("/*","/*",1)
uncommented=re.sub(r"/\*[\s\S]*?\*/|//[^\n]*","",uncommented)
sdk_factory=bool(re.search(r"withPoolAndServiceClass\s*\([^;]*kern_packet_svc_class_t serviceClass",sdk,re.S))
sdk_init=bool(re.search(r"initWithPool\s*\([^;]*kern_packet_svc_class_t serviceClass",sdk,re.S))
tx_sdk_setter=bool(re.search(r"(?:set|Set)ServiceClass\s*\(",sdk))
queue_dispatch_calls_perform=dispatch.count("call\tqword ptr [rax + 0x218]")>=2
wmm_values=set(re.findall(r"0x[0-9a-fA-F]{8}",ptr))
checks={
 "source_owns_concrete_ioskywalk_tx_submission_queue":"IOSkywalkTxSubmissionQueue *_txSubmission" in hpp,
 "sdk_declares_explicit_serviceclass_factory":sdk_factory,
 "sdk_declares_explicit_serviceclass_initializer":sdk_init,
 "sdk_has_no_public_setserviceclass_declaration":not tx_sdk_setter,
 "target_native_tx_class_has_zero_named_setter_candidates":native_service_count,
 "target_usernetwork_setter_impls_are_two_distinct_symbols":observed_impl==expected_impl,
 "field_scan_has_exactly_two_direct_setter_writes":len(write_rows)==2,
 "both_direct_field_writes_map_to_usernetwork_classes":len(write_names)==2 and all("IOUserNetworkTxSubmissionQueue" in x for x in write_names),
 "setter_method_bodies_write_offset_b8":"mov\tdword ptr [rdi + 0xb8], esi" in dis and all(x in dis for x in expected_impl),
 "rpc_wrappers_route_through_osmetaclassbase_invoke":"__ZN15OSMetaClassBase6InvokeE5IORPC" in trace,
 "setter_call_trace_contains_no_native_ioskywalk_setter":"IOSkywalkTxSubmissionQueue" not in trace,
 "native_tx_vtable_slot_69_is_performcommand":native_slot69,
 "usernetwork_tx_vtable_slot_69_is_distinct_performcommand":user_slot69,
 "queueset_classification_uses_virtual_performcommand_slot":queue_dispatch_calls_perform and "OBJECT_VPTR_OFFSET=0x218" in dispatch,
 "queue_role_dispatch_is_not_serviceclass_setter":native_slot69 and "call\tqword ptr [rax + 0x218]" in dispatch and "SetServiceClass" not in dispatch,
 "v12_sdk_target_factory_mapping_remains_unproven":"SDK_TO_TARGET_DIRECT_OVERLOAD_MAPPING=NOT_FOUND" in cross,
 "v12_target_factory_order_places_serviceclass_after_options":"TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in v12,
 "v15_source_still_has_only_one_tx_submission_queue":"one_factory_assignment_for__txSubmission=PASS" in inv,
 "v15_four_pointer_array_is_not_implemented":"no_four_entry_tx_submission_pointer_array=PASS" in inv,
 "v15_four_pointer_tests_are_design_only":"STATUS=DESIGN_ONLY_NOT_IMPLEMENTED" in ptr,
 "wmm_contract_has_four_distinct_values":len(wmm_values)>=4 and "four_distinct_wmm_values=PASS" in own,
 "v16_factory_gate_remains_blocked":"DECISION=DO_NOT_CONSTRUCT_FOUR_QUEUES" in gate and "DIRECT_ABI_ADAPTER=NOT_PROVEN" in gate,
 "v16_reconciliation_is_complete_but_not_stage_exit":"RECONCILED_COMPATIBILITY_CHECKS=22/22" in recon and "STAGE89_EXIT=NOT_MET" in recon,
 "source_does_not_write_private_serviceclass_field":not re.search(r"(?:->|\.)\s*mServiceClass\s*=",cpp),
 "source_has_no_live_registration_call":not re.search(r"registerEthernetInterface\s*\(",uncommented)
}
failed=[k for k,v in checks.items() if not v]
rows=["STAGE89_V17_USERNETWORK_SETTER_AND_NATIVE_API_CHECKS"]
for k,v in checks.items(): rows.append(k+"="+("PASS" if v else "FAIL"))
rows += [
 "CHECK_COUNT="+str(len(checks)),
 "CHECKS_PASSED="+str(sum(checks.values())),
 "CHECKS_FAILED="+str(len(failed)),
 "FAILED_CHECK_NAMES="+(",".join(failed) if failed else "NONE"),
 "DIRECT_SETTER_WRITE_METHODS="+(",".join(write_names) if write_names else "NONE"),
 "DIRECT_SETTER_WRITE_OWNERS="+(",".join(write_classes) if write_classes else "NONE")
]
(p/"setter-api-identity-checks.txt").write_text("\n".join(rows)+"\n")

analysis="""STAGE89_V17_NATIVE_VS_USERNETWORK_SERVICECLASS_API_ANALYSIS
NATIVE_QUEUE_CLASS=IOSkywalkTxSubmissionQueue
NATIVE_QUEUE_SDK_HEADER=IOSkywalkTxSubmissionQueue.h
EVIDENCE_MODE=READ_ONLY_RECONCILIATION_OF_PINNED_24H32_SOURCE_HEADERS_AND_PRIOR_TARGET_BINARY_AUDITS
FRESH_KERNEL_BINARY_CAPTURE=NOT_RUN
NATIVE_SDK_EXPLICIT_FACTORY=withPoolAndServiceClass(pool,capacity,queueId,serviceClass,owner,handler,action,refCon,options)
NATIVE_SDK_EXPLICIT_INITIALIZER=initWithPool(pool,capacity,queueId,serviceClass,owner,handler,action,refCon,options)
NATIVE_SDK_SETTER=NOT_DECLARED_IN_PINNED_HEADER
TARGET_NATIVE_NAMED_SETTER_CANDIDATES=0_IN_STAGE89_V2_CLASS_CATALOG
USERNETWORK_SETTER_DECLARING_CLASSES:
  IOUserNetworkTxSubmissionQueue
  IOUserNetworkTxSubmissionQueueCompat
USERNETWORK_IMPL_DIRECT_WRITE=mov dword ptr [rdi + 0xb8], esi
USERNETWORK_IMPL_DIRECT_WRITES=2
USERNETWORK_IMPL_FIELD_OFFSET=0xb8
USERNETWORK_RPC_WRAPPERS=SetServiceClass_Invoke_AND_SetServiceClass_RPC
USERNETWORK_RPC_DISPATCH=OSMetaClassBase::Invoke
NATIVE_IOSKYWALK_AND_USERNETWORK_OBJECT_IDENTITY=NOT_PROVEN_EQUIVALENT
USERNETWORK_SETTER_CALLABILITY_ON_NATIVE_IOSKYWALK_QUEUE=NOT_PROVEN
DO_NOT_CAST_NATIVE_QUEUE_TO_USERNETWORK_QUEUE
DO_NOT_CALL_PRIVATE_SETTER_BY_GUESSED_FUNCTION_POINTER
DO_NOT_WRITE_OFFSET_0XB8_DIRECTLY
DO_NOT_REORDER_TX_FACTORY_ARGUMENTS
QUEUESET_ROLE_CLASSIFICATION_VIRTUAL_SLOT=0x218
NATIVE_TX_QUEUE_SLOT_69=IOSkywalkTxSubmissionQueue::performCommand
USERNETWORK_TX_QUEUE_SLOT_69=IOUserNetworkTxSubmissionQueue::performCommand
QUEUESET_COMMAND=0x10000
QUEUESET_COMMAND_IS_NOT_A_SERVICECLASS_SETTER
SDK_TARGET_DIRECT_FACTORY_MAPPING=NOT_PROVEN
CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1
REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4
STABLE_FOUR_POINTER_ARRAY=NOT_IMPLEMENTED
EXECUTABLE_POINTER_ARRAY_TESTS=NOT_IMPLEMENTED
NATIVE_REGISTRATION_CALLS=0
DECISION=NO_SAFE_PUBLIC_OR_VERIFIED_NATIVE_SETTER_PATH_ESTABLISHED_BY_AVAILABLE_24H32_EVIDENCE
"""
(p/"native-vs-usernetwork-api-analysis.txt").write_text(analysis)

decision="""STAGE89_V17_DECISION
RESULT=REVIEW_REQUIRED
WHY=The only observed direct service-class field writers in the pinned setter audit are methods declared on IOUserNetworkTxSubmissionQueue and IOUserNetworkTxSubmissionQueueCompat. Their RPC wrappers dispatch through OSMetaClassBase::Invoke. The current source constructs IOSkywalkTxSubmissionQueue. The checked evidence does not establish that the UserNetwork setter API is a supported/callable setter for the native IOSkywalk queue.
FACTORY_ABI=NOT_PROVEN
SAFE_CONSTRUCTION_OF_FOUR_WMM_TX_QUEUES=BLOCKED
REGISTRATION=KEEP_ABSENT
SOURCE_IMPLEMENTATION=NOT_AUTHORIZED_BY_V17
NEXT_TECHNICAL_REQUIREMENT=Find a public 24H32 API or complete target-backed factory/initializer ABI proof for IOSkywalkTxSubmissionQueue; do not infer inheritance or callability from a matching field offset.
STAGE89_EXIT=NOT_MET
ACTIVATION_GATE=BLOCKED
"""
(p/"decision.txt").write_text(decision)

passed=sum(checks.values())
report=[
 "========== STAGE 89 V17 — USERNETWORK SETTER / NATIVE QUEUE API SEPARATION ==========",
 "RUN="+p.name,
 "PREDECESSOR=run-20261105-065722-726c6e65856b",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "AUDIT_CHECKS_PASSED="+str(passed)+"/"+str(len(checks)),
 "EVIDENCE_MODE=READ_ONLY_RECONCILIATION_OF_PINNED_24H32_SOURCE_HEADERS_AND_PRIOR_TARGET_BINARY_AUDITS",
 "FRESH_KERNEL_BINARY_CAPTURE=NOT_RUN",
 "AUDIT_CHECKS_FAILED="+str(len(failed)),
 "FAILED_CHECK_NAMES="+(",".join(failed) if failed else "NONE"),
 "USERNETWORK_DIRECT_SETTER_WRITES=2",
 "USERNETWORK_SETTER_CLASS_IDENTITY=IOUserNetworkTxSubmissionQueue_AND_COMPAT",
 "NATIVE_IOSKYWALK_TX_SETTER=NOT_FOUND_IN_PINNED_CLASS_CATALOG_OR_SDK_HEADER",
 "NATIVE_QUEUE_USERNETWORK_SETTER_CALLABILITY=NOT_PROVEN",
 "QUEUESET_PERFORMCOMMAND_IS_ROLE_CLASSIFICATION_NOT_SETTER",
 "SDK_TARGET_DIRECT_FACTORY_MAPPING=NOT_PROVEN",
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT=1",
 "REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4",
 "FOUR_QUEUE_CONSTRUCTION=BLOCKED",
 "STABLE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "REGISTRATION_CALLS=0",
 "FRESH_KERNEL_BINARY_CAPTURE=NOT_RUN",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "SIGNING=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "HARDWARE_TEST=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "STAGE89_EXIT=NOT_MET",
 "ACTIVATION_GATE=BLOCKED"
]
(p/"report.txt").write_text("\n".join(report)+"\n")
print("STAGE89_V17_CHECKS_PASSED="+str(passed)+"/"+str(len(checks)))
print("STAGE89_V17_CHECKS_FAILED="+str(len(failed)))
print("FAILED_CHECK_NAMES="+(",".join(failed) if failed else "NONE"))
PYAUDIT

{
 echo "========== STAGE 89 V17 — USERNETWORK SETTER / NATIVE QUEUE API SEPARATION =========="
 echo "STAGE89_V17_RUN: $RUN"
 echo "STAGE89_V17_VERSION: STAGE89_V17_USERNETWORK_SETTER_API_SEPARATION_AUDIT"
 echo "STAGE89_V17_PREDECESSOR: $PREDECESSOR"
 echo "STAGE89_V17_SOURCE_HEADER_PINS: PASS"
 echo "STAGE89_V17_EVIDENCE_MODE: PINNED_24H32_PRIOR_TARGET_BINARY_AUDITS"
 echo "STAGE89_V17_FRESH_KERNEL_BINARY_CAPTURE: NOT_RUN"
 echo "STAGE89_V17_AUDIT_CHECKS: $(grep '^CHECKS_PASSED=' "$OUT/setter-api-identity-checks.txt" | cut -d= -f2)/$(grep '^CHECK_COUNT=' "$OUT/setter-api-identity-checks.txt" | cut -d= -f2)"
 echo "STAGE89_V17_USERNETWORK_SETTER_DIRECT_WRITES: 2"
 echo "STAGE89_V17_NATIVE_IOSKYWALK_SETTER_CALLABILITY: NOT_PROVEN"
 echo "STAGE89_V17_QUEUESET_PERFORMCOMMAND_ROLE: ROLE_CLASSIFICATION"
 echo "STAGE89_V17_SDK_TARGET_FACTORY_MAPPING: NOT_PROVEN"
 echo "STAGE89_V17_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1"
 echo "STAGE89_V17_REQUIRED_TX_SUBMISSION_QUEUE_COUNT: 4"
 echo "STAGE89_V17_FOUR_QUEUE_CONSTRUCTION: BLOCKED"
 echo "STAGE89_V17_REGISTRATION_CALLS: 0"
 echo "STAGE89_V17_SOURCE_MODIFIED: NO"
 echo "STAGE89_V17_BUILD: NOT_RUN"
 echo "STAGE89_V17_SIGNING: NOT_RUN"
 echo "STAGE89_V17_INSTALL: NOT_RUN"
 echo "STAGE89_V17_LOAD: NOT_RUN"
 echo "STAGE89_V17_OPENCORE_CHANGE: NONE"
 echo "STAGE89_V17_RESULT: REVIEW_REQUIRED"
 echo "STAGE89_V17_ACTIVATION_GATE: BLOCKED"
 echo "STAGE89_V17_LOGS: $REMOTE/"
 echo "========================================================================"
} > "$OUT/checkpoint-block.txt"

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
names=["setter-api-identity-checks.txt","native-vs-usernetwork-api-analysis.txt","decision.txt","report.txt","checkpoint-block.txt"]
lines=["STAGE89_V17_MANIFEST","RUN="+p.name,"PREDECESSOR=run-20261105-065722-726c6e65856b","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(p/n).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 lines.append("ARTIFACT|"+n+"|"+sha+"|"+str(len(b)))
(p/"manifest.txt").write_text("\n".join(lines)+"\n")
PYMANIFEST

echo "STAGE89_V17_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V17_USERNETWORK_SETTER_API_SEPARATION_AUDIT"
echo "READ_ONLY=YES"
for f in setter-api-identity-checks.txt native-vs-usernetwork-api-analysis.txt decision.txt report.txt checkpoint-block.txt manifest.txt; do
 upload "$OUT/$f" "$REMOTE/$f"
done
append_checkpoint
echo "STAGE89_V17_RESULT=REVIEW_REQUIRED"
echo "CANONICAL_HISTORY_UPDATE=PASS"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
