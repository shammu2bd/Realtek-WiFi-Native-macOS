#!/bin/bash
# Stage 84 V1 — 24H32 queue-array materialization and WMM gate audit.
# READ ONLY: no driver source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage84/$RUN"
mkdir -p "$OUT"; exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes();print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ curl -fsSLo "$OUT/$1" "$3"; got="$(blob "$OUT/$1")"; [[ "$got" == "$2" ]] || fail "pin mismatch $1 got=$got expected=$2"; }
upload(){
 local f="$1" p="$2" j="$OUT/up-$(basename "$f").json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage84 queue array gate evidence","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$p" --input "$j" > "$OUT/up-response.json"
 put="$(python3 - "$OUT/up-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$p" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "GitHub readback mismatch: $p"
}
append_log(){
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
 python3 - "$OUT/output-before.json" "$OUT/output-payload.json" "$RUN" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]));old=base64.b64decode(o["content"])
entry=("\n========== STAGE 84 QUEUE ARRAY / WMM GATE ==========\nSTAGE84_RUN: "+sys.argv[3]+"\nSTAGE84_VERSION: STAGE84_V1_20261103\nSTAGE84_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nQUEUE_POINTER_ARRAY: NOT_FOUND | NATIVE_REGISTRATION_CALL: NOT_FOUND | ACTIVATION_GATE: BLOCKED\nSTAGE84_LOGS: Development/Logs/stage84/"+sys.argv[3]+"/\n=====================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage84 queue array audit","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
 local p g
 p="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 g="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
 [[ "$p" == "$g" ]] || fail "output.log readback mismatch"
}
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=84";echo "VERSION=STAGE84_V1_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage84 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage84/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "project source directory missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage73-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin stage61-queue-jump-tables.txt 7b017c03a4f008ba017a0f40d557132a3f623f2f "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queueset-classification-jump-tables.txt"
pin stage61-queue-command-disassembly.txt 0e2edad27bfd9b0346d1d0bc44fbb2cc539fdf43 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queue-command-method-disassembly.txt"
pin stage61-queueset-init-disassembly.txt 80d8fd7434a835f3cc6a072edb36419bfcfdd5d6 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queueset-init-disassembly.txt"
pin stage62-method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-disassembly.txt"
pin stage62-queueset-info.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51 "$BASE/stage62/run-20261102-161032-d54adc732d87/queueset-info-word-crosswalk.txt"
pin stage80-crosswalk.txt 423dd2db9e87f579e157294eb7da1131af0de873 "$BASE/stage80/run-20261102-185641-e10688bb526c/queue-constructor-and-typecode-crosswalk.txt"
pin stage80-summary.txt 9c93002085f931a11dd3c8b98ac8926787257778 "$BASE/stage80/run-20261102-185641-e10688bb526c/audit-summary.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/stage83-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=re.findall(r"STAGE83_RUN: (run-[A-Za-z0-9-]+)",s)
if not m: raise SystemExit("Stage83 predecessor run not found in output.log")
open(sys.argv[2],"w").write(m[-1])
PY
S83="$(cat "$OUT/stage83-run.txt")"
curl -fsSLo "$OUT/stage83-manifest.txt" "$BASE/stage83/$S83/manifest.txt"
[[ "$(blob "$OUT/stage83-manifest.txt")" == "$(gh api "repos/$REPO/contents/Development/Logs/stage83/$S83/manifest.txt" -q .sha)" ]] || fail "Stage83 manifest SHA mismatch"
for f in audit-summary.txt report.txt; do
 want="$(awk -F'|' -v n="$f" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/stage83-manifest.txt")"
 [[ -n "$want" ]] || fail "Stage83 manifest missing $f"
 pin "stage83-$f" "$want" "$BASE/stage83/$S83/$f"
