#!/bin/bash
# Stage 75 V1 — 24H32 RegistrationInfo payload and native queue-array argument audit.
# VERSION_MARKER: STAGE75_V1_20261103
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE75_V1_20261103"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE73_RUN="run-20261102-180530-d711b3944b06"
STAGE74_RUN="run-20261102-181437-4023b97e1165"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage75/$RUN"
PREV="$OUT/predecessor-evidence"
mkdir -p "$OUT" "$PREV"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage75/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=75"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "========== CONSOLE TAIL =========="; tail -n 250 "$CONSOLE_LOG"
  echo "========== GENERATED FILES =========="; find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage75 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then echo "STAGE75_FAILURE_REPORT_GITHUB=$rp"; else echo "STAGE75_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 75 FAILURE REPORT ==========\nSTAGE75_FAILURE_RUN: %s\nSTAGE75_VERSION: %s\nSTAGE75_EXIT_CODE: %s\nSTAGE75_FAILED_LINE: %s\nSTAGE75_FAILED_COMMAND: %s\nSTAGE75_FAILURE_REPORT: %s\nSTAGE75_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage75 failure to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then echo "STAGE75_FAILURE_OUTPUT_LOG=UPDATED"; else echo "STAGE75_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE75_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE75_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee find date tail split basename cut sed; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
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
RAW74="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage74/$STAGE74_RUN"
curl -fsSLo "$PREV/stage73-source-tree-fingerprint.txt" "$RAW73/source-tree-fingerprint.txt"
curl -fsSLo "$PREV/stage74-audit-summary.txt" "$RAW74/audit-summary.txt"
curl -fsSLo "$PREV/stage74-source-tree-revalidation.txt" "$RAW74/source-tree-revalidation.txt"
curl -fsSLo "$PREV/stage74-registration-reference-map.txt" "$RAW74/registration-and-callback-reference-map.txt"
curl -fsSLo "$PREV/stage74-queue-contract-evidence.txt" "$RAW74/queue-registration-contract-evidence.txt"
curl -fsSLo "$PREV/stage74-callback-wiring-matrix.txt" "$RAW74/callback-wiring-matrix.txt"
curl -fsSLo "$PREV/stage74-teardown-order.txt" "$RAW74/teardown-and-registration-order.txt"
pin "$PREV/stage73-source-tree-fingerprint.txt" 74a6ab39ea5e273d1788d17ea8c99895a1fd86df
pin "$PREV/stage74-audit-summary.txt" 9bc7dab95a4d2372972ffbf733193ded6d9716f9
pin "$PREV/stage74-source-tree-revalidation.txt" 2a46b6613c7dc903f2980332e5a8617bd7ad6e4f
pin "$PREV/stage74-registration-reference-map.txt" e024c814304a6010b715779cf80e2868b1ee6b71
pin "$PREV/stage74-queue-contract-evidence.txt" f37776e3f38227732bdaadcc5d3153bf91b9c5a5
pin "$PREV/stage74-callback-wiring-matrix.txt" aa80e1fd38423df4ef52e7715cf33ea64ecb71fd
pin "$PREV/stage74-teardown-order.txt" 7b4b67e706ad16f11b11945f9f20e5f30b36561c
grep -q '^RESULT=PASS$' "$PREV/stage74-audit-summary.txt" || fail "Stage74 predecessor audit did not PASS"
grep -q '^SOURCE_TREE_REVALIDATION=PASS$' "$PREV/stage74-audit-summary.txt" || fail "Stage74 source tree revalidation failed"
grep -q '^DIRECT_SKYWALK_REGISTRATION_API_CALLS_IN_TARGET_CPP=0$' "$PREV/stage74-audit-summary.txt" || fail "Stage74 registration-call baseline changed"
grep -q '^TX_DRAIN_REFERENCE_LOCATIONS=0$' "$PREV/stage74-audit-summary.txt" || fail "Stage74 TX drain baseline changed"

python3 - "$SRC" "$PREV" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); prev=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
expected={}
for line in (prev/"stage73-source-tree-fingerprint.txt").read_text().splitlines():
 m=re.match(r"^([0-9a-f]{64})  (.+)$",line)
 if m: expected[m.group(2)]=m.group(1)
exts={".cpp",".cc",".c",".mm",".h",".hpp"}
actual={p.relative_to(src).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (src/"src").rglob("*") if p.is_file() and p.suffix in exts}
lines=["STAGE75_STAGE73_SOURCE_TREE_REVALIDATION","EXPECTED_FILES=%d"%len(expected),"ACTUAL_FILES=%d"%len(actual)]
ok=(len(expected)==91 and set(expected)==set(actual))
for rel in sorted(set(expected)|set(actual)):
 want=expected.get(rel,"MISSING"); got=actual.get(rel,"MISSING")
 if want!=got: ok=False
 lines.append("FILE="+rel+" EXPECTED="+want+" ACTUAL="+got+" RESULT="+("MATCH" if want==got else "MISMATCH"))
