#!/bin/bash
# Stage 86 V1 — whole-driver queue pointer-array and registration callsite inventory.
# READ ONLY: source scan only; no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage86/$RUN"
mkdir -p "$OUT"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage86 queue array source inventory","content":base64.b64encode(p.read_bytes()).decode()}))
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
entry=("\n========== STAGE 86 QUEUE ARRAY SOURCE INVENTORY ==========\nSTAGE86_RUN: "+sys.argv[3]+"\nSTAGE86_VERSION: STAGE86_V2_20261103\nSTAGE86_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nQUEUE_ARRAY_SOURCE: "+sys.argv[4]+"\nNATIVE_REGISTRATION_CALLS: "+sys.argv[5]+"\nACTIVATION_GATE: BLOCKED\nSTAGE86_LOGS: Development/Logs/stage86/"+sys.argv[3]+"/\n============================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage86 queue array source inventory","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
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
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=86";echo "VERSION=STAGE86_V2_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage86 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage86/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "Stage26 source directory missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/stage85-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=re.findall(r"STAGE85_RUN: (run-[A-Za-z0-9-]+)",s)
if not m: raise SystemExit("Stage85 predecessor run missing")
open(sys.argv[2],"w").write(m[-1])
PY
S85="$(cat "$OUT/stage85-run.txt")"
curl -fsSLo "$OUT/stage85-manifest.txt" "$BASE/stage85/$S85/manifest.txt"
want_manifest="$(gh api "repos/$REPO/contents/Development/Logs/stage85/$S85/manifest.txt" -q .sha)"
[[ "$(blob "$OUT/stage85-manifest.txt")" == "$want_manifest" ]] || fail "Stage85 manifest SHA mismatch"
for f in audit-summary.txt wmm-predicate-disassembly.txt; do
 want="$(awk -F'|' -v n="$f" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/stage85-manifest.txt")"
 [[ -n "$want" ]] || fail "Stage85 manifest missing $f"
 pin "stage85-$f" "$want" "$BASE/stage85/$S85/$f"
done
grep -q '^RESULT=PASS$' "$OUT/stage85-audit-summary.txt" || fail "Stage85 predecessor is not PASS"
python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-reference-inventory.txt" "$OUT/registration-callsite-inventory.txt" "$OUT/pointer-array-declaration-inventory.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$RUN" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); fp=pathlib.Path(sys.argv[2]); reval=pathlib.Path(sys.argv[3])
queue_out=pathlib.Path(sys.argv[4]); reg_out=pathlib.Path(sys.argv[5]); ptr_out=pathlib.Path(sys.argv[6])
summary_out=pathlib.Path(sys.argv[7]); report_out=pathlib.Path(sys.argv[8]); run=sys.argv[9]
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix.lower() in exts)
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
source_ok=len(expected)==91 and set(expected)==set(actual)
rr=["STAGE86_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING"); b=actual.get(rel,"MISSING")
 if a!=b: source_ok=False
 rr.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
reval.write_text("\n".join(rr)+"\n")
texts={}
for p in files:
 rel=p.relative_to(src).as_posix()
 try: texts[rel]=p.read_text(errors="replace").splitlines()
 except Exception: texts[rel]=[]
queue_members=["_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"]
qrows=["STAGE86_QUEUE_MEMBER_REFERENCE_INVENTORY","SOURCE_FILES_SCANNED=%d"%len(files)]
member_counts={}
for member in queue_members:
 hits=[]
 for rel,lines in texts.items():
  for i,line in enumerate(lines):
   if member in line:
    hits.append("%s:%d:%s"%(rel,i+1,line.strip()[:260]))
 member_counts[member]=len(hits)
 qrows += ["\nMEMBER="+member,"REFERENCE_COUNT=%d"%len(hits)]
 qrows.extend(hits or ["NO_REFERENCES_FOUND"])
queue_out.write_text("\n".join(qrows)+"\n")
# Confirm only actual IOSkywalkPacketQueue pointer arrays and actual C++ call expressions.
def scrub_cpp(text):
    text=re.sub(r"/\*.*?\*/",lambda m:"\n"*m.group(0).count("\n"),text,flags=re.S)
    text=re.sub(r"//[^\n]*","",text)
    text=re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',"",text)
    return text

