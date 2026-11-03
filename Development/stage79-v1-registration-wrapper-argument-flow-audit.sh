#!/bin/bash
# Stage 79 V1 — 24H32 registration wrapper argument-flow audit.
# VERSION_MARKER: STAGE79_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage79/$RUN"
mkdir -p "$OUT"; exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=79"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/fail.json" <<'"'"'PY'"'"'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage79 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage79/$RUN/failure-report.txt" --input "$OUT/fail.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname wc tr tee date tail cut basename; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "source root not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes();print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ curl -fsSLo "$OUT/$1" "$3"; got="$(blob "$OUT/$1")"; [[ "$got" == "$2" ]] || fail "pin mismatch $1 got=$got expected=$2"; }
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage62-audit-summary.txt 99415ab0329a1973fd004e67d20da3b8acff7120 "$BASE/stage62/run-20261102-161032-d54adc732d87/audit-summary.txt"
pin stage62-method-status.txt f0d6e3bdfbc265453ed21e17df397f392f825625 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-status.txt"
pin stage62-method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-disassembly.txt"
pin stage75-audit-summary.txt 8bf032d3916517c990eb37ae015711e057011e50 "$BASE/stage75/run-20261102-182045-29fbc9d32933/audit-summary.txt"
pin stage78-audit-summary.txt fa4cd30bc3a6b9bf4674e531141a1f937c8f77d9 "$BASE/stage78/run-20261102-182749-501d7134ab5e/audit-summary.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
grep -q '^RESULT=PASS$' "$OUT/stage62-audit-summary.txt" || fail "Stage62 audit not PASS"
grep -q '^RESULT=PASS$' "$OUT/stage75-audit-summary.txt" || fail "Stage75 audit not PASS"
grep -q '^RESULT=PASS$' "$OUT/stage78-audit-summary.txt" || fail "Stage78 audit not PASS"
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" "$OUT/stage62-method-disassembly.txt" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3]);asm=pathlib.Path(sys.argv[4]).read_text(errors="replace");root=pathlib.Path(sys.argv[5])
expected={}
for l in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",l)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE79_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for p in sorted(set(expected)|set(actual)):
 a=expected.get(p,"MISSING");b=actual.get(p,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+p+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok:raise SystemExit("Stage73 source baseline mismatch")
markers={
"INFRA":"===== METHOD class=IO80211InfraInterface label=infra_registration_wrapper",
"ETHERNET":"===== METHOD class=IOSkywalkEthernetInterface label=ethernet_registration_wrapper",
"ARRAY":"===== METHOD class=IOSkywalkNetworkInterface label=queue_array_registration",
"LOGICAL":"===== METHOD class=IOSkywalkNetworkInterface label=logical_link_registration"}
parts={}
for k,m in markers.items():
 i=asm.find(m)
 if i<0:raise SystemExit("Apple disassembly method missing: "+k)
 j=asm.find("\n===== METHOD ",i+len(m));parts[k]=asm[i:j if j>=0 else len(asm)]
checks={
"INFRA_SAVES_INFO_QUEUE_ARRAY_COUNT_POOLS":all(x in parts["INFRA"] for x in ["mov r13, rsi","mov qword ptr [rbp - 0x78], rdx","mov r15d, ecx","mov qword ptr [rbp - 0x80], r8","mov r12, r9"]),
"INFRA_CALLS_ETHERNET_WRAPPER":"registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue" in parts["INFRA"],
"INFRA_SUPPLIES_ZERO_FINAL_OPTION":"push 0x0" in parts["INFRA"],
"ETHERNET_FORWARDS_ARRAY_AND_COUNT":all(x in parts["ETHERNET"] for x in ["mov rdx, r12","mov ecx, r15d"]),
"ETHERNET_FORWARDS_BOTH_POOL_REGISTERS":all(x in parts["ETHERNET"] for x in ["mov r8, r14","mov r9, qword ptr [rbp - 0x30]"]),
"ETHERNET_SETS_FINAL_OPTION_ZERO":"mov dword ptr [rsp], 0x0" in parts["ETHERNET"],
"ETHERNET_CALLS_GENERIC_ARRAY_OVERLOAD":"registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue" in parts["ETHERNET"],
"ARRAY_PASSES_COUNT_TO_WMM_AND_QUEUESET":"isWMMSchedModelCapable" in parts["ARRAY"] and "mov rsi, rbx" in parts["ARRAY"] and "createWithQueuesEPP20IOSkywalkPacketQueue" in parts["ARRAY"],
"ARRAY_SELECTS_QUEUESYSTEM_CONTROL_0X3_OR_0XB":"mov dword ptr [rbp - 0x84], 0x3" in parts["ARRAY"] and "mov dword ptr [rbp - 0x84], 0xb" in parts["ARRAY"],
"ARRAY_CREATES_ONE_LOGICAL_LINK":"mov esi, 0x1" in parts["ARRAY"] and "createWithQueueSet" in parts["ARRAY"],
"ARRAY_CALLS_LOGICAL_LINK_OVERLOAD":"registerNetworkInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLink" in parts["ARRAY"],
"LOGICAL_METHOD_CHECKS_REGISTRATION_INFO":"cmp dword ptr [r12], 0x1" in parts["LOGICAL"] and "cmp dword ptr [r12 + 0x4], 0x108" in parts["LOGICAL"]}
outrows=["STAGE79_REGISTRATION_WRAPPER_ARGUMENT_FLOW"]
for k,p in parts.items():outrows.extend(["\n===== "+k+" PINNED APPLE METHOD =====",p])
for k,v in checks.items():outrows.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
r9=[x.strip() for x in parts["LOGICAL"].splitlines() if re.search(r"\br9\b",x)]
outrows.append("LOGICAL_OVERLOAD_R9_REFERENCES=%d"%len(r9))
outrows.append("LIMIT=The private QueueSetInfo_s and LogicalLinkInfo_s formal layouts remain unresolved; the generic array overload's trailing option dataflow is not inferred.")
(root/"registration-wrapper-argument-flow.txt").write_text("\n".join(outrows)+"\n")
summary=[
"STAGE79_24H32_REGISTRATION_WRAPPER_ARGUMENT_FLOW_AUDIT",
"TARGET=macOS_15.8.1_24H32_x86_64","STAGE62_PREDECESSOR=PIN_PASS","STAGE75_PREDECESSOR=PIN_PASS","STAGE78_PREDECESSOR=PIN_PASS",
"SOURCE_TREE_REVALIDATION=PASS","WRAPPER_FLOW_CHECKS=%d/%d"%(sum(checks.values()),len(checks)),
"INFRA_TO_ETHERNET_WRAPPER="+("PASS" if checks["INFRA_CALLS_ETHERNET_WRAPPER"] else "REVIEW_REQUIRED"),
"ETHERNET_TO_NETWORK_ARRAY_OVERLOAD="+("PASS" if checks["ETHERNET_CALLS_GENERIC_ARRAY_OVERLOAD"] else "REVIEW_REQUIRED"),
"QUEUE_COUNT_TO_QUEUESET="+("PASS" if checks["ARRAY_PASSES_COUNT_TO_WMM_AND_QUEUESET"] else "REVIEW_REQUIRED"),
"QUEUESET_TO_LOGICAL_LINK="+("PASS" if checks["ARRAY_CREATES_ONE_LOGICAL_LINK"] and checks["ARRAY_CALLS_LOGICAL_LINK_OVERLOAD"] else "REVIEW_REQUIRED"),
"PRIVATE_QUEUESET_INFO_FORMAL_SIZE=UNRESOLVED","PRIVATE_LOGICALLINK_INFO_FORMAL_SIZE=UNRESOLVED",
"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
"ISSUES="+("NONE" if all(checks.values()) else "WRAPPER_FLOW_REVIEW"),
"RESULT="+("PASS" if all(checks.values()) else "REVIEW_REQUIRED"),"ACTIVATION_GATE=BLOCKED"]
(root/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(root/"report.txt").write_text("\n".join(["========== STAGE 79 REGISTRATION WRAPPER FLOW ==========","VERSION=STAGE79_V1_20261103","RUN="+root.name,"",*summary,"","PASS means the Apple method-flow evidence was audited; the driver itself still has no registration callsite.","========== END STAGE 79 =========="])+"\n")
print("\n".join(summary))
if not all(checks.values()):raise SystemExit("Stage79 wrapper flow requires review")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=79";echo "VERSION=STAGE79_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/registration-wrapper-argument-flow.txt" "$OUT/report.txt";do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN";done
upload(){
 local f="$1" p="$2" j="$OUT/payload-$(basename "$f").json" put got want
 want="$(blob "$f")";python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage79 registration wrapper evidence","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$p" --input "$j" > "$OUT/put.json"
 put="$(python3 - "$OUT/put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)";got="$(gh api "repos/$REPO/contents/$p" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]]||fail "readback mismatch $p"
}
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/registration-wrapper-argument-flow.txt" "$OUT/report.txt" "$MAN";do upload "$f" "Development/Logs/stage79/$RUN/$(basename "$f")";done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/outlog.json"
python3 - "$OUT/outlog.json" "$OUT/outlog-payload.json" "$RUN" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]));old=base64.b64decode(o["content"])
e=("\n========== STAGE 79 REGISTRATION WRAPPER FLOW ==========\nSTAGE79_RUN: %s\nSTAGE79_VERSION: STAGE79_V1_20261103\nSTAGE79_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nACTIVATION_GATE: BLOCKED — driver registration callsite remains absent\nSTAGE79_LOGS: Development/Logs/stage79/%s/\n========================================================\n"%(sys.argv[3],sys.argv[3])).encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage79 wrapper flow audit","sha":o["sha"],"content":base64.b64encode(old.rstrip()+e).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/outlog-payload.json" > "$OUT/outlog-put.json"
P="$(python3 - "$OUT/outlog-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)";G="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$P" == "$G" ]]||fail "output.log readback mismatch"
echo "STAGE79_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt"|cut -d= -f2)"
echo "STAGE79_RUN=$RUN"
echo "STAGE79_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage79/$RUN"
