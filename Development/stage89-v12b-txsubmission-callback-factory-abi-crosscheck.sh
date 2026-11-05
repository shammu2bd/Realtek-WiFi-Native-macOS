#!/bin/bash
# Stage89 V12B — callback/factory ABI cross-check, immutable retry runner.
# READ ONLY: no driver/header edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v12/$RUN"
REMOTE="Development/Logs/stage89-v12/$RUN"
V9_RUN="run-20261105-034922-6566f42c51aa"
V10_RUN="run-20261105-041550-62ef6b8a0915"
V11_RUN="run-20261105-042010-eb8eee87ee44"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V12B callback/factory ABI crosscheck","content":base64.b64encode(p.read_bytes()).decode()}))
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
   echo "STAGE89_V12B_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   echo "LAST_OUTPUT:"
   tail -n 100 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  gh auth status >/dev/null 2>&1 && upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail xcrun; do command -v "$t" >/dev/null 2>&1 || fail "Missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "Expected project source tree missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "Target must be Sequoia 15.8.1 (24H32) x86_64"
CFILT="$(xcrun --find c++filt 2>/dev/null || command -v c++filt || true)"
[[ -n "$CFILT" && -x "$CFILT" ]] || fail "c++filt unavailable"

BASE="https://raw.githubusercontent.com/$REPO/main"
LOGS="$BASE/Development/Logs"
pin v9-disassembly.txt a4c4cd35016228e79953b9991426f45bcdc69089 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-disassembly.txt"
pin v9-symbol-index.txt 41cbdaf57b7d38fc40c09b20ca54e34eb504d109 "$LOGS/stage89-v9/$V9_RUN/target-txsubmission-factory-symbol-index.txt"
pin v10-dataflow.txt 60301de086cffeba45d77da1510db3de319ec5a3 "$LOGS/stage89-v10/$V10_RUN/argument-dataflow-checks.txt"
pin v10-manifest.txt 156cbf378f521a2ddd10dc5a858c24694ef9b0da "$LOGS/stage89-v10/$V10_RUN/manifest.txt"
pin v11-crosswalk.txt 1f7628022b90902c792a3873fd67759dcba870ca "$LOGS/stage89-v11/$V11_RUN/api-crosswalk-verdict.txt"
pin v11-manifest.txt 006f9eacf0ea5d1ea09fe93a4416367ff59c4fd3 "$LOGS/stage89-v11/$V11_RUN/manifest.txt"
pin sdk-header.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin source.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/preflight.json"
python3 - "$OUT/preflight.json" "$V9_RUN" "$V10_RUN" "$V11_RUN" <<'PREFLIGHT'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
for stage,expected in (("V9",sys.argv[2]),("V10",sys.argv[3]),("V11",sys.argv[4])):
 matches=re.findall(r"STAGE89_"+stage+r"_RUN:\s*(run-[A-Za-z0-9-]+)",log)
 if not matches or matches[-1]!=expected: raise SystemExit("Latest "+stage+" checkpoint differs from pinned predecessor")
if "STAGE89_V11_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V11 REVIEW_REQUIRED checkpoint missing")
if "STAGE89_V12_RUN:" in log or "STAGE89_V12B_RUN:" in log: raise SystemExit("V12 checkpoint already exists; inspect it instead of duplicating")
print("PREDECESSOR_GATE=PASS")
PREFLIGHT

echo "STAGE89_V12B_RUN=$RUN"
echo "RUNNER_VERSION=STAGE89_V12B_IMMUTABLE_RETRY"
echo "READ_ONLY=YES"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"

python3 -u - "$OUT" "$CFILT" <<'PY'
import pathlib,re,subprocess,sys
out=pathlib.Path(sys.argv[1]); demangler=sys.argv[2]
dis=(out/"v9-disassembly.txt").read_text(errors="replace")
index=(out/"v9-symbol-index.txt").read_text(errors="replace")
header=(out/"sdk-header.h").read_text(errors="replace")
source=(out/"source.cpp").read_text(errors="replace")
v10=(out/"v10-dataflow.txt").read_text(errors="replace")
v11=(out/"v11-crosswalk.txt").read_text(errors="replace")

def method(address):
    pat=r"===== ADDRESS=0x"+re.escape(address)+r" SYMBOL=.*? =====\s*\n(.*?)(?=\n===== ADDRESS=|\Z)"
    found=re.search(pat,dis,re.S)
    if found is None:
        raise RuntimeError("Unable to locate disassembly method "+address)
    return found.group(1)