pointer_patterns=[
    r"\bIOSkywalkPacketQueue\s*\*+\s*[A-Za-z_]\w*\s*\[\s*\d*\s*\]",
    r"\bstd::array\s*<\s*IOSkywalkPacketQueue\s*\*\s*,\s*\d+\s*>",
    r"\bstd::vector\s*<\s*IOSkywalkPacketQueue\s*\*>"
]
ptr_hits=[]
aggregate_hits=[]
call_names=["registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface","isWMMSchedModelCapable"]
call_hits=[]
implementation_files=[p for p in files if p.suffix.lower() in (".cpp",".cc",".mm")]
for p in files:
    rel=p.relative_to(src).as_posix()
    raw=p.read_text(errors="replace")
    clean=scrub_cpp(raw)
    for pat in pointer_patterns:
        for m in re.finditer(pat,clean,re.I):
            line=clean.count("\n",0,m.start())+1
            ptr_hits.append("%s:%d:PATTERN=%s:MATCH=%s"%(rel,line,pat,m.group(0)))
    # Count a queue aggregation only when the four exact queue members are present
    # in the same initializer, or are assigned to indexed slots of the same array.
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\[\s*(\d+)\s*\]\s*=\s*&?\s*(_(?:txSubmission|txCompletion|rxSubmission|rxCompletion))\b",clean):
        aggregate_hits.append("%s:%d:ARRAY=%s INDEX=%s MEMBER=%s"%(rel,clean.count("\n",0,m.start())+1,m.group(1),m.group(2),m.group(3)))
    for m in re.finditer(r"\b(?:IOSkywalkPacketQueue\s*\*+\s*[A-Za-z_]\w*\s*\[\s*\d*\s*\]|std::array\s*<\s*IOSkywalkPacketQueue\s*\*\s*,\s*\d+\s*>)\s*=\s*\{([^}]*)\}",clean,re.S):
        body=m.group(1)
        found=[name for name in ["_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"] if re.search(r"\b"+name+r"\b",body)]
        if len(found)==4:
            aggregate_hits.append("%s:%d:FOUR_QUEUE_INITIALIZER=%s"%(rel,clean.count("\n",0,m.start())+1,",".join(found)))
# Only implementation files are searched for actual calls. Header prototypes and comments are not callsites.
for p in implementation_files:
    rel=p.relative_to(src).as_posix()
    clean=scrub_cpp(p.read_text(errors="replace"))
    for name in call_names:
        pattern=re.compile(r"\b"+name+r"\s*\(")
        for m in pattern.finditer(clean):
            pos=m.end()
            depth=1
            while pos<len(clean) and depth:
                if clean[pos]=="(": depth+=1
                elif clean[pos]==")": depth-=1
                pos+=1
            if depth: continue
            tail=pos
            while tail<len(clean) and clean[tail].isspace(): tail+=1
            if tail>=len(clean) or clean[tail]!=";": continue
            # A qualified method definition is not an invocation.
            line_start=clean.rfind("\n",0,m.start())+1
            prefix=clean[line_start:m.start()]
            if re.search(r"::\s*$",prefix): continue
            line=clean.count("\n",0,m.start())+1
            call_hits.append("%s:%d:CALL=%s"%(rel,line,name))
