#!/bin/bash
# Stage 63 V1 — native four-queue / Apple registration-argument readiness audit.
# VERSION_MARKER: STAGE63_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE63_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE62_RUN="run-20261102-161032-d54adc732d87"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage63/$RUN"
PREV="$OUT/stage62-evidence"
mkdir -p "$OUT" "$PREV"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE63_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum grep awk sw_vers uname wc tr split; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"

RAW="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage62/$STAGE62_RUN"
for name in audit-summary.txt report.txt method-status.txt method-disassembly.txt queueset-info-word-crosswalk.txt logical-link-info-crosswalk.txt registration-lifecycle-matrix.txt private-metadata-source-inventory.txt source-fingerprint.txt manifest.txt; do
  curl -fsSLo "$PREV/$name" "$RAW/$name"
done
blob_sha(){
  python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
verify_pin(){
  local file="$1" expected="$2" got
  got="$(blob_sha "$PREV/$file")"
  [[ "$got" == "$expected" ]] || fail "Stage62 predecessor pin mismatch: $file expected=$expected got=$got"
  echo "STAGE62_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt 99415ab0329a1973fd004e67d20da3b8acff7120
verify_pin report.txt 927626bf1543777723f1ac3e10a8567cad41c6e2
verify_pin method-status.txt f0d6e3bdfbc265453ed21e17df397f392f825625
verify_pin method-disassembly.txt af5d43e7d7371910b8e65829309ef6b7b52ea700
verify_pin queueset-info-word-crosswalk.txt ef25fdc28340d6e6bc18d6e80ff011b7df334a51
verify_pin logical-link-info-crosswalk.txt 71802f2540ca976ffe5fe0b43b3f2b406fdb88fd
verify_pin registration-lifecycle-matrix.txt 55655268f9d410721de79b7bec3cac9f3b895c9e
verify_pin private-metadata-source-inventory.txt ae184e2d92b051b4d4ed396d4ce390e8c45e1a1b
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin manifest.txt 8cbfe36891dfc80d847fca9a59d6560532ef78c1
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage62 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage62 source continuity is not PASS"

python3 - "$SRC" "$OUT" <<'PY'
import hashlib,pathlib,sys
src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
expected={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4",
}
rows=[]; good=True
for rel,want in expected.items():
 p=src/rel
 got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 ok=got==want; good &= ok
 rows += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if ok else "MISMATCH")]
rows.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if good else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(rows)+"\n")
print("\n".join(rows))
if not good: raise SystemExit("Stage43 baseline changed; stop before further interpretation")
PY

python3 - "$SRC" "$OUT" <<'PY'
import pathlib,re,sys
src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
ext={".h",".hpp",".hh",".cpp",".cc",".cxx"}
files=sorted(p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in ext and
             not any(x in ("build","out","DerivedData",".git") for x in p.relative_to(src).parts))
texts={}
for p in files:
 try: texts[str(p.relative_to(src))]=p.read_text(errors="replace")
 except Exception: pass

def body_of(cls,name):
 rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(name)+r"\s*\(")
 found=[]
 for path,text in texts.items():
  for m in rx.finditer(text):
   brace=text.find("{",m.end()); semi=text.find(";",m.end())
   if brace<0 or (semi>=0 and semi<brace): continue
   depth=0; state="code"; quote=""
   i=brace
   while i<len(text):
    c=text[i]; n=text[i+1] if i+1<len(text) else ""
    if state=="line":
     if c=="\n":state="code"
    elif state=="block":
     if c=="*" and n=="/":state="code";i+=1
    elif state=="str":
     if c=="\\":i+=1
     elif c==quote:state="code"
    else:
     if c=="/" and n=="/":state="line";i+=1
     elif c=="/" and n=="*":state="block";i+=1
     elif c in ("'","\""):state="str";quote=c
     elif c=="{":depth+=1
     elif c=="}":
      depth-=1
      if depth==0:break
    i+=1
   if depth==0: found.append((path,text.count("\n",0,m.start())+1,text[m.start():i+1]))
 return found

