#!/bin/bash
# Stage 85 V1 — exact 24H32 IOSkywalkQueueSet WMM predicate body audit.
# READ ONLY: no driver edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage85/$RUN"
mkdir -p "$OUT/tools" "$OUT/kc-cache"
exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ curl -fsSLo "$OUT/$1" "$3"; got="$(blob "$OUT/$1")"; [[ "$got" == "$2" ]] || fail "GitHub evidence pin mismatch: $1 got=$got expected=$2"; }
upload(){
 local f="$1" p="$2" j="$OUT/up-$(basename "$f").json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage85 WMM predicate evidence","content":base64.b64encode(p.read_bytes()).decode()}))
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
entry=("\n========== STAGE 85 WMM PREDICATE BODY ==========\nSTAGE85_RUN: "+sys.argv[3]+"\nSTAGE85_VERSION: STAGE85_V1_20261103\nSTAGE85_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nWMM_PREDICATE_BODY: DISASSEMBLED | ACCEPTANCE_RULE: REVIEW_REQUIRED | ACTIVATION_GATE: BLOCKED\nSTAGE85_LOGS: Development/Logs/stage85/"+sys.argv[3]+"/\n=================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage85 WMM predicate audit","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
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
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=85";echo "VERSION=STAGE85_V1_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage85 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage85/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename xcrun; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" && -f "$BOOTKC" ]] || fail "Stage26 source or BootKernelExtensions.kc missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage62-method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-disassembly.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/stage84-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=re.findall(r"STAGE84_RUN: (run-[A-Za-z0-9-]+)",s)
if not m: raise SystemExit("Stage84 predecessor run missing")
open(sys.argv[2],"w").write(m[-1])
PY
S84="$(cat "$OUT/stage84-run.txt")"
curl -fsSLo "$OUT/stage84-manifest.txt" "$BASE/stage84/$S84/manifest.txt"
want_manifest="$(gh api "repos/$REPO/contents/Development/Logs/stage84/$S84/manifest.txt" -q .sha)"
[[ "$(blob "$OUT/stage84-manifest.txt")" == "$want_manifest" ]] || fail "Stage84 manifest SHA mismatch"
for f in audit-summary.txt queue-array-and-wmm-gate-matrix.txt; do
 want="$(awk -F'|' -v n="$f" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/stage84-manifest.txt")"
 [[ -n "$want" ]] || fail "Stage84 manifest missing $f"
 pin "stage84-$f" "$want" "$BASE/stage84/$S84/$f"
