#!/bin/bash
# Stage 89 V7 — queue-role/WMM cardinality and TX service-class factory ABI audit.
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/Realtek-WiFi-Native-macOS-Main (Local)"
SRC="$ROOT/driver/RTL88WiFi"
V6_RUN="run-20261104-122352-a8be252ec590"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage89-v7/$RUN"
REMOTE="Development/Logs/stage89-v7/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
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
 python3 - "$f" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage89 V7 queue-role/WMM topology and TX factory ABI audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 echo "UPLOAD_START=$remote BYTES=$(wc -c < "$f" | tr -d ' ') EXPECTED_SHA=$want"
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$remote" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$remote SHA=$got"; return 0; fi
  if ! gh api --method PUT "repos/$REPO/contents/$remote" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt"; then
   echo "UPLOAD_RETRY=$remote ATTEMPT=$attempt ERROR=$(tr '\n' ' ' < "$OUT/upload-error.txt" | cut -c1-220)"
  fi
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
   echo "STAGE89_V7_FAILURE"
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
echo "STAGE89_V7_RUN=$RUN"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"
echo "READ_ONLY=YES"

BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin v6-audit-summary.txt b337d23e8c4e6728d21007c22d9a514fdfb05882 "$BASE/stage89-v6/$V6_RUN/audit-summary.txt"
pin v6-method-disassembly.txt 74cfa4df545e860b60d1a6e77eb26aed2c052313 "$BASE/stage89-v6/$V6_RUN/native-queue-method-disassembly.txt"
pin v6-method-index.txt 93a03a3200dd5e7f4770c3602f92bfae02bcde19 "$BASE/stage89-v6/$V6_RUN/native-queue-method-index.txt"
pin v6-source-model.txt 29cfc3ae55af2e8e9bdc981d9807911875483891 "$BASE/stage89-v6/$V6_RUN/source-queue-construction-model.txt"
pin v6-factory-facts.txt 4eb4433d8ec67dee4ccaab9860ec7448b7c38ddb "$BASE/stage89-v6/$V6_RUN/native-queue-factory-performcommand-facts.txt"
pin v6-vtable-crosswalk.txt f661860e2b4214ff50ab658d103c2081e905b130 "$BASE/stage89-v6/$V6_RUN/native-queue-vtable-crosswalk.txt"
pin stage62-queueset-crosswalk.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51 "$BASE/stage62/run-20261102-161032-d54adc732d87/queueset-info-word-crosswalk.txt"
pin stage88-wmm-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin tx-submission-header.txt 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "https://raw.githubusercontent.com/$REPO/main/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
pin rx-submission-header.txt 8b10f9bc9610a71912b1dc91fc6933c3e635a0d4 "https://raw.githubusercontent.com/$REPO/main/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkRxSubmissionQueue.h"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-preflight.json"
python3 - "$OUT/output-preflight.json" "$V6_RUN" <<'PY'
import base64,json,re,sys
log=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
runs=re.findall(r"STAGE89_V6_RUN: (run-[A-Za-z0-9-]+)",log)
if not runs or runs[-1]!=sys.argv[2]: raise SystemExit("Latest V6 predecessor does not match pinned run")
if "STAGE89_V6_RESULT: REVIEW_REQUIRED" not in log: raise SystemExit("V6 REVIEW_REQUIRED checkpoint missing")
if "STAGE89_V7_RUN:" in log: raise SystemExit("A V7 checkpoint already exists; inspect it instead of duplicating")
print("PREDECESSOR_GATE=PASS V6_RUN="+runs[-1])
PY

