#!/bin/bash
# Stage 89 V10 — TXSubmission service-class argument data-flow audit.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
V9_RUN="run-20261105-034922-6566f42c51aa"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v10/$RUN"
REMOTE="Development/Logs/stage89-v10/$RUN"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V10 TX service-class dataflow audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V10_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 80 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "Project source folder missing at expected project root"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be macOS 15.8.1 / 24H32 / x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main"
V9="$BASE/Development/Logs/stage89-v9/$V9_RUN"
pin v9-manifest.txt 2a9bcb8389eee070619efea5d2ddbb785a5907f8 "$V9/manifest.txt"
pin v9-target-disassembly.txt a4c4cd35016228e79953b9991426f45bcdc69089 "$V9/target-txsubmission-factory-disassembly.txt"
pin v9-symbol-index.txt 41cbdaf57b7d38fc40c09b20ca54e34eb504d109 "$V9/target-txsubmission-factory-symbol-index.txt"
pin v9-crosswalk.txt f6b797a210f37a1d4335dc6fe81ae68c17df4a71 "$V9/tx-factory-symbol-demangle-crosswalk.txt"
pin v9-audit-summary.txt 61bb759a6db37561f4448a5668bd22b97db5bba7 "$V9/audit-summary.txt"
pin tx-submission-sdk-header.txt 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V9_RUN" <<'PYLOG'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V9_RUN:\s*(run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]: raise SystemExit("Latest V9 checkpoint differs from pinned evidence")
if "STAGE89_V9_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V9 review checkpoint missing")
if "STAGE89_V10_RUN:" in log: raise SystemExit("V10 checkpoint already exists; inspect it rather than duplicating")
print("PREDECESSOR_GATE=PASS V9="+runs[-1])
PYLOG
echo "STAGE89_V10_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"

python3 -u - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
dis=(out/"v9-target-disassembly.txt").read_text(errors="replace")
cross=(out/"v9-crosswalk.txt").read_text(errors="replace")
header=(out/"tx-submission-sdk-header.txt").read_text(errors="replace")
symbols=(out/"v9-symbol-index.txt").read_text(errors="replace")

def method(address):
    m=re.search(r"===== ADDRESS=0x"+address+r" SYMBOL=.*? =====\n(.*?)(?=\n===== ADDRESS=|\Z)",dis,re.S)
    if not m: raise SystemExit("Required method body missing: 0x"+address)
    return m.group(1)
main=method("ffffff8002983ff0")
mutable=method("ffffff800298409e")
action_only=method("ffffff80029840c2")
init=method("ffffff80029840e8")

def has(body, pattern):
    return re.search(pattern,body,re.I) is not None
