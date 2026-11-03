#!/bin/bash
# Stage 87 V1 — consolidated 24H32 native queue registration readiness gate.
# READ ONLY: evidence synthesis only; no driver edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage87/$RUN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
upload(){
 local f="$1" p="$2" j="$OUT/up-$(basename "$f").json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage87 native registration readiness synthesis","content":base64.b64encode(p.read_bytes()).decode()}))
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
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=87";echo "VERSION=STAGE87_V1_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage87 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage87/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename cut sed; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/predecessor-runs.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
rows=[]
for stage in (82,83,84,85,86):
 m=re.findall(r"STAGE%d_RUN: (run-[A-Za-z0-9-]+)"%stage,s)
 if not m: raise SystemExit("Stage%d predecessor run missing"%stage)
 rows.append("STAGE%d=%s"%(stage,m[-1]))
open(sys.argv[2],"w").write("\n".join(rows)+"\n")
PY
# Re-fetch each latest predecessor manifest and summary; validate GitHub blob SHA before use.
while IFS='=' read -r label run; do
 stage="$(printf '%s' "$label" | sed 's/^STAGE//')"
 curl -fsSLo "$OUT/$label-manifest.txt" "$BASE/stage$stage/$run/manifest.txt"
 remote="$(gh api "repos/$REPO/contents/Development/Logs/stage$stage/$run/manifest.txt" -q .sha)"
 [[ "$(blob "$OUT/$label-manifest.txt")" == "$remote" ]] || fail "$label manifest SHA mismatch"
 want="$(awk -F'|' '$1=="ARTIFACT"&&$2=="audit-summary.txt"{print $3}' "$OUT/$label-manifest.txt")"
 [[ -n "$want" ]] || fail "$label manifest missing audit-summary.txt"
 curl -fsSLo "$OUT/$label-audit-summary.txt" "$BASE/stage$stage/$run/audit-summary.txt"
 [[ "$(blob "$OUT/$label-audit-summary.txt")" == "$want" ]] || fail "$label audit-summary SHA mismatch"
 grep -q '^RESULT=PASS$' "$OUT/$label-audit-summary.txt" || fail "$label predecessor is not PASS"
done < "$OUT/predecessor-runs.txt"
# Pin detailed artifacts needed to classify remaining blockers.
for spec in \
 "STAGE84|queue-array-and-wmm-gate-matrix.txt" \
 "STAGE85|wmm-predicate-disassembly.txt" \
 "STAGE86|queue-array-reference-inventory.txt" \
 "STAGE86|registration-callsite-inventory.txt" \
 "STAGE86|pointer-array-declaration-inventory.txt"; do
 label="$(printf '%s' "$spec" | cut -d'|' -f1)"
 name="$(printf '%s' "$spec" | cut -d'|' -f2-)"
 stage="$(printf '%s' "$label" | sed 's/^STAGE//')"
 run="$(awk -F= -v n="$label" '$1==n{print $2}' "$OUT/predecessor-runs.txt")"
 want="$(awk -F'|' -v n="$name" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/$label-manifest.txt")"
 [[ -n "$want" ]] || fail "$label manifest missing $name"
 curl -fsSLo "$OUT/$label-$name" "$BASE/stage$stage/$run/$name"
 [[ "$(blob "$OUT/$label-$name")" == "$want" ]] || fail "$label artifact SHA mismatch: $name"
done
python3 - "$OUT" "$RUN" <<'PY'
import pathlib,sys
out=pathlib.Path(sys.argv[1]); run=sys.argv[2]
def kv(name):
 d={}
 for line in (out/name).read_text(errors="replace").splitlines():
  if "=" in line:
   k,v=line.split("=",1); d[k.strip()]=v.strip()
 return d
