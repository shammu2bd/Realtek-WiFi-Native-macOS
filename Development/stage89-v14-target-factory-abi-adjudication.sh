#!/bin/bash
# Stage89 V14 — target TX factory ABI adjudication and V13 audit-check correction.
# READ ONLY. No source/header changes, build, signing, install/load, hardware test, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v14/$RUN"
REMOTE="Development/Logs/stage89-v14/$RUN"
V13_RUN="run-20261105-044058-f70e48e79796"
V12_RUN="run-20261105-043238-9923f409a010"
V9_RUN="run-20261105-034922-6566f42c51aa"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V14 target factory ABI adjudication","content":base64.b64encode(p.read_bytes()).decode()}))
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
  { echo "STAGE89_V14_FAILURE"; echo "RUN=$RUN"; echo "EXIT=$rc"; tail -n 100 "$OUT/console-output.log" 2>/dev/null || true; } > "$OUT/failure-report.txt"
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
pin v13-checks.txt 495aca9f22f5eb6b844fc040ee0e701062cfe9eb "$LOGS/stage89-v13/$V13_RUN/adapter-feasibility-checks.txt"
pin v13-verdict.txt 40b397c7c3cc6892ddebc692973a1dc88d7adf12 "$LOGS/stage89-v13/$V13_RUN/adapter-feasibility-verdict.txt"
pin v12-crosswalk.txt 5c1afc5bd220a8da52e9dc9d6bfed6b7b8da6831 "$LOGS/stage89-v12/$V12_RUN/callback-factory-api-crosswalk.txt"
pin v9-symbol-index.txt 41cbdaf57b7d38fc40c09b20ca54e34eb504d109 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-symbol-index.txt"
pin v9-disassembly.txt a4c4cd35016228e79953b9991426f45bcdc69089 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-disassembly.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/preflight.json"
python3 - "$OUT/preflight.json" "$V13_RUN" <<'PREFLIGHT'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V13_RUN:\s*(run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]: raise SystemExit("Latest V13 checkpoint mismatch")
if "STAGE89_V14_RUN:" in log: raise SystemExit("V14 checkpoint already exists")
print("PREDECESSOR_GATE=PASS")
PREFLIGHT
echo "STAGE89_V14_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V14_ABI_ADJUDICATION"
echo "READ_ONLY=YES"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
python3 -u - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
v13=(out/"v13-checks.txt").read_text()
v12=(out/"v12-crosswalk.txt").read_text()
idx=(out/"v9-symbol-index.txt").read_text()
dis=(out/"v9-disassembly.txt").read_text()
checks={}
def add(k,v): checks[k]="PASS" if v else "FAIL"
add("v13_report_is_12_of_13","CHECKS_PASSED=12" in v13)
add("v13_failed_check_is_only_order_label_check","target_primary_factory_order_places_owner_before_handlers=FAIL" in v13 and v13.count("=FAIL")==1)
add("v12_records_actual_target_order", "TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass" in v12)
add("v12_records_target_serviceclass_after_options","TARGET_MAIN_EXTRA_STACK_U32S=2 (options then serviceClass)" in v12)
add("v12_records_sdk_named_serviceclass_before_owner","SDK_FACTORY=static IOSkywalkTxSubmissionQueue * withPoolAndServiceClass" in v12 and "UInt32 queueId, kern_packet_svc_class_t serviceClass, OSObject * owner" in v12)
add("v12_direct_sdk_mapping_not_found","SDK_TO_TARGET_DIRECT_OVERLOAD_MAPPING=NOT_FOUND" in v12)
add("target_primary_symbol_is_query_action_with_two_trailing_u32s","TARGET_MAIN_FACTORY_SYMBOL=" in v12 and re.search(r"TARGET_MAIN_FACTORY_SYMBOL=.*PKP15IOSkywalkPacket.*jj$",v12,re.M) is not None)
add("target_mutable_wrapper_is_separate_symbol","TARGET_MUTABLE_WRAPPER_SYMBOL=" in v12 and "PP15IOSkywalkPacket" in v12)
add("action_only_wrapper_is_separate_symbol","TARGET_ACTION_ONLY_WRAPPER_SYMBOL=" in v12 and "TARGET_ACTION_ONLY_SERVICE_CLASS_DEFAULT=0xffffffff" in v12)
add("symbol_inventory_has_four_methods","TXSUBMISSION_METHOD_SYMBOL_COUNT=4" in idx)
add("disassembly_shows_primary_factory_pushes_options_and_serviceclass","mov r10d, dword ptr [rbp + 0x18]" in dis and "mov edx, dword ptr [rbp + 0x20]" in dis and "push r10" in dis)
add("disassembly_shows_action_only_wrapper_pushes_minus_one","push -0x1" in dis)
add("disassembly_shows_mutable_wrapper_sets_option_bit_8","or r10d, 0x8" in dis)
add("no_public_thunk_or_exact_named_symbol_in_inventory","withPoolAndServiceClass" not in idx)
passed=sum(v=="PASS" for v in checks.values())
(out/"abi-adjudication-checks.txt").write_text("STAGE89_V14_ABI_ADJUDICATION_CHECKS\n"+"\n".join(k+"="+v for k,v in checks.items())+"\nCHECK_COUNT="+str(len(checks))+"\nCHECKS_PASSED="+str(passed)+"\n")
findings=[
"STAGE89_V14_TARGET_FACTORY_ABI_ADJUDICATION",
"V13_CHECK_CORRECTION=The single failed V13 check searched for TARGET_MAIN_FACTORY_ORDER in the V12 crosswalk, while V12 stores the same ordered ABI in its report summary under TARGET_MAIN_FACTORY_ORDER and its detailed crosswalk uses TARGET_MAIN_EXTRA_STACK_U32S plus the demangled symbol. Revalidation uses the pinned V12 crosswalk and symbol/disassembly evidence.",
"TARGET_PRIMARY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass",
"SDK_NAMED_WITHPOOLSERVICECLASS_ORDER=pool,capacity,queueId,serviceClass,owner,queryHandler,action,refCon,options",
"TARGET_PRIMARY_IS_NOT_DIRECTLY_DECLARED_BY_EXISTING_SDK=YES",
"TARGET_ACTION_ONLY_WRAPPER_DEFAULT_SERVICE_CLASS=0xffffffff",
"TARGET_MUTABLE_WRAPPER_ADDS_OPTION_BIT=0x8",
"EXISTING_PUBLIC_THUNK_PROVEN=NO",
"ABI_ADAPTER_DECISION=BLOCKED; do not cast/reinterpret SDK declarations, call guessed/private symbols, or write private fields",
"NEXT_ALLOWED_WORK=Read-only queue-construction and ownership requirements audit; implementation requires separate explicit authorization",
"STAGE89_EXIT=NOT_MET; four TX submission queues, stable pointer array, and tests are not implemented"
]
(out/"abi-adjudication-verdict.txt").write_text("\n".join(findings)+"\n")
report=[
"========== STAGE 89 V14 — TARGET FACTORY ABI ADJUDICATION ==========",
"RUN="+out.name,
"CHECK_COUNT="+str(len(checks)),
"CHECKS_PASSED="+str(passed),
"",
"V13 CHECK REVIEW:",
"The V13 12/13 result is explained by a field-name mismatch in its audit predicate. The V12 crosswalk does not contain the exact key string the V13 check searched for; the target order itself is corroborated by the pinned V12 demangled factory symbol and V9 disassembly, including separate options and service-class stack words.",
"",
"ABI RESULT:",
"The target primary factory order remains pool, capacity, queueId, owner, queryHandler, action, refCon, options, serviceClass. The public SDK withPoolAndServiceClass declaration orders serviceClass before owner. The target action-only wrapper supplies 0xffffffff, and the mutable wrapper is a separate callback shape that adds option bit 0x8. No direct public SDK symbol/thunk mapping is proven by this inventory.",
"",
"DECISION:",
"Do not treat V13's one failed predicate as evidence of an ABI change. The substantive adapter blocker remains. Do not use guessed overloads, casts, private mangled-symbol calls, or private field writes. A separately reviewed and explicitly authorized ABI adapter would be required before source/header changes.",
"",
"NEXT:",
"Proceed only with read-only queue-construction, queue-role, ownership/lifetime and pointer-array test-design audit. Stage89 remains open; Stage90 is locked.",
"",
"SAFETY:",
"Source/header modified=NO; build/sign/install/load/hardware test=NOT_RUN; OpenCore/SIP/NVRAM changes=NONE; known-good legacy kext and everyday EFI untouched."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
(out/"checkpoint-block.txt").write_text(
"========== STAGE 89 V14 — TARGET FACTORY ABI ADJUDICATION ==========\n"+
"STAGE89_V14_RUN: "+out.name+"\n"+
"STAGE89_V14_VERSION: STAGE89_V14_ABI_ADJUDICATION\n"+
"STAGE89_V14_PREDECESSOR: "+ "run-20261105-044058-f70e48e79796\n"+
"STAGE89_V14_EVIDENCE_PINS: PASS\n"+
"STAGE89_V14_CHECKS_PASSED: "+str(passed)+"/"+str(len(checks))+"\n"+
"STAGE89_V14_V13_FAILURE_CAUSE: AUDIT_PREDICATE_FIELD_NAME_MISMATCH\n"+
"STAGE89_V14_TARGET_SDK_DIRECT_MAPPING: NOT_PROVEN\n"+
"STAGE89_V14_ADAPTER_FEASIBILITY: BLOCKED\n"+
"STAGE89_V14_SOURCE_MODIFIED: NO\n"+
"STAGE89_V14_BUILD: NOT_RUN\n"+
"STAGE89_V14_SIGNING: NOT_RUN\n"+
"STAGE89_V14_INSTALL: NOT_RUN\n"+
"STAGE89_V14_LOAD: NOT_RUN\n"+
"STAGE89_V14_OPENCORE_CHANGE: NONE\n"+
"STAGE89_V14_RESULT: REVIEW_REQUIRED\n"+
"STAGE89_V14_ACTIVATION_GATE: BLOCKED\n"+
"STAGE89_V14_LOGS: Development/Logs/stage89-v14/"+out.name+"/\n")
print("STAGE89_V14_RESULT=REVIEW_REQUIRED",flush=True)
PY
python3 - "$OUT" <<'PYMANIFEST'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1]); names=["abi-adjudication-checks.txt","abi-adjudication-verdict.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V14_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(out/n).read_bytes(); sha=hashlib.sha1(b"blob "+str(len(b)).encode()+bytes([0])+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(n,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST
for f in "$OUT/abi-adjudication-checks.txt" "$OUT/abi-adjudication-verdict.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do upload "$f" "$REMOTE/$(basename "$f")" || fail "Upload/readback failed: $(basename "$f")"; done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1])); old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V14_RUN:" in old: raise SystemExit("V14 checkpoint already exists")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V14 target factory ABI adjudication","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
PYOUT
WANT="$(blob "$OUT/output-updated.txt")"; OK=NO
for attempt in 1 2 3 4; do
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-update-response.json" 2> "$OUT/output-update-error.txt" || true
 GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 if [[ "$GOT" == "$WANT" ]]; then OK=YES; break; fi
 sleep 2
done
[[ "$OK" == YES ]] || fail "Canonical output.log readback SHA mismatch"
echo "CANONICAL_LOG_VERIFIED=YES SHA=$GOT"
echo "STAGE89_V14_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
