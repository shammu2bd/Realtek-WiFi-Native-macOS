#!/bin/bash
# Stage 80 V1 — 24H32 four-queue descriptor/type-code and pool mapping audit.
# VERSION_MARKER: STAGE80_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage80/$RUN"
mkdir -p "$OUT";exec > >(tee -a "$OUT/console-output.log") 2>&1
fail(){ echo "ERROR: $*" >&2;exit 2; }
trap 'rc=$?;if ((rc!=0));then { echo "STAGE=80";echo "RUN=$RUN";echo "EXIT_CODE=$rc";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "INSTALL=NOT_RUN";echo "LOAD=NOT_RUN";tail -n 160 "$OUT/console-output.log";} > "$OUT/failure-report.txt";if gh auth status >/dev/null 2>&1;then python3 - "$OUT/failure-report.txt" "$OUT/fail.json" <<'"'"'PY'"'"'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Stage80 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/Logs/stage80/$RUN/failure-report.txt" --input "$OUT/fail.json" >/dev/null || true;fi;fi' EXIT
for t in curl gh python3 grep awk sw_vers uname wc tr tee date tail cut basename;do command -v "$t" >/dev/null 2>&1||fail "missing tool $t";done
[[ -d "$SRC/src" ]]||fail "source root missing"
gh auth status >/dev/null 2>&1||fail "GitHub CLI not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]]||fail "target must be macOS 15.8.1/24H32/x86_64"
blob(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes();print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ curl -fsSLo "$OUT/$1" "$3";got="$(blob "$OUT/$1")";[[ "$got" == "$2" ]]||fail "pin mismatch $1 got=$got expected=$2"; }
BASE="https://raw.githubusercontent.com/$REPO/main/Development/Logs"
pin stage61-audit-summary.txt 0bd6d1c41871f7a4659c8499265b5533170fd116 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/audit-summary.txt"
pin stage61-descriptor-matrix.txt 04c68bd635f16bc7a51615031f8950d620ba0818 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queue-descriptor-record-matrix.txt"
pin stage61-jump-tables.txt 7b017c03a4f008ba017a0f40d557132a3f623f2f "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queueset-classification-jump-tables.txt"
pin stage61-queueset-disassembly.txt 80d8fd7434a835f3cc6a072edb36419bfcfdd5d6 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queueset-init-disassembly.txt"
pin stage61-command-disassembly.txt 0e2edad27bfd9b0346d1d0bc44fbb2cc539fdf43 "$BASE/stage61/run-20261102-152354-434ec3c3ae26/queue-command-method-disassembly.txt"
pin stage73-source-fingerprint.txt 74a6ab39ea5e273d1788d17ea8c99895a1fd86df "$BASE/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
grep -q '^RESULT=PASS$' "$OUT/stage61-audit-summary.txt"||fail "Stage61 descriptor analysis not PASS"

# Find the exact Stage79 run produced immediately before this stage, then verify its manifest pins.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/prior-output.json"
python3 - "$OUT/prior-output.json" "$OUT/stage79-run.txt" <<'PY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=re.findall(r"STAGE79_RUN: (run-[A-Za-z0-9-]+)",s)
if not m:raise SystemExit("Stage79 run is missing from output.log")
open(sys.argv[2],"w").write(m[-1])
PY
STAGE79_RUN="$(cat "$OUT/stage79-run.txt")"
RAW79="$BASE/stage79/$STAGE79_RUN"
pin stage79-manifest.txt "$(python3 - "$RAW79/manifest.txt" "$OUT/stage79-manifest.txt" <<'PY'
import urllib.request,hashlib,sys
b=urllib.request.urlopen(sys.argv[1]).read();open(sys.argv[2],"wb").write(b);print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
)" "$RAW79/manifest.txt"
for name in audit-summary.txt registration-wrapper-argument-flow.txt report.txt;do
 want="$(awk -F'|' -v n="$name" '$1=="ARTIFACT"&&$2==n{print $3}' "$OUT/stage79-manifest.txt")"
 [[ -n "$want" ]]||fail "Stage79 manifest missing $name"
 pin "stage79-$name" "$want" "$RAW79/$name"
done
grep -q '^RESULT=PASS$' "$OUT/stage79-audit-summary.txt"||fail "Stage79 predecessor not PASS"