s82=kv("STAGE82-audit-summary.txt"); s83=kv("STAGE83-audit-summary.txt")
s84=kv("STAGE84-audit-summary.txt"); s85=kv("STAGE85-audit-summary.txt")
s86=kv("STAGE86-audit-summary.txt")
matrix=(out/"STAGE84-queue-array-and-wmm-gate-matrix.txt").read_text(errors="replace")
reg=(out/"STAGE86-registration-callsite-inventory.txt").read_text(errors="replace")
ptr=(out/"STAGE86-pointer-array-declaration-inventory.txt").read_text(errors="replace")
queue=(out/"STAGE86-queue-array-reference-inventory.txt").read_text(errors="replace")
issues=[]
for stage,d in [(82,s82),(83,s83),(84,s84),(85,s85),(86,s86)]:
 if d.get("RESULT")!="PASS": issues.append("STAGE%d_NOT_PASS"%stage)
wrappers=s82.get("WRAPPER_ABI_CHECKS","UNRESOLVED")
queue_pointer=s84.get("DRIVER_QUEUE_POINTER_ARRAY","UNRESOLVED")
native_calls=s84.get("DRIVER_NATIVE_REGISTRATION_CALLS","UNRESOLVED")
wmm_rule=s85.get("WMM_ACCEPTANCE_RULE","UNRESOLVED")
array_source=s86.get("QUEUE_ARRAY_SOURCE","UNRESOLVED")
native_like=s86.get("NATIVE_REGISTRATION_CALL_LIKE_REFERENCES","UNRESOLVED")
formal_q=s83.get("QUEUESET_INFO_FORMAL_SIZE","UNRESOLVED")
formal_l=s83.get("LOGICALLINK_INFO_FORMAL_SIZE","UNRESOLVED")
summary=[
"STAGE87_24H32_NATIVE_REGISTRATION_READINESS_SYNTHESIS",
"TARGET=macOS_15.8.1_24H32_x86_64",
"EVIDENCE_CHAIN=STAGES_82_83_84_85_86",
"STAGE82_WRAPPER_ABI_CHECKS="+wrappers,
"STAGE83_PRIVATE_METADATA_CHECKS="+s83.get("CHECKS","UNRESOLVED"),
"STAGE84_QUEUE_FACTORY_CROSSWALK="+s84.get("DRIVER_QUEUE_FACTORIES","UNRESOLVED"),
"STAGE84_QUEUE_POINTER_ARRAY="+queue_pointer,
"STAGE84_NATIVE_REGISTRATION_CALLS="+native_calls,
"STAGE85_WMM_PREDICATE_BODY="+s85.get("WMM_PREDICATE_DISASSEMBLY","UNRESOLVED"),
"STAGE85_WMM_ACCEPTANCE_RULE="+wmm_rule,
"STAGE86_QUEUE_ARRAY_SOURCE="+array_source,
"STAGE86_NATIVE_REGISTRATION_CALL_LIKE_REFERENCES="+native_like,
"QUEUESET_INFO_FORMAL_SIZE="+formal_q,
"LOGICALLINK_INFO_FORMAL_SIZE="+formal_l,
"CALLBACK_HANDOFFS_STILL_MISSING=4",
"CALLBACK_HANDOFF_1=TX_submission_to_adapter",
"CALLBACK_HANDOFF_2=TX_completion_to_drain",
"CALLBACK_HANDOFF_3=RX_submission_to_refill",
"CALLBACK_HANDOFF_4=RX_completion_to_controller_delivery",
"QUEUE_ARRAY_IMPLEMENTED="+("NO" if queue_pointer=="NOT_FOUND" and array_source=="NOT_FOUND" else "NOT_PROVEN"),
"NATIVE_REGISTRATION_IMPLEMENTED="+("NO" if native_calls=="0" else "NOT_PROVEN"),
"WMM_ACCEPTANCE_SEMANTICS="+("UNRESOLVED" if "REVIEW" in wmm_rule or "UNRESOLVED" in wmm_rule else "REQUIRES_HUMAN_REVIEW"),
"IMPLEMENTATION_AUTHORIZED=NO",
"BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN",
"OPENCORE_MODIFIED=NO","SOURCE_MODIFIED=NO",
"RESULT="+("PASS" if not issues else "REVIEW_REQUIRED"),
"ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(out/"implementation-blocker-matrix.txt").write_text("\n".join([
"STAGE87_IMPLEMENTATION_BLOCKER_MATRIX",
"REGISTRATION_WRAPPER=APPLE_ARGUMENT_FLOW_REVALIDATED; DRIVER_CALLSITE_ABSENT",
"FOUR_QUEUE_FACTORY_OBJECTS=IDENTIFIED; POINTER_ARRAY_STORAGE_AND_POPULATION_NOT_PROVEN",
"APPLE_QUEUESET=ITERATES_SUPPLIED_ARRAY_AND_CLASSIFIES_BY_TYPECODE",
"WMM_PREDICATE_BODY=EXTRACTED; ACCEPTANCE_SEMANTICS_REQUIRES_INSTRUCTION_LEVEL_REVIEW",
"QUEUESET_PRIVATE_INFO=OBSERVED_MINIMUM_ACCESS_4_BYTES; FORMAL_SIZE_UNRESOLVED",
"LOGICALLINK_PRIVATE_INFO=CALLER_STAGES_0x50_BYTES; FORMAL_SIZE_UNRESOLVED",
"TX_RX_CALLBACKS=ALL_FOUR_HANDOFFS_MISSING",
"IMPLEMENTATION_AUTHORIZED=NO","ACTIVATION_GATE=BLOCKED"])+"\n")
(out/"evidence-chain.txt").write_text("\n".join([
"STAGE87_EVIDENCE_CHAIN",
"STAGE82_WRAPPER_SUMMARY=PASS","STAGE83_METADATA_SUMMARY=PASS",
"STAGE84_ARRAY_WMM_SUMMARY=PASS","STAGE85_WMM_BODY_SUMMARY=PASS","STAGE86_SOURCE_INVENTORY_SUMMARY=PASS",
"\n===== STAGE84 QUEUE ARRAY / WMM DETAIL =====",matrix,
"\n===== STAGE86 REGISTRATION CALLSITE DETAIL =====",reg,
"\n===== STAGE86 POINTER ARRAY DETAIL =====",ptr,
"\n===== STAGE86 QUEUE MEMBER REFERENCES =====",queue])+"\n")
(out/"report.txt").write_text("\n".join([
"========== STAGE 87 IMPLEMENTATION READINESS SYNTHESIS ==========",
"VERSION=STAGE87_V1_20261103","RUN="+run,"TARGET=macOS_15.8.1_24H32_x86_64",
*summary,
"INTERPRETATION=The audit chain is complete, but native registration and TX/RX ownership handoffs are not implemented.",
"NEXT_ENGINEERING_GATE=resolve WMM predicate semantics, materialize a correctly owned four-queue pointer array, prove its lifetime and teardown, then wire native registration and all callback handoffs before any build or activation work.",
"========== END STAGE 87 =========="])+"\n")
print("\n".join(summary))
if issues: raise SystemExit("Stage87 evidence synthesis requires review")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=87";echo "VERSION=STAGE87_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stages82-86";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/implementation-blocker-matrix.txt" "$OUT/evidence-chain.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/implementation-blocker-matrix.txt" "$OUT/evidence-chain.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage87/$RUN/$(basename "$f")"; done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/output-payload.json" "$RUN" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]));old=base64.b64decode(o["content"])
entry=("\n========== STAGE 87 IMPLEMENTATION READINESS ==========\nSTAGE87_RUN: "+sys.argv[3]+"\nSTAGE87_VERSION: STAGE87_V1_20261103\nSTAGE87_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nEVIDENCE_CHAIN: STAGES_82_83_84_85_86_PASS | IMPLEMENTATION_AUTHORIZED: NO | ACTIVATION_GATE: BLOCKED\nSTAGE87_LOGS: Development/Logs/stage87/"+sys.argv[3]+"/\n=======================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage87 readiness synthesis","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
p="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
g="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$p" == "$g" ]] || fail "output.log readback mismatch"
echo "STAGE87_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE87_RUN=$RUN"
echo "STAGE87_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage87/$RUN"
