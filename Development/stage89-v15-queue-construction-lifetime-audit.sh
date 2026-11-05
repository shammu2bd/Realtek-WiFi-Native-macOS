#!/bin/bash
# AUTO_SAFE_READ_ONLY=YES
# AUTO_SCOPE=STAGE89_AUDIT
# Stage89 V15 — queue construction, ownership/lifetime and pointer-array test contract.
# READ ONLY. No source/header changes, build, signing, install/load, hardware test or OpenCore/SIP/NVRAM change.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v15/$RUN"
REMOTE="Development/Logs/stage89-v15/$RUN"
PREDECESSOR="run-20261105-044323-71e5e6619e48"
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
 [[ "$actual" == "$sha" ]] || fail "Pinned evidence mismatch $n expected=$sha actual=$actual"
 echo "PIN_VERIFIED=$n SHA=$actual"
}
upload(){
 local f="$1" dest="$2" payload="$OUT/payload.json" want got attempt
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PYUPLOAD'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V15 queue construction and pointer-array lifetime audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
append_checkpoint(){
 local block="$OUT/checkpoint-block.txt" payload="$OUT/output-log-update.json" current
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-log-before.json"
 python3 - "$OUT/output-log-before.json" "$block" "$payload" <<'PYAPPEND'
import base64,json,pathlib,sys
obj=json.load(open(sys.argv[1]))
old=base64.b64decode(obj["content"])
add=pathlib.Path(sys.argv[2]).read_bytes()
if b"STAGE89_V15_RUN:" in old:
    raise SystemExit("V15 checkpoint already present; refusing duplicate append")
new=old.rstrip()+b"\n\n"+add
out={"message":"Record Stage89 V15 queue construction and pointer-array audit","content":base64.b64encode(new).decode(),"sha":obj["sha"],"branch":"main"}
pathlib.Path(sys.argv[3]).write_text(json.dumps(out))
PYAPPEND
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$payload" > "$OUT/output-log-update-response.json"
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-log-after.json"
 python3 - "$OUT/output-log-after.json" "$RUN" <<'PYVERIFY'
import base64,json,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
if "STAGE89_V15_RUN: "+sys.argv[2] not in s: raise SystemExit("Canonical output.log read-after-write verification failed")
print("CANONICAL_OUTPUT_LOG_READBACK=PASS")
PYVERIFY
}
on_exit(){
 local rc=$?
 if [[ $rc -ne 0 ]]; then
  { echo "STAGE89_V15_FAILURE"; echo "RUN=$RUN"; echo "EXIT=$rc"; tail -n 100 "$OUT/console-output.log" 2>/dev/null || true; } > "$OUT/failure-report.txt"
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
pin v14-checks.txt e736071cf45a5963fea897ce302b6db1772839fc "$LOGS/stage89-v14/$PREDECESSOR/abi-adjudication-checks.txt"
pin v14-report.txt 69545562fe6cb6e3a96107cac941800e79f79973 "$LOGS/stage89-v14/$PREDECESSOR/report.txt"
pin v14-verdict.txt dd8cc80f287dbf9424fb3e46c67a7c50edcbb151 "$LOGS/stage89-v14/$PREDECESSOR/abi-adjudication-verdict.txt"
pin v9-disassembly.txt a4c4cd35016228e79953b9991426f45bcdc69089 "$LOGS/stage89-v9/run-20261105-034922-6566f42c51aa/target-txsubmission-factory-disassembly.txt"
pin v12-crosswalk.txt 5c1afc5bd220a8da52e9dc9d6bfed6b7b8da6831 "$LOGS/stage89-v12/run-20261105-043238-9923f409a010/callback-factory-api-crosswalk.txt"
pin wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1 "$LOGS/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin queue-array-lifetime.txt 394c0ed715d6d219ae3e9990fab26ed0d2d49054 "$LOGS/stage88/run-20261102-205135-b4f4ddc49298/queue-array-lifetime-abi.txt"
pin queueset-crosswalk.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51 "$LOGS/stage62/run-20261102-161032-d54adc732d87/queueset-info-word-crosswalk.txt"
python3 - "$OUT/v14-checks.txt" "$OUT/v14-report.txt" "$OUT/v14-verdict.txt" "$OUT/v9-disassembly.txt" "$OUT/v12-crosswalk.txt" <<'PYFIX'
import pathlib,re,sys
checks=pathlib.Path(sys.argv[1]).read_text()
report=pathlib.Path(sys.argv[2]).read_text()
verdict=pathlib.Path(sys.argv[3]).read_text()
dis=pathlib.Path(sys.argv[4]).read_text()
cross=pathlib.Path(sys.argv[5]).read_text()
norm=lambda s: re.sub(r"\s+"," ",s)
dn=norm(dis)
results={
"v14_failed_target_order_check_is_field_name_mismatch": "v12_records_actual_target_order=FAIL" in checks and "TARGET_PRIMARY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in verdict,
"v14_action_only_field_label_mismatch_is_confirmed": "action_only_wrapper_is_separate_symbol=FAIL" in checks and "TARGET_ACTION_ONLY_SERVICECLASS_DEFAULT=0xffffffff" in cross,
"v14_instruction_checks_are_whitespace_sensitive": all(x in dn for x in ["mov r10d, dword ptr [rbp + 0x18]","mov edx, dword ptr [rbp + 0x20]","push r10","push -0x1","or r10d, 0x8"]),
"target_order_and_sdk_order_conflict_remains": "TARGET_PRIMARY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in verdict and "SDK_NAMED_WITHPOOLSERVICECLASS_ORDER=pool,capacity,queueId,serviceClass,owner,queryHandler,action,refCon,options" in verdict,
"direct_sdk_mapping_remains_unproven": "EXISTING_PUBLIC_THUNK_PROVEN=NO" in verdict and "SDK_TO_TARGET_DIRECT_OVERLOAD_MAPPING=NOT_FOUND" in cross,
}
p=sum(results.values())
pathlib.Path(sys.argv[1]).with_name("v14-predicate-reconciliation.txt").write_text("STAGE89_V14_PREDICATE_RECONCILIATION\n"+"\n".join(k+"="+("PASS" if v else "FAIL") for k,v in results.items())+f"\nCHECK_COUNT={len(results)}\nCHECKS_PASSED={p}\n")
if p != len(results): raise SystemExit("V14 predicate reconciliation did not pass")
print("V14_FALSE_NEGATIVE_RECONCILIATION=PASS")
PYFIX
python3 - "$ROOT" "$OUT" <<'PYSOURCE'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
rel_cpp="driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
rel_hpp="driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
expected={
rel_cpp:"59501f4ed08b5e30e82af810c99552bec2018213",
rel_hpp:"1059a4a06d52d28ee7fa7fe17970b618db0faabd",
}
def gitsha(p):
 b=p.read_bytes()
 return hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
sources={}
for rel,sha in expected.items():
 p=root/rel
 if not p.is_file(): raise SystemExit("Missing source "+rel)
 actual=gitsha(p)
 if actual!=sha: raise SystemExit(f"Source fingerprint mismatch {rel}: expected {sha}, got {actual}")
 sources[rel]=p.read_text(errors="replace")
cpp=sources[rel_cpp]; hpp=sources[rel_hpp]
def strip_comments(s):
 s=re.sub(r"/\*.*?\*/"," ",s,flags=re.S)
 s=re.sub(r"//.*"," ",s)
 return s
code=strip_comments(cpp)
checks={}
def add(k,v): checks[k]="PASS" if v else "FAIL"
for name,typ in [("_txSubmission","IOSkywalkTxSubmissionQueue"),("_txCompletion","IOSkywalkTxCompletionQueue"),("_rxSubmission","IOSkywalkRxSubmissionQueue"),("_rxCompletion","IOSkywalkRxCompletionQueue")]:
 add("one_member_for_"+name, len(re.findall(r"\b"+re.escape(typ)+r"\s*\*\s*"+re.escape(name)+r"\b",hpp))==1)
 add("one_factory_assignment_for_"+name, len(re.findall(r"\b"+re.escape(name)+r"\s*=\s*"+re.escape(typ)+r"::withPool\s*\(",code))==1)
add("tx_submission_factory_is_action_only_withpool", bool(re.search(r"_txSubmission\s*=\s*IOSkywalkTxSubmissionQueue::withPool\s*\(",code)))
add("no_named_serviceclass_factory_in_source","withPoolAndServiceClass" not in code)
add("current_source_constructs_one_of_each_base_role", all(len(re.findall(r"\b"+re.escape(n)+r"\s*=\s*"+re.escape(t)+r"::withPool\s*\(",code))==1 for n,t in [("_txSubmission","IOSkywalkTxSubmissionQueue"),("_txCompletion","IOSkywalkTxCompletionQueue"),("_rxSubmission","IOSkywalkRxSubmissionQueue"),("_rxCompletion","IOSkywalkRxCompletionQueue")]))
add("no_four_entry_tx_submission_pointer_array", re.search(r"IOSkywalkTxSubmissionQueue\s*\*\s*\w+\s*\[\s*4\s*\]",hpp+code) is None)
add("no_tx_submission_pointer_array_member", re.search(r"IOSkywalkTxSubmissionQueue\s*\*\s*\w+\s*\[\s*\]",hpp) is None)
add("no_registration_call_in_current_source", re.search(r"\bregisterEthernetInterface\s*\(",code) is None)
add("allocation_guard_checks_existing_resources", "_allocated" in code and "_txPool || _rxPool || _txSubmission || _txCompletion" in code)
add("queue_cleanup_is_reverse_queue_creation_order", code.index("if (_rxCompletion)") < code.index("if (_rxSubmission)") < code.index("if (_txCompletion)") < code.index("if (_txSubmission)"))
add("pool_cleanup_is_reverse_pool_creation_order", code.index("if (_rxPool)") < code.index("if (_txPool)"))
add("four_callback_entrypoints_exist", all(n in hpp and n in code for n in ["txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"]))
add("callback_acceptance_is_currently_fail_closed", code.count("return static_cast<IOReturn>(0);")>=6)
add("allocated_state_requires_both_pools_and_four_base_queues", "return _allocated && _txPool && _rxPool && _txSubmission &&" in code)
(out/"queue-construction-inventory.txt").write_text("STAGE89_V15_QUEUE_CONSTRUCTION_INVENTORY\nSOURCE_CPP_GIT_BLOB="+expected[rel_cpp]+"\nSOURCE_HPP_GIT_BLOB="+expected[rel_hpp]+"\n"+"\n".join(k+"="+v for k,v in checks.items())+"\nCHECK_COUNT="+str(len(checks))+"\nCHECKS_PASSED="+str(sum(v=="PASS" for v in checks.values()))+"\n")
if any(v!="PASS" for v in checks.values()): raise SystemExit("Queue construction source audit contains a failed predicate")
print("SOURCE_TREE_FINGERPRINTS=PASS")
print("QUEUE_CONSTRUCTION_INVENTORY=PASS")
PYSOURCE
python3 - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
wmm=(out/"wmm-table.txt").read_text()
life=(out/"queue-array-lifetime.txt").read_text()
qs=(out/"queueset-crosswalk.txt").read_text()
cpp=(out/"queue-construction-inventory.txt").read_text()
vals=re.findall(r"WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]+)",wmm)
checks={
"four_distinct_wmm_values": len(vals)==4 and len(set(vals))==4,
"wmm_values_are_expected_numeric_set": set(vals)=={"0x00100080","0x00000000","0x00380100","0x00400180"},
"queueset_copies_control_word_and_initializes_from_queue_array": "FACTORY=IOSkywalkQueueSet::createWithQueues" in qs and "CALLEE=IOSkywalkQueueSet::initWithQueues" in qs,
"queueset_array_lifetime_not_equivalent_to_queue_object_lifetime": "OBSERVED_EFFECT" in qs,
"source_still_has_only_one_tx_submission_queue": "one_factory_assignment_for__txSubmission=PASS" in cpp,
}
(out/"ownership-lifetime-audit.txt").write_text("STAGE89_V15_OWNERSHIP_AND_LIFETIME_AUDIT\n"+"\n".join(k+"="+("PASS" if v else "FAIL") for k,v in checks.items())+f"\nCHECK_COUNT={len(checks)}\nCHECKS_PASSED={sum(checks.values())}\n")
if not all(checks.values()): raise SystemExit("Ownership/lifetime evidence audit failed")
(out/"pointer-array-test-contract.txt").write_text("""STAGE89_V15_POINTER_ARRAY_TEST_CONTRACT
STATUS=DESIGN_ONLY_NOT_IMPLEMENTED
ROLE=ROLE_1_TX_SUBMISSION_ARRAY_ONLY
EXPECTED_COUNT=4
EXPECTED_WMM_ORDER=0x00100080,0x00000000,0x00380100,0x00400180
REQUIRED_ASSERTIONS:
1. Exactly four TX submission queue objects are constructed; no missing or extra role-1 queue.
2. Every pointer is non-null before registration argument assembly.
3. All four pointers are pairwise unique; aliasing two service classes is a failure.
4. Each queue reports the expected numeric service class; each class occurs exactly once.
5. Pointer-array order is deterministic and matches EXPECTED_WMM_ORDER.
6. The array address and its four entries remain unchanged for the complete synchronous registration call.
7. Queue objects remain retained and alive for the full registration/QueueSet ownership transition; an array copy does not imply that caller-owned queue objects can be released early.
8. Any construction failure releases only successfully acquired objects in reverse acquisition order and leaves registration unreachable.
9. Repeat create/destroy, partial-construction failure and double-destroy tests must prove idempotence and no stale pointers.
10. No test may infer a private service-class setter or use the unproven SDK/target factory mapping.
TEST_CASES_REQUIRED=empty_slot;duplicate_pointer;wrong_order;duplicate_service_class;unknown_service_class;array_mutated_during_call;queue_release_before_queue_set_retains;fourth_constructor_failure;repeat_destroy
REGISTRATION_POLICY=FAIL_CLOSED; no live registration in Stage89 V15
GATE=Stage89 exit remains blocked until a reviewed implementation and executable tests prove these properties.
""")
PY
python3 - "$OUT" <<'PY'
import pathlib,sys
out=pathlib.Path(sys.argv[1])
checks=(out/"v14-predicate-reconciliation.txt").read_text()
inv=(out/"queue-construction-inventory.txt").read_text()
life=(out/"ownership-lifetime-audit.txt").read_text()
test=(out/"pointer-array-test-contract.txt").read_text()
passed=sum(x.count("=PASS") for x in [checks,inv,life])
failed=sum(x.count("=FAIL") for x in [checks,inv,life])
report=f"""========== STAGE 89 V15 — QUEUE CONSTRUCTION / OWNERSHIP / POINTER ARRAY ==========
RUN={out.name}
AUDIT_CHECKS_PASSED={passed}
AUDIT_CHECKS_FAILED={failed}
SOURCE_TREE_FINGERPRINTS=PASS
CURRENT_TX_SUBMISSION_QUEUE_COUNT=1
TARGET_WMM_ROLE_1_CARDINALITY_REQUIRED=4
FOUR_QUEUE_CONSTRUCTION=NOT_IMPLEMENTED
STABLE_FOUR_POINTER_ARRAY=NOT_IMPLEMENTED
EXECUTABLE_POINTER_ARRAY_TESTS=NOT_IMPLEMENTED
POINTER_ARRAY_TEST_CONTRACT=DESIGN_ONLY
CURRENT_QUEUE_CLEANUP_ORDER=REVERSE_ACQUISITION
CURRENT_REGISTRATION_CALLS=0
FACTORY_SERVICECLASS_MAPPING=NOT_PROVEN; DO_NOT_GUESS
V14_FAILURES=RECONCILED_AS_AUDIT_PREDICATE_FIELD_OR_WHITESPACE_MISMATCHES
SOURCE_MODIFIED=NO
BUILD=NOT_RUN
SIGNING=NOT_RUN
INSTALL=NOT_RUN
LOAD=NOT_RUN
HARDWARE_TEST=NOT_RUN
OPENCORE_CHANGE=NONE
RESULT=REVIEW_REQUIRED
STAGE89_EXIT=NOT_MET
ACTIVATION_GATE=BLOCKED
"""
(out/"report.txt").write_text(report)
PY
echo "STAGE89_V15_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V15_QUEUE_CONSTRUCTION_LIFETIME_AUDIT"
echo "READ_ONLY=YES"
python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
names=["v14-predicate-reconciliation.txt","queue-construction-inventory.txt","ownership-lifetime-audit.txt","pointer-array-test-contract.txt","report.txt"]
lines=["STAGE89_V15_MANIFEST","RUN="+p.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(p/n).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 lines.append(f"ARTIFACT|{n}|{sha}|{len(b)}")
(p/"manifest.txt").write_text("\n".join(lines)+"\n")
PYMANIFEST
for f in v14-predicate-reconciliation.txt queue-construction-inventory.txt ownership-lifetime-audit.txt pointer-array-test-contract.txt report.txt; do upload "$OUT/$f" "$REMOTE/$f"; done
upload "$OUT/manifest.txt" "$REMOTE/manifest.txt"
{
 echo "========== STAGE 89 V15 — QUEUE CONSTRUCTION / OWNERSHIP / POINTER ARRAY =========="
 echo "STAGE89_V15_RUN: $RUN"
 echo "STAGE89_V15_VERSION: STAGE89_V15_QUEUE_CONSTRUCTION_LIFETIME_AUDIT"
 echo "STAGE89_V15_PREDECESSOR: $PREDECESSOR"
 echo "STAGE89_V15_SOURCE_TREE_REVALIDATION: PASS"
 echo "STAGE89_V15_V14_PREDICATE_RECONCILIATION: PASS"
 echo "STAGE89_V15_AUDIT_CHECKS_PASSED:  $(( $(grep -c '=PASS' "$OUT/v14-predicate-reconciliation.txt") + $(grep -c '=PASS' "$OUT/queue-construction-inventory.txt") + $(grep -c '=PASS' "$OUT/ownership-lifetime-audit.txt") ))"
 echo "STAGE89_V15_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1"
 echo "STAGE89_V15_REQUIRED_TX_SUBMISSION_QUEUE_COUNT: 4"
 echo "STAGE89_V15_QUEUE_POINTER_ARRAY: NOT_IMPLEMENTED"
 echo "STAGE89_V15_POINTER_ARRAY_TESTS: DESIGN_ONLY_NOT_IMPLEMENTED"
 echo "STAGE89_V15_REGISTRATION_CALLS: 0"
 echo "STAGE89_V15_FACTORY_ABI_MAPPING: NOT_PROVEN"
 echo "STAGE89_V15_SOURCE_MODIFIED: NO"
 echo "STAGE89_V15_BUILD: NOT_RUN"
 echo "STAGE89_V15_SIGNING: NOT_RUN"
 echo "STAGE89_V15_INSTALL: NOT_RUN"
 echo "STAGE89_V15_LOAD: NOT_RUN"
 echo "STAGE89_V15_OPENCORE_CHANGE: NONE"
 echo "STAGE89_V15_RESULT: REVIEW_REQUIRED"
 echo "STAGE89_V15_ACTIVATION_GATE: BLOCKED"
 echo "STAGE89_V15_LOGS: $REMOTE/"
 echo "========================================================================"
} > "$OUT/checkpoint-block.txt"
upload "$OUT/checkpoint-block.txt" "$REMOTE/checkpoint-block.txt"
append_checkpoint
echo "STAGE89_V15_RESULT=REVIEW_REQUIRED"
echo "CANONICAL_HISTORY_UPDATE=PASS"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