done
grep -q '^RESULT=PASS$' "$OUT/stage83-audit-summary.txt" || fail "Stage83 predecessor not PASS"
python3 - "$SRC" "$OUT/stage73-fingerprint.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-and-wmm-gate-matrix.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$RUN" "$OUT/stage80-crosswalk.txt" "$OUT/stage61-queue-jump-tables.txt" "$OUT/stage61-queue-command-disassembly.txt" "$OUT/stage61-queueset-init-disassembly.txt" "$OUT/stage62-method-disassembly.txt" "$OUT/stage62-queueset-info.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);reval=pathlib.Path(sys.argv[3]);matrix_path=pathlib.Path(sys.argv[4]);summary_path=pathlib.Path(sys.argv[5]);report_path=pathlib.Path(sys.argv[6]);run=sys.argv[7]
cross=pathlib.Path(sys.argv[8]).read_text(errors="replace");jumps=pathlib.Path(sys.argv[9]).read_text(errors="replace");cmd=pathlib.Path(sys.argv[10]).read_text(errors="replace")
qset_init=pathlib.Path(sys.argv[11]).read_text(errors="replace");registration=pathlib.Path(sys.argv[12]).read_text(errors="replace");qset_info=pathlib.Path(sys.argv[13]).read_text(errors="replace")
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=[p for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts]
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
source_ok=len(expected)==91 and set(expected)==set(actual)
rr=["STAGE84_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:source_ok=False
 rr.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
reval.write_text("\n".join(rr)+"\n")
# Search only the driver implementation sources; declarations and comments are retained separately as evidence.
qcpp=src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
qhpp=src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
if not qcpp.is_file() or not qhpp.is_file(): raise SystemExit("expected Skywalk queue source files missing")
cpp=qcpp.read_text(errors="replace");hpp=qhpp.read_text(errors="replace")
members=["_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"]
factory_map={"_txSubmission":("IOSkywalkTxSubmissionQueue",1),"_txCompletion":("IOSkywalkTxCompletionQueue",2),"_rxSubmission":("IOSkywalkRxSubmissionQueue",3),"_rxCompletion":("IOSkywalkRxCompletionQueue",4)}
factory_rows=[]
for member,(klass,code) in factory_map.items():
 m=re.search(re.escape(member)+r"\s*=\s*("+klass+r")::withPool\s*\(",cpp)
 factory_rows.append("FACTORY="+member+" CLASS="+klass+" TYPECODE="+str(code)+" RESULT="+("PASS" if m else "MISSING"))
# Look for real construction of a pointer array, not merely four independent pointer members.
alltext="\n".join(p.read_text(errors="replace") for p in files)
array_patterns=[
 r"IOSkywalkPacketQueue\s*\*\s*[A-Za-z_]\w*\s*\[\s*\d*\s*\]",
 r"std::array\s*<\s*IOSkywalkPacketQueue\s*\*",
 r"queue(?:Pointer|Queue)?Array|queue_array|queuePointers"]
array_hits=[]
for pat in array_patterns:
 for m in re.finditer(pat,alltext,re.I):
  line=alltext.count("\n",0,m.start())+1
  array_hits.append("PATTERN="+pat+" MATCH="+m.group(0)+" COMBINED_SOURCE_LINE="+str(line))
# Direct native-registration invocations are distinguished from method declarations.
call_patterns=[r"(?:->|\.)\s*registerInfraEthernetInterface\s*\(",r"(?:->|\.)\s*registerEthernetInterface\s*\(",r"(?:->|\.)\s*registerNetworkInterface\s*\("]
calls=[]
for p in files:
 text=p.read_text(errors="replace")
 for pat in call_patterns:
  for m in re.finditer(pat,text):
   line=text.count("\n",0,m.start())+1
   calls.append(p.relative_to(src).as_posix()+":"+str(line)+":"+m.group(0))
typecodes=all(x in cross for x in ["FACTORY_TO_APPLE_TYPECODE_MATCHES=4/4","APPLE_TYPECODES=1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION"])
queue_classifier=all(x in jumps for x in ["QUEUE_KIND=1 CLASS=IOSkywalkTxSubmissionQueue","QUEUE_KIND=2 CLASS=IOSkywalkTxCompletionQueue","QUEUE_KIND=3 CLASS=IOSkywalkRxSubmissionQueue","QUEUE_KIND=4 CLASS=IOSkywalkRxCompletionQueue"])
command_record=all(re.search(r"mov\s+(?:dword|qword) ptr \[rdx\],\s*0x"+str(n)+r"\b",cmd,re.I) for n in range(1,5))
qset_loop=all(re.search(p,qset_init,re.I) for p in [r"mov\s+esi,\s*0x10000",r"mov\s+ecx,\s*0x10",r"call\s+qword ptr \[rax \+ 0x218\]",r"cmp\s+r15,\s*qword ptr \[r14 \+ 0x58\]",r"jb\s"])
wmm_call=all(re.search(p,registration,re.I) for p in [r"call\s+0xffffff800298ac44\b",r"mov\s+rdi,\s*rdx",r"mov\s+rsi,\s*rbx"])
wmm_control=("CONTROL_WORD_VALUES=0x3 when WMM sched-model check is false; 0xb when true" in qset_info and "OPTIONAL_EXTRA_NEXUS_ALLOCATION" in qset_info)
checks={
"FOUR_DRIVER_QUEUE_FACTORY_MEMBERS_PRESENT":all("RESULT=PASS" in x for x in factory_rows),
"STAGE80_TYPECODE_CROSSWALK_4_OF_4":typecodes,
"APPLE_QUEUESET_KIND_TABLE_HAS_FOUR_TYPES":queue_classifier,
"QUEUESET_ITERATES_INPUT_ARRAY_AND_QUERIES_TYPECODE":qset_loop,
"WMM_PREDICATE_RECEIVES_QUEUE_POINTER_AND_COUNT":wmm_call,
"QUEUESET_WMM_CONTROL_BIT_IS_EVIDENCE_BACKED":wmm_control,
"PERFORMCOMMAND_EMITS_FOUR_TYPE_CODES":command_record,
"DRIVER_QUEUE_POINTER_ARRAY_NOT_FOUND":len(array_hits)==0,
"DRIVER_NATIVE_REGISTRATION_CALL_NOT_FOUND":len(calls)==0,
"STAGE73_SOURCE_FINGERPRINT_MATCHES":source_ok}
rows=["STAGE84_QUEUE_ARRAY_AND_WMM_GATE_MATRIX","TARGET=macOS_15.8.1_24H32_x86_64",
"DRIVER_QUEUE_OBJECTS"]
rows.extend(factory_rows)
rows += ["\nQUEUE_ARRAY_SEARCH_RESULTS="+str(len(array_hits))]
rows.extend(array_hits or ["QUEUE_ARRAY_CANDIDATES=NONE"])
rows += ["\nNATIVE_REGISTRATION_CALL_SEARCH_RESULTS="+str(len(calls))]
rows.extend(calls or ["NATIVE_REGISTRATION_CALLS=NONE"])
rows += ["\nAPPLE_QUEUESET_CLASSIFICATION_EVIDENCE",
"TYPECODE_MAP=1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION",
"QUEUESET_CLASSIFIES_EACH_SUPPLIED_QUEUE_BY_PERFORMCOMMAND_TYPECODE=YES",
"QUEUESET_ITERATES_THE_SUPPLIED_POINTER_ARRAY_UP_TO_QUEUE_COUNT="+("YES" if qset_loop else "REVIEW_REQUIRED"),
"INPUT_ARRAY_ORDER_REQUIRED=NOT_PROVEN",
"WMM_PREDICATE_CALLED_WITH_QUEUE_POINTER_AND_COUNT="+("YES" if wmm_call else "REVIEW_REQUIRED"),
"WMM_PREDICATE_BODY_AND_EXACT_ACCEPTANCE_RULE=NOT_IN_PINNED_METHOD_SET",
"QUEUESET_WMM_CONTROL_BIT_3_ENABLES_AN_ADDITIONAL_WMM_CAPABILITY_PATH="+("YES" if wmm_control else "REVIEW_REQUIRED"),
"WMM_REQUIRED_QUEUE_COMBINATION_OR_ORDER=UNRESOLVED",
"NOTE=Type-code grouping supports classification independent of ordinal position, but it does not prove the WMM predicate has no order-sensitive requirement."]
for k,v in checks.items(): rows.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
matrix_path.write_text("\n".join(rows)+"\n")
summary=[
"STAGE84_24H32_QUEUE_ARRAY_AND_WMM_GATE_AUDIT","TARGET=macOS_15.8.1_24H32_x86_64",
"SOURCE_TREE_REVALIDATION="+("PASS" if source_ok else "REVIEW_REQUIRED"),
"DRIVER_QUEUE_FACTORIES=%d/4"%sum("RESULT=PASS" in x for x in factory_rows),
"APPLE_TYPECODE_CROSSWALK=4/4","APPLE_QUEUESET_TYPECODE_CLASSIFICATION=CONFIRMED",
"DRIVER_QUEUE_POINTER_ARRAY="+("NOT_FOUND" if not array_hits else "CANDIDATE_FOUND_REVIEW"),
"DRIVER_NATIVE_REGISTRATION_CALLS="+str(len(calls)),
"WMM_PREDICATE_CALLED_WITH_ARRAY_AND_COUNT="+("YES" if wmm_call else "REVIEW_REQUIRED"),"WMM_PREDICATE_ACCEPTANCE_RULE=UNRESOLVED",
"INPUT_ARRAY_ORDER=NOT_PROVEN_AS_REQUIRED",
"BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SOURCE_MODIFIED=NO",
"IMPLEMENTATION_AUTHORIZED=NO",
"RESULT="+("PASS" if all(checks.values()) else "REVIEW_REQUIRED"),"ACTIVATION_GATE=BLOCKED"]
summary_path.write_text("\n".join(summary)+"\n")
report_path.write_text("\n".join(["========== STAGE 84 QUEUE ARRAY / WMM GATE ==========","VERSION=STAGE84_V1_20261103","RUN="+run,"",*summary,"","PASS means the source and Apple queue classification evidence was checked. It does not mean a queue array is implemented or that WMM readiness is proven.","========== END STAGE 84 =========="])+"\n")
print("\n".join(summary))
if not all(checks.values()): raise SystemExit("queue array/WMM audit requires review")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=84";echo "VERSION=STAGE84_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stage83";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-and-wmm-gate-matrix.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-and-wmm-gate-matrix.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage84/$RUN/$(basename "$f")"; done
append_log
echo "STAGE84_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE84_RUN=$RUN"
echo "STAGE84_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage84/$RUN"
