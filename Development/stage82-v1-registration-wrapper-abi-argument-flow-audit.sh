#!/bin/bash
# Stage 82 V1 — 24H32 registration wrapper ABI argument-flow revalidation.
# READ ONLY: no driver source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$ROOT/run log/stage82/$RUN"
mkdir -p "$OUT"; exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2; exit 2; }
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ curl -fsSLo "$OUT/$1" "$3"; got="$(blob "$OUT/$1")"; [[ "$got" == "$2" ]] || fail "pin mismatch $1 got=$got expected=$2"; }
upload(){
 local f="$1" p="$2" j="$OUT/up-$(basename "$f").json" want put got
 want="$(blob "$f")"
 python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage82 wrapper ABI evidence","content":base64.b64encode(p.read_bytes()).decode()}))
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
entry=("\n========== STAGE 82 REGISTRATION WRAPPER ABI ==========\nSTAGE82_RUN: "+sys.argv[3]+"\nSTAGE82_VERSION: STAGE82_V1_20261103\nSTAGE82_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nWRAPPER_ARGUMENT_FLOW: REVALIDATED | ACTIVATION_GATE: BLOCKED\nSTAGE82_LOGS: Development/Logs/stage82/"+sys.argv[3]+"/\n=======================================================\n").encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage82 wrapper ABI audit","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
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
trap 'rc=$?; if ((rc!=0)); then { echo "STAGE=82";echo "VERSION=STAGE82_V1_20261103";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"; if gh auth status >/dev/null 2>&1; then python3 - "$OUT/failure-report.txt" "$OUT/failure.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage82 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage82/$RUN/failure-report.txt" --input "$OUT/failure.json" >/dev/null || true; fi; fi' EXIT
for t in curl gh python3 grep awk sw_vers uname tee date tail basename; do command -v "$t" >/dev/null 2>&1 || fail "missing tool $t"; done
[[ -d "$SRC/src" ]] || fail "project source directory missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1/24H32/x86_64"
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage73-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
pin stage79-flow.txt 9ce6b4aebec60952bd7ae2d86e2a35ce1fc34771 "$BASE/stage79/run-20261102-185618-e15eed178161/registration-wrapper-argument-flow.txt"
pin stage79-summary.txt 4cbb13220af0ec77d4ede8c48ea3a755f65a7f43 "$BASE/stage79/run-20261102-185618-e15eed178161/audit-summary.txt"
pin stage62-summary.txt 99415ab0329a1973fd004e67d20da3b8acff7120 "$BASE/stage62/run-20261102-161032-d54adc732d87/audit-summary.txt"
grep -q '^RESULT=PASS$' "$OUT/stage62-summary.txt" || fail "Stage62 evidence not PASS"
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
rows=["STAGE82_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok: raise SystemExit("source tree differs from Stage73 baseline")
PY
python3 - "$OUT/stage79-flow.txt" "$OUT/wrapper-abi-argument-flow.txt" "$OUT/audit-summary.txt" "$OUT/report.txt" "$RUN" <<'PY'
import pathlib,re,sys
flow=pathlib.Path(sys.argv[1]).read_text(errors="replace")
out=pathlib.Path(sys.argv[2]);summary_path=pathlib.Path(sys.argv[3]);report_path=pathlib.Path(sys.argv[4]);run=sys.argv[5]
def section(marker):
 i=flow.find(marker)
 if i<0: raise SystemExit("missing pinned method section: "+marker)
 # Skip the immediately following "===== METHOD class=..." heading;
 # that heading belongs to this section, not the next section.
 first=flow.find("\n===== ",i+len(marker))
 if first<0: return flow[i:]
 second=flow.find("\n===== ",first+1)
 return flow[i:second if second>=0 else len(flow)]
def ins(block):
 a=block.find("DISASSEMBLY_BEGIN");b=block.find("DISASSEMBLY_END",a)
 if a<0 or b<0: raise SystemExit("bad disassembly block")
 return [m.group(1).strip() for line in block[a:b].splitlines() if (m:=re.match(r"^\s*[0-9a-fA-F]+:\s+(.*)$",line))]
infra=ins(section("===== INFRA PINNED APPLE METHOD ====="))
eth=ins(section("===== ETHERNET PINNED APPLE METHOD ====="))
array=ins(section("===== ARRAY PINNED APPLE METHOD ====="))
logical=ins(section("===== LOGICAL PINNED APPLE METHOD ====="))
def has(seq,pat): return any(re.search(pat,x,re.I) for x in seq)
def idx(seq,pat):
 return next((i for i,x in enumerate(seq) if re.search(pat,x,re.I)),-1)
checks={}
checks["INFRA_ENTRY_CAPTURES_INFO_QUEUE_COUNT_AND_POOLS"]=all([
 has(infra,r"mov\s+r13,\s*rsi$"),has(infra,r"mov\s+qword ptr \[rbp - 0x78\],\s*rdx$"),
 has(infra,r"mov\s+r15d,\s*ecx$"),has(infra,r"mov\s+qword ptr \[rbp - 0x80\],\s*r8$"),has(infra,r"mov\s+r12,\s*r9$")])
i_call=idx(infra,r"call\s+0xffffff8002988078\b")
i_rdx=idx(infra,r"mov\s+rdx,\s*qword ptr \[rbp - 0x78\]$")
i_r8=idx(infra,r"mov\s+r8,\s*qword ptr \[rbp - 0x80\]$")
checks["INFRA_FORWARDS_ALL_SIX_REGISTER_ARGUMENTS"]=all([
 i_call>0,i_rdx>0,i_r8>0,idx(infra,r"mov\s+rdi,\s*rbx$")<i_call,
 idx(infra,r"mov\s+rsi,\s*r13$")<i_call,idx(infra,r"mov\s+ecx,\s*r15d$")<i_call,
 idx(infra,r"mov\s+r9,\s*r12$")<i_call,i_rdx<i_call,i_r8<i_call,
 not any(re.search(r"\bcall\b",x,re.I) for x in infra[max(i_rdx,i_r8)+1:i_call])])
checks["INFRA_FINAL_STACK_OPTION_ZERO"]=has(infra,r"push\s+0x0$") and idx(infra,r"push\s+0x0$")<i_call
checks["ETHERNET_ENTRY_PRESERVES_ARRAY_COUNT_AND_POOLS"]=all([
 has(eth,r"mov\s+r12,\s*rdx$"),has(eth,r"mov\s+r15d,\s*ecx$"),
 has(eth,r"mov\s+r14,\s*r8$"),has(eth,r"mov\s+qword ptr \[rbp - 0x30\],\s*r9$")])
checks["ETHERNET_LOADS_COPIED_REGISTRATION_INFO"]=has(eth,r"mov\s+rax,\s*qword ptr \[r13 \+ 0x108\]$") and has(eth,r"mov\s+rsi,\s*qword ptr \[rax\]$")
e_call=idx(eth,r"call\s+0xffffff8002981d7e\b")
checks["ETHERNET_FORWARDS_ARRAY_COUNT_AND_TWO_POOLS"]=all([
 e_call>0,idx(eth,r"mov\s+rdx,\s*r12$")<e_call,idx(eth,r"mov\s+ecx,\s*r15d$")<e_call,
 idx(eth,r"mov\s+r8,\s*r14$")<e_call,idx(eth,r"mov\s+r9,\s*qword ptr \[rbp - 0x30\]$")<e_call])
checks["ETHERNET_FINAL_OPTION_ZERO"]=has(eth,r"mov\s+dword ptr \[rsp\],\s*0x0$")
checks["ARRAY_OVERLOAD_PASSES_QUEUE_POINTER_AND_COUNT_TO_WMM"]=all([
 has(array,r"mov\s+rdi,\s*rdx$"),has(array,r"mov\s+rsi,\s*rbx$"),
 has(array,r"call\s+0xffffff800298ac44\b")])
checks["ARRAY_OVERLOAD_SETS_QUEUESET_CONTROL_0X3_OR_0XB"]=has(array,r"mov\s+dword ptr \[rbp - 0x84\],\s*0x3$") and has(array,r"mov\s+dword ptr \[rbp - 0x84\],\s*0xb$")
checks["ARRAY_OVERLOAD_CREATES_ONE_LOGICAL_LINK"]=has(array,r"mov\s+dword ptr \[rdx\],\s*0x1$") and has(array,r"mov\s+esi,\s*0x1$") and has(array,r"call\s+0xffffff80029839c6\b")
checks["ARRAY_OVERLOAD_CALLS_LOGICAL_LINK_REGISTRATION"]=has(array,r"call\s+0xffffff8002981eac\b")
checks["LOGICAL_LINK_OVERLOAD_CHECKS_REGISTRATION_INFO_VERSION_AND_SIZE"]=has(logical,r"cmp\s+dword ptr \[r12 \+ 0x4\],\s*0x108$") and has(logical,r"cmp\s+dword ptr \[r12\],\s*0x1$")
checks["LOGICAL_LINK_OVERLOAD_COPIES_0X108_REGISTRATION_INFO_BYTES"]=has(logical,r"mov\s+edx,\s*0x108$") and has(logical,r"mov\s+rsi,\s*r12$")
rows=["STAGE82_REGISTRATION_WRAPPER_ABI_ARGUMENT_FLOW","TARGET=macOS_15.8.1_24H32_x86_64","METHOD_EVIDENCE=Stage79 pinned Apple 24H32 disassembly"]
for label,seq in [("INFRA",infra),("ETHERNET",eth),("QUEUE_ARRAY",array),("LOGICAL_LINK",logical)]:
 rows.append("\n===== "+label+" RELEVANT INSTRUCTIONS =====")
 rows.extend(seq)
for k,v in checks.items(): rows.append("CHECK="+k+" RESULT="+("PASS" if v else "REVIEW_REQUIRED"))
rows += ["NOTE=Stage79's original literal-string checks are superseded by instruction-pattern and call-target checks in this audit.",
"LIMIT=This validates Apple's wrapper argument forwarding only; it does not create a driver registration callsite or prove private metadata formal sizes."]
out.write_text("\n".join(rows)+"\n")
count=sum(checks.values())
summary=[
"STAGE82_24H32_REGISTRATION_WRAPPER_ABI_REVALIDATION","TARGET=macOS_15.8.1_24H32_x86_64",
"SOURCE_TREE_REVALIDATION=PASS","WRAPPER_ABI_CHECKS=%d/%d"%(count,len(checks)),
"INFRA_TO_ETHERNET_ARGUMENT_FLOW="+("PASS" if checks["INFRA_FORWARDS_ALL_SIX_REGISTER_ARGUMENTS"] and checks["INFRA_FINAL_STACK_OPTION_ZERO"] else "REVIEW_REQUIRED"),
"ETHERNET_TO_ARRAY_ARGUMENT_FLOW="+("PASS" if checks["ETHERNET_FORWARDS_ARRAY_COUNT_AND_TWO_POOLS"] and checks["ETHERNET_FINAL_OPTION_ZERO"] else "REVIEW_REQUIRED"),
"QUEUE_ARRAY_TO_LOGICAL_LINK="+("PASS" if checks["ARRAY_OVERLOAD_CREATES_ONE_LOGICAL_LINK"] and checks["ARRAY_OVERLOAD_CALLS_LOGICAL_LINK_REGISTRATION"] else "REVIEW_REQUIRED"),
"REGISTRATION_INFO_VERSION_SIZE_CHECK="+("PASS" if checks["LOGICAL_LINK_OVERLOAD_CHECKS_REGISTRATION_INFO_VERSION_AND_SIZE"] else "REVIEW_REQUIRED"),
"PRIVATE_QUEUESET_INFO_SIZE=UNRESOLVED","PRIVATE_LOGICALLINK_INFO_SIZE=UNRESOLVED",
"DRIVER_NATIVE_REGISTRATION_CALL=NOT_AUDITED_BY_THIS_STAGE","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
"RESULT="+("PASS" if count==len(checks) else "REVIEW_REQUIRED"),"ACTIVATION_GATE=BLOCKED"]
summary_path.write_text("\n".join(summary)+"\n")
report_path.write_text("\n".join(["========== STAGE 82 REGISTRATION WRAPPER ABI ==========","VERSION=STAGE82_V1_20261103","RUN="+run,"",*summary,"","RESULT=PASS means the Apple-side register wrapper call chain was validated, not that the driver is registered or functional.","========== END STAGE 82 =========="])+"\n")
print("\n".join(summary))
if count!=len(checks): raise SystemExit("wrapper ABI evidence needs review")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=82";echo "VERSION=STAGE82_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/wrapper-abi-argument-flow.txt" "$OUT/report.txt"; do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN"; done
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/wrapper-abi-argument-flow.txt" "$OUT/report.txt" "$MAN"; do upload "$f" "Development/Logs/stage82/$RUN/$(basename "$f")"; done
append_log
echo "STAGE82_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE82_RUN=$RUN"
echo "STAGE82_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage82/$RUN"