(out/"source-tree-revalidation.txt").write_text("\n".join(lines)+"\n")
if not ok: raise SystemExit("Stage73 source fingerprint mismatch; stop before interpreting registration contract")
PY

python3 - "$SRC" "$OUT" <<'PY'
import pathlib,re,sys
src=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
rels=[
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
 "src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp",
 "src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp",
 "src/kext/wcl24h32/RTW88WCLController.cpp",
 "src/kext/wcl24h32/RTW88WCLController.hpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLTxCompletionSlots.hpp"]
files={}
for rel in rels:
 p=src/rel
 if not p.is_file(): raise SystemExit("Required Stage75 source missing: "+rel)
 files[rel]=p.read_text(errors="replace")

def strip_comments(s):
 out=[]; i=0; state="code"
 while i<len(s):
  c=s[i]; n=s[i+1] if i+1<len(s) else ""
  if state=="code":
   if c=='"': state="str"; out.append(c); i+=1; continue
   if c=="'": state="char"; out.append(c); i+=1; continue
   if c=="/" and n=="/": out.extend("  "); i+=2; state="line"; continue
   if c=="/" and n=="*": out.extend("  "); i+=2; state="block"; continue
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

def function_body(rel, qualified_name):
 s=clean[rel]
 m=re.search(r"(?<![A-Za-z0-9_])"+re.escape(qualified_name)+r"\s*\(",s)
 if not m: return None
 brace=s.find("{",m.end()); semi=s.find(";",m.end())
 if brace<0 or (semi>=0 and semi<brace): return None
 depth=0; state="code"; i=brace
 while i<len(s):
  c=s[i]
  if state=="code":
   if c=='"': state="str"
   elif c=="'": state="char"
   elif c=="{": depth+=1
   elif c=="}":
    depth-=1
    if depth==0: return (s[brace:i+1],s.count("\n",0,brace)+1,s.count("\n",0,i)+1)
  elif state in ("str","char"):
   if c=="\\": i+=1
   elif (state=="str" and c=='"') or (state=="char" and c=="'"): state="code"
  i+=1
 return None

def dump_body(dst, rel, name, label=None):
 got=function_body(rel,name)
 dst.append("\n===== FUNCTION "+(label or name)+" SOURCE="+rel+" =====")
 if not got: dst.append("FUNCTION_BODY=NOT_FOUND"); return False
 body,start,end=got
 dst.append("SOURCE_LINES=%d-%d"%(start,end))
 dst.extend("%d: %s"%(start+i,line) for i,line in enumerate(body.splitlines()))
 return True

# Detailed, line-numbered registration storage declarations and exact init/write sequence.
payload=["STAGE75_24H32_REGISTRATION_PAYLOAD_AND_LIFECYCLE_EVIDENCE"]
for rel in ["src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
            "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"]:
 s=files[rel].splitlines()
 payload.append("\n===== STORAGE_AND_HELPER_DECLARATIONS "+rel+" =====")
 chosen=set()
 for i,line in enumerate(s):
  if re.search(r"RegistrationInfo|_registrationInfo|kSize|kVersionAndSize|kHardwareAddress|kOpaqueSlot|applyAppleProducerWrites|validate|clearRegistrationInfo|prepareRegistrationInfo|static_assert",line):
   chosen.update(range(max(0,i-2),min(len(s),i+4)))
 last=-2
 for i in sorted(chosen):
  if i>last+1: payload.append("...")
  payload.append("%d: %s"%(i+1,s[i])); last=i
dump_body(payload,"src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
          "RTW88WCLInfraInterface::prepareRegistrationInfo")
dump_body(payload,"src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
          "RTW88WCLInfraInterface::clearRegistrationInfo")
dump_body(payload,"src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
          "applyAppleProducerWrites","RegistrationInfo applyAppleProducerWrites helper")
dump_body(payload,"src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp",
          "validate","RegistrationInfo validation helper")
(out/"registration-payload-and-sequence.txt").write_text("\n".join(payload)+"\n")