checks={
 "main_factory_loads_final_stack_u32_into_edx":has(main,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]"),
 "main_factory_maps_first_u32_to_init_ecx":has(main,r"mov\s+ecx,\s*r14d"),
 "main_factory_maps_second_u32_to_init_r8d":has(main,r"mov\s+r8d,\s*r13d"),
 "main_factory_maps_options_from_stack_plus_18":has(main,r"mov\s+r10d,\s*dword ptr \[rbp \+ 0x18\]"),
 "main_factory_passes_options_to_init":has(main,r"push\s+r10"),
 "main_factory_passes_refcon_to_init":has(main,r"push\s+qword ptr \[rbp \+ 0x10\]"),
 "main_factory_calls_initializer_vtable_slot_2a8":has(main,r"call\s+qword ptr \[rax \+ 0x2a8\]"),
 "init_checks_ecx_capacity_minimum_8":has(init,r"cmp\s+ecx,\s*0x8"),
 "init_copies_edx_into_r15d":has(init,r"mov\s+r15d,\s*edx"),
 "init_persists_r15d_at_object_offset_b8":has(init,r"mov\s+dword ptr \[rbx \+ 0xb8\],\s*r15d"),
 "init_preserves_second_u32_as_queue_id":has(init,r"mov\s+r9d,\s*r8d"),
 "mutable_wrapper_forwards_final_stack_u32":has(mutable,r"mov\s+eax,\s*dword ptr \[rbp \+ 0x20\]") and has(mutable,r"push\s+rax"),
 "mutable_wrapper_forwards_options_with_bit_8":has(mutable,r"or\s+r10d,\s*0x8") and has(mutable,r"push\s+r10"),
 "action_only_wrapper_pushes_minus_one":has(action_only,r"push\s+-0x1"),
 "all_three_factory_symbols_are_present":all(x in symbols for x in ["2983ff0","298409e","29840c2"]),
 "initializer_symbol_is_present": "29840e8" in symbols,
 "target_has_no_exact_named_public_factory": "TARGET_EXACT_NAMED_WITHPOOLANDSERVICECLASS_SYMBOLS=0" in cross,
}
service_class_dataflow=all(checks[k] for k in [
 "main_factory_loads_final_stack_u32_into_edx",
 "init_copies_edx_into_r15d",
 "init_persists_r15d_at_object_offset_b8"
])
capacity_queueid_map=all(checks[k] for k in [
 "main_factory_maps_first_u32_to_init_ecx",
 "main_factory_maps_second_u32_to_init_r8d",
 "init_checks_ecx_capacity_minimum_8",
 "init_preserves_second_u32_as_queue_id"
])
wrapper_map=all(checks[k] for k in [
 "mutable_wrapper_forwards_final_stack_u32",
 "mutable_wrapper_forwards_options_with_bit_8",
 "action_only_wrapper_pushes_minus_one"
])
# The public SDK declaration places serviceClass before owner; target withPool overload
# has two UInt32s before owner and two UInt32s after refCon (options, then serviceClass).
has_explicit_header="withPoolAndServiceClass" in header
header_line=next((x.strip() for x in header.splitlines() if "withPoolAndServiceClass" in x),"")
target_main_symbol=next((x for x in cross.splitlines() if x.startswith("TARGET_FACTORY_ADDRESS=0xffffff8002983ff0")),"")
header_target_direct_compat=False
summary=[
 "STAGE89_V10_TXSUBMISSION_SERVICECLASS_ARGUMENT_DATAFLOW",
 "VERSION=STAGE89_V10_20261105",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "V9_EVIDENCE_RUN=run-20261105-034922-6566f42c51aa",
 "V9_EVIDENCE_PINS=PASS",
 "CHECK_COUNT="+str(len(checks)),
 "CHECKS_PASSED="+str(sum(bool(v) for v in checks.values())),
 "TARGET_FACTORY_FINAL_U32_IS_SERVICE_CLASS="+("PROVEN_BY_REGISTER_TO_FIELD_DATAFLOW" if service_class_dataflow else "NOT_PROVEN"),
 "TARGET_FACTORY_FIRST_U32_IS_CAPACITY="+("PROVEN" if checks["main_factory_maps_first_u32_to_init_ecx"] and checks["init_checks_ecx_capacity_minimum_8"] else "NOT_PROVEN"),
 "TARGET_FACTORY_SECOND_U32_IS_QUEUE_ID="+("PROVEN" if capacity_queueid_map else "NOT_PROVEN"),
 "MUTABLE_CALLBACK_WRAPPER_PRESERVES_SERVICE_CLASS="+("PROVEN" if wrapper_map and checks["mutable_wrapper_forwards_final_stack_u32"] else "NOT_PROVEN"),
 "ACTION_ONLY_WRAPPER_DEFAULT_SERVICE_CLASS=0xffffffff" if checks["action_only_wrapper_pushes_minus_one"] and service_class_dataflow else "ACTION_ONLY_DEFAULT_SERVICE_CLASS=NOT_PROVEN",
 "SDK_WITHPOOLANDSERVICECLASS_DECLARATION_PRESENT="+("YES" if has_explicit_header else "NO"),
 "SDK_DECLARATION_DIRECTLY_MATCHES_TARGET_WITHPOOL_ABI="+("YES" if header_target_direct_compat else "NO"),
 "SDK_TARGET_API_MAPPING=NOT_EXPOSED_AS_MATCHING_OVERLOAD_IN_VENDORED_HEADER",
 "TARGET_SERVICE_CLASS_TRAILING_ARGUMENT_ORDER=AFTER_OPTIONS",
 "FOUR_TX_SUBMISSION_QUEUES_REQUIRED_BY_WMM=YES",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUES=1",
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
 "NEXT=The target dataflow identifies a trailing service-class argument, but the vendored SDK header exposes no matching withPool overload. Continue read-only API-surface review; do not change the header or source until separately authorized."
]
(out/"argument-dataflow-checks.txt").write_text("\n".join(["STAGE89_V10_ARGUMENT_DATAFLOW_CHECKS"]+[k+"="+("PASS" if v else "FAIL") for k,v in checks.items()])+"\n")
(out/"sdk-target-api-crosswalk.txt").write_text("\n".join([
 "STAGE89_V10_SDK_TARGET_API_CROSSWALK",
 "SDK_EXPLICIT_FACTORY_DECLARATION="+(header_line or "NOT_FOUND"),
 "TARGET_MAIN_WITHPOOL_SYMBOL="+target_main_symbol,
 "TARGET_FACTORY_PARAMETER_FLOW=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass",
 "TARGET_INIT_PARAMETER_FLOW=this,pool,serviceClass,capacity,queueId,owner,queryHandler,action,refCon,options",
 "TARGET_SERVICE_CLASS_DATAFLOW="+("PROVEN" if service_class_dataflow else "NOT_PROVEN"),
 "DIRECT_SDK_DECLARATION_MATCH=NO",
 "REASON=SDK named factory places serviceClass before owner; captured target withPool signature places its extra serviceClass UInt32 after options and uses a different method name",
 "IMPLEMENTATION_ACTION=NONE"
])+"\n")
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V10 — TXSUBMISSION SERVICE-CLASS ARGUMENT DATA-FLOW AUDIT ==========",
 *summary,"",
 "ARGUMENT DATA-FLOW CHECKS:",
 *(k+"="+("PASS" if v else "FAIL") for k,v in checks.items()),"",
 "TARGET FACTORY TO INIT DATA-FLOW:",
 "The target withPool factory loads the final stack UInt32 from [rbp+0x20] into EDX before its virtual init call. The captured initializer moves EDX into R15D and stores R15D at object offset 0xb8. This register-to-field chain proves the trailing factory UInt32 supplies the TX submission service-class field.",
 "The factory maps its first UInt32 through ECX to the initializer, where ECX is checked against the minimum capacity threshold 8. It maps the second UInt32 through R8D, then the initializer preserves that value as the queue identifier while preparing the base initializer call.",
 "The mutable-callback wrapper forwards the final stack UInt32 and options (with option bit 0x8 added) to the main factory. The action-only wrapper instead pushes -1 as the final UInt32; because the same path writes that argument into the service-class field, its default class is 0xffffffff.",
 "",
 "SDK DECLARATION LIMITATION:",
 "The vendored SDK declares withPoolAndServiceClass with serviceClass before owner. The target kernel inventory contains no exact withPoolAndServiceClass symbol. The target withPool overload carrying service class is a different symbol shape: two UInt32 arguments before owner and two trailing UInt32 arguments after refCon (options followed by service class). Thus the semantic role of the final target argument is established, but a source-level direct call through the vendored SDK declaration is not established and must not be guessed.",
 "",
 "REMAINING STAGE89 BLOCKERS:",
 "The source still constructs one TX submission queue, not four; no stable four-pointer array exists; no registration call exists; and four TX/RX callback handoffs remain incomplete. Do not implement the queue array by inventing an API declaration, reorder SDK arguments, or write private object fields.",
 "",
 "SAFETY:",
 "Read-only analysis of pinned V9 target-kernel evidence. No source/header modification, build, signing, installation, load, hardware test, SIP/NVRAM or OpenCore modification occurred."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
