#!/bin/bash
# Stage 74 V1 — 24H32 registration boundary, queue constructor and ownership wiring audit.
# VERSION_MARKER: STAGE74_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE74_V1_20261103"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE73_RUN="run-20261102-180530-d711b3944b06"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage74/$RUN"
PREV="$OUT/predecessor-evidence"
mkdir -p "$OUT" "$PREV"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage74/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=74"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "========== CONSOLE TAIL =========="; tail -n 250 "$CONSOLE_LOG"
  echo "========== GENERATED FILES =========="; find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage74 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then echo "STAGE74_FAILURE_REPORT_GITHUB=$rp"; else echo "STAGE74_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 74 FAILURE REPORT ==========\nSTAGE74_FAILURE_RUN: %s\nSTAGE74_VERSION: %s\nSTAGE74_EXIT_CODE: %s\nSTAGE74_FAILED_LINE: %s\nSTAGE74_FAILED_COMMAND: %s\nSTAGE74_FAILURE_REPORT: %s\nSTAGE74_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage74 failure to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then echo "STAGE74_FAILURE_OUTPUT_LOG=UPDATED"; else echo "STAGE74_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE74_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE74_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee find date tail split basename cut; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
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

RAW73="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage73/$STAGE73_RUN"
for name in audit-summary.txt source-tree-fingerprint.txt source-reference-inventory.txt member-function-bodies.txt ownership-chain-matrix.txt handoff-blocker-inventory.txt baseline-source-fingerprint.txt report.txt manifest.txt; do
 curl -fsSLo "$PREV/stage73-$name" "$RAW73/$name"
done
pin "$PREV/stage73-audit-summary.txt" e19b9fd7cecf2d6c2c069d7b2c37ab406b19e141
pin "$PREV/stage73-source-tree-fingerprint.txt" 74a6ab39ea5e273d1788d17ea8c99895a1fd86df
pin "$PREV/stage73-source-reference-inventory.txt" 00a1019307e1a9804c7d750b2df6abc62f683504
pin "$PREV/stage73-member-function-bodies.txt" 8ed90a17f85583729b528aab073b4bcf97b77296
pin "$PREV/stage73-ownership-chain-matrix.txt" f1f28658b448c9d0e9a40a6e7b7af2ec8a8a1414
pin "$PREV/stage73-handoff-blocker-inventory.txt" eb6f7f56a24ed15083fb17949bc8f2069033c522
pin "$PREV/stage73-baseline-source-fingerprint.txt" b4a5e62f27264e40ac1134801919ca79a6d84370
pin "$PREV/stage73-report.txt" ef39117ba560fbdbc7ba9a792f62411437881144
pin "$PREV/stage73-manifest.txt" 62e090375fde173b7f9b33969c5c54be83b17e3c
grep -q '^RESULT=PASS$' "$PREV/stage73-audit-summary.txt" || fail "Stage73 predecessor did not PASS"
grep -q '^SOURCE_FILES_SCANNED=91$' "$PREV/stage73-audit-summary.txt" || fail "Stage73 source count mismatch"
grep -q '^SOURCE_BASELINE_FINGERPRINTS=PASS$' "$PREV/stage73-audit-summary.txt" || fail "Stage73 baseline hash check failed"