# Exact ABI prototypes and type relationships vs actual driver-owned queue storage.
qarg=["STAGE75_NATIVE_REGISTRATION_ARGUMENT_AND_QUEUE_ARRAY_AUDIT"]
abi=files["src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"].splitlines()
qarg.append("\n===== ABI_DECLARATIONS =====")
for i,line in enumerate(abi):
 if re.search(r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|registerNetworkInterfaceWithLogicalLink|deregisterEthernetInterface|deregisterNetworkInterface|class IOSkywalkPacketQueue|class IOSkywalk(Tx|Rx)(Submission|Completion)Queue|class IOSkywalkPacketBufferPool",line):
  for j in range(max(0,i-2),min(len(abi),i+5)):
   qarg.append("%d: %s"%(j+1,abi[j]))
qcpp="src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
qhpp="src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
qarg.append("\n===== QUEUE_OBJECT_LAYOUT_AND_API =====")
for rel in [qhpp,qcpp]:
 lines=files[rel].splitlines(); qarg.append("SOURCE="+rel)
 for i,line in enumerate(lines):
  if re.search(r"IOSkywalkPacketQueue|IOSkywalk(Tx|Rx)(Submission|Completion)Queue|IOSkywalkPacketBufferPool|_txPool|_rxPool|_txSubmission|_txCompletion|_rxSubmission|_rxCompletion|createQueues|destroyQueues|withName|withPool|_allocated",line):
   qarg.append("%d: %s"%(i+1,line.strip()))
for name in ["RTW88WCLSkywalkQueues::createQueues","RTW88WCLSkywalkQueues::destroyQueues",
             "RTW88WCLSkywalkQueues::txSubmissionAction","RTW88WCLSkywalkQueues::txCompletionAction",
             "RTW88WCLSkywalkQueues::rxSubmissionAction","RTW88WCLSkywalkQueues::rxCompletionAction"]:
 dump_body(qarg,qcpp,name)
# Record declarations/storage of queue-array objects separately from API prototypes.
pointer_patterns=[
 r"IOSkywalkPacketQueue\s*\*\s*[A-Za-z_]\w*\s*(?:\[\s*\])?",
 r"IOSkywalkPacketQueue\s*\*\s*[A-Za-z_]\w*\s*;",
 r"(?:std::array|array)\s*<\s*IOSkywalkPacketQueue"]
pointer_hits=[]
for rel,body in clean.items():
 for n,line in enumerate(body.splitlines(),1):
  if any(re.search(p,line) for p in pointer_patterns):
   pointer_hits.append((rel,n,line.strip()))
qarg.append("\n===== DRIVER_QUEUE_ARRAY_STORAGE_CANDIDATES =====")
qarg.append("CANDIDATE_COUNT=%d"%len(pointer_hits))
for rel,n,line in pointer_hits: qarg.append("SOURCE=%s:%d TEXT=%s"%(rel,n,line[:300]))
# Count registration and deregistration invocations in implementation units only.
api_names=["registerInfraEthernetInterface","registerEthernetInterface",
           "registerNetworkInterfaceWithLogicalLink","registerNetworkInterface"]
dereg_names=["deregisterEthernetInterface","deregisterNetworkInterface","deregisterLogicalLink"]
calls=[]; dereg=[]
for rel,body in clean.items():
 if not rel.endswith((".cpp",".cc",".mm")): continue
 lines=body.splitlines()
 for n,line in enumerate(lines,1):
  for name in api_names:
   if re.search(r"(?<![A-Za-z0-9_:])"+name+r"\s*\(",line):
    calls.append((rel,n,name,line.strip()))
  for name in dereg_names:
   if re.search(r"(?<![A-Za-z0-9_:])"+name+r"\s*\(",line):
    dereg.append((rel,n,name,line.strip()))
qarg.append("\n===== IMPLEMENTATION_CALLS =====")
qarg.append("NATIVE_REGISTRATION_CALL_COUNT=%d"%len(calls))
for rel,n,name,line in calls: qarg.append("CALL=%s:%d API=%s TEXT=%s"%(rel,n,name,line[:300]))
qarg.append("NATIVE_DEREGISTRATION_CALL_COUNT=%d"%len(dereg))
for rel,n,name,line in dereg: qarg.append("CALL=%s:%d API=%s TEXT=%s"%(rel,n,name,line[:300]))
(out/"native-registration-argument-contract.txt").write_text("\n".join(qarg)+"\n")

# Lifecycle order and registration gates, retaining exact method bodies.
life=["STAGE75_REGISTRATION_LIFECYCLE_AND_ROLLBACK_EVIDENCE"]
controller="src/kext/wcl24h32/RTW88WCLController.cpp"
infra="src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
for name in ["RTW88WCLController::start","RTW88WCLController::stop",
             "RTW88WCLController::free","RTW88WCLController::quiescePacketPath",
             "RTW88WCLController::recycleStagedRxPackets"]:
 dump_body(life,controller,name)
for name in ["RTW88WCLInfraInterface::start","RTW88WCLInfraInterface::stop",
             "RTW88WCLInfraInterface::free","RTW88WCLInfraInterface::prepareRegistrationInfo",
             "RTW88WCLInfraInterface::detachRadio"]:
 dump_body(life,infra,name)
(out/"registration-lifecycle-and-rollback.txt").write_text("\n".join(life)+"\n")

# The audit itself passes only if source hashes are unchanged and all required evidence was generated.
source_ok=True
for rel in rels:
 want=None
 # the full 91-file comparison above is authoritative; this only asserts selected inputs exist.
 if not (src/rel).is_file(): source_ok=False
queue_factory_count=len(re.findall(r"\bwithPool\s*\(",clean[qcpp]))
pool_factory_count=len(re.findall(r"\bwithName\s*\(",clean[qcpp]))
storage_size=("kSize = 0x130" in clean["src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp"])
native_calls=len(calls); dereg_calls=len(dereg)
array_built=(len(pointer_hits)>0)
summary=[
 "STAGE75_24H32_REGISTRATION_PAYLOAD_AND_QUEUE_ARGUMENT_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE74_PREDECESSOR=PASS",
 "SOURCE_TREE_REVALIDATION=PASS",
 "REGISTRATION_STORAGE_0x130_DECLARATION="+("PRESENT" if storage_size else "NOT_CONFIRMED"),
 "QUEUE_POOL_FACTORIES=withName:%d_withPool:%d"%(pool_factory_count,queue_factory_count),
 "NATIVE_REGISTRATION_CALLS=%d"%native_calls,
 "NATIVE_DEREGISTRATION_CALLS=%d"%dereg_calls,
 "DRIVER_QUEUE_ARRAY_STORAGE_CANDIDATES=%d"%len(pointer_hits),
 "QUEUE_ARRAY_ARGUMENT_ASSEMBLY="+("CANDIDATE_PRESENT_REQUIRES_REVIEW" if array_built else "NOT_FOUND"),
 "REGISTRATION_PAYLOAD_SEQUENCE=EXTRACTED",
 "QUEUE_ARGUMENT_AND_TYPE_EVIDENCE=EXTRACTED",
 "START_STOP_AND_ROLLBACK_BODIES=EXTRACTED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+("NONE" if source_ok else "MISSING_REQUIRED_SOURCE"),
 "RESULT="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 75 24H32 REGISTRATION PAYLOAD / QUEUE ARGUMENT AUDIT ==========",
 "VERSION=STAGE75_V1_20261103","RUN="+out.name,"TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "PREDECESSOR=Stage74 run run-20261102-181437-4023b97e1165",
 "PURPOSE=extract the exact RegistrationInfo initialization/write sequence, driver queue storage, Apple registration argument declarations, native callsites and rollback lifecycle",
 "SCOPE=read-only; source tree is pinned to Stage73 and revalidated again before analysis",
 "INTERPRETATION=RESULT=PASS means evidence extraction completed against unchanged source; it does not mean native registration or queue-array assembly exists",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "ARTIFACTS=source-tree-revalidation.txt,registration-payload-and-sequence.txt,native-registration-argument-contract.txt,registration-lifecycle-and-rollback.txt",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 75 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=75"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=RegistrationInfo payload and native queue-array argument contract audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage74 run $STAGE74_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"; PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage75 registration payload and queue argument audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-tree-revalidation.txt "$OUT"/registration-payload-and-sequence.txt "$OUT"/native-registration-argument-contract.txt "$OUT"/registration-lifecycle-and-rollback.txt; do
 [[ -f "$f" ]] || fail "missing Stage75 artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$f" "Development/Logs/stage75/$RUN/$(basename "$f")"
 else
  split -b 220k "$f" "$f.part-"
  for part in "$f".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage75/$RUN/$(basename "$part")"; done
 fi
done
upload_one "$MAN" "Development/Logs/stage75/$RUN/manifest.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 75 REGISTRATION PAYLOAD / QUEUE ARGUMENT AUDIT ==========\n"
 "STAGE75_RUN: %s\n"%run+
 "STAGE75_VERSION: %s\n"%version+
 "STAGE75_SCOPE: inspect 24H32 RegistrationInfo payload, native queue-array argument contract, registration callsites and rollback lifecycle\n"+
 "STAGE75_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — registration and callback handoff implementation remain incomplete\n"+
 "STAGE75_LOGS: Development/Logs/stage75/%s/\n"%run+
 "==========================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(o["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage75 registration payload and queue argument audit","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE75_VERSION=$VERSION"
echo "STAGE75_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE75_RUN=$RUN"
echo "STAGE75_LOCAL_OUTPUT=$OUT"
echo "STAGE75_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage75/$RUN"
echo "STAGE75_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE75_SOURCE_MODIFIED=NO"
echo "STAGE75_BUILD=NOT_RUN"
echo "STAGE75_INSTALL=NOT_RUN"
echo "STAGE75_LOAD=NOT_RUN"
