#!/bin/bash
# Stage 78 V1 — consolidated RTL88WiFi implementation-readiness gate and work order.
# VERSION_MARKER: STAGE78_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE78_V1_20261103"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE73_RUN="run-20261102-180530-d711b3944b06"
STAGE75_RUN="run-20261102-182045-29fbc9d32933"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage78/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
git_blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
gh_contents_upload(){
 local file="$1" path="$2" message="$3" payload="$OUT/upload-$(basename "$file").json" put got want
 want="$(git_blob_sha "$file")"
 python3 - "$file" "$payload" "$message" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$OUT/upload-response.json"
 put="$(python3 - "$OUT/upload-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "upload readback mismatch $path expected=$want put=$put got=$got"
 echo "$path|$got" >> "$OUT/uploaded-artifacts.txt"
}
append_output_log(){
 local entry="$1"
 gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output.json"
 python3 - "$OUT/remote-output.json" "$OUT/output-payload.json" "$entry" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1])); old=base64.b64decode(o["content"])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage78 implementation readiness gate to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+sys.argv[3].encode()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
 local a b
 a="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 b="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
 [[ "$a" == "$b" ]] || fail "output.log readback SHA mismatch"
}
on_exit(){
 local rc="$1" rp="Development/Logs/stage78/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 { echo "STAGE=78"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"; echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"; echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "===== CONSOLE TAIL ====="; tail -n 220 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"
 if gh auth status >/dev/null 2>&1; then gh_contents_upload "$OUT/failure-report.txt" "$rp" "Upload Stage78 failure report" || true; append_output_log "\n========== STAGE 78 FAILURE ==========\nSTAGE78_FAILURE_RUN: $RUN\nSTAGE78_EXIT_CODE: $rc\nSTAGE78_FAILURE_REPORT: $rp\nSTAGE78_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n======================================\n" || true; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT
for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee date tail cut basename; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -d "$SRC/src" ]] || fail "source directory missing: $SRC/src"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "wrong host target; expected macOS 15.8.1/24H32/x86_64"

# Resolve the exact latest Stage76 and Stage77 runs appended by the first two commands.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/predecessor-output-log.json"
python3 - "$OUT/predecessor-output-log.json" "$OUT/predecessor-runs.txt" <<'PY'
import base64,json,re,sys
o=json.load(open(sys.argv[1]));s=base64.b64decode(o["content"]).decode(errors="replace")
found={}
for stage in (76,77):
 m=re.findall(r"STAGE%d_RUN: (run-[A-Za-z0-9-]+)"%stage,s)
 if not m:raise SystemExit("Stage%d run missing from output.log"%stage)
 found[stage]=m[-1]
open(sys.argv[2],"w").write("STAGE76_RUN="+found[76]+"\nSTAGE77_RUN="+found[77]+"\n")
PY
STAGE76_RUN="$(awk -F= '$1=="STAGE76_RUN"{print $2}' "$OUT/predecessor-runs.txt")"
STAGE77_RUN="$(awk -F= '$1=="STAGE77_RUN"{print $2}' "$OUT/predecessor-runs.txt")"
RAW76="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage76/$STAGE76_RUN"
RAW77="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage77/$STAGE77_RUN"
RAW75="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage75/$STAGE75_RUN"
curl -fsSLo "$OUT/stage75-audit-summary.txt" "$RAW75/audit-summary.txt"
[[ "$(git_blob_sha "$OUT/stage75-audit-summary.txt")" == "8bf032d3916517c990eb37ae015711e057011e50" ]] || fail "Stage75 pin mismatch"
for stage in 76 77; do
 if [[ "$stage" == "76" ]]; then raw="$RAW76"; else raw="$RAW77"; fi
 curl -fsSLo "$OUT/stage$stage-manifest.txt" "$raw/manifest.txt"
 grep -q "^STAGE=$stage$" "$OUT/stage$stage-manifest.txt" || fail "Stage$stage manifest missing or wrong"
 for name in audit-summary.txt report.txt; do
  want="$(awk -F'|' -v n="$name" '$1=="ARTIFACT" && $2==n {print $3}' "$OUT/stage$stage-manifest.txt")"
  [[ -n "$want" ]] || fail "Stage$stage manifest does not pin $name"
  curl -fsSLo "$OUT/stage$stage-$name" "$raw/$name"
  got="$(git_blob_sha "$OUT/stage$stage-$name")"
  [[ "$got" == "$want" ]] || fail "Stage$stage $name hash mismatch"
 done
 grep -q '^RESULT=PASS$' "$OUT/stage$stage-audit-summary.txt" || fail "Stage$stage audit result is not PASS"
