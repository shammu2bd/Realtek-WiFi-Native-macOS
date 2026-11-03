#!/bin/bash
# Stage 83 V1 — 24H32 private metadata access-boundary audit.
# READ ONLY: no driver source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage83/$RUN"
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
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage83 private metadata evidence","content":base64.b64encode(p.read_bytes()).decode()}))
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
entry=("\n========== STAGE 83 PRIVATE METADATA BOUNDS ==========\nSTAGE83_RUN: "+sys.argv[3]+"\nSTAGE83_VERSION: STAGE83_V1_20261103\nSTAGE83_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nPRIVATE_METADATA: ACCESS BOUNDS CLASSIFIED | FORMAL SIZES UNRESOLVED\nSTAGE83_LOGS: Development/Logs/stage83/"+sys.argv[3]+"/\n======================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage83 metadata bounds audit","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
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
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=83";echo "VERSION=STAGE83_V1_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage83 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage83/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "project source directory missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage73-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin stage62-method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700 "$BASE/stage62/run-20261102-161032-d54adc732d87/method-disassembly.txt"
pin stage62-queueset-crosswalk.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51 "$BASE/stage62/run-20261102-161032-d54adc732d87/queueset-info-word-crosswalk.txt"
pin stage62-logical-crosswalk.txt 71802f2540ca976ffe5fe0b43b3f2b406fdb88fd "$BASE/stage62/run-20261102-161032-d54adc732d87/logical-link-info-crosswalk.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/output-current.json"
python3 - "$OUT/output-current.json" "$OUT/stage82-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=re.findall(r"STAGE82_RUN: (run-[A-Za-z0-9-]+)",s)
if not m: raise SystemExit("Stage82 predecessor run not found in output.log")
open(sys.argv[2],"w").write(m[-1])
PY
S82="$(cat "$OUT/stage82-run.txt")"
curl -fsSLo "$OUT/stage82-manifest.txt" "$BASE/stage82/$S82/manifest.txt"
[[ "$(blob "$OUT/stage82-manifest.txt")" == "$(gh api "repos/$REPO/contents/Development/Logs/stage82/$S82/manifest.txt" -q .sha)" ]] || fail "Stage82 manifest SHA mismatch"
for f in audit-summary.txt report.txt; do
 want="$(awk -F'|' -v n="$f" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/stage82-manifest.txt")"
 [[ -n "$want" ]] || fail "Stage82 manifest missing $f"
 pin "stage82-$f" "$want" "$BASE/stage82/$S82/$f"
done
grep -q '^RESULT=PASS$' "$OUT/stage82-audit-summary.txt" || fail "Stage82 predecessor not PASS"
python3 - "$SRC" "$OUT/stage73-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE83_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("source tree differs from Stage73 baseline")
PY
python3 - "$OUT/stage62-method-disassembly.txt" "$OUT/stage62-queueset-crosswalk.txt" "$OUT/stage62-logical-crosswalk.txt" "$OUT/private-metadata-access-boundaries.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$RUN" <<'PY'
import pathlib,re,sys
asm=pathlib.Path(sys.argv[1]).read_text(errors="replace")
qs=pathlib.Path(sys.argv[2]).read_text(errors="replace")
ll=pathlib.Path(sys.argv[3]).read_text(errors="replace")
out=pathlib.Path(sys.argv[4]);sp=pathlib.Path(sys.argv[5]);rp=pathlib.Path(sys.argv[6]);run=sys.argv[7]
def method(label):
 m=re.search(r"^===== METHOD .*label="+re.escape(label)+r".*?^DISASSEMBLY_BEGIN$(.*?)^DISASSEMBLY_END$",asm,re.M|re.S)
 if not m: raise SystemExit("missing Apple method "+label)
 return m.group(1)
