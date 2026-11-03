#!/bin/bash
# Stage 81 V2 — 24H32 implementation contract synthesis.
# VERSION_MARKER: STAGE81_V2_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage81/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=81"; echo "VERSION=STAGE81_V2_20261103"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; tail -n 180 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage81 V2 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage81/$RUN/failure-report.txt" --input "$OUT/failure-payload.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname wc tr tee date tail basename sed; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "source directory missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "wrong host target"
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
upload(){
 local file="$1" path="$2" payload="$OUT/upload-$(basename "$file").json" want put got
 want="$(blob "$file")"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage81 V2 implementation contract evidence","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$OUT/upload-response.json"
 put="$(python3 - "$OUT/upload-response.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]] || fail "upload readback mismatch: $path"
}
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/predecessor-runs.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
found={}
for n in (79,80):
 m=re.findall(r"STAGE"+str(n)+r"_RUN: (run-[A-Za-z0-9-]+)",s)
 if not m: raise SystemExit("Stage "+str(n)+" run absent from output.log")
 found[n]=m[-1]
open(sys.argv[2],"w").write(found[79]+"\n"+found[80]+"\n")
PY
S79="$(sed -n '1p' "$OUT/predecessor-runs.txt")"
S80="$(sed -n '2p' "$OUT/predecessor-runs.txt")"
for n in 79 80; do
 if [[ "$n" == 79 ]]; then run="$S79"; else run="$S80"; fi
 raw="$BASE/stage$n/$run"
 curl -fsSLo "$OUT/stage$n-manifest.txt" "$raw/manifest.txt"
 [[ "$(gh api "repos/$REPO/contents/Development/Logs/stage$n/$run/manifest.txt" -q .sha)" == "$(blob "$OUT/stage$n-manifest.txt")" ]] || fail "Stage$n manifest SHA mismatch"
 grep -q "^STAGE=$n$" "$OUT/stage$n-manifest.txt" || fail "Stage$n manifest invalid"
 for name in audit-summary.txt report.txt; do
  expected="$(awk -F'|' -v f="$name" '$1=="ARTIFACT" && $2==f {print $3}' "$OUT/stage$n-manifest.txt")"
  [[ -n "$expected" ]] || fail "Stage$n manifest missing $name"
  curl -fsSLo "$OUT/stage$n-$name" "$raw/$name"
  [[ "$(blob "$OUT/stage$n-$name")" == "$expected" ]] || fail "Stage$n $name SHA mismatch"
 done
 grep -q '^RESULT=PASS$' "$OUT/stage$n-audit-summary.txt" || fail "Stage$n audit is not PASS"
done
for spec in "75|run-20261102-182045-29fbc9d32933|8bf032d3916517c990eb37ae015711e057011e50" "76|run-20261102-182650-26c858a60bed|e787a2f706808a75a1198254d07307ef4076dc7c" "77|run-20261102-182715-f8a47365a98b|9bf10441aa3a4f4d06c62e08c95435c999558546" "78|run-20261102-182749-501d7134ab5e|fa4cd30bc3a6b9bf4674e531141a1f937c8f77d9"; do
 n="${spec%%|*}"; rest="${spec#*|}"; run="${rest%%|*}"; want="${rest#*|}"
 curl -fsSLo "$OUT/stage$n-summary.txt" "$BASE/stage$n/$run/audit-summary.txt"
 [[ "$(blob "$OUT/stage$n-summary.txt")" == "$want" ]] || fail "Stage$n pinned summary SHA mismatch"
 grep -q '^RESULT=PASS$' "$OUT/stage$n-summary.txt" || fail "Stage$n predecessor not PASS"
done
curl -fsSLo "$OUT/stage73-fingerprint.txt" "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
[[ "$(blob "$OUT/stage73-fingerprint.txt")" == "74a6ab39ea5e273d1788d17ea8c99895a1fd86df" ]] || fail "Stage73 source fingerprint SHA mismatch"
python3 - "$SRC" "$OUT/stage73-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE81_SOURCE_TREE_REVALIDATION","EXPECTED_FILES="+str(len(expected)),"ACTUAL_FILES="+str(len(actual))]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok:raise SystemExit("Stage73 source baseline mismatch")
PY
python3 - "$OUT" <<'PY'
import pathlib,re,sys
o=pathlib.Path(sys.argv[1])
def val(file,key):
 s=(o/file).read_text()
 m=re.search("^"+re.escape(key)+"=(.*)$",s,re.M)
 return m.group(1).strip() if m else "NOT_REPORTED"
