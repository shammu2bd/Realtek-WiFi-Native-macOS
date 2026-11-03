#!/bin/bash
# Stage 77 V1 — callback ABI, packet-count semantics and TX/RX ownership audit.
# VERSION_MARKER: STAGE77_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE77_V1_20261103"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE64_RUN="run-20261102-163320-6a2d28788a13"
STAGE66_RUN="run-20261102-170400-52c2a2c1997c"
STAGE74_RUN="run-20261102-181437-4023b97e1165"
STAGE75_RUN="run-20261102-182045-29fbc9d32933"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage77/$RUN"
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
pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage77 callback ownership audit to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+sys.argv[3].encode()).decode()}))
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
 local rc="$1" rp="Development/Logs/stage77/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 { echo "STAGE=77"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"; echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"; echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "===== CONSOLE TAIL ====="; tail -n 220 "$OUT/console-output.log"; } > "$OUT/failure-report.txt"
 if gh auth status >/dev/null 2>&1; then gh_contents_upload "$OUT/failure-report.txt" "$rp" "Upload Stage77 failure report" || true; append_output_log "\n========== STAGE 77 FAILURE ==========\nSTAGE77_FAILURE_RUN: $RUN\nSTAGE77_EXIT_CODE: $rc\nSTAGE77_FAILURE_REPORT: $rp\nSTAGE77_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n======================================\n" || true; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT
for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee date tail cut basename; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -d "$SRC/src" ]] || fail "source directory missing: $SRC/src"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "wrong host target; expected macOS 15.8.1/24H32/x86_64"
pin(){
 local file="$1" want="$2" url="$3" got
 curl -fsSLo "$OUT/$file" "$url"
 got="$(git_blob_sha "$OUT/$file")"
 [[ "$got" == "$want" ]] || fail "predecessor pin mismatch $file expected=$want got=$got"
 echo "PIN_PASS=$file SHA=$got"
}
RAW64="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage64/$STAGE64_RUN"
RAW66="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage66/$STAGE66_RUN"
RAW74="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage74/$STAGE74_RUN"
RAW75="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage75/$STAGE75_RUN"
pin "stage64-audit-summary.txt" a87be021ffef6de76199a4939c2d90d388fe1955 "$RAW64/audit-summary.txt"
pin "stage64-callback-behavior.txt" 9c4b083399aed46dbc027fb4457f13c61c890b6b "$RAW64/callback-behavior-matrix.txt"
pin "stage64-sdk-action-typedefs.txt" 777fdb451e766d271ce0a0c3b50227e2d0d521b2 "$RAW64/sdk-action-typedefs.txt"
pin "stage66-callback-registration-contract.txt" 562917e2c7d9c9e24baeceec5a0715bc653f1541 "$RAW66/callback-registration-contract.txt"
pin "stage74-callback-wiring-matrix.txt" aa80e1fd38423df4ef52e7715cf33ea64ecb71fd "$RAW74/callback-wiring-matrix.txt"
pin "stage75-audit-summary.txt" 8bf032d3916517c990eb37ae015711e057011e50 "$RAW75/audit-summary.txt"
grep -q '^RESULT=PASS$' "$OUT/stage64-audit-summary.txt" || fail "Stage64 callback ABI evidence not PASS"
grep -q '^RESULT=PASS$' "$OUT/stage75-audit-summary.txt" || fail "Stage75 source audit not PASS"

# Stage76 is produced immediately before this stage in the combined run.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/predecessor-output-log.json"
python3 - "$OUT/predecessor-output-log.json" "$OUT/stage76-run.txt" <<'PY'
import base64,json,re,sys
o=json.load(open(sys.argv[1])); s=base64.b64decode(o["content"]).decode(errors="replace")
m=re.findall(r"STAGE76_RUN: (run-[A-Za-z0-9-]+)",s)
if not m: raise SystemExit("Stage76 run is not present in output.log")
open(sys.argv[2],"w").write(m[-1])
PY
STAGE76_RUN="$(cat "$OUT/stage76-run.txt")"
RAW76="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage76/$STAGE76_RUN"
curl -fsSLo "$OUT/stage76-manifest.txt" "$RAW76/manifest.txt"
grep -q '^STAGE=76$' "$OUT/stage76-manifest.txt" || fail "Stage76 manifest missing"
for name in audit-summary.txt source-tree-revalidation.txt startup-control-flow-evidence.txt registration-and-packetpath-callsite-map.txt report.txt; do
 want="$(awk -F'|' -v n="$name" '$1=="ARTIFACT" && $2==n {print $3}' "$OUT/stage76-manifest.txt")"
 [[ -n "$want" ]] || fail "Stage76 manifest has no pin for $name"
 pin "stage76-$name" "$want" "$RAW76/$name"