specs=[
 ("RTW88WCLController","start"),
 ("RTW88WCLController","releaseNativeResources"),
 ("RTW88WCLController","stagedRxFrame"),
 ("RTW88WCLInfraInterface","start"),
 ("RTW88WCLInfraInterface","prepareRegistrationInfo"),
 ("RTW88WCLInfraInterface","clearRegistrationInfo"),
 ("RTW88WCLSkywalkQueues","createQueues"),
 ("RTW88WCLSkywalkQueues","destroyQueues"),
 ("RTW88WCLSkywalkQueues","txSubmissionAction"),
 ("RTW88WCLSkywalkQueues","txCompletionAction"),
 ("RTW88WCLSkywalkQueues","rxSubmissionAction"),
 ("RTW88WCLSkywalkQueues","rxCompletionAction"),
]
bodies={}; method_lines=["STAGE63_NATIVE_METHOD_BODY_EXTRACTS","SOURCE_FILES_SCANNED=%d"%len(files)]
for cls,name in specs:
 found=body_of(cls,name)
 key=cls+"::"+name
 if len(found)==1:
  path,line,body=found[0]; bodies[key]=body
  method_lines += ["\n===== "+key+" "+path+":"+str(line)+" =====",body[:30000]]
 else:
  method_lines += ["\n===== "+key+" FOUND_COUNT="+str(len(found))+" ====="]
(out/"native-method-bodies.txt").write_text("\n".join(method_lines)+"\n")

# Capture source references to registration, queue arrays, pools, callbacks, and packet ownership.
patterns={
 "registration_api":r"registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|deregisterEthernetInterface|deregisterNetworkInterface",
 "queue_objects":r"_txSubmission|_txCompletion|_rxSubmission|_rxCompletion",
 "queue_array_shapes":r"IOSkywalkPacketQueue\s*\*\s*\w+\s*\[\s*\d*\s*\]|IOSkywalkPacketQueue\s*\*\s*\w+\s*=\s*\{",
 "queue_pools":r"_txPool|_rxPool|txPacketPool|rxPacketPool",
 "queue_callbacks":r"txSubmissionAction|txCompletionAction|rxSubmissionAction|rxCompletionAction",
 "registration_info":r"prepareRegistrationInfo|initRegistrationInfo|_registrationInfo|RegistrationInfo",
 "packet_handoff":r"stagedRxFrame|submitPacket|drainCompletions|push\(|pop\(|recycleStagedRxPackets",
 "queue_type_metadata":r"QueueSetInfo_s|LogicalLinkInfo_s|createWithQueues|createWithQueueSet|setLogicalLink|queueOptions",
}
ref_lines=["STAGE63_NATIVE_SOURCE_REFERENCE_INVENTORY","SOURCE_FILES_SCANNED=%d"%len(files)]
for label,pat in patterns.items():
 rx=re.compile(pat,re.I); hits=[]
 for path,text in texts.items():
  for i,line in enumerate(text.splitlines(),1):
   if rx.search(line): hits.append((path,i,line.strip()))
 ref_lines += ["\nREFERENCE="+label,"MATCHES=%d"%len(hits)]
 ref_lines += ["%s:%d: %s"%x for x in hits[:250]]
(out/"source-reference-inventory.txt").write_text("\n".join(ref_lines)+"\n")

def has(body,pat): return re.search(pat,body,re.I|re.S) is not None
checks={}
q=bodies.get("RTW88WCLSkywalkQueues::createQueues","")
qd=bodies.get("RTW88WCLSkywalkQueues::destroyQueues","")
istart=bodies.get("RTW88WCLInfraInterface::start","")
prep=bodies.get("RTW88WCLInfraInterface::prepareRegistrationInfo","")
cstart=bodies.get("RTW88WCLController::start","")
crelease=bodies.get("RTW88WCLController::releaseNativeResources","")
callbacks={x:bodies.get("RTW88WCLSkywalkQueues::"+x,"") for x in
           ("txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction")}
for cls,name in specs: checks["METHOD_"+cls+"_"+name.upper()]=len(body_of(cls,name))==1
for name in ("_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"):
 checks["QUEUE_FACTORY_"+name]=re.search(re.escape(name)+r"\s*=\s*IOSkywalk\w+Queue::withPool",q) is not None