python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/v6-method-disassembly.txt" "$OUT/v6-method-index.txt" "$OUT/v6-source-model.txt" "$OUT/stage62-queueset-crosswalk.txt" "$OUT/stage88-wmm-table.txt" "$OUT/tx-submission-header.txt" "$OUT/rx-submission-header.txt" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1])
expected={}
for line in pathlib.Path(sys.argv[2]).read_text(errors="replace").splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
ok=len(expected)==91 and len(actual)==91 and set(expected)==set(actual) and all(expected[k]==actual[k] for k in expected)
source_lines=["STAGE89_V7_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual),"RESULT="+("PASS" if ok else "REVIEW_REQUIRED")]
for k in sorted(set(expected)|set(actual)):
 if expected.get(k)!=actual.get(k): source_lines.append("MISMATCH="+k)
pathlib.Path(sys.argv[10],"source-tree-revalidation.txt").write_text("\n".join(source_lines)+"\n")
if not ok: raise SystemExit("Native source does not match Stage73 baseline")

dis=pathlib.Path(sys.argv[3]).read_text(errors="replace")
index=pathlib.Path(sys.argv[4]).read_text(errors="replace")
source_model=pathlib.Path(sys.argv[5]).read_text(errors="replace")
qcross=pathlib.Path(sys.argv[6]).read_text(errors="replace")
wmm=pathlib.Path(sys.argv[7]).read_text(errors="replace")
txh=pathlib.Path(sys.argv[8]).read_text(errors="replace")
rxh=pathlib.Path(sys.argv[9]).read_text(errors="replace")
def get_method(fragment):
 blocks=re.split(r"(?=^===== ADDRESS=)",dis,flags=re.M)
 hits=[b for b in blocks if "SYMBOL="+fragment in b.splitlines()[0] if b.splitlines()]
 if len(hits)!=1: raise SystemExit("Expected exactly one disassembly method for "+fragment+" got "+str(len(hits)))
 return hits[0]
symbols={
 "tx_submit":"__ZN26IOSkywalkTxSubmissionQueue14performCommandEjPvm",
 "tx_complete":"__ZN26IOSkywalkTxCompletionQueue14performCommandEjPvm",
 "rx_submit":"__ZN26IOSkywalkRxSubmissionQueue14performCommandEjPvm",
 "rx_complete":"__ZN26IOSkywalkRxCompletionQueue14performCommandEjPvm",
 "queueset_init":"__ZN17IOSkywalkQueueSet14initWithQueuesEPP20IOSkywalkPacketQueuemPNS_14QueueSetInfo_sE",
 "wmm_predicate":"__ZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuem",
 "base_init":"__ZN20IOSkywalkPacketQueue12initWithPoolEP25IOSkywalkPacketBufferPooljjjjP8OSObjectPFvS3_zEPv",
 "tx_init":"__ZN26IOSkywalkTxSubmissionQueue12initWithPoolEP25IOSkywalkPacketBufferPooljjjP8OSObjectPFjS3_PS_PjEPFjS3_S4_PKP15IOSkywalkPacketjPvESC_j",
 "tx_factory_main":"__ZN26IOSkywalkTxSubmissionQueue8withPoolEP25IOSkywalkPacketBufferPooljjP8OSObjectPFjS3_PS_PjEPFjS3_S4_PKP15IOSkywalkPacketjPvESC_jj",
 "tx_factory_default":"__ZN26IOSkywalkTxSubmissionQueue8withPoolEP25IOSkywalkPacketBufferPooljjP8OSObjectPFjS3_PS_PKP15IOSkywalkPacketjPvES9_j"
}
methods={k:get_method(v) for k,v in symbols.items()}
role_patterns={
 "TX_SUBMISSION":r"mov\s+dword ptr \[rdx\],\s*0x1",
 "TX_COMPLETION":r"mov\s+qword ptr \[rdx\],\s*0x2",
 "RX_SUBMISSION":r"mov\s+qword ptr \[rdx\],\s*0x3",
 "RX_COMPLETION":r"mov\s+dword ptr \[rdx\],\s*0x4"
}
role_rows=["STAGE89_V7_NATIVE_QUEUE_ROLE_CODE_MAP"]
role_values={}
for name,pat in role_patterns.items():
 m=re.search(pat,methods[{"TX_SUBMISSION":"tx_submit","TX_COMPLETION":"tx_complete","RX_SUBMISSION":"rx_submit","RX_COMPLETION":"rx_complete"}[name]],re.I)
 if not m: raise SystemExit("Could not prove performCommand type code for "+name)
 val=int(re.search(r"0x([1-4])",m.group(0)).group(1),16)
 role_values[name]=val
 role_rows.append("ROLE=%s PERFORMCOMMAND_TYPE_CODE=%d EVIDENCE=%s"%(name,val,m.group(0)))

# QueueSet first groups every supplied queue by performCommand type code 1..4.
qi=methods["queueset_init"]
grouping_proven=("cmp eax, 0x3" in qi and "dec eax" in qi and
                 "mov qword ptr [r14 + 0x20]" in qi and
                 "mov qword ptr [r14 + 0x30]" in qi and
                 "mov qword ptr [r14 + 0x38]" in qi)
# The WMM predicate is invoked with role-1 queue array and its count.
wmm_call=("mov\trdi, qword ptr [r14 + 0x20]" in qi and
          "mov\trsi, qword ptr [r14 + 0x60]" in qi and
          "call\t0xffffff800298ac44" in qi)
# It only asks a queue for its mServiceClass when performCommand returns role 1.
wp=methods["wmm_predicate"]
wmm_role1=("cmp\tdword ptr [rbp - 0x50], 0x1" in wp and
           "call\t0xffffff8002980bb0" in wp)
four_exact=("cmp\tdword ptr [rbp + 4*rcx - 0x40], 0x1" in wp and
            "cmp\trcx, 0x3" in wp)
if not (grouping_proven and wmm_call and wmm_role1 and four_exact):
 raise SystemExit("QueueSet role grouping / WMM role-1 cardinality evidence is incomplete")

# Native TXSubmission simple factory sends 0xffffffff as the hidden final service class.
factory_default=methods["tx_factory_default"]
factory_main=methods["tx_factory_main"]
tx_init=methods["tx_init"]
base=methods["base_init"]
default_sentinel="push\t-0x1" in factory_default
main_forwards_arg9=("mov\tedx, dword ptr [rbp + 0x20]" in factory_main)
tx_init_assign=("mov\tr15d, edx" in tx_init and "mov\tdword ptr [rbx + 0xb8], r15d" in tx_init)
base_default=("mov\tdword ptr [rbx + 0xb8], 0xffffffff" in base)
if not (default_sentinel and main_forwards_arg9 and tx_init_assign and base_default):
 raise SystemExit("Could not reconstruct TXSubmission default service-class constructor chain")

# Target factory method index contains withPool variants but no matching named
# withPoolAndServiceClass symbol. Keep this separate from the header declaration.
header_decl=bool(re.search(r"withPoolAndServiceClass\s*\(",txh))
target_named=( "withPoolAndServiceClass" in index )
tx_init_decl=re.search(r"initWithPool\s*\(\s*IOSkywalkPacketBufferPool\s*\*\s*pool\s*,([^;]+);",txh,re.S)
tx_init_order="UNPARSED"
if tx_init_decl:
 sig=tx_init_decl.group(1)
 tx_init_order="HEADER_ORDER_CAPACITY_QUEUEID_SERVICECLASS" if re.search(r"capacity[^,]*,\s*UInt32\s+queueId[^,]*,\s*kern_packet_svc_class_t\s+serviceClass",sig) else "HEADER_ORDER_REVIEW_REQUIRED"
# The target constructor stores the first UInt32 after pool from EDX into mServiceClass.
# Its internal factory maps its extra final stack argument to EDX.
target_order=("TARGET_INIT_FIRST_U32_AFTER_POOL_IS_M_SERVICE_CLASS" if tx_init_assign else "UNPROVEN")
rx_init_symbol="__ZN26IOSkywalkRxSubmissionQueue12initWithPoolEP25IOSkywalkPacketBufferPooljjjP8OSObjectPFjS3_PS_PKP15IOSkywalkPacketjPvES9_j"
rx_init=get_method(rx_init_symbol)
rx_default_path=("mov\tdword ptr [rbx + 0x110], r15d" in rx_init and
                 "call\tqword ptr [r11 + 0x240]" in rx_init and
                 "mov\tdword ptr [rbx + 0xb8]" not in rx_init)
source_counts={}
for line in source_model.splitlines():
 m=re.match(r"CALL_COUNT\|(.+)\|(\d+)$",line)
 if m: source_counts[m.group(1)]=int(m.group(2))
tx_count=source_counts.get("IOSkywalkTxSubmissionQueue::withPool",0)+source_counts.get("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass",0)
other_counts={k:source_counts.get("IOSkywalk"+k+"Queue::withPool",0) for k in ["TxCompletion","RxSubmission","RxCompletion"]}
wmm_values=re.findall(r"^WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]{8})",wmm,re.M)
if len(wmm_values)!=4: raise SystemExit("Expected four pinned WMM service class values")
if not all(x in wmm for x in wmm_values): raise SystemExit("WMM table values are not pinned")

# Source creates one of each native queue role, but WMM class counts are over role 1.
current_total=tx_count+sum(other_counts.values())
current_role_counts={
 "TX_SUBMISSION":tx_count,
 "TX_COMPLETION":other_counts["TxCompletion"],
 "RX_SUBMISSION":other_counts["RxSubmission"],
 "RX_COMPLETION":other_counts["RxCompletion"]
}
current_cardinality=all(v==1 for v in current_role_counts.values())
topology_rows=[
 "STAGE89_V7_QUEUE_ROLE_WMM_CARDINALITY_ANALYSIS",
 "QUEUE_ROLE_TYPE_CODE_SOURCE=performCommand(0x10000, 16-byte-result)",
 *role_rows[1:],
 "QUEUESET_ROLE_GROUPING="+("PROVEN" if grouping_proven else "NOT_PROVEN"),
 "QUEUESET_WMM_INPUT_ARRAY=ROLE_1_TX_SUBMISSION_ARRAY",
 "QUEUESET_WMM_INPUT_COUNT=ROLE_1_TX_SUBMISSION_COUNT",
 "QUEUESET_WMM_INPUT_CROSSWALK="+("PROVEN" if wmm_call else "NOT_PROVEN"),
 "WMM_GETSERVICECLASS_FILTER=ROLE_1_ONLY",
 "WMM_FILTER_EVIDENCE="+("PROVEN" if wmm_role1 else "NOT_PROVEN"),
 "WMM_CARDINALITY=EXACTLY_ONE_OF_EACH_OF_FOUR_WMM_VALUES",
 "WMM_CARDINALITY_EVIDENCE="+("PROVEN" if four_exact else "NOT_PROVEN"),
 "WMM_VALUES="+",".join(wmm_values),
 "CURRENT_SOURCE_ROLE_COUNTS="+",".join(k+":"+str(v) for k,v in current_role_counts.items()),
 "CURRENT_SOURCE_TOTAL_QUEUE_OBJECTS="+str(current_total),
 "CURRENT_SOURCE_ROLE_CARDINALITY="+("ONE_EACH_ROLE" if current_cardinality else "OTHER"),
 "CURRENT_SOURCE_ROLE_1_WMM_QUEUE_COUNT="+str(current_role_counts["TX_SUBMISSION"]),
 "CURRENT_SOURCE_CAN_SATISFY_FOUR_WMM_CLASSES="+("YES" if current_role_counts["TX_SUBMISSION"]>=4 else "NO"),
 "WMM_MINIMUM_ROLE_1_TX_SUBMISSION_QUEUES=4",
 "ADDITIONAL_ROLE_2_3_4_QUEUE_COUNTS=REGISTRATION_CALLBACK_PLAN_REVIEW_REQUIRED",
 "SEVEN_QUEUE_TOPOLOGY=FOUR_TX_SUBMISSION_PLUS_ONE_EACH_OTHER_ROLE (CANDIDATE_ONLY)",
 "SEVEN_QUEUE_TOPOLOGY_STATUS=NOT_YET_AUTHORIZED_OR_IMPLEMENTED"
]
pathlib.Path(sys.argv[10],"queue-role-wmm-cardinality-analysis.txt").write_text("\n".join(topology_rows)+"\n")

factory_rows=[
 "STAGE89_V7_TX_SUBMISSION_FACTORY_ARGUMENT_ABI_CROSSWALK",
 "TARGET_KERNEL_FACTORY_MAIN_SYMBOL=withPool overload with an additional final UInt32 argument",
 "TARGET_SIMPLE_FACTORY_WRAPPER_PUSHES_DEFAULT_SERVICE_CLASS=0xffffffff",
 "TARGET_FACTORY_FORWARDS_EXTRA_FINAL_ARGUMENT_TO_INIT_EDX="+("YES" if main_forwards_arg9 else "NO"),
 "TARGET_INIT_STORES_FIRST_UINT32_AFTER_POOL_TO_M_SERVICE_CLASS="+("YES" if tx_init_assign else "NO"),
 "TARGET_BASE_QUEUE_INIT_DEFAULTS_M_SERVICE_CLASS_TO_0xffffffff="+("YES" if base_default else "NO"),
 "DEFAULT_SIMPLE_WITHPOOL_SERVICE_CLASS=0xffffffff",
 "SDK_HEADER_DECLARES_WITHPOOLANDSERVICECLASS="+("YES" if header_decl else "NO"),
 "TARGET_METHOD_INDEX_CONTAINS_WITHPOOLANDSERVICECLASS_SYMBOL="+("YES" if target_named else "NO"),
 "SDK_INITWITHPOOL_PARAMETER_ORDER="+tx_init_order,
 "TARGET_INITWITHPOOL_ARGUMENT_ORDER="+target_order,
 "SDK_DECLARATION_TO_TARGET_ABI_ORDER_MATCH="+("YES" if tx_init_order=="HEADER_ORDER_CAPACITY_QUEUEID_SERVICECLASS" and target_order=="TARGET_INIT_FIRST_U32_AFTER_POOL_IS_M_SERVICE_CLASS" else "NOT_PROVEN"),
 "RX_SUBMISSION_BASE_INIT_PATH_PRESERVES_BASE_M_SERVICE_CLASS_SENTINEL="+("YES" if rx_default_path else "NOT_PROVEN"),
 "TX_FACTORY_ASSIGNMENT_PATH_USABLE_WITH_CURRENT_PUBLIC_HEADER=NOT_PROVEN",
 "SOURCE_CURRENTLY_CALLS_EXPLICIT_SERVICECLASS_FACTORY="+("YES" if "WMM_FACTORY_CURRENTLY_USED=YES" in source_model else "NO"),
 "ABI_REVIEW=REQUIRED_BEFORE_ANY_TX_SERVICECLASS_CALL"
]
pathlib.Path(sys.argv[10],"tx-submission-factory-abi-crosswalk.txt").write_text("\n".join(factory_rows)+"\n")

summary=[
 "STAGE89_V7_QUEUE_ROLE_WMM_CARDINALITY_AND_TX_FACTORY_ABI_AUDIT",
 "VERSION=STAGE89_V7_20261104",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "SOURCE_TREE_REVALIDATION=PASS",
 "QUEUE_ROLE_CODES=1:TX_SUBMISSION,2:TX_COMPLETION,3:RX_SUBMISSION,4:RX_COMPLETION",
 "QUEUESET_WMM_INPUT=ROLE_1_TX_SUBMISSION_ARRAY",
 "WMM_REQUIRES_EXACTLY_ONE_OF_EACH_FOUR_VALUES_IN_ROLE_1_ARRAY=YES",
 "WMM_CLASS_VALUES="+",".join(wmm_values),
 "CURRENT_SOURCE_TX_SUBMISSION_QUEUE_COUNT="+str(tx_count),
 "CURRENT_SOURCE_OTHER_ROLE_QUEUE_COUNTS="+",".join(k+":"+str(v) for k,v in other_counts.items()),
 "CURRENT_SOURCE_WMM_ROLE_1_CARDINALITY=INSUFFICIENT",
 "TX_SIMPLE_WITHPOOL_DEFAULT_SERVICE_CLASS=0xffffffff",
 "TARGET_WITHPOOL_EXTRA_ARGUMENT_ABI=FOUND",
 "WITHPOOLANDSERVICECLASS_TARGET_SYMBOL=NOT_FOUND_IN_SELECTED_TARGET_METHOD_INDEX",
 "HEADER_TO_TARGET_INIT_ABI=REVIEW_REQUIRED",
 "ROLE_1_FOUR_QUEUE_CONSTRUCTION=NOT_IMPLEMENTED",
 "STABLE_QUEUE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "OTHER_QUEUE_ROLE_COUNTS=REQUIRES_REVIEW",
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
 "NEXT=Manually resolve the target TX factory ABI and decide the complete queue-role counts. Then implement and test Stage89 only under explicit implementation authorization; Stage90 remains blocked."
]
pathlib.Path(sys.argv[10],"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 89 V7 — QUEUE ROLE / WMM CARDINALITY / TX FACTORY ABI ==========",
 *summary,"",
 "QUEUE ROLE AND WMM CARDINALITY:",*topology_rows,"",
 "TX SUBMISSION FACTORY ARGUMENT ABI:",*factory_rows,"",
 "SOURCE CONSTRUCTION MODEL:",source_model,"",
 "STAGE62 QUEUESET CONTROL-WORD CROSSWALK:",qcross,"",
 "INTERPRETATION:",
 "performCommand(0x10000) identifies four queue roles. The QueueSet WMM predicate receives only the role-1 TX-submission queue array and requires exactly one of each of the four WMM service-class values in that array. A single TX-submission object cannot satisfy that condition.",
 "The current native source creates one object of each role. A candidate WMM topology therefore needs four TX-submission queue instances plus the other role queues required by the intended callback/registration plan. A seven-object topology is a candidate, not an approved implementation assumption.",
 "The TXSubmission simple withPool wrapper passes 0xffffffff as the service class. The target has a lower-level withPool overload with an extra final UInt32 argument, but the local SDK names a different withPoolAndServiceClass factory and the initWithPool parameter order requires ABI review. Do not call a guessed overload.",
 "",
 "SAFETY:",
 "No source files changed. No build, signing, installation, loading, hardware test, SIP/NVRAM change or OpenCore modification occurred.",
 "Stage90 ownership/rollback work is not started because Stage89 queue construction and stable pointer-array exit criteria remain unmet."
]
pathlib.Path(sys.argv[10],"report.txt").write_text("\n".join(report)+"\n")
print("QUEUE_ROLE_CODES=1/2/3/4",flush=True)
print("WMM_INPUT_ROLE=1_TX_SUBMISSION",flush=True)
print("WMM_EXACT_CARDINALITY=ONE_OF_EACH_FOUR",flush=True)
print("CURRENT_TX_SUBMISSION_QUEUES=%d"%tx_count,flush=True)
print("TARGET_TX_SIMPLE_WITHPOOL_DEFAULT=0xffffffff",flush=True)
print("STAGE89_V7_RESULT=REVIEW_REQUIRED",flush=True)
PY

cat > "$OUT/checkpoint-block.txt" <<EOF
========== STAGE 89 V7 — QUEUE ROLE / WMM CARDINALITY / TX FACTORY ABI ==========
STAGE89_V7_RUN: $RUN
STAGE89_V7_VERSION: STAGE89_V7_20261104
STAGE89_V7_PREDECESSOR: $V6_RUN
STAGE89_V7_SOURCE_TREE_REVALIDATION: PASS
STAGE89_V7_QUEUE_ROLE_MAP: 1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION
STAGE89_V7_WMM_INPUT: ROLE_1_TX_SUBMISSION_ARRAY
STAGE89_V7_WMM_CARDINALITY: EXACTLY_ONE_OF_EACH_FOUR
STAGE89_V7_CURRENT_TX_SUBMISSION_QUEUE_COUNT: 1
STAGE89_V7_TX_SIMPLE_WITHPOOL_DEFAULT: 0xffffffff
STAGE89_V7_TARGET_TX_FACTORY_ABI: REVIEW_REQUIRED
STAGE89_V7_QUEUE_ARRAY: NOT_IMPLEMENTED
STAGE89_V7_CALLBACK_HANDOFFS_STILL_MISSING: 4
STAGE89_V7_IMPLEMENTATION_AUTHORIZATION: NO
STAGE89_V7_SOURCE_MODIFIED: NO
STAGE89_V7_BUILD: NOT_RUN
STAGE89_V7_SIGNING: NOT_RUN
STAGE89_V7_INSTALL: NOT_RUN
STAGE89_V7_LOAD: NOT_RUN
STAGE89_V7_OPENCORE_CHANGE: NONE
STAGE89_V7_RESULT: REVIEW_REQUIRED
STAGE89_V7_ACTIVATION_GATE: BLOCKED
STAGE89_V7_LOGS: $REMOTE/
EOF
python3 - "$OUT" <<'PY'
import hashlib,pathlib,sys
out=pathlib.Path(sys.argv[1])
names=["source-tree-revalidation.txt","queue-role-wmm-cardinality-analysis.txt","tx-submission-factory-abi-crosswalk.txt","audit-summary.txt","report.txt","checkpoint-block.txt"]
rows=["STAGE89_V7_MANIFEST","RUN="+out.name,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for n in names:
 b=(out/n).read_bytes()
 sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 rows.append("ARTIFACT|%s|%s|%d"%(n,sha,len(b)))
(out/"manifest.txt").write_text("\n".join(rows)+"\n")
PY
for f in \
 "$OUT/source-tree-revalidation.txt" \
 "$OUT/queue-role-wmm-cardinality-analysis.txt" \
 "$OUT/tx-submission-factory-abi-crosswalk.txt" \
 "$OUT/audit-summary.txt" "$OUT/report.txt" "$OUT/checkpoint-block.txt" "$OUT/manifest.txt"; do
 upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub upload/readback failed: $(basename "$f")"
done

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/checkpoint-block.txt" "$OUT/output-updated.txt" "$OUT/output-payload.json" <<'PY'
import base64,json,pathlib,sys
cur=json.load(open(sys.argv[1]))
old=base64.b64decode(cur["content"]).decode(errors="replace")
if "STAGE89_V7_RUN:" in old: raise SystemExit("V7 checkpoint already exists; refusing duplicate")
new=old.rstrip()+"\n\n"+pathlib.Path(sys.argv[2]).read_text()
pathlib.Path(sys.argv[3]).write_text(new)
pathlib.Path(sys.argv[4]).write_text(json.dumps({"message":"Record Stage89 V7 role/WMM cardinality and TX factory ABI audit","content":base64.b64encode(new.encode()).decode(),"sha":cur["sha"]}))
PY
LOG_WANT="$(blob "$OUT/output-updated.txt")"
LOG_OK=NO
for attempt in 1 2 3 4; do
 if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-update-response.json" 2> "$OUT/output-update-error.txt"; then echo "CANONICAL_LOG_UPDATE_ATTEMPT=$attempt"; fi
 LOG_GOT="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha 2>/dev/null || true)"
 if [[ "$LOG_GOT" == "$LOG_WANT" ]]; then LOG_OK=YES; break; fi
 sleep 2
done
[[ "$LOG_OK" == "YES" ]] || fail "Canonical Development/output.log SHA readback failed"
echo "CANONICAL_LOG_VERIFIED=YES SHA=$LOG_GOT"
echo "STAGE89_V7_RESULT=REVIEW_REQUIRED"
echo "GITHUB_LOGS=$REMOTE/"
echo "LOCAL_LOGS=$OUT"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