done

curl -fsSLo "$OUT/stage73-source-tree-fingerprint.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage73/$STAGE73_RUN/source-tree-fingerprint.txt"
[[ "$(git_blob_sha "$OUT/stage73-source-tree-fingerprint.txt")" == "74a6ab39ea5e273d1788d17ea8c99895a1fd86df" ]] || fail "Stage73 source fingerprint pin mismatch"
python3 - "$SRC" "$OUT/stage73-source-tree-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE78_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok:raise SystemExit("source tree changed from Stage73 baseline")
PY

python3 - "$OUT" <<'PY'
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
s75=(out/"stage75-audit-summary.txt").read_text()
s76=(out/"stage76-audit-summary.txt").read_text()
s77=(out/"stage77-audit-summary.txt").read_text()
def field(s,k):
 m=re.search(r"^"+re.escape(k)+r"=(.*)$",s,re.M)
 return m.group(1).strip() if m else "NOT_REPORTED"
gates=[
 ("SOURCE_BASELINE","PASS","91-file Stage73 source tree revalidated in Stages 76–78"),
 ("REGISTRATION_INFO","PRESENT","0x130-byte storage and 24H32 initializer/template preparation exist"),
 ("NATIVE_REGISTRATION","MISSING","Stage75 found zero native registration callsites"),
 ("NATIVE_DEREGISTRATION","MISSING","Stage75 found zero native deregistration callsites"),
 ("QUEUE_POINTER_ARRAY","MISSING","Stage75 found no driver IOSkywalkPacketQueue pointer-array storage candidate"),
 ("QUEUE_ORDER_AND_ARGUMENT_CONTRACT","UNRESOLVED","Do not guess order/count/flags; prove against 24H32 native caller before coding"),
 ("CONTROLLER_START_PUBLICATION","BLOCKED","Stage76 controller start has a terminal failure path; no successful publication path confirmed"),
 ("INFRA_INTERFACE_START","BLOCKED","Stage76 infra start has no success return path"),
 ("TX_SUBMISSION_HANDOFF","MISSING",field(s77,"TX_SUBMISSION_TO_ADAPTER")),
 ("TX_COMPLETION_DRAIN","MISSING",field(s77,"TX_COMPLETION_TO_DRAIN")),
 ("RX_SUBMISSION_REFILL","MISSING",field(s77,"RX_SUBMISSION_TO_REFILL")),
 ("RX_COMPLETION_DELIVERY","MISSING",field(s77,"RX_COMPLETION_TO_CONTROLLER")),
 ("TX_DRAIN_CALLSITE","MISSING","Stage77 reports zero external TX drain callsites"),
 ("BUILD_AND_LINK","NOT_RUN","No build was authorized or performed"),
 ("KEXT_INSTALL_OR_LOAD","NOT_RUN","No installation or load was authorized or performed"),
 ("OPENCORE_OR_HARDWARE_TEST","NOT_RUN","No OpenCore/NVRAM/SIP or hardware tests were performed")]