for name in ("txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"):
 checks["CALLBACK_BOUND_"+name]=re.search(r"&RTW88WCLSkywalkQueues::"+name,q) is not None
checks["QUEUE_OWNER_CREATES_BOTH_POOLS"]=has(q,r"_txPool\s*=\s*IOSkywalkPacketBufferPool::withName") and has(q,r"_rxPool\s*=\s*IOSkywalkPacketBufferPool::withName")
checks["QUEUE_TEARDOWN_RELEASES_QUEUES_BEFORE_POOLS"]=qd.find("_rxCompletion")>=0 and qd.find("_txSubmission")>=0 and qd.find("_rxPool")>qd.find("_txSubmission") and qd.find("_txPool")>qd.find("_rxPool")
checks["INTERFACE_START_STILL_FENCED"]=has(istart,r"return\s+false\s*;")
checks["REGISTRATION_INFO_HELPER_USES_APPLE_INIT"]=has(prep,r"initRegistrationInfo\s*\(\s*info\s*,\s*1\s*,\s*sizeof\s*\(\s*_registrationInfo\.bytes\s*\)")
checks["CONTROLLER_CREATES_QUEUE_OWNER"]=has(cstart,r"new\s+RTW88WCLSkywalkQueues") and has(cstart,r"->createQueues\s*\(")
checks["CONTROLLER_START_HAS_PUBLICATION_FENCE"]=has(cstart,r"refusing publication|publication fence")
checks["CONTROLLER_CLEANUP_DRAINS_BEFORE_QUEUE_DESTROY"]=has(crelease,r"recycleStagedRxPackets") and has(crelease,r"destroyQueues")
# These negative findings are expected and explicitly documented as implementation gaps.
checks["NO_NATIVE_INFRA_REGISTRATION_CALL"]=not has(istart,r"registerInfraEthernetInterface|registerEthernetInterface")
checks["NO_QUEUE_ARRAY_PASSED_TO_REGISTRATION"]=not any(re.search(patterns["queue_array_shapes"],t,re.I) for t in texts.values())
checks["NO_NATIVE_QUEUESET_FACTORY_CALL"]=not any(re.search(r"createWithQueues|createWithQueueSet",t,re.I) for t in texts.values())
checks["NO_REGISTERED_TX_COMPLETION_SINK"]=not any(re.search(r"registerInfraEthernetInterface|registerEthernetInterface",t,re.I) for t in texts.values())

# Decode the four queue constructor calls, preserving actual arguments verbatim.
qcalls=[]
for name in ("_txSubmission","_txCompletion","_rxSubmission","_rxCompletion"):
 m=re.search(re.escape(name)+r"\s*=\s*(IOSkywalk\w+Queue)::withPool\s*\(",q,re.S)
 if not m: continue
 start=m.end(); depth=1; i=start; quote=""
 while i<len(q) and depth:
  c=q[i]
  if quote:
   if c=="\\":i+=1
   elif c==quote:quote=""
  elif c in ("'","\""):quote=c
  elif c=="(":depth+=1
  elif c==")":depth-=1
  i+=1
 args=q[start:i-1] if depth==0 else q[start:]
 qcalls.append((name,m.group(1),args.strip().replace("\n"," ")))
queue_lines=["STAGE63_FOUR_QUEUE_CONSTRUCTION_MAP","ORDER_FROM_CURRENT_SOURCE=_txSubmission,_txCompletion,_rxSubmission,_rxCompletion",
             "APPLE_QUEUE_DESCRIPTOR_TYPES_FROM_STAGE61=1_TX_SUBMISSION,2_TX_COMPLETION,3_RX_SUBMISSION,4_RX_COMPLETION",
             "NOTE=queueId argument in withPool is not assumed to be the Apple queue-type ID"]
for name,typ,args in qcalls: queue_lines.append("QUEUE=%s CLASS=%s ARGUMENTS=%s"%(name,typ,args))
queue_lines.append("QUEUE_CONSTRUCTOR_CALLS_FOUND=%d/4"%len(qcalls))
(out/"four-queue-construction-map.txt").write_text("\n".join(queue_lines)+"\n")