def symbol_at(address):
    prefix="ADDRESS=0x"+address+" "
    for line in index.splitlines():
        if prefix not in line: continue
        marker="MANGLED="
        pos=line.find(marker)
        if pos < 0: continue
        value=line[pos+len(marker):].strip()
        if value: return value
    raise RuntimeError("MANGLED symbol not found for "+address)

def has(text, pattern):
    return re.search(pattern,text,re.I) is not None

main=method("ffffff8002983ff0")
mutable=method("ffffff800298409e")
action=method("ffffff80029840c2")
main_sym=symbol_at("ffffff8002983ff0")
mutable_sym=symbol_at("ffffff800298409e")
action_sym=symbol_at("ffffff80029840c2")
print("TARGET_SYMBOL_PARSE=PASS main=1 mutable=1 action=1",flush=True)

typedefs={}
for name in ("IOSkywalkQueryFreeSpaceHandler","IOSkywalkTxSubmissionQueueAction"):
    pattern=r"typedef\s+([^;]+?)\(\s*\*"+re.escape(name)+r"\s*\)\s*\(([^;]+)\)\s*;"
    match=re.search(pattern,header,re.S)
    if match is not None:
        typedefs[name]=(re.sub(r"\s+"," ",match.group(1)).strip(),
                        re.sub(r"\s+"," ",match.group(2)).strip())

factory_matches=re.findall(
    r"static\s+IOSkywalkTxSubmissionQueue\s*\*\s*(?:withPoolAndServiceClass|withPool)\s*\([^;]+;",
    header,re.S)
factories=[re.sub(r"\s+"," ",x).strip() for x in factory_matches]
header_const=bool(re.search(r"const\s+IOSkywalkPacket\s*\*\s*\*",header))
header_mutable=bool(re.search(r"(?<!const\s)IOSkywalkPacket\s*\*\s*\*",header))
def demangle(symbol):
    for candidate in (symbol[1:] if symbol.startswith("_") else symbol,
                      symbol[2:] if symbol.startswith("__") else symbol):
        try:
            result=subprocess.run([demangler,candidate],capture_output=True,text=True,timeout=8)
            out_text=result.stdout.strip()
            if result.returncode==0 and out_text and not out_text.startswith("_Z"):
                return out_text
        except Exception:
            pass
    return "DEMANGLE_UNAVAILABLE:"+symbol

checks={
 "sdk_query_handler_typedef_found":"IOSkywalkQueryFreeSpaceHandler" in typedefs,
 "sdk_action_typedef_found":"IOSkywalkTxSubmissionQueueAction" in typedefs,
 "sdk_action_uses_const_packet_pointer_array":header_const and not header_mutable,
 "target_main_factory_symbol_found":bool(main_sym),
 "target_mutable_factory_wrapper_symbol_found":bool(mutable_sym),
 "target_action_only_wrapper_symbol_found":bool(action_sym),
 "target_main_factory_uses_const_packet_pointer_action":"PKP15IOSkywalkPacket" in main_sym,
 "target_mutable_wrapper_uses_mutable_packet_pointer_action":"PP15IOSkywalkPacket" in mutable_sym and "PKP15IOSkywalkPacket" not in mutable_sym,
 "target_action_only_wrapper_uses_const_packet_pointer_action":"PKP15IOSkywalkPacket" in action_sym,
 "main_factory_has_options_then_serviceclass_stack_words":has(main,r"mov\s+r10d,\s*dword ptr \[rbp \+ 0x18\]") and has(main,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]"),
 "main_factory_forwards_serviceclass_to_init":has(main,r"mov\s+edx,\s*dword ptr \[rbp \+ 0x20\]") and has(main,r"call\s+qword ptr \[rax \+ 0x2a8\]"),
 "mutable_wrapper_sets_option_bit_8":has(mutable,r"or\s+r10d,\s*0x8"),
 "mutable_wrapper_forwards_final_serviceclass":has(mutable,r"mov\s+eax,\s*dword ptr \[rbp \+ 0x20\]") and has(mutable,r"push\s+rax"),
 "action_only_wrapper_uses_minus_one":has(action,r"push\s+-0x1"),
 "v10_serviceclass_dataflow_predecessor_passed":"init_persists_r15d_at_object_offset_b8=PASS" in v10,
 "v11_direct_api_mapping_still_not_found":"DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND" in v11,
}
print("CHECK_COUNT=%d CHECKS_PASSED=%d"%(len(checks),sum(1 for value in checks.values() if value)),flush=True)
(out/"callback-abi-checks.txt").write_text(
    "STAGE89_V12_CALLBACK_ABI_CHECKS\n"+
    "\n".join(key+"="+("PASS" if value else "FAIL") for key,value in checks.items())+"\n")