s75="stage75-summary.txt";s76="stage76-summary.txt";s77="stage77-summary.txt";s79="stage79-audit-summary.txt";s80="stage80-audit-summary.txt"
matrix=[
"STAGE81_IMPLEMENTATION_CONTRACT_MATRIX",
"RESULT_MEANING=PASS means evidence synthesis completed, not product readiness",
"GATE=SOURCE_BASELINE|PASS|91 files match Stage73 fingerprint",
"GATE=APPLE_REGISTRATION_WRAPPER|"+val(s79,"INFRA_TO_ETHERNET_WRAPPER")+"|Apple Infra wrapper forwarding",
"GATE=GENERIC_ARRAY_TO_QUEUESET|"+val(s79,"QUEUE_COUNT_TO_QUEUESET")+"|Queue count into QueueSet factory",
"GATE=QUEUESET_TO_LOGICAL_LINK|"+val(s79,"QUEUESET_TO_LOGICAL_LINK")+"|QueueSet then LogicalLink",
"GATE=FOUR_QUEUE_TYPECODE_MATCH|"+val(s80,"FACTORY_TO_APPLE_TYPECODE_MATCHES")+"|Driver factories compared with Apple type codes",
"GATE=QUEUE_POINTER_ARRAY|"+val(s75,"QUEUE_ARRAY_ARGUMENT_ASSEMBLY")+"|Driver queue array absent",
"GATE=NATIVE_REGISTRATION_CALLS|"+val(s75,"NATIVE_REGISTRATION_CALLS")+"|Native registration callsite absent",
"GATE=NATIVE_DEREGISTRATION_CALLS|"+val(s75,"NATIVE_DEREGISTRATION_CALLS")+"|Native deregistration callsite absent",
"GATE=QUEUESET_INFO_FORMAL_SIZE|UNRESOLVED|Observed control word does not prove formal type size",
"GATE=LOGICALLINK_INFO_FORMAL_SIZE|UNRESOLVED|Observed staging buffer does not prove formal type size",
"GATE=CONTROLLER_START|BLOCKED|Fail-closed start path remains",
"GATE=INFRA_START|BLOCKED|No successful return or registration preparation call",
"GATE=TX_SUBMISSION|"+val(s77,"TX_SUBMISSION_TO_ADAPTER")+"|No adapter handoff",
"GATE=TX_COMPLETION|"+val(s77,"TX_COMPLETION_TO_DRAIN")+"|No deferred drain caller",
"GATE=RX_SUBMISSION|"+val(s77,"RX_SUBMISSION_TO_REFILL")+"|No refill",
"GATE=RX_COMPLETION|"+val(s77,"RX_COMPLETION_TO_CONTROLLER")+"|No delivery",
"GATE=BUILD_INSTALL_LOAD|NOT_RUN|No build, install, load or hardware test"]
(o/"implementation-contract-matrix.txt").write_text("\n".join(matrix)+"\n")
plan=[
"STAGE81_ORDERED_IMPLEMENTATION_PREREQUISITES",
"1. Resolve formal QueueSetInfo_s and LogicalLinkInfo_s size, alignment and full initialization requirements from matching 24H32 evidence.",
"2. Resolve WMM predicate queue requirements and remaining registration-option dataflow. Do not infer mandatory array order from member declaration order.",
"3. Materialize one IOSkywalkPacketQueue pointer per confirmed descriptor type: 1 TX submission, 2 TX completion, 3 RX submission, 4 RX completion. Pass the actual pointer count.",
"4. Implement registration and matching deregistration as a transaction with explicit partial-failure rollback and queue/pool lifetime guarantees.",
"5. Connect TX submission, TX completion drain, RX refill and RX delivery. Keep IOReturn Action callbacks distinct from packet-count callbacks.",
"6. Prove packet ownership, RX acceptance/rejection, overflow, quiesce and teardown invariants.",
"7. Request separate source-edit authorization before implementation. Compile/link and ABI checks precede install/load or OpenCore testing.",
"IMPLEMENTATION_AUTHORIZED=NO"]
(o/"ordered-implementation-prerequisites.txt").write_text("\n".join(plan)+"\n")
summary=[
"STAGE81_24H32_IMPLEMENTATION_CONTRACT_SYNTHESIS",
"TARGET=macOS_15.8.1_24H32_x86_64",
"STAGE79_PREDECESSOR=PASS","STAGE80_PREDECESSOR=PASS","SOURCE_TREE_REVALIDATION=PASS",
"APPLE_INFRA_WRAPPER="+val(s79,"INFRA_TO_ETHERNET_WRAPPER"),
"GENERIC_ARRAY_TO_QUEUESET="+val(s79,"QUEUE_COUNT_TO_QUEUESET"),
"QUEUESET_LOGICAL_LINK="+val(s79,"QUEUESET_TO_LOGICAL_LINK"),
"FOUR_QUEUE_TYPECODE_MATCHES="+val(s80,"FACTORY_TO_APPLE_TYPECODE_MATCHES"),
"QUEUE_POINTER_ARRAY="+val(s75,"QUEUE_ARRAY_ARGUMENT_ASSEMBLY"),
"NATIVE_REGISTRATION_CALLS="+val(s75,"NATIVE_REGISTRATION_CALLS"),
"PRIVATE_QUEUESET_INFO_SIZE=UNRESOLVED","PRIVATE_LOGICALLINK_INFO_SIZE=UNRESOLVED",
"CONTROLLER_START=BLOCKED","INFRA_START=BLOCKED",
"TX_SUBMISSION="+val(s77,"TX_SUBMISSION_TO_ADAPTER"),
"TX_COMPLETION="+val(s77,"TX_COMPLETION_TO_DRAIN"),
"RX_SUBMISSION="+val(s77,"RX_SUBMISSION_TO_REFILL"),
"RX_COMPLETION="+val(s77,"RX_COMPLETION_TO_CONTROLLER"),
"BUILD=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
"IMPLEMENTATION_AUTHORIZED=NO","RESULT=PASS","ACTIVATION_GATE=BLOCKED"]
(o/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(o/"report.txt").write_text("\n".join(["========== STAGE 81 V2 IMPLEMENTATION CONTRACT ==========","VERSION=STAGE81_V2_20261103","RUN="+o.name,"",*summary,"","PASS means evidence synthesis completed; it does not mean the driver is ready.","========== END STAGE 81 =========="])+"\n")
print("\n".join(summary))
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=81"; echo "VERSION=STAGE81_V2_20261103"; echo "RUN=$RUN"; echo "TARGET=15.8.1/24H32/x86_64"; echo "PREDECESSORS=79,80"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/implementation-contract-matrix.txt" "$OUT/ordered-implementation-prerequisites.txt" "$OUT/report.txt"; do
 echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"
done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/implementation-contract-matrix.txt" "$OUT/ordered-implementation-prerequisites.txt" "$OUT/report.txt" "$MAN"; do
 upload "$f" "Development/Logs/stage81/$RUN/$(basename "$f")"
done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-remote.json"
python3 - "$OUT/output-remote.json" "$OUT/output-payload.json" "$RUN" "$S79" "$S80" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]));old=base64.b64decode(o["content"])
entry=("\n========== STAGE 81 IMPLEMENTATION CONTRACT ==========\n"
"STAGE81_RUN: "+sys.argv[3]+"\n"
"STAGE81_VERSION: STAGE81_V2_20261103\n"
"STAGE81_PREDECESSOR_STAGE79_RUN: "+sys.argv[4]+"\n"
"STAGE81_PREDECESSOR_STAGE80_RUN: "+sys.argv[5]+"\n"
"STAGE81_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
"IMPLEMENTATION_AUTHORIZED: NO | ACTIVATION_GATE: BLOCKED\n"
"STAGE81_LOGS: Development/Logs/stage81/"+sys.argv[3]+"/\n"
"======================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage81 V2 to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE81_RESULT=PASS"
echo "STAGE81_RUN=$RUN"
echo "STAGE81_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage81/$RUN"