arg_lines=[
 "STAGE63_REGISTRATION_ARGUMENT_READINESS_MATRIX",
 "APPLE_ENTRY_FROM_STAGE62=registerNetworkInterface(RegistrationInfo, LogicalLink, TX pool, RX pool, options) after QueueSet then LogicalLink construction",
 "APPLE_ARRAY_ENTRY_FROM_SDK=registerInfraEthernetInterface(RegistrationInfo, IOSkywalkPacketQueue** queues, queueOptions, pool1, pool2)",
 "REGISTRATION_INFO_PREPARATION="+("PRESENT" if checks["REGISTRATION_INFO_HELPER_USES_APPLE_INIT"] else "NOT_CONFIRMED"),
 "REGISTRATION_INFO_HELPER_CALLED_FROM_INTERFACE_START="+("YES" if has(istart,r"prepareRegistrationInfo\s*\(") else "NO"),
 "QUEUE_OBJECTS_CREATED=%d/4"%len(qcalls),
 "QUEUE_ARRAY_MATERIALIZATION="+("PRESENT" if checks["NO_QUEUE_ARRAY_PASSED_TO_REGISTRATION"] is False else "NOT_FOUND"),
 "QUEUESET_OR_LOGICALLINK_FACTORY_IN_NATIVE_SOURCE="+("PRESENT" if checks["NO_NATIVE_QUEUESET_FACTORY_CALL"] is False else "NOT_FOUND"),
 "TX_POOL_OBJECT="+("PRESENT" if "_txPool" in q else "NOT_FOUND"),
 "RX_POOL_OBJECT="+("PRESENT" if "_rxPool" in q else "NOT_FOUND"),
 "QUEUE_ARRAY_ARGUMENT_ORDER=NOT_IMPLEMENTED_IN_CURRENT_SOURCE",
 "QUEUE_OPTIONS_VALUE=NOT_IMPLEMENTED_IN_CURRENT_SOURCE",
 "PRIVATE_QUEUESET_INFO_FORMAL_LAYOUT=UNRESOLVED",
 "PRIVATE_LOGICALLINK_INFO_FORMAL_LAYOUT=UNRESOLVED",
 "NATIVE_INTERFACE_START="+("FENCED_RETURN_FALSE" if checks["INTERFACE_START_STILL_FENCED"] else "REVIEW"),
 "NATIVE_APPLE_REGISTRATION_CALL="+("ABSENT" if checks["NO_NATIVE_INFRA_REGISTRATION_CALL"] else "PRESENT"),
 "ACTIVATION=BLOCKED; do not infer a registration array or private structure layout from queue member order alone",
]
(out/"registration-argument-matrix.txt").write_text("\n".join(arg_lines)+"\n")

ownership=[
 "STAGE63_CALLBACK_AND_OWNERSHIP_MAP",
 "TX_SUBMISSION_CALLBACK="+("BODY_FOUND" if callbacks["txSubmissionAction"] else "BODY_NOT_FOUND"),
 "TX_COMPLETION_CALLBACK="+("BODY_FOUND" if callbacks["txCompletionAction"] else "BODY_NOT_FOUND"),
 "RX_SUBMISSION_CALLBACK="+("BODY_FOUND" if callbacks["rxSubmissionAction"] else "BODY_NOT_FOUND"),
 "RX_COMPLETION_CALLBACK="+("BODY_FOUND" if callbacks["rxCompletionAction"] else "BODY_NOT_FOUND"),
 "TX_ADAPTER_SUBMIT_PACKET_REFERENCE="+("PRESENT" if re.search(r"submitPacket", "\n".join(texts.values())) else "ABSENT"),
 "TX_ADAPTER_DRAIN_COMPLETIONS_REFERENCE="+("PRESENT" if re.search(r"drainCompletions", "\n".join(texts.values())) else "ABSENT"),
 "CONTROLLER_RX_STAGING_REFERENCE="+("PRESENT" if "stagedRxFrame" in cstart or "stagedRxFrame" in crelease else "PRESENT_IN_SOURCE_INVENTORY" if re.search(r"stagedRxFrame", "\n".join(texts.values())) else "ABSENT"),
 "CURRENT_CONTROLLER_START_FENCE="+("PRESENT" if checks["CONTROLLER_START_HAS_PUBLICATION_FENCE"] else "NOT_CONFIRMED"),
 "CURRENT_CLEANUP_ORDER="+("QUIESCE_RECYCLE_QUEUE_POOL_RELEASE" if checks["CONTROLLER_CLEANUP_DRAINS_BEFORE_QUEUE_DESTROY"] else "REVIEW_REQUIRED"),
 "QUEUE_TEARDOWN_ORDER="+("QUEUE_OBJECTS_BEFORE_POOLS" if checks["QUEUE_TEARDOWN_RELEASES_QUEUES_BEFORE_POOLS"] else "REVIEW_REQUIRED"),
 "NO_QUEUE_SCHEDULING_OR_REGISTRATION_AUTHORIZED=YES",
]
(out/"callback-and-ownership-map.txt").write_text("\n".join(ownership)+"\n")

