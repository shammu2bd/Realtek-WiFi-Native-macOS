#!/bin/bash
# Stage 73 V1 — TX/RX queue-to-adapter ownership path and teardown inventory.
# VERSION_MARKER: STAGE73_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE73_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE72_RUN="run-20261102-180101-2f24c05d158d"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage73/$RUN"
PREV="$OUT/predecessor-evidence"
mkdir -p "$OUT" "$PREV"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage73/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=73"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "========== CONSOLE TAIL =========="; tail -n 250 "$CONSOLE_LOG"
  echo "========== GENERATED FILES =========="; find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage73 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then echo "STAGE73_FAILURE_REPORT_GITHUB=$rp"; else echo "STAGE73_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 73 FAILURE REPORT ==========\nSTAGE73_FAILURE_RUN: %s\nSTAGE73_VERSION: %s\nSTAGE73_EXIT_CODE: %s\nSTAGE73_FAILED_LINE: %s\nSTAGE73_FAILED_COMMAND: %s\nSTAGE73_FAILURE_REPORT: %s\nSTAGE73_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage73 failure to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then echo "STAGE73_FAILURE_OUTPUT_LOG=UPDATED"; else echo "STAGE73_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE73_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE73_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee find date tail split; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -d "$SRC/src" ]] || fail "source directory missing: $SRC/src"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ local f="$1" want="$2" got; got="$(blob_sha "$f")"; [[ "$got" == "$want" ]] || fail "evidence pin mismatch: $(basename "$f") expected=$want got=$got"; echo "PIN_PASS=$(basename "$f") SHA=$got"; }

RAW72="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage72/$STAGE72_RUN"
for name in audit-summary.txt method-contract-matrix.txt callback-handoff-gap-matrix.txt report.txt manifest.txt; do
 curl -fsSLo "$PREV/stage72-$name" "$RAW72/$name"
done
pin "$PREV/stage72-audit-summary.txt" 0d12bdc35953c3743e6161d9fe6eba8d66340708
pin "$PREV/stage72-method-contract-matrix.txt" 0d6ad3a1a19c94df58b564711a4a156ffdcb4ad9
pin "$PREV/stage72-callback-handoff-gap-matrix.txt" ef34f453a43f5342973819942f7b344a7f91a9d8
pin "$PREV/stage72-report.txt" 8ade6e02846df438a98f1f8bf37333c03c9a7a6f
pin "$PREV/stage72-manifest.txt" 783229c01835cc5ab1d9ee245c96041fc3b3c84c
grep -q '^RESULT=PASS$' "$PREV/stage72-audit-summary.txt" || fail "Stage72 predecessor did not PASS"
grep -q '^CALLEE_METHOD_CONTRACTS=12/12_PASS$' "$PREV/stage72-audit-summary.txt" || fail "Stage72 callee contract count mismatch"
grep -q '^CALLBACK_STUBS_CONFIRMED=4/4$' "$PREV/stage72-audit-summary.txt" || fail "Stage72 callback evidence count mismatch"

python3 - "$SRC" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
files=sorted(p for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts)
if not files: raise SystemExit("No C/C++ source files found under src/src")
texts={}
for p in files:
 try: texts[p]=p.read_text(errors="replace")
 except OSError: continue
hash_lines=["STAGE73_SOURCE_TREE_SHA256","SOURCE_FILE_COUNT=%d"%len(texts)]
for p,body in texts.items():
 rel=p.relative_to(src).as_posix()
 hash_lines.append(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+rel)
(out/"source-tree-fingerprint.txt").write_text("\n".join(hash_lines)+"\n")

# Search inventory: map public registration, callbacks, adapters, packet pools,
# deferred RX delivery and lifecycle/rollback terms to exact source locations.
patterns={
 "QUEUE_REGISTRATION":r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|registerLogicalLink|createLogicalLink|deleteLogicalLink|QueueSet|LogicalLink|RegistrationInfo",
 "QUEUE_CONSTRUCTION":r"initWithPool|QueueDescriptor|queueSet|_txSubmission|_txCompletion|_rxSubmission|_rxCompletion|packetPool|PacketBufferPool",
 "TX_HANDOFF":r"txSubmissionAction|submitPacket\s*\(|outputPacketWithCompletion|backendCompletion|drainCompletions|claimCompleted|packetSubmission",
 "RX_HANDOFF":r"rxSubmissionAction|rxCompletionAction|copyMbufToSkywalkPacket|checkForWork|stagedRxFrame|_stagedRxPackets|enqueue.*Packet|receivePacket",
 "OWNERSHIP":r"TicketPool|reserve\s*\(|claimCompleted|packet->retain|packet->release|deallocatePacket|deallocatePackets|disposeAllPackets|completeWithQueue|completePreparedPacket",
 "TEARDOWN":r"removeEventSource|_stopping|quiesce|deregister|deleteLogicalLink|detach|recycleStagedRxPackets|disposeAllPackets|stop\s*\("}