python3 - "$SRC" "$PREV" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); prev=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
finger= (prev/"stage73-source-tree-fingerprint.txt").read_text().splitlines()
expected={}
for line in finger:
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
tree=["STAGE74_STAGE73_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
tree_ok=(set(expected)==set(actual))
for rel in sorted(set(expected)|set(actual)):
 want=expected.get(rel,"MISSING"); got=actual.get(rel,"MISSING")
 if want!=got: tree_ok=False
 tree.append("FILE="+rel+" EXPECTED="+want+" ACTUAL="+got+" RESULT="+("MATCH" if want==got else "MISMATCH"))
(out/"source-tree-revalidation.txt").write_text("\n".join(tree)+"\n")
if not tree_ok: raise SystemExit("Stage73 source tree changed since Stage73 inventory")

target_rel=[
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.hpp",
 "src/kext/wcl24h32/RTW88WCLController.cpp",
 "src/kext/wcl24h32/RTW88WCLController.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLPacketView.hpp",
 "src/kext/wcl24h32/RTW88WCLTxCompletionSlots.hpp"]
files={}
for rel in target_rel:
 p=src/rel
 if not p.is_file(): raise SystemExit("Required source missing: "+rel)
 files[rel]=p.read_text(errors="replace")

def strip_comments(s):
 out=[]; i=0; state="code"
 while i<len(s):
  c=s[i]; n=s[i+1] if i+1<len(s) else ""
  if state=="code":
   if c=='"' : state="str"; out.append(c); i+=1; continue
   if c=="'" : state="char"; out.append(c); i+=1; continue
   if c=="/" and n=="/":
    out.extend("  "); i+=2; state="line"; continue
   if c=="/" and n=="*":
    out.extend("  "); i+=2; state="block"; continue
   out.append(c); i+=1; continue
  if state in ("str","char"):
   out.append(c); i+=1
   if c=="\\" and i<len(s): out.append(s[i]); i+=1; continue
   if (state=="str" and c=='"') or (state=="char" and c=="'"): state="code"
   continue
  if state=="line":
   if c=="\n": out.append("\n"); state="code"
   else: out.append(" ")
   i+=1; continue
  if state=="block":
   if c=="*" and n=="/": out.extend("  "); i+=2; state="code"
   else: out.append("\n" if c=="\n" else " "); i+=1
 return "".join(out)

clean={k:strip_comments(v) for k,v in files.items()}
# All API and construction references are line-numbered against comment-stripped source.
groups={
 "REGISTRATION_API":["initRegistrationInfo","registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface","registerNetworkInterfaceWithLogicalLink","deregisterEthernetInterface","deregisterNetworkInterface","deregisterLogicalLink","createLogicalLink","deleteLogicalLink"],
 "QUEUE_FACTORIES":["withName","withPool","QueueDescriptor","QueueSet","LogicalLink","RegistrationInfo"],
 "CALLBACKS":["txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"],
 "TX_ADAPTER":["submitPacket","outputPacketWithCompletion","backendCompletion","drainCompletions","claimCompleted","CompletionSink"],
 "RX_ADAPTER":["enqueueFrame","copyMbufToSkywalkPacket","checkForWork","stagedRxFrame","_stagedRxPackets"],
 "ROLLBACK_TEARDOWN":["freeQueues","releaseQueues","_allocated","disposeAllPackets","quiescePacketPath","recycleStagedRxPackets","removeEventSource","deregister","release()"]}
refs=["STAGE74_COMMENT_FILTERED_SOURCE_REFERENCE_MAP"]
for group,terms in groups.items():
 refs.append("\nGROUP="+group)
 for rel,body in clean.items():
  original=files[rel].splitlines(); filtered=body.splitlines()
  for n,line in enumerate(filtered,1):
   matched=[term for term in terms if re.search(r"(?<![A-Za-z0-9_])"+re.escape(term)+r"(?![A-Za-z0-9_])",line)]
   if matched:
    refs.append("SOURCE="+rel+":"+str(n)+" TERMS="+",".join(matched)+" TEXT="+original[n-1].strip()[:360])
refs.append("\nDIRECT_REGISTRATION_IMPLEMENTATION_CALLS")
reg_calls=["registerInfraEthernetInterface","registerEthernetInterface","registerNetworkInterface","registerNetworkInterfaceWithLogicalLink"]
reg_total=0
for rel,body in clean.items():
 if not rel.endswith((".cpp",".cc",".mm")): continue
 for n,line in enumerate(body.splitlines(),1):
  hit=[x for x in reg_calls if re.search(r"(?<![A-Za-z0-9_])"+x+r"\s*\(",line)]
  if hit:
   reg_total+=len(hit); refs.append("SOURCE="+rel+":"+str(n)+" API="+",".join(hit)+" TEXT="+files[rel].splitlines()[n-1].strip()[:360])
refs.append("DIRECT_REGISTRATION_CALL_COUNT=%d"%reg_total)
(out/"registration-and-callback-reference-map.txt").write_text("\n".join(refs)+"\n")

# Report constructor calls with their full multi-line argument windows.
queue=files["src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"]
qlines=queue.splitlines()
queue_map=["STAGE74_QUEUE_POOL_AND_CALLBACK_CONSTRUCTOR_CALLS"]
for i,line in enumerate(qlines):
 if "withName(" in line or "withPool(" in line:
  # Capture through the first semicolon while preserving exact source text.
  j=i
  while j+1<len(qlines) and ";" not in qlines[j]: j+=1
  queue_map.append("\nSOURCE=RTW88WCLSkywalkQueues.cpp:%d-%d"%(i+1,j+1))
  queue_map.extend(qlines[i:j+1])
for label,rel in [
 ("QUEUE_HEADER","src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"),
 ("REGISTRATION_INFO_HELPERS","src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp"),
 ("ABI_REGISTRATION_DECLARATIONS","src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp")]:
 queue_map.append("\n===== "+label+" "+rel+" =====")
 lines=files[rel].splitlines()
 pattern=re.compile(r"RegistrationInfo|registerEthernetInterface|registerNetworkInterface|registerInfraEthernetInterface|QueueDescriptor|QueueSet|LogicalLink|txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction|static_assert|kSize|withPool|PoolOptions")
 hits=[i for i,x in enumerate(lines) if pattern.search(x)]
 selected=set()
 for i in hits:
  for j in range(max(0,i-2),min(len(lines),i+3)): selected.add(j)
 last=-2
 for j in sorted(selected):
  if j>last+1: queue_map.append("...")
  queue_map.append("%d: %s"%(j+1,lines[j]))
  last=j
(out/"queue-registration-contract-evidence.txt").write_text("\n".join(queue_map)+"\n")

# Verify actual source wiring and avoid counting declarations/comments as handoffs.
def count_token(rel,token):
 body=clean[rel]
 return len(list(re.finditer(r"(?<![A-Za-z0-9_])"+re.escape(token)+r"\s*\(",body)))
qcpp="src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
txcpp="src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp"
rxcpp="src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp"
ccpp="src/kext/wcl24h32/RTW88WCLController.cpp"
icpp="src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
callback_matrix=[
 ("TX_SUBMISSION_CALLBACK_TO_ADAPTER","txSubmissionAction",qcpp,"submitPacket",txcpp),
 ("TX_COMPLETION_CALLBACK_TO_DRAIN","txCompletionAction",qcpp,"drainCompletions",txcpp),
 ("RX_SUBMISSION_CALLBACK_TO_POOL_REFILL","rxSubmissionAction",qcpp,"allocatePacket",qcpp),
 ("RX_COMPLETION_CALLBACK_TO_CONTROLLER","rxCompletionAction",qcpp,"stagedRxFrame",ccpp)]
handoff=["STAGE74_CALLBACK_HANDOFF_SOURCE_WIRING"]
for label,source_fn,source_file,target_fn,target_file in callback_matrix:
 body=clean[source_file]
 # Get the exact callback definition from source lines; count target use within its brace-delimited body.
 pat=re.compile(r"\bRTW88WCLSkywalkQueues\s*::\s*"+source_fn+r"\s*\(")
 m=pat.search(body); count=0
 if m:
  brace=body.find("{",m.end()); depth=0; end=-1
  if brace>=0:
   for k in range(brace,len(body)):
    if body[k]=="{": depth+=1
    elif body[k]=="}":
     depth-=1
     if depth==0: end=k; break
   if end>=0:
    fnbody=body[brace:end+1]
    count=len(list(re.finditer(r"(?<![A-Za-z0-9_])"+re.escape(target_fn)+r"\s*\(",fnbody)))
 handoff.append("EDGE="+label+"|CALLBACK_FOUND="+("YES" if m else "NO")+"|TARGET_REFERENCE_COUNT="+str(count)+"|RESULT="+("CONNECTED" if count else "MISSING"))
# Count the adapter drain method's references from every implementation file; distinguish its own definition.
all_cpp={k:v for k,v in clean.items() if k.endswith((".cpp",".cc",".mm"))}
drain_refs=[]
for rel,body in all_cpp.items():
 for n,line in enumerate(body.splitlines(),1):
  if re.search(r"\bdrainCompletions\s*\(",line) and "::drainCompletions" not in line:
   drain_refs.append((rel,n,line.strip()))
handoff.append("TX_DRAIN_CALL_SITES="+str(len(drain_refs)))
for rel,n,line in drain_refs: handoff.append("DRAIN_REF="+rel+":"+str(n)+" "+line[:240])
# Controller RX enqueue and stage ring has no deliver-to-Skywalk API in this slice.
for token in ["enqueueFrame","_stagedRxPackets.push","_stagedRxPackets.pop","inputPacket","receivePacket","deliverPacket"]:
 handoff.append("CONTROLLER_TOKEN="+token+"|COUNT="+str(sum(len(re.findall(r"(?<![A-Za-z0-9_])"+re.escape(token)+r"(?![A-Za-z0-9_])",v)) for v in clean.values())))
(out/"callback-wiring-matrix.txt").write_text("\n".join(handoff)+"\n")

# Basic teardown order source evidence; preserve ordered line numbers from controller stop.
controller=files[ccpp].splitlines()
teardown=["STAGE74_CONTROLLER_TEARDOWN_ORDER_EVIDENCE"]
for n,line in enumerate(controller,1):
 if re.search(r"quiescePacketPath|_radio->stop|_rxAdapter->stop|recycleStagedRxPackets|_skywalkQueues|disposeAllPackets|release\(",clean[ccpp].splitlines()[n-1]):
  teardown.append("CONTROLLER.cpp:%d: %s"%(n,line.strip()[:300]))
infra=files[icpp].splitlines()
for n,line in enumerate(infra,1):
 if re.search(r"prepareRegistrationInfo|clearRegistrationInfo|detachRadio|_bridge\.detach|_workQueue->stop|registerInfraEthernetInterface|registerEthernetInterface",clean[icpp].splitlines()[n-1]):
  teardown.append("InfraInterface.cpp:%d: %s"%(n,line.strip()[:300]))
(out/"teardown-and-registration-order.txt").write_text("\n".join(teardown)+"\n")

# Summaries deliberately describe evidence completeness separately from product readiness.
queue_factory_count=len(re.findall(r"\bwithPool\s*\(",strip_comments(queue)))
pool_factory_count=len(re.findall(r"\bwithName\s*\(",strip_comments(queue)))
registration_prepare=count_token(icpp,"initRegistrationInfo")
# Ignore the function definition when counting registration API tokens; only implementation file callsites matter.
direct_calls=reg_total
source_ok=True
for rel in target_rel:
 want=expected.get(rel); got=hashlib.sha256((src/rel).read_bytes()).hexdigest()
 if want!=got: source_ok=False
summary=[
 "STAGE74_24H32_REGISTRATION_BOUNDARY_AND_CALLBACK_WIRING_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE73_PREDECESSOR=PASS",
 "SOURCE_TREE_REVALIDATION="+("PASS" if tree_ok else "REVIEW_REQUIRED"),
 "TARGET_SOURCE_FILES_RECHECKED=%d"%len(target_rel),
 "QUEUE_POOL_FACTORIES=withName:%d_withPool:%d"%(pool_factory_count,queue_factory_count),
 "REGISTRATION_INFO_INIT_CALLS_IN_INFRA_CPP=%d"%registration_prepare,
 "DIRECT_SKYWALK_REGISTRATION_API_CALLS_IN_TARGET_CPP=%d"%direct_calls,
 "QUEUE_CALLBACK_EDGES="+(";".join(x[0]+":" for x in callback_matrix)),
 "TX_SUBMISSION_TO_ADAPTER="+("CONNECTED" if "RESULT=CONNECTED" in handoff[1] else "MISSING"),
 "TX_COMPLETION_TO_DRAIN="+("CONNECTED" if "RESULT=CONNECTED" in handoff[2] else "MISSING"),
 "RX_SUBMISSION_TO_POOL_REFILL="+("CONNECTED" if "RESULT=CONNECTED" in handoff[3] else "MISSING"),
 "RX_COMPLETION_TO_CONTROLLER="+("CONNECTED" if "RESULT=CONNECTED" in handoff[4] else "MISSING"),
 "TX_DRAIN_REFERENCE_LOCATIONS=%d"%len(drain_refs),
 "QUEUE_AND_REGISTRATION_EVIDENCE=GENERATED",
 "CALLBACK_AND_TEARDOWN_EVIDENCE=GENERATED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+("NONE" if tree_ok and source_ok else "SOURCE_TREE_OR_TARGET_HASH_MISMATCH"),
 "RESULT="+("PASS" if tree_ok and source_ok else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 74 24H32 REGISTRATION BOUNDARY / CALLBACK WIRING AUDIT ==========",
 "VERSION=STAGE74_V1_20261103","RUN="+out.name,"TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "PREDECESSOR=Stage73 V1 source ownership inventory run "+ "run-20261102-180530-d711b3944b06",
 "PURPOSE=verify RegistrationInfo preparation versus actual Skywalk registration calls, queue/pool constructor arguments, callback wiring and controller teardown order against the unchanged source tree",
 "SCOPE=read-only source revalidation and exact callsite extraction; no implementation changes",
 "SAFETY=the audit distinguishes existing helper implementations from actual callback-to-queue integration; missing edges remain blocked",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "ARTIFACTS=source-tree-revalidation.txt,registration-and-callback-reference-map.txt,queue-registration-contract-evidence.txt,callback-wiring-matrix.txt,teardown-and-registration-order.txt",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 74 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=74"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=registration boundary and callback-to-queue source wiring audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage73 run $STAGE73_RUN"
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
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage74 registration and callback wiring audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-tree-revalidation.txt "$OUT"/registration-and-callback-reference-map.txt "$OUT"/queue-registration-contract-evidence.txt "$OUT"/callback-wiring-matrix.txt "$OUT"/teardown-and-registration-order.txt; do
 [[ -f "$f" ]] || fail "missing Stage74 artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$f" "Development/Logs/stage74/$RUN/$(basename "$f")"
 else
  split -b 220k "$f" "$f.part-"
  for part in "$f".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage74/$RUN/$(basename "$part")"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage74/$RUN/manifest.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 74 REGISTRATION / CALLBACK WIRING AUDIT ==========\n"
 "STAGE74_RUN: %s\n"%run+
 "STAGE74_VERSION: %s\n"%version+
 "STAGE74_SCOPE: verify 24H32 RegistrationInfo boundary, queue constructors, callback wiring and teardown order from unchanged source files\n"+
 "STAGE74_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — this is a source wiring audit; it does not register or activate Skywalk queues\n"+
 "STAGE74_LOGS: Development/Logs/stage74/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(o["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage74 registration and callback wiring audit","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE74_VERSION=$VERSION"
echo "STAGE74_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE74_RUN=$RUN"
echo "STAGE74_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE74_LOCAL_OUTPUT=$OUT"
echo "STAGE74_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage74/$RUN"
echo "STAGE74_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE74_SOURCE_MODIFIED=NO"
echo "STAGE74_BUILD=NOT_RUN"
echo "STAGE74_INSTALL=NOT_RUN"
echo "STAGE74_LOAD=NOT_RUN"