# Audit is a pass when its predecessor, source baseline, and expected source methods exist.
required=[
 "METHOD_RTW88WCLController_START","METHOD_RTW88WCLController_RELEASENATIVERESOURCES",
 "METHOD_RTW88WCLInfraInterface_START","METHOD_RTW88WCLInfraInterface_PREPAREREGISTRATIONINFO",
 "METHOD_RTW88WCLSkywalkQueues_CREATEQUEUES","METHOD_RTW88WCLSkywalkQueues_DESTROYQUEUES",
 "QUEUE_FACTORY__txSubmission","QUEUE_FACTORY__txCompletion","QUEUE_FACTORY__rxSubmission","QUEUE_FACTORY__rxCompletion",
 "CALLBACK_BOUND_txSubmissionAction","CALLBACK_BOUND_txCompletionAction","CALLBACK_BOUND_rxSubmissionAction","CALLBACK_BOUND_rxCompletionAction",
 "QUEUE_OWNER_CREATES_BOTH_POOLS","QUEUE_TEARDOWN_RELEASES_QUEUES_BEFORE_POOLS",
 "REGISTRATION_INFO_HELPER_USES_APPLE_INIT","CONTROLLER_CREATES_QUEUE_OWNER",
 "CONTROLLER_START_HAS_PUBLICATION_FENCE"
]
passed=sum(bool(checks.get(x)) for x in required)
issues=[x for x in required if not checks.get(x)]
summary=[
 "STAGE63_NATIVE_FOUR_QUEUE_REGISTRATION_ARGUMENT_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE62_PREDECESSOR=10/10_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY=PASS",
 "NATIVE_SOURCE_FILES_SCANNED=%d"%len(files),
 "REQUIRED_NATIVE_SOURCE_CHECKS=%d/%d"%(passed,len(required)),
 "FOUR_QUEUE_FACTORY_CALLS=%d/4"%len(qcalls),
 "CALLBACK_BINDINGS=%d/4"%sum(checks.get("CALLBACK_BOUND_"+x,False) for x in ("txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction")),
 "REGISTRATION_INFO_APPLE_INITIALIZER="+("PASS" if checks["REGISTRATION_INFO_HELPER_USES_APPLE_INIT"] else "REVIEW_REQUIRED"),
 "QUEUE_ARRAY_MATERIALIZATION=NOT_FOUND",
 "APPLE_REGISTRATION_CALL=NOT_IMPLEMENTED",
 "PRIVATE_QUEUESET_INFO_FORMAL_SIZE=UNRESOLVED",
 "PRIVATE_LOGICALLINK_INFO_FORMAL_SIZE=UNRESOLVED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "EXPECTED_GAPS=QUEUE_ARRAY_ORDER,QUEUE_OPTIONS,QUEUESET_LOGICALLINK_FACTORY_ARGUMENTS,REGISTRATION_CALLSITE,TX_RX_PACKET_HANDOFF",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if not issues and len(qcalls)==4 else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")