q=method("queueset_init"); l=method("logical_link_init")
def has(s,p): return re.search(p,s,re.I|re.M) is not None
checks={
"QUEUESET_CALLER_WRITES_CONTROL_WORD_0X3_AND_0XB":all(x in qs for x in ["CONTROL_WORD_VALUES=0x3 when WMM sched-model check is false; 0xb when true","STACK_WORD_ADDRESS=rbp-0x84"]),
"QUEUESET_INIT_TESTS_BIT_3_AT_INFO_BYTE_ZERO":has(q,r"test\s+byte ptr \[rbx\],\s*0x8"),
"QUEUESET_INIT_READS_INFO_DWORD_AT_OFFSET_ZERO":has(q,r"mov\s+ecx,\s*dword ptr \[rbx\]"),
"QUEUESET_PRIVATE_INFO_FORMAL_SIZE_NOT_ESTABLISHED":"complete private struct size/layout is not proven" in qs,
"LOGICALLINK_CALLER_STAGES_0X50_BYTES": "copies 10 qwords (0x50 bytes)" in ll and "STAGING_BUFFER=rbp-0x80" in ll,
"LOGICALLINK_INIT_READS_INFO_DWORD_AT_OFFSET_ZERO":has(l,r"mov\s+eax,\s*dword ptr \[rax\]"),
"LOGICALLINK_FIRST_DWORD_IS_SET_TO_ONE":"FIRST_WORD=caller overwrites the first 32-bit word with 1" in ll,
"LOGICALLINK_PRIVATE_INFO_FORMAL_SIZE_NOT_ESTABLISHED":"formal sizeof/alignment is not established" in ll}
rows=["STAGE83_PRIVATE_METADATA_ACCESS_BOUNDARY_MATRIX","TARGET=macOS_15.8.1_24H32_x86_64"]
rows += ["\n===== QUEUESET INIT RAW METHOD =====",q,"\n===== LOGICAL LINK INIT RAW METHOD =====",l]
rows += ["\n===== INTERPRETATION =====",
"QUEUESET_INFO_S: caller supplies a 4-byte control word; Apple reads the byte at offset 0 for bit 3 and reads the dword at offset 0. This establishes a minimum accessed span of 4 bytes, not formal sizeof or alignment.",
"LOGICAL_LINK_INFO_S: caller copies 0x50 bytes into a staging buffer and sets the first dword to 1; init reads the dword at offset 0. The staged 0x50-byte span is not proof of formal sizeof or alignment.",
"OBJECT_ALLOCATIONS_ARE_SEPARATE: QueueSet object allocation size 0x80 and LogicalLink object allocation size 0x30 describe objects, not either private info argument.",
"NO_PRIVATE_STRUCT_SIZE_GUESS=YES"]
for k,v in checks.items(): rows.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
out.write_text("\n".join(rows)+"\n")
summary=[
"STAGE83_24H32_PRIVATE_METADATA_ACCESS_BOUNDARY_AUDIT","TARGET=macOS_15.8.1_24H32_x86_64",
"SOURCE_TREE_REVALIDATION=PASS",
"QUEUESET_INFO_MINIMUM_ACCESSED_SPAN=4_BYTES","QUEUESET_INFO_FORMAL_SIZE=UNRESOLVED",
"QUEUESET_INFO_OBSERVED_READS=BYTE_0_BIT_3_AND_DWORD_0",
"LOGICALLINK_INFO_CALLER_STAGED_SPAN=0x50_BYTES","LOGICALLINK_INFO_OBSERVED_READ=DWORD_0",
"LOGICALLINK_INFO_FORMAL_SIZE=UNRESOLVED",
"QUEUESET_OBJECT_ALLOCATION=0x80_BYTES_NOT_INFO_SIZE","LOGICALLINK_OBJECT_ALLOCATION=0x30_BYTES_NOT_INFO_SIZE",
"CHECKS=%d/%d"%(sum(checks.values()),len(checks)),
"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
"RESULT="+("PASS" if all(checks.values()) else "REVIEW_REQUIRED"),"ACTIVATION_GATE=BLOCKED"]
sp.write_text("\n".join(summary)+"\n")
rp.write_text("\n".join(["========== STAGE 83 PRIVATE METADATA BOUNDS ==========","VERSION=STAGE83_V1_20261103","RUN="+run,"",*summary,"","Do not turn observed access bounds or staging-buffer size into a guessed private C++ struct definition.","========== END STAGE 83 =========="])+"\n")
print("\n".join(summary))
if not all(checks.values()): raise SystemExit("private metadata evidence needs review")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=83";echo "VERSION=STAGE83_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stage82";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/private-metadata-access-boundaries.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/private-metadata-access-boundaries.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage83/$RUN/$(basename "$f")"; done
append_log
echo "STAGE83_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE83_RUN=$RUN"
echo "STAGE83_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage83/$RUN"