if not all(checks.values()):
    print("STAGE89_V10_RESULT=REVIEW_REQUIRED_CHECK_FAILURES",flush=True)
else:
    print("TARGET_FACTORY_FINAL_U32_IS_SERVICE_CLASS=PROVEN_BY_REGISTER_TO_FIELD_DATAFLOW",flush=True)
print("SDK_DECLARATION_DIRECTLY_MATCHES_TARGET_WITHPOOL_ABI=NO",flush=True)
print("STAGE89_V10_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V10 — TXSUBMISSION SERVICE-CLASS ARGUMENT DATA-FLOW AUDIT ==========
STAGE89_V10_RUN: $RUN
STAGE89_V10_VERSION: STAGE89_V10_20261105
STAGE89_V10_PREDECESSOR: $V9_RUN
STAGE89_V10_V9_EVIDENCE_PINS: PASS
STAGE89_V10_TARGET_FACTORY_FINAL_U32_SERVICE_CLASS: SEE_REPORT
STAGE89_V10_SDK_DIRECT_FACTORY_MAPPING: NOT_PROVEN
STAGE89_V10_FOUR_TX_SUBMISSION_QUEUES_REQUIRED: YES
STAGE89_V10_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1
STAGE89_V10_QUEUE_ARRAY: NOT_IMPLEMENTED
STAGE89_V10_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V10_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V10_SOURCE_MODIFIED: NO
STAGE89_V10_BUILD: NOT_RUN
STAGE89_V10_SIGNING: NOT_RUN
STAGE89_V10_INSTALL: NOT_RUN
STAGE89_V10_LOAD: NOT_RUN
STAGE89_V10_OPENCORE_CHANGE: NONE
STAGE89_V10_RESULT: REVIEW_REQUIRED
STAGE89_V10_ACTIVATION_GATE: BLOCKED
STAGE89_V10_LOGS: $REMOTE/
EOF

python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["argument-dataflow-checks.txt","sdk-target-api-crosswalk.txt","audit-summary.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V10_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in names:
 b=(out/name).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(name,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST
for f in "$OUT/argument-dataflow-checks.txt" "$OUT/sdk-target-api-crosswalk.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V10_RUN:" in old: raise SystemExit("V10 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V10 TX service-class argument dataflow audit","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
echo "STAGE89_V10_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