done
grep -q '^RESULT=PASS$' "$OUT/stage76-audit-summary.txt" || fail "Stage76 predecessor audit did not PASS"

curl -fsSLo "$OUT/stage73-source-tree-fingerprint.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage73/run-20261102-180530-d711b3944b06/source-tree-fingerprint.txt"
[[ "$(git_blob_sha "$OUT/stage73-source-tree-fingerprint.txt")" == "74a6ab39ea5e273d1788d17ea8c99895a1fd86df" ]] || fail "Stage73 source fingerprint pin mismatch"
python3 - "$SRC" "$OUT/stage73-source-tree-fingerprint.txt" "$OUT/source-tree-revalidation.txt" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); fp=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
expected={}
for line in fp.read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m:expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
ok=len(expected)==91 and set(expected)==set(actual)
rows=["STAGE77_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
for rel in sorted(set(expected)|set(actual)):
 a=expected.get(rel,"MISSING");b=actual.get(rel,"MISSING")
 if a!=b:ok=False
 rows.append("FILE="+rel+" EXPECTED="+a+" ACTUAL="+b+" RESULT="+("MATCH" if a==b else "MISMATCH"))
out.write_text("\n".join(rows)+"\n")
if not ok:raise SystemExit("source tree changed from Stage73 baseline")
PY

python3 - "$SRC" "$OUT" <<'PY'
import pathlib,re,sys
src=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
relmap={
 "queues":"src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
 "queues_h":"src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp",
 "tx":"src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp",
 "rx":"src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp",
 "controller":"src/kext/wcl24h32/RTW88WCLController.cpp"}
files={k:(src/v).read_text(errors="replace") for k,v in relmap.items()}
def clean(s):
 out=[];i=0;state="code"
 while i<len(s):
  c=s[i];n=s[i+1] if i+1<len(s) else ""
  if state=="code":
   if c=='"':state="str";out.append(c);i+=1;continue
   if c=="'":state="char";out.append(c);i+=1;continue
   if c=="/" and n=="/":out.extend("  ");i+=2;state="line";continue
   if c=="/" and n=="*":out.extend("  ");i+=2;state="block";continue
   out.append(c);i+=1;continue
  if state in ("str","char"):
   out.append(c);i+=1
   if c=="\\" and i<len(s):out.append(s[i]);i+=1;continue
   if (state=="str" and c=='"') or (state=="char" and c=="'"):state="code"
   continue
  if state=="line":
   if c=="\n":out.append("\n");state="code"
   else:out.append(" ")
   i+=1;continue
  if state=="block":
   if c=="*" and n=="/":out.extend("  ");i+=2;state="code"
   else:out.append("\n" if c=="\n" else " ");i+=1
 return "".join(out)
code={k:clean(v) for k,v in files.items()}
def body(key,name):
 s=code[key];m=re.search(r"(?<![A-Za-z0-9_])"+re.escape(name)+r"\s*\(",s)
 if not m:return None
 b=s.find("{",m.end());semi=s.find(";",m.end())
 if b<0 or (semi>=0 and semi<b):return None
 depth=0;state="code";i=b
 while i<len(s):
  c=s[i]
  if state=="code":
   if c=='"':state="str"
   elif c=="'":state="char"
   elif c=="{":depth+=1
   elif c=="}":
    depth-=1
    if depth==0:return s[b:i+1],s.count("\n",0,b)+1
  elif state in ("str","char"):
   if c=="\\":i+=1
   elif (state=="str" and c=='"') or (state=="char" and c=="'"):state="code"
  i+=1
 return None
cb=[
 ("TX_SUBMISSION","txSubmissionAction","submitPacket","queues"),
 ("TX_COMPLETION","txCompletionAction","drainCompletions","queues"),
 ("RX_SUBMISSION","rxSubmissionAction","allocatePacket","queues"),
 ("RX_COMPLETION","rxCompletionAction","stagedRxFrame","queues")]
matrix=["STAGE77_CALLBACK_ABI_AND_OWNERSHIP_MATRIX",
 "RULE=queue Action callbacks use IOReturn; IOReturn success is not packet-count acceptance",
 "SEPARATE_RULE=Stage66 packet callback fields used by packet completion helpers return packet counts and are not the Stage64 Action callback typedefs"]
bodies=[]
for label,fn,target,key in cb:
 got=body("queues","RTW88WCLSkywalkQueues::"+fn)
 if not got:
  matrix.append("EDGE="+label+"|BODY=NOT_FOUND|TARGET_CALLS=UNKNOWN|RESULT=REVIEW_REQUIRED")
  continue
 b,start=got
 count=len(re.findall(r"(?<![A-Za-z0-9_])"+re.escape(target)+r"\s*\(",b))
 matrix.append("EDGE="+label+"|BODY=FOUND|RETURN_TYPE=IOReturn|TARGET="+target+"|TARGET_CALLS="+str(count)+"|RESULT="+("CONNECTED" if count else "MISSING"))
 bodies.append("\n===== "+label+" "+fn+" SOURCE_LINE="+str(start)+" =====")
 bodies.extend("%d: %s"%(start+i,x) for i,x in enumerate(b.splitlines()))
# Count adapter's actual deferred drain callers, excluding its method definition.
drain=[]
for key in ["queues","tx","rx","controller"]:
 for n,line in enumerate(code[key].splitlines(),1):
  if re.search(r"\bdrainCompletions\s*\(",line) and "::drainCompletions" not in line:
   drain.append((relmap[key],n,line.strip()))
matrix.append("TX_DRAIN_NONDEFINITION_CALLS="+str(len(drain)))
for x in drain:matrix.append("DRAIN_CALL="+str(x))
# Exact action declarations and definitions are saved, not inferred from return values.
for key in ["queues_h","queues"]:
 for n,line in enumerate(code[key].splitlines(),1):
  if re.search(r"txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction",line):
   matrix.append("CALLBACK_SIGNATURE_OR_REFERENCE="+relmap[key]+":"+str(n)+" "+line.strip()[:300])
# Controller receive callback and RX adapter acceptance path.
for key,tokens in [("rx",["copyMbufToSkywalkPacket","_sink","_rxPool->deallocatePacket"]),
                   ("controller",["stagedRxFrame","_stagedRxPackets.push","_stagedRxPackets.pop","inputPacket","receivePacket","deliverPacket"])]:
 for token in tokens:
  count=len(re.findall(r"(?<![A-Za-z0-9_])"+re.escape(token)+r"(?![A-Za-z0-9_])",code[key]))
  matrix.append("OWNERSHIP_TOKEN="+key+":"+token+"|COUNT="+str(count))
(out/"callback-contract-and-implementation-matrix.txt").write_text("\n".join(matrix)+"\n")
(out/"callback-method-bodies.txt").write_text("\n".join(bodies)+"\n")
blockers=[
 "STAGE77_PACKET_OWNERSHIP_BLOCKERS",
 "TX_SUBMISSION=callback currently validates packet descriptors; no submitPacket handoff",
 "TX_COMPLETION=callback stub; no adapter drain callsite; packet ticket drain helper exists but is unconnected",
 "RX_SUBMISSION=callback stub; no allocation/refill operation",
 "RX_COMPLETION=callback stub; no staged controller delivery call",
 "RX_ADAPTER=converts received mbufs to pool packets and invokes sink; sink rejection deallocates packet",
 "CONTROLLER_RX=staged ring is an intermediate ownership holder; current evidence does not show native RX completion queue delivery",
 "STATUS_SEMANTICS=Action callback return IOReturn success is not a packet count",
 "PACKET_COMPLETION_SEMANTICS=Stage66 packet callback return count is distinct; do not interchange these callback types",
 "ACTIVATION_GATE=BLOCKED"]
(out/"ownership-blocker-and-callback-contract.txt").write_text("\n".join(blockers)+"\n")
summary=[
 "STAGE77_24H32_CALLBACK_ABI_AND_PACKET_OWNERSHIP_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE76_PREDECESSOR=PASS","STAGE64_ACTION_TYPEDEFS=PIN_PASS","STAGE66_PACKET_CALLBACK_CONTRACT=PIN_PASS",
 "STAGE74_WIRING_MATRIX=PIN_PASS","STAGE75_REGISTRATION_AUDIT=PIN_PASS","SOURCE_TREE_REVALIDATION=PASS",
 "TX_SUBMISSION_TO_ADAPTER="+("CONNECTED" if "EDGE=TX_SUBMISSION|BODY=FOUND|RETURN_TYPE=IOReturn|TARGET=submitPacket|TARGET_CALLS=1" in "\n".join(matrix) else "MISSING"),
 "TX_COMPLETION_TO_DRAIN="+("CONNECTED" if "EDGE=TX_COMPLETION|BODY=FOUND|RETURN_TYPE=IOReturn|TARGET=drainCompletions|TARGET_CALLS=1" in "\n".join(matrix) else "MISSING"),
 "RX_SUBMISSION_TO_REFILL="+("CONNECTED" if "EDGE=RX_SUBMISSION|BODY=FOUND|RETURN_TYPE=IOReturn|TARGET=allocatePacket|TARGET_CALLS=1" in "\n".join(matrix) else "MISSING"),
 "RX_COMPLETION_TO_CONTROLLER="+("CONNECTED" if "EDGE=RX_COMPLETION|BODY=FOUND|RETURN_TYPE=IOReturn|TARGET=stagedRxFrame|TARGET_CALLS=1" in "\n".join(matrix) else "MISSING"),
 "TX_DRAIN_CALLSITES=%d"%len(drain),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_MODIFIED=NO",
 "ISSUES=NONE","RESULT=PASS","ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
(out/"report.txt").write_text("\n".join(["========== STAGE 77 CALLBACK / OWNERSHIP AUDIT ==========","VERSION=STAGE77_V1_20261103","RUN="+out.name,"PREDECESSOR=Stage76 startup gate audit","",*summary,"","RESULT=PASS denotes a completed read-only audit, not a working datapath.","========== END STAGE 77 =========="])+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{ echo "STAGE=77"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "TARGET=15.8.1/24H32/x86_64"; echo "PREDECESSOR=Stage76"; echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; } > "$MAN"
for f in "$OUT/audit-summary.txt" "$OUT/source-tree-revalidation.txt" "$OUT/callback-contract-and-implementation-matrix.txt" "$OUT/callback-method-bodies.txt" "$OUT/ownership-blocker-and-callback-contract.txt" "$OUT/report.txt"; do
 sha="$(git_blob_sha "$f")"; echo "ARTIFACT|$(basename "$f")|$sha" >> "$MAN"
 gh_contents_upload "$f" "Development/Logs/stage77/$RUN/$(basename "$f")" "Add Stage77 callback ownership evidence"
done
gh_contents_upload "$MAN" "Development/Logs/stage77/$RUN/manifest.txt" "Add Stage77 manifest"
append_output_log "\n========== STAGE 77 CALLBACK / OWNERSHIP AUDIT ==========\nSTAGE77_RUN: $RUN\nSTAGE77_VERSION: $VERSION\nSTAGE77_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\nACTIVATION_GATE: BLOCKED — four callback handoffs remain incomplete\nSTAGE77_LOGS: Development/Logs/stage77/$RUN/\n=========================================================\n"
echo "STAGE77_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE77_RUN=$RUN"
echo "STAGE77_GITHUB=https://github.com/$REPO/tree/main/Development/Logs/stage77/$RUN"