report=[
 "========== STAGE 63 NATIVE FOUR-QUEUE / REGISTRATION ARGUMENT AUDIT ==========",
 "VERSION="+ "STAGE63_V1_20261102",
 "RUN="+out.name,
 "TARGET="+os.environ.get("STAGE63_TARGET","15.8.1/24H32/x86_64"),
 "PREDECESSOR=Stage62 V2 "+ "run-20261102-161032-d54adc732d87",
 "PURPOSE=map the existing four queue objects, pools, callbacks and RegistrationInfo preparation to Apple's Stage62-verified registration transaction",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE",
 "",
 "STAGE62_CONFIRMED=QueueSet factory -> LogicalLink factory -> registerNetworkInterface(LogicalLink overload)",
 "STAGE63_SCOPE=read-only native source inventory; no queue array or private metadata is synthesized",
 "CURRENT_GAP=queue owner allocates four queue objects, but native interface start remains fenced and no Apple registration call is present",
 "QUEUE_ORDER_CANDIDATE=TX submission, TX completion, RX submission, RX completion; this is the current member order only, not a proven Apple array contract",
 "QUEUE_ID_CAUTION=withPool queueId values are not treated as Stage61 queue-type IDs",
 "",
 *summary,
 "========== END STAGE 63 =========="
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if issues or len(qcalls)!=4: raise SystemExit("Stage63 source audit requires review")
PY

MAN="$OUT/manifest.txt"
{
  echo "STAGE=63"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
  echo "PURPOSE=read-only native four-queue and Apple registration argument readiness audit"
  echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage62 V2 $STAGE62_RUN"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"
  echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

PAYLOAD_INDEX=0
upload_one(){
  local file="$1" path="$2" expected payload response put got
  expected="$(blob_sha "$file")"
  PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
  payload="$OUT/payload-$PAYLOAD_INDEX.json"
  response="$OUT/response-$PAYLOAD_INDEX.json"
  python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
f,d=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({
 "message":"Add Stage63 read-only native queue registration audit",
 "content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()
}))
PY
  gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
  put="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
  got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
  [[ "$put" == "$expected" && "$got" == "$expected" ]] || {
    echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1;
  }
  echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
upload_artifact(){
  local file="$1" base bytes
  base="$(basename "$file")"
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes <= 225280 )); then
    upload_one "$file" "Development/Logs/stage63/$RUN/$base"
  else
    split -b 220k "$file" "$file.part-"
    for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage63/$RUN/$(basename "$part")"; done
  fi
  echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/native-method-bodies.txt "$OUT"/source-reference-inventory.txt "$OUT"/four-queue-construction-map.txt "$OUT"/registration-argument-matrix.txt "$OUT"/callback-and-ownership-map.txt; do
  [[ -f "$f" ]] || fail "missing Stage63 artifact: $f"
  upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage63/$RUN/manifest.txt"

# Append to the existing GitHub output.log using its current SHA, then read it back.
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 63 NATIVE FOUR-QUEUE / REGISTRATION ARGUMENT AUDIT ==========\n"
 "STAGE63_RUN: %s\n"%run+
 "STAGE63_VERSION: %s\n"%version+
 "STAGE63_SCOPE: native four-queue construction, RegistrationInfo preparation, callback and Apple registration argument readiness\n"+
 "STAGE63_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — native registration call and TX/RX packet ownership handoff remain unimplemented\n"+
 "STAGE63_LOGS: Development/Logs/stage63/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
LOG_SHA="$(cat "$OUT/output.log.sha")"
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$LOG_SHA" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({
 "message":"Append Stage63 native registration readiness audit to output.log",
 "sha":sha,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()
}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"

echo
echo "STAGE63_VERSION=$VERSION"
echo "STAGE63_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE63_RUN=$RUN"
echo "STAGE63_LOCAL_OUTPUT=$OUT"
echo "STAGE63_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage63/$RUN"
echo "STAGE63_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE63_SOURCE_MODIFIED=NO"
echo "STAGE63_BUILD=NOT_RUN"
echo "STAGE63_INSTALL=NOT_RUN"
echo "STAGE63_LOAD=NOT_RUN"