ref=["STAGE73_SOURCE_REFERENCE_INVENTORY"]
for label,pattern in patterns.items():
 rx=re.compile(pattern,re.I); count=0
 ref.append("\nCATEGORY="+label)
 for p,body in texts.items():
  rel=p.relative_to(src).as_posix()
  for n,line in enumerate(body.splitlines(),1):
   if rx.search(line):
    count+=1
    ref.append("%s:%d: %s"%(rel,n,line.strip()[:260]))
 ref.append("CATEGORY_HITS=%d"%count)
(out/"source-reference-inventory.txt").write_text("\n".join(ref)+"\n")

# Extract named member-function bodies with brace balancing. This is source text
# only; no source is compiled or modified.
specs=[
 ("RTW88WCLSkywalkQueues",["txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction","start","stop","registerQueues","unregisterQueues"]),
 ("RTW88WCLSkywalkTxAdapter",["submitPacket","backendCompletion","drainCompletions","start","stop"]),
 ("RTW88WCLSkywalkRxAdapter",["copyMbufToSkywalkPacket","checkForWork","start","stop","enqueue","signal"]),
 ("RTW88WCLController",["stagedRxFrame","recycleStagedRxPackets","start","stop","free","stopAdapters"])]
def skip_quote(s,i):
 q=s[i]; i+=1
 while i<len(s):
  if s[i]=="\\": i+=2; continue
  if s[i]==q: return i+1
  i+=1
 return i
def close_paren(s,i):
 depth=0
 while i<len(s):
  if s.startswith("//",i):
   j=s.find("\n",i); i=len(s) if j<0 else j+1; continue
  if s.startswith("/*",i):
   j=s.find("*/",i+2); i=len(s) if j<0 else j+2; continue
  if s[i] in "\"" + "'": i=skip_quote(s,i); continue
  if s[i]=="(": depth+=1
  elif s[i]==")":
   depth-=1
   if depth==0:return i
  i+=1
 return -1
def close_brace(s,i):
 depth=0
 while i<len(s):
  if s.startswith("//",i):
   j=s.find("\n",i); i=len(s) if j<0 else j+1; continue
  if s.startswith("/*",i):
   j=s.find("*/",i+2); i=len(s) if j<0 else j+2; continue
  if s[i] in "\"" + "'": i=skip_quote(s,i); continue
  if s[i]=="{": depth+=1
  elif s[i]=="}":
   depth-=1
   if depth==0:return i
  i+=1
 return -1
body_lines=["STAGE73_MEMBER_FUNCTION_BODY_INVENTORY"]
found={}
for cls,methods in specs:
 for method in methods:
  rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(method)+r"\s*\(")
  hits=[]
  for p,body in texts.items():
   for m in rx.finditer(body):
    par=close_paren(body,m.end()-1)
    if par<0: continue
    # Function definition has a body before a terminating semicolon.
    brace=body.find("{",par+1); semi=body.find(";",par+1)
    if brace<0 or (semi>=0 and semi<brace): continue
    end=close_brace(body,brace)
    if end<0: continue
    line=body.count("\n",0,m.start())+1
    rel=p.relative_to(src).as_posix()
    item=(rel,line,body[m.start():end+1])
    if not any(x[0]==rel and x[1]==line for x in hits): hits.append(item)
  found[(cls,method)]=hits
  body_lines.append("\n===== "+cls+"::"+method+" FOUND_COUNT="+str(len(hits))+" =====")
  for rel,line,chunk in hits:
   body_lines.append("SOURCE="+rel+":"+str(line))
   body_lines.append(chunk[:18000])
(out/"member-function-bodies.txt").write_text("\n".join(body_lines)+"\n")

def one(cls,method):
 hs=found.get((cls,method),[])
 return hs[0][2] if hs else ""
def has(body,rx): return bool(re.search(rx,body,re.I))
chain=[]
def row(name,cls,method,checks):
 b=one(cls,method); vals=[has(b,x) for x in checks]
 chain.append("NODE="+name+"|SOURCE_BODY="+("FOUND" if b else "MISSING")+"|CHECKS="+str(sum(vals))+"/"+str(len(vals))+"|RESULT="+("PASS" if b and all(vals) else "GAP_OR_REVIEW"))