done
grep -q '^RESULT=PASS$' "$OUT/stage84-audit-summary.txt" || fail "Stage84 predecessor is not PASS"
curl -fsSLo "$OUT/tools/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960/kcfile.py"
[[ "$(blob "$OUT/tools/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "Pinned kernel collection parser mismatch"
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); fp=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE85_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING"); b=actual.get(rel,"MISSING")
 if a!=b: ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("Source tree differs from Stage73 baseline")
PY
python3 - "$OUT/tools" "$BOOTKC" "$OUT/kc-cache" "$OBJDUMP" "$OUT/wmm-predicate-disassembly.txt" "$OUT/predicate-control-flow.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$RUN" "$OUT/stage62-method-disassembly.txt" <<'PY'
import pathlib,re,subprocess,sys
tools,bootkc,cache,objdump,dis_path,flow_path,sum_path,report_path,run,stage62=sys.argv[1:]
sys.path.insert(0,tools)
from kcfile import KC
stage62_text=pathlib.Path(stage62).read_text(errors="replace")
symbol="__ZN17IOSkywalkQueueSet22isWMMSchedModelCapableEPP20IOSkywalkPacketQueuem"
target=0xffffff800298ac44
if symbol not in stage62_text or "call\t0x%016x <%s>"%(target,symbol) not in stage62_text:
 raise SystemExit("Pinned Stage62 callsite does not identify the expected WMM predicate")
kc=KC(bootkc)
hits=[(va,nm) for va,nm in kc.methods("IOSkywalkQueueSet") if nm==symbol]
if len(hits)!=1: raise SystemExit("Expected exactly one IOSkywalkQueueSet WMM predicate symbol; found %d"%len(hits))
va,nm=hits[0]
owner=kc.owner(va) or kc.sym_owner.get(va)
if not owner or owner!=kc.sym_owner.get(va): raise SystemExit("WMM predicate Mach-O owner validation failed")
if va!=target: raise SystemExit("WMM predicate address mismatch: resolved 0x%x expected 0x%x"%(va,target))
carved=pathlib.Path(cache)/"wmm-predicate-owner.macho"
kc.carve(owner,str(carved))
nxt=kc.next_sym(va); end=nxt if nxt and va<nxt<=va+0x20000 else va+0x1000
p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],capture_output=True,text=True)
ins=[x for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
if p.returncode!=0 or not ins: raise SystemExit("WMM predicate disassembly failed (exit=%d instructions=%d)"%(p.returncode,len(ins)))
pathlib.Path(dis_path).write_text("\n".join([
"STAGE85_EXACT_WMM_PREDICATE_DISASSEMBLY",
"CLASS=IOSkywalkQueueSet",
"SYMBOL="+nm,
"ADDRESS=0x%x"%va,
"MACHO_OWNER="+owner,
"INSTRUCTIONS=%d"%len(ins),
"DISASSEMBLY_BEGIN",
p.stdout.rstrip(),
"DISASSEMBLY_END"])+"\n")
control=[]
for line in ins:
 if re.search(r"\b(cmp|test|and|or|xor|add|sub|inc|dec|call|ret|j[a-z]+|cmov[a-z]+|set[a-z]+)\b",line,re.I):
  control.append(line)
branches=[x for x in ins if re.search(r"\bj[a-z]+\s",x,re.I)]
calls=[x for x in ins if re.search(r"\bcall\b",x,re.I)]
flow=[
"STAGE85_WMM_PREDICATE_CONTROL_FLOW_INDEX",
"SYMBOL="+nm,"ADDRESS=0x%x"%va,"INSTRUCTION_COUNT=%d"%len(ins),
"CONDITIONAL_OR_UNCONDITIONAL_BRANCHES=%d"%len(branches),
"CALL_INSTRUCTIONS=%d"%len(calls),
"RETURN_INSTRUCTIONS=%d"%sum(bool(re.search(r"\bret\b",x,re.I)) for x in ins),
"IMPORTANT=This file lists evidence-bearing instructions; no WMM acceptance rule is inferred from the caller alone.",
"\nCONTROL_FLOW_AND_DATA_INSTRUCTIONS"]
flow.extend(control)
pathlib.Path(flow_path).write_text("\n".join(flow)+"\n")
summary=[
"STAGE85_24H32_IOSKYWALK_WMM_PREDICATE_BODY_AUDIT",
"STAGE84_PREDECESSOR=PASS",
"SOURCE_TREE_REVALIDATION=PASS",
"WMM_PREDICATE_SYMBOL_RESOLUTION=PASS",
"WMM_PREDICATE_ADDRESS=0x%x"%va,
"WMM_PREDICATE_OWNER="+owner,
"WMM_PREDICATE_DISASSEMBLY=PASS",
"WMM_PREDICATE_INSTRUCTIONS=%d"%len(ins),
"WMM_CONTROL_FLOW_BRANCHES=%d"%len(branches),
"WMM_CALL_INSTRUCTIONS=%d"%len(calls),
"WMM_ACCEPTANCE_RULE=BODY_CAPTURED_REQUIRES_SEMANTIC_REVIEW",
"BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN",
"OPENCORE_MODIFIED=NO","SOURCE_MODIFIED=NO",
"IMPLEMENTATION_AUTHORIZED=NO",
"RESULT=PASS",
"ACTIVATION_GATE=BLOCKED"]
pathlib.Path(sum_path).write_text("\n".join(summary)+"\n")
pathlib.Path(report_path).write_text("\n".join([
"========== STAGE 85 WMM PREDICATE BODY AUDIT ==========",
"VERSION=STAGE85_V1_20261103","RUN="+run,"TARGET=macOS_15.8.1_24H32_x86_64",
"METHOD=IOSkywalkQueueSet::isWMMSchedModelCapable(IOSkywalkPacketQueue**, unsigned long)",
"CALLSITE=Stage62 registerNetworkInterface(queue-array overload), exact target address verified",
*summary,
"LIMIT=PASS confirms exact method resolution and disassembly capture. WMM acceptance semantics still require review of the emitted instruction-level evidence.",
"ACTIVATION_GATE=BLOCKED","========== END STAGE 85 =========="])+"\n")
print("\n".join(summary))
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=85";echo "VERSION=STAGE85_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stage84";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/wmm-predicate-disassembly.txt" "$OUT/predicate-control-flow.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/wmm-predicate-disassembly.txt" "$OUT/predicate-control-flow.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage85/$RUN/$(basename "$f")"; done
append_log
echo "STAGE85_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE85_RUN=$RUN"
echo "STAGE85_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage85/$RUN"