python3 - "$SRC" "$OUT/stage73-source-fingerprint.txt" "$OUT/source-tree-revalidation.txt" "$OUT/stage61-descriptor-matrix.txt" "$OUT/stage61-jump-tables.txt" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]);fp=pathlib.Path(sys.argv[2]);out=pathlib.Path(sys.argv[3]);desc=pathlib.Path(sys.argv[4]).read_text();jumps=pathlib.Path(sys.argv[5]).read_text();root=pathlib.Path(sys.argv[6])
expected={}
for l in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",l)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE80_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for p in sorted(set(expected)|set(actual)):
 a=expected.get(p,"MISSING");b=actual.get(p,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+p+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok:raise SystemExit("Stage73 source baseline mismatch")
q=(src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp").read_text(errors="replace")
h=(src/"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp").read_text(errors="replace")
calls=list(re.finditer(r"(_(?:tx|rx)(?:Submission|Completion))\s*=\s*(IOSkywalk\w+Queue)::withPool\s*\((.*?)\);",q,re.S))
mapping={
"_txSubmission":("IOSkywalkTxSubmissionQueue","_txPool","txSubmissionAction",1),
"_txCompletion":("IOSkywalkTxCompletionQueue","_txPool","txCompletionAction",2),
"_rxSubmission":("IOSkywalkRxSubmissionQueue","_rxPool","rxSubmissionAction",3),
"_rxCompletion":("IOSkywalkRxCompletionQueue","_rxPool","rxCompletionAction",4)}
found={};cross=["STAGE80_DRIVER_QUEUE_FACTORY_TO_APPLE_TYPECODE_CROSSWALK"]
for m in calls:
 member,klass,args=m.group(1),m.group(2),m.group(3)
 found[member]=(klass,args)
 pos=q.count("\n",0,m.start())+1
 expected_class,pool,cb,code=mapping.get(member,("","","",-1))
 valid=member in mapping and klass==expected_class and pool in args and cb in args
 cross.append("QUEUE_MEMBER=%s|SOURCE_LINE=%d|CLASS=%s|POOL=%s|CALLBACK=%s|APPLE_TYPECODE=%s|RESULT=%s"%(member,pos,klass,pool,cb,code,"PASS" if valid else "REVIEW_REQUIRED"))
 if member not in mapping or not valid:ok=False
cross.append("FACTORY_CALLS_FOUND=%d"%len(calls))
cross.append("QUEUE_HEADER_POOL_MEMBERS="+",".join(x for x in ["_txPool","_rxPool","_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"] if x in h))
cross.append("APPLE_DESCRIPTOR_LAYOUT=uint32_typeCode@+0x00;uint32_capacity@+0x04;IOSkywalkPacketBufferPool*@+0x08")
cross.append("APPLE_QUERY=performCommand(command=0x10000,dataSize=0x10)")
cross.append("TYPECODE_1=IOSkywalkTxSubmissionQueue")
cross.append("TYPECODE_2=IOSkywalkTxCompletionQueue")
cross.append("TYPECODE_3=IOSkywalkRxSubmissionQueue")
cross.append("TYPECODE_4=IOSkywalkRxCompletionQueue")
cross.append("QUEUESET_ARRAY_MEMBER_OFFSETS=0x20,0x28,0x30,0x38")
cross.append("QUEUESET_COUNT_MEMBER_OFFSETS=0x60,0x68,0x70,0x78")
cross.append("DESCRIPTOR_CAPACITY=TX_SUBMISSION_AND_RX_COMPLETION_EXPLICIT;TX_COMPLETION_AND_RX_SUBMISSION_ZERO")
cross.append("INPUT_ARRAY_ORDER=NOT_PROVEN_AS_A_REQUIRED_ORDER;QueueSet groups by queried typeCode; WMM predicate order requirements are not resolved here")
cross.append("CURRENT_SOURCE_QUEUE_POINTER_ARRAY=NOT_MATERIALIZED")
(root/"queue-constructor-and-typecode-crosswalk.txt").write_text("\n".join(cross)+"\n")
summary=[
"STAGE80_24H32_QUEUE_TYPECODE_AND_POOL_CROSSWALK_AUDIT",
"TARGET=macOS_15.8.1_24H32_x86_64","STAGE61_PREDECESSOR=PIN_PASS","STAGE79_PREDECESSOR=PASS",
"SOURCE_TREE_REVALIDATION=PASS","QUEUE_FACTORY_CALLS_FOUND=%d"%len(calls),
"EXPECTED_QUEUE_FACTORIES=4/4","FACTORY_TO_APPLE_TYPECODE_MATCHES=%d/4"%sum(1 for x in cross if "|RESULT=PASS" in x),
"APPLE_TYPECODES=1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION",
"DESCRIPTOR_SIZE=0x10","QUEUESET_PER_TYPE_ARRAY_OFFSETS=0x20,0x28,0x30,0x38",
"QUEUESET_PER_TYPE_COUNT_OFFSETS=0x60,0x68,0x70,0x78",
"TX_POOL_MAPPING=TX_SUBMISSION_AND_TX_COMPLETION","RX_POOL_MAPPING=RX_SUBMISSION_AND_RX_COMPLETION",
"INPUT_ARRAY_ORDER=NOT_PROVEN_AS_A_REQUIRED_ORDER","QUEUE_POINTER_ARRAY_MATERIALIZATION=NOT_FOUND",
"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
"ISSUES="+("NONE" if len(calls)==4 and len([x for x in cross if "|RESULT=PASS" in x])==4 else "QUEUE_FACTORY_CROSSWALK_REVIEW"),
"RESULT="+("PASS" if len(calls)==4 and len([x for x in cross if "|RESULT=PASS" in x])==4 else "REVIEW_REQUIRED"),
"ACTIVATION_GATE=BLOCKED"]
(root/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(root/"report.txt").write_text("\n".join(["========== STAGE 80 QUEUE TYPECODE / POOL CROSSWALK ==========","VERSION=STAGE80_V1_20261103","RUN="+root.name,"",*summary,"","The Apple QueueSet classifies queue objects using their performCommand descriptor type code; this audit does not claim an input-array order is mandatory.","========== END STAGE 80 =========="])+"\n")
print("\n".join(summary))
if len(calls)!=4 or len([x for x in cross if "|RESULT=PASS" in x])!=4:raise SystemExit("queue factory crosswalk review required")
PY
MAN="$OUT/manifest.txt"
{ echo "STAGE=80";echo "VERSION=STAGE80_V1_20261103";echo "RUN=$RUN";echo "TARGET=15.8.1/24H32/x86_64";echo "PREDECESSOR=Stage79 run $STAGE79_RUN";echo "SOURCE_MODIFIED=NO";echo "BUILD=NOT_RUN";echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-constructor-and-typecode-crosswalk.txt" "$OUT/report.txt";do echo "ARTIFACT|$(basename "$f")|$(blob "$f")" >> "$MAN";done
upload(){
 local f="$1" p="$2" j="$OUT/payload-$(basename "$f").json" put got want
 want="$(blob "$f")";python3 - "$f" "$j" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage80 queue typecode evidence","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$p" --input "$j" > "$OUT/put.json"
 put="$(python3 - "$OUT/put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)";got="$(gh api "repos/$REPO/contents/$p" -q .sha)"
 [[ "$put" == "$want" && "$got" == "$want" ]]||fail "readback mismatch $p"
}
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/queue-constructor-and-typecode-crosswalk.txt" "$OUT/report.txt" "$MAN";do upload "$f" "Development/Logs/stage80/$RUN/$(basename "$f")";done
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/outlog.json"
python3 - "$OUT/outlog.json" "$OUT/outlog-payload.json" "$RUN" "$STAGE79_RUN" <<'PY'
import base64,json,pathlib,sys
o=json.load(open(sys.argv[1]));old=base64.b64decode(o["content"])
e=("\n========== STAGE 80 QUEUE TYPECODE CROSSWALK ==========\nSTAGE80_RUN: %s\nSTAGE80_VERSION: STAGE80_V1_20261103\nSTAGE80_PREDECESSOR_STAGE79_RUN: %s\nSTAGE80_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nACTIVATION_GATE: BLOCKED — the driver queue-pointer array and native registration call remain absent\nSTAGE80_LOGS: Development/Logs/stage80/%s/\n=======================================================\n"%(sys.argv[3],sys.argv[4],sys.argv[3])).encode()
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage80 queue typecode crosswalk","sha":o["sha"],"content":base64.b64encode(old.rstrip()+e).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/outlog-payload.json" > "$OUT/outlog-put.json"
P="$(python3 - "$OUT/outlog-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)";G="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$P" == "$G" ]]||fail "output.log readback mismatch"
echo "STAGE80_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt"|cut -d= -f2)"
echo "STAGE80_RUN=$RUN"
echo "STAGE80_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage80/$RUN"