row("TX_SUBMISSION_CALLBACK","RTW88WCLSkywalkQueues","txSubmissionAction",[r"RTW88WCLResolveEthernetTxPacket",r"submitPacket\s*\("])
row("TX_COMPLETION_CALLBACK","RTW88WCLSkywalkQueues","txCompletionAction",[r"drainCompletions\s*\(",r"completeWithQueue|enqueue"])
row("RX_SUBMISSION_CALLBACK","RTW88WCLSkywalkQueues","rxSubmissionAction",[r"allocatePacket|allocatePackets|enqueue|prepare"])
row("RX_COMPLETION_CALLBACK","RTW88WCLSkywalkQueues","rxCompletionAction",[r"stagedRxFrame|enqueue|deliverPacket|receivePacket"])
row("TX_ADAPTER_SUBMIT","RTW88WCLSkywalkTxAdapter","submitPacket",[r"outputPacketWithCompletion",r"TicketPool::reserve|\.reserve\s*\(",r"packet->retain"])
row("TX_BACKEND_COMPLETION","RTW88WCLSkywalkTxAdapter","backendCompletion",[r"TicketPool|ticket",r"transmit|complete|status"])
row("TX_COMPLETION_DRAIN","RTW88WCLSkywalkTxAdapter","drainCompletions",[r"claimCompleted",r"sink\(",r"TicketPool::finish",r"packet->release"])
row("RX_COPY_AND_DEFERRED_SINK","RTW88WCLSkywalkRxAdapter","checkForWork",[r"copyMbufToSkywalkPacket",r"_sink",r"deallocatePacket"])
row("CONTROLLER_RX_STAGE","RTW88WCLController","stagedRxFrame",[r"_stagedRxPackets\.push"])
row("CONTROLLER_RX_RECYCLE","RTW88WCLController","recycleStagedRxPackets",[r"deallocatePacket",r"disposeAllPackets"])
(out/"ownership-chain-matrix.txt").write_text("STAGE73_TX_RX_OWNERSHIP_CHAIN_MATRIX\n"+"\n".join(chain)+"\n")

# A concise explicit blocker inventory. A PASS here means the gap was positively
# identified; it does not mean the datapath is implemented.
blockers=[
 "TX_ACTION_TO_ADAPTER="+("MISSING" if not has(one("RTW88WCLSkywalkQueues","txSubmissionAction"),r"submitPacket\s*\(") else "SOURCE_REFERENCE_PRESENT"),
 "TX_COMPLETION_TO_DRAIN="+("MISSING" if not has(one("RTW88WCLSkywalkQueues","txCompletionAction"),r"drainCompletions\s*\(") else "SOURCE_REFERENCE_PRESENT"),
 "RX_SUBMISSION_REFILL_OR_ENQUEUE="+("MISSING" if not has(one("RTW88WCLSkywalkQueues","rxSubmissionAction"),r"allocatePacket|allocatePackets|enqueue|prepare") else "SOURCE_REFERENCE_PRESENT"),
 "RX_COMPLETION_DELIVERY="+("MISSING" if not has(one("RTW88WCLSkywalkQueues","rxCompletionAction"),r"stagedRxFrame|enqueue|deliverPacket|receivePacket") else "SOURCE_REFERENCE_PRESENT"),
 "TX_ADAPTER_BACKEND_COMPLETION="+("PRESENT" if one("RTW88WCLSkywalkTxAdapter","backendCompletion") else "MISSING"),
 "TX_ADAPTER_DEFERRED_DRAIN="+("PRESENT" if one("RTW88WCLSkywalkTxAdapter","drainCompletions") else "MISSING"),
 "RX_ADAPTER_DEFERRED_SINK="+("PRESENT" if one("RTW88WCLSkywalkRxAdapter","checkForWork") else "MISSING"),
 "RX_CONTROLLER_STAGING="+("PRESENT" if one("RTW88WCLController","stagedRxFrame") else "MISSING"),
 "RX_CONTROLLER_RECYCLE="+("PRESENT" if one("RTW88WCLController","recycleStagedRxPackets") else "MISSING")]
(out/"handoff-blocker-inventory.txt").write_text("STAGE73_HANDOFF_BLOCKER_INVENTORY\n"+"\n".join(blockers)+"\n")

# Baseline ABI-facing source hashes are independently pinned to Stage43.
expected={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"}
finger=[]; source_ok=True
for rel,want in expected.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"; ok=got==want; source_ok &= ok
 finger += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if ok else "MISMATCH")]