ptr_out.write_text("\n".join([
"STAGE86_POINTER_ARRAY_DECLARATION_INVENTORY",
"DECLARATION_PATTERN_HITS=%d"%len(ptr_hits),
*(ptr_hits or ["POINTER_ARRAY_DECLARATIONS=NONE_FOUND"]),
"\nARRAY_AGGREGATION_AND_ADDRESS_CLUES=%d"%len(aggregate_hits),
*(aggregate_hits or ["QUEUE_MEMBER_AGGREGATION_CLUES=NONE_FOUND"])])+"\n")
reg_out.write_text("\n".join([
"STAGE86_REGISTRATION_AND_WMM_CALLSITE_INVENTORY",
"CALL_LIKE_REFERENCES=%d"%len(call_hits),
*(call_hits or ["REGISTRATION_AND_WMM_CALLS=NONE_FOUND"])])+"\n")
queue_found=bool(ptr_hits or aggregate_hits)
registration_calls=sum(1 for x in call_hits if any(re.search(r"\b"+n+r"\s*\(",x) for n in call_names[:3]))
wmm_calls=sum(1 for x in call_hits if re.search(r"\bisWMMSchedModelCapable\s*\(",x))
summary=[
"STAGE86_24H32_QUEUE_POINTER_ARRAY_AND_REGISTRATION_SOURCE_AUDIT",
"STAGE85_PREDECESSOR=PASS",
"SOURCE_TREE_REVALIDATION="+("PASS" if source_ok else "REVIEW_REQUIRED"),
"SOURCE_FILES_SCANNED=%d"%len(files),
"QUEUE_MEMBER_REFERENCE_COUNTS="+",".join(k+":"+str(v) for k,v in member_counts.items()),
"POINTER_ARRAY_DECLARATION_HITS=%d"%len(ptr_hits),
"QUEUE_AGGREGATION_CLUES=%d"%len(aggregate_hits),
"QUEUE_ARRAY_SOURCE="+("FOUND" if queue_found else "NOT_FOUND"),
"NATIVE_REGISTRATION_CALL_LIKE_REFERENCES=%d"%registration_calls,
"WMM_CALL_LIKE_REFERENCES=%d"%wmm_calls,
"BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SOURCE_MODIFIED=NO",
"IMPLEMENTATION_AUTHORIZED=NO",
"RESULT="+("PASS" if source_ok else "REVIEW_REQUIRED"),
"ACTIVATION_GATE=BLOCKED"]
summary_out.write_text("\n".join(summary)+"\n")
report_out.write_text("\n".join([
"========== STAGE 86 QUEUE ARRAY SOURCE INVENTORY ==========",
"VERSION=STAGE86_V2_20261103","RUN="+run,"TARGET=macOS_15.8.1_24H32_x86_64",
*summary,
"LIMIT=PASS means the whole driver source inventory completed against the pinned baseline. It does not mean a missing array or registration call has been implemented.",
"========== END STAGE 86 =========="])+"\n")
print("\n".join(summary))
if not source_ok: raise SystemExit("Source tree differs from Stage73 baseline")
PY
QUEUE_STATE="$(grep '^QUEUE_ARRAY_SOURCE=' "$OUT/audit-summary.txt" | cut -d= -f2)"
REG_COUNT="$(grep '^NATIVE_REGISTRATION_CALL_LIKE_REFERENCES=' "$OUT/audit-summary.txt" | cut -d= -f2)"
MAN="$OUT/manifest.txt"
{ echo "STAGE=86";echo "VERSION=STAGE86_V2_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stage85";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-reference-inventory.txt" "$OUT/registration-callsite-inventory.txt" "$OUT/pointer-array-declaration-inventory.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-array-reference-inventory.txt" "$OUT/registration-callsite-inventory.txt" "$OUT/pointer-array-declaration-inventory.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage86/$RUN/$(basename "$f")"; done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-before.json"
python3 - "$OUT/output-before.json" "$OUT/output-payload.json" "$RUN" "$QUEUE_STATE" "$REG_COUNT" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); o=json.load(open(p)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 86 QUEUE ARRAY SOURCE INVENTORY ==========\nSTAGE86_RUN: "+sys.argv[3]+"\nSTAGE86_VERSION: STAGE86_V2_20261103\nSTAGE86_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nQUEUE_ARRAY_SOURCE: "+sys.argv[4]+"\nNATIVE_REGISTRATION_CALLS: "+sys.argv[5]+"\nACTIVATION_GATE: BLOCKED\nSTAGE86_LOGS: Development/Logs/stage86/"+sys.argv[3]+"/\n============================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage86 queue array source inventory","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
p="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
g="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$p" == "$g" ]] || fail "output.log readback mismatch"
echo "STAGE86_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE86_RUN=$RUN"
echo "STAGE86_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage86/$RUN"