lines=["STAGE78_IMPLEMENTATION_READINESS_MATRIX","RESULT_MEANING=PASS means evidence synthesis completed, not product readiness"]
for name,status,detail in gates:lines.append("GATE="+name+"|STATUS="+status+"|DETAIL="+detail)
(out/"implementation-readiness-matrix.txt").write_text("\n".join(lines)+"\n")
plan=[
 "STAGE78_ORDERED_IMPLEMENTATION_PLAN",
 "RULE=No implementation edit should be made until the exact 24H32 registration call contract, queue-pointer order/count, pools and rollback semantics are established.",
 "STEP_1=Resolve the native IO80211InfraInterface registration caller and exact argument contract from matching 24H32 kernel/driver evidence. Queue order, array length, flags and pool mapping remain unknown; do not infer them from member declaration order.",
 "STEP_2=Design queue-array storage and registration/deregistration lifecycle with explicit partial-failure rollback. Preserve reverse-order teardown and packet-pool lifetime.",
 "STEP_3=Only after Step 1/2 are proven, implement registration on the interface startup path and controller publication gate; replace current fail-closed start behavior only after all rollback paths are defined.",
 "STEP_4=Connect TX submission Action to the existing TX adapter with explicit packet retain/ticket rules and error/acceptance semantics.",
 "STEP_5=Connect native TX completion handling to the deferred ticket drain and prove exactly-once completion/release under synchronous and asynchronous backend completion.",
 "STEP_6=Implement RX submission refill and RX completion delivery using the correct Skywalk packet-count callback contract; keep it distinct from IOReturn Action callbacks.",
 "STEP_7=Prove RX sink ownership transfer, rejection/deallocation, staged-ring overflow, stop/quiesce and pool disposal invariants.",
 "STEP_8=Run static checks and compile/link validation before any install/load proposal. Then separately prepare an OpenCore test plan and recovery path.",
 "DO_NOT=Do not use AirportRTW as a substitute, do not block IOSkywalkFamily as a workaround, and do not alter SIP/NVRAM/OpenCore during these audit stages.",
 "CURRENT_STATE=No working kext has been produced or validated by Stages 64–78."]
(out/"ordered-implementation-plan.txt").write_text("\n".join(plan)+"\n")
summary=[
 "STAGE78_24H32_IMPLEMENTATION_READINESS_SYNTHESIS",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE75_PREDECESSOR=PASS","STAGE76_PREDECESSOR=PASS","STAGE77_PREDECESSOR=PASS",
 "SOURCE_TREE_REVALIDATION=PASS",
 "NATIVE_REGISTRATION="+field(s75,"NATIVE_REGISTRATION_CALLS"),
 "NATIVE_DEREGISTRATION="+field(s75,"NATIVE_DEREGISTRATION_CALLS"),
 "QUEUE_POINTER_ARRAY="+field(s75,"QUEUE_ARRAY_ARGUMENT_ASSEMBLY"),
 "CONTROLLER_START_GATE="+field(s76,"CONTROLLER_START_TERMINAL_GOTO_FAIL"),
 "INFRA_START_SUCCESS_RETURNS="+field(s76,"INFRA_START_RETURN_TRUE_COUNT"),
 "TX_SUBMISSION="+field(s77,"TX_SUBMISSION_TO_ADAPTER"),
 "TX_COMPLETION="+field(s77,"TX_COMPLETION_TO_DRAIN"),
 "RX_SUBMISSION="+field(s77,"RX_SUBMISSION_TO_REFILL"),
 "RX_COMPLETION="+field(s77,"RX_COMPLETION_TO_CONTROLLER"),
 "BUILD=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
 "ISSUES=NONE","RESULT=PASS","ACTIVATION_GATE=BLOCKED",
 "NEXT_GATE=resolve_and_prove_exact_24H32_native_registration_argument_order_before_any_source_implementation"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=["========== STAGE 78 IMPLEMENTATION READINESS ==========","VERSION=STAGE78_V1_20261103","RUN="+out.name,"PREDECESSORS=Stages 75, 76 and 77 passed their read-only audits","",*summary,"","INTERPRETATION=Stage78 PASS means synthesis completed; driver remains not test-ready.","========== END STAGE 78 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{ echo "STAGE=78"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "TARGET=15.8.1/24H32/x86_64"; echo "PREDECESSOR=Stages 75,76,77"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/implementation-readiness-matrix.txt" "$OUT/ordered-implementation-plan.txt" "$OUT/report.txt"; do
 sha="$(git_blob_sha "$f")"; echo "ARTIFACT|$(basename "$f")|$sha" >> "$MAN"
 gh_contents_upload "$f" "Development/Logs/stage78/$RUN/$(basename "$f")" "Add Stage78 readiness synthesis"
done
gh_contents_upload "$MAN" "Development/Logs/stage78/$RUN/manifest.txt" "Add Stage78 manifest"
append_output_log "\n========== STAGE 78 IMPLEMENTATION READINESS ==========\nSTAGE78_RUN: $RUN\nSTAGE78_VERSION: $VERSION\nSTAGE78_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nACTIVATION_GATE: BLOCKED — registration and TX/RX datapath are still incomplete\nSTAGE78_LOGS: Development/Logs/stage78/$RUN/\n=======================================================\n"
echo "STAGE78_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE78_RUN=$RUN"
echo "STAGE78_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage78/$RUN"