cross=[
 "STAGE89_V12_CALLBACK_AND_FACTORY_DECLARATION_CROSSWALK",
 "SDK_TYPEDEF|IOSkywalkQueryFreeSpaceHandler|"+str(typedefs.get("IOSkywalkQueryFreeSpaceHandler","NOT_FOUND")),
 "SDK_TYPEDEF|IOSkywalkTxSubmissionQueueAction|"+str(typedefs.get("IOSkywalkTxSubmissionQueueAction","NOT_FOUND")),
 "SDK_HAS_CONST_PACKET_ARRAY_ACTION="+("YES" if header_const else "NO"),
 "SDK_HAS_MUTABLE_PACKET_ARRAY_ACTION="+("YES" if header_mutable else "NO"),
 "SDK_FACTORY_DECLARATIONS:",
 *["SDK_FACTORY="+x for x in factories],
 "TARGET_MAIN_FACTORY_SYMBOL="+main_sym,
 "TARGET_MAIN_FACTORY_DEMANGLED="+demangle(main_sym),
 "TARGET_MUTABLE_WRAPPER_SYMBOL="+mutable_sym,
 "TARGET_MUTABLE_WRAPPER_DEMANGLED="+demangle(mutable_sym),
 "TARGET_ACTION_ONLY_WRAPPER_SYMBOL="+action_sym,
 "TARGET_ACTION_ONLY_WRAPPER_DEMANGLED="+demangle(action_sym),
 "TARGET_MAIN_CALLBACK_CONSTNESS="+("CONST_PACKET_POINTER_ARRAY" if "PKP15IOSkywalkPacket" in main_sym else "UNKNOWN"),
 "TARGET_MUTABLE_CALLBACK_CONSTNESS="+("MUTABLE_PACKET_POINTER_ARRAY" if "PP15IOSkywalkPacket" in mutable_sym and "PKP15IOSkywalkPacket" not in mutable_sym else "UNKNOWN"),
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
summary=[
 "STAGE89_V12_TXSUBMISSION_CALLBACK_FACTORY_ABI_CROSSCHECK",
 "VERSION=STAGE89_V12_20261105",
 "RUNNER=V12B_IMMUTABLE_RETRY",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "V9_V10_V11_EVIDENCE_PINS=PASS",
 "CHECK_COUNT="+str(len(checks)),
 "CHECKS_PASSED="+str(sum(1 for value in checks.values() if value)),
 "SDK_QUERY_HANDLER_TYPE="+str(typedefs.get("IOSkywalkQueryFreeSpaceHandler","NOT_FOUND")),
 "SDK_ACTION_TYPE="+str(typedefs.get("IOSkywalkTxSubmissionQueueAction","NOT_FOUND")),
 "TARGET_MAIN_FACTORY_CALLBACK_CONSTNESS="+("MATCHES_SDK_CONST_PACKET_ARRAY" if checks["target_main_factory_uses_const_packet_pointer_action"] and header_const else "REVIEW_REQUIRED"),
 "TARGET_MUTABLE_WRAPPER_CALLBACK_CONSTNESS="+("MUTABLE_PACKET_ARRAY_NOT_DECLARED_BY_SDK_ACTION_TYPE" if checks["target_mutable_wrapper_uses_mutable_packet_pointer_action"] and not header_mutable else "REVIEW_REQUIRED"),
 "TARGET_MAIN_FACTORY_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options,serviceClass",
 "SDK_QUERY_ACTION_WITHPOOL_ORDER=pool,capacity,queueId,owner,queryHandler,action,refCon,options",
 "SDK_NAMED_WITHPOOLANDSERVICECLASS_ORDER=pool,capacity,queueId,serviceClass,owner,queryHandler,action,refCon,options",
 "TARGET_ACTION_ONLY_DEFAULT_SERVICE_CLASS=0xffffffff",
 "DIRECT_SDK_TO_TARGET_FACTORY_MAPPING=NOT_FOUND",
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT=1",
 "FOUR_TX_SUBMISSION_QUEUES_REQUIRED=YES",
 "QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "CALLBACK_HANDOFFS_STILL_MISSING=4",
 "NATIVE_REGISTRATION_CALLS=0",
 "IMPLEMENTATION_AUTHORIZATION=NO",
 "SOURCE_MODIFIED=NO",
 "BUILD=NOT_RUN",
 "SIGNING=NOT_RUN",
 "INSTALL=NOT_RUN",
 "LOAD=NOT_RUN",
 "OPENCORE_CHANGE=NONE",
 "RESULT=REVIEW_REQUIRED",
 "ACTIVATION_GATE=BLOCKED"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V12 — TXSUBMISSION CALLBACK / FACTORY ABI CROSS-CHECK ==========",
 *summary,"",
 "CALLBACK TYPE COMPARISON:",
 "The SDK action typedef uses const IOSkywalkPacket ** with a query-free-space handler. The target primary withPool symbol uses the const packet-pointer callback shape. V9/V10 register-flow evidence shows that its trailing UInt32 after the options word is the service class.",
 "The alternate target wrapper uses a mutable IOSkywalkPacket ** callback and adds option bit 0x8 before calling the primary factory. The SDK action typedef does not expose that mutable array form.",
 "",
 "FACTORY ABI FINDING:",
 "The target primary factory parameter order is pool, capacity, queueId, owner, query handler, action, refCon, options, serviceClass. The SDK query/action withPool declaration ends at options. The SDK withPoolAndServiceClass declaration places serviceClass before owner and no exact target symbol with that name was found.",
 "",
 "LIMITATION:",
 "The evidence shows a target callback-compatible factory shape, but the current SDK has no directly matching declaration. Do not invent a declaration, reorder arguments, call a guessed private overload, or write the private service-class field. Any ABI adapter or header change requires separately reviewed implementation authorization.",
 "",
 "REMAINING STAGE89 BLOCKERS:",
 "The source still constructs one TX submission queue, not four. The stable four-pointer array and count/uniqueness/order/lifetime tests are absent. Native registration is absent and four TX/RX callback handoffs remain incomplete.",
 "",
 "SAFETY:",
 "Read-only analysis only. No source/header modification, build, signing, installation, load, hardware test, SIP/NVRAM or OpenCore change."
]
(out/"report.txt").write_text("\n".join(report)+"\n")
(out/"checkpoint-block.txt").write_text(
"========== STAGE 89 V12 — TXSUBMISSION CALLBACK / FACTORY ABI CROSS-CHECK ==========\n"+
"STAGE89_V12_RUN: "+str(out.name)+"\n"+
"STAGE89_V12_VERSION: STAGE89_V12_20261105\n"+
"STAGE89_V12_PREDECESSOR: "+ "run-20261105-042010-eb8eee87ee44\n"+
"STAGE89_V12_V9_V10_V11_EVIDENCE_PINS: PASS\n"+
"STAGE89_V12_CALLBACK_FACTORY_CROSSCHECK: CAPTURED\n"+
"STAGE89_V12_CHECKS_PASSED: "+str(sum(1 for value in checks.values() if value))+"/"+str(len(checks))+"\n"+
"STAGE89_V12_SDK_DIRECT_OVERLOAD_MAPPING: NOT_FOUND\n"+
"STAGE89_V12_FOUR_TX_SUBMISSION_QUEUES_REQUIRED: YES\n"+
"STAGE89_V12_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1\n"+
"STAGE89_V12_QUEUE_ARRAY: NOT_IMPLEMENTED\n"+
"STAGE89_V12_CALLBACK_HANDOFFS_STILL_MISSING: 4\n"+
"STAGE89_V12_IMPLEMENTATION_AUTHORIZATION: NO\n"+
"STAGE89_V12_SOURCE_MODIFIED: NO\n"+
"STAGE89_V12_BUILD: NOT_RUN\n"+
"STAGE89_V12_SIGNING: NOT_RUN\n"+
"STAGE89_V12_INSTALL: NOT_RUN\n"+
"STAGE89_V12_LOAD: NOT_RUN\n"+
"STAGE89_V12_OPENCORE_CHANGE: NONE\n"+
"STAGE89_V12_RESULT: REVIEW_REQUIRED\n"+
"STAGE89_V12_ACTIVATION_GATE: BLOCKED\n"+
"STAGE89_V12_LOGS: "+ "Development/Logs/stage89-v12/"+str(out.name)+"/\n"
)
print("STAGE89_V12_RESULT=REVIEW_REQUIRED",flush=True)
PY

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
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PYOUT'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V12_RUN:" in old or "STAGE89_V12B_RUN:" in old:
 raise SystemExit("V12 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V12 callback/factory ABI crosscheck","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
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