(out/"baseline-source-fingerprint.txt").write_text("\n".join(finger)+"\n")
required=[("RTW88WCLSkywalkQueues","txSubmissionAction"),("RTW88WCLSkywalkQueues","txCompletionAction"),("RTW88WCLSkywalkQueues","rxSubmissionAction"),("RTW88WCLSkywalkQueues","rxCompletionAction"),("RTW88WCLSkywalkTxAdapter","submitPacket"),("RTW88WCLSkywalkTxAdapter","backendCompletion"),("RTW88WCLSkywalkTxAdapter","drainCompletions"),("RTW88WCLSkywalkRxAdapter","checkForWork"),("RTW88WCLController","stagedRxFrame"),("RTW88WCLController","recycleStagedRxPackets")]
missing=[c+"::"+m for c,m in required if not found.get((c,m))]
all_ref=sum(1 for x in ref if re.match(r"^[^\n]+:\d+: ",x))
summary=[
 "STAGE73_TX_RX_OWNERSHIP_PATH_AND_TEARDOWN_INVENTORY",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE72_PREDECESSOR=PASS",
 "SOURCE_FILES_SCANNED=%d"%len(texts),
 "SOURCE_BASELINE_FINGERPRINTS="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "REQUIRED_MEMBER_BODIES=%d/%d"%(len(required)-len(missing),len(required)),
 "MISSING_MEMBER_BODIES="+(",".join(missing) if missing else "NONE"),
 "TX_ACTION_TO_ADAPTER="+blockers[0].split("=",1)[1],
 "TX_COMPLETION_TO_DRAIN="+blockers[1].split("=",1)[1],
 "RX_SUBMISSION_REFILL_OR_ENQUEUE="+blockers[2].split("=",1)[1],
 "RX_COMPLETION_DELIVERY="+blockers[3].split("=",1)[1],
 "ADAPTER_AND_CONTROLLER_SUPPORT_PATHS=INVENTORIED",
 "SOURCE_REFERENCE_INVENTORY=GENERATED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(["MISSING_BODY:"+x for x in missing]+([] if source_ok else ["BASELINE_SOURCE_HASH_MISMATCH"])) or "NONE"),
 "RESULT="+("PASS" if source_ok and not missing else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 73 TX/RX OWNERSHIP PATH / TEARDOWN INVENTORY ==========",
 "VERSION=STAGE73_V1_20261102","RUN="+out.name,"TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "PREDECESSOR=Stage72 V1 run "+ "run-20261102-180101-2f24c05d158d",
 "PURPOSE=map existing queue callbacks, TX/RX adapters, controller staging/recycling, packet ownership calls and teardown paths before implementation",
 "SCOPE=read-only source-tree symbol search, member-body extraction, ownership-chain matrix and baseline source fingerprint",
 "IMPORTANT=an identified missing callback edge is a blocker, not permission to return success or silently transfer packet ownership",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "ARTIFACTS=source-reference-inventory.txt,member-function-bodies.txt,ownership-chain-matrix.txt,handoff-blocker-inventory.txt,source-tree-fingerprint.txt,baseline-source-fingerprint.txt",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 73 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=73"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=source-level TX/RX packet ownership and teardown path inventory"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage72 run $STAGE72_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"; PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage73 ownership path audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$expected" && "$got" == "$expected" ]] || { echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$OUT/upload-error.txt"; return 1; }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-reference-inventory.txt "$OUT"/member-function-bodies.txt "$OUT"/ownership-chain-matrix.txt "$OUT"/handoff-blocker-inventory.txt "$OUT"/source-tree-fingerprint.txt "$OUT"/baseline-source-fingerprint.txt; do
 [[ -f "$f" ]] || fail "missing Stage73 artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$f" "Development/Logs/stage73/$RUN/$(basename "$f")"
 else
  split -b 220k "$f" "$f.part-"
  for part in "$f".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage73/$RUN/$(basename "$part")"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage73/$RUN/manifest.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 73 TX/RX OWNERSHIP PATH INVENTORY ==========\n"
 "STAGE73_RUN: %s\n"%run+
 "STAGE73_VERSION: %s\n"%version+
 "STAGE73_SCOPE: map native queue callbacks, TX/RX adapters, packet ownership and teardown dependencies\n"+
 "STAGE73_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — no TX/RX callback handoff or native queue registration implemented by this inventory\n"+
 "STAGE73_LOGS: Development/Logs/stage73/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(o["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage73 ownership path inventory","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE73_VERSION=$VERSION"
echo "STAGE73_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE73_RUN=$RUN"
echo "STAGE73_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE73_LOCAL_OUTPUT=$OUT"
echo "STAGE73_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage73/$RUN"
echo "STAGE73_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE73_SOURCE_MODIFIED=NO"
echo "STAGE73_BUILD=NOT_RUN"
echo "STAGE73_INSTALL=NOT_RUN"
echo "STAGE73_LOAD=NOT_RUN"
