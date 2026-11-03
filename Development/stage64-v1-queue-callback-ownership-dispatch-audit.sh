#!/bin/bash
# Stage 64 V1 — four queue callback behavior, Apple dispatch and packet-ownership audit.
# VERSION_MARKER: STAGE64_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE64_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE63_RUN="run-20261102-162123-d7577a1a3dff"
STAGE58_RUN="run-20261102-143451-43ae9daec178"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage64/$RUN"
PREV="$OUT/predecessor-evidence"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE64_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found through selected Xcode"
export LLVM_OBJDUMP="$OBJDUMP"

blob_sha(){
python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
RAW63="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage63/$STAGE63_RUN"
for name in audit-summary.txt report.txt native-method-bodies.txt source-fingerprint.txt callback-and-ownership-map.txt manifest.txt; do
  curl -fsSLo "$PREV/$name" "$RAW63/$name"
done
verify_pin(){
 local file="$1" expected="$2" got
 got="$(blob_sha "$PREV/$file")"
 [[ "$got" == "$expected" ]] || fail "Stage63 predecessor pin mismatch: $file expected=$expected got=$got"
 echo "STAGE63_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt 5c8eca57ad3bdc75a1c4983fb38b3e40138e491d
verify_pin report.txt a58babd177c4735a208761ac0e4a51a6baa1b2a8
verify_pin native-method-bodies.txt 39f050e72c37e80fed5c43c7d295f6658782d153
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin callback-and-ownership-map.txt 78763cd3496b9fa544d011946d2bfcd7002e7481
verify_pin manifest.txt beb92902f3c665003cec9cc75c86b649c2b064a8
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage63 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage63 source continuity is not PASS"

RAW58="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage58/$STAGE58_RUN"
curl -fsSLo "$PREV/callback-return-abi-clarification.txt" "$RAW58/callback-return-abi-clarification.txt"
[[ "$(blob_sha "$PREV/callback-return-abi-clarification.txt")" == "74df6ecbcab7acdcf1a979629e8dc08085d572e4" ]] || fail "Stage58 callback ABI clarification pin mismatch"
grep -q 'IOSkywalkTxSubmissionQueueAction=IOReturn' "$PREV/callback-return-abi-clarification.txt" || fail "Stage58 callback typedef evidence is missing"

curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={"kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589",
          "disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"}
for name,want in expected.items():
 data=(root/name).read_bytes()
 got=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
 print("UPSTREAM_GIT_BLOB_%s=%s"%(name,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Pinned upstream parser mismatch: "+name)
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1]); bootkc=sys.argv[2]; cache=pathlib.Path(sys.argv[3])
objdump=sys.argv[4]; out=pathlib.Path(sys.argv[5])
tools=out/"tools"; sys.path.insert(0,str(tools))
from kcfile import KC
import disasm
os.environ["LLVM_OBJDUMP"]=objdump

source_files=sorted(p for p in src.rglob("*") if p.is_file() and
 p.suffix.lower() in (".h",".hpp",".hh",".cpp",".cc",".cxx") and
 not any(z in ("build","out","DerivedData",".git") for z in p.relative_to(src).parts))
texts={}
for p in source_files:
 try: texts[str(p.relative_to(src))]=p.read_text(errors="replace")
 except Exception: pass

fingerprint_items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4",
}
fingerprint_rows=[]; source_ok=True
for rel,want in fingerprint_items.items():
 p=src/rel
 got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 match=(got==want); source_ok &= match
 fingerprint_rows += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if match else "MISMATCH")]
fingerprint_rows.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(fingerprint_rows)+"\n")

def extract_body(text,brace):
 depth=0; state="code"; quote=""; i=brace
 while i<len(text):
  c=text[i]; n=text[i+1] if i+1<len(text) else ""
  if state=="line":
   if c=="\n": state="code"
  elif state=="block":
   if c=="*" and n=="/": state="code"; i+=1
  elif state=="str":
   if c=="\\": i+=1
   elif c==quote: state="code"
  else:
   if c=="/" and n=="/": state="line"; i+=1
   elif c=="/" and n=="*": state="block"; i+=1
   elif c in ("'","\""): state="str"; quote=c
   elif c=="{": depth+=1
   elif c=="}":
    depth-=1
    if depth==0: return text[brace:i+1]
  i+=1
 return ""

def find_method(cls,name):
 rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(name)+r"\s*\(")
 found=[]
 for path,text in texts.items():
  for m in rx.finditer(text):
   brace=text.find("{",m.end()); semi=text.find(";",m.end())
   if brace<0 or (semi>=0 and semi<brace): continue
   body=extract_body(text,brace)
   if body: found.append((path,text.count("\n",0,m.start())+1,text[m.start():brace].strip(),body))
 return found

targets=[
 ("RTW88WCLSkywalkQueues","txSubmissionAction"),
 ("RTW88WCLSkywalkQueues","txCompletionAction"),
 ("RTW88WCLSkywalkQueues","rxSubmissionAction"),
 ("RTW88WCLSkywalkQueues","rxCompletionAction"),
 ("RTW88WCLSkywalkTxAdapter","submitPacket"),
 ("RTW88WCLSkywalkTxAdapter","drainCompletions"),
 ("RTW88WCLSkywalkRxAdapter","checkForWork"),
 ("RTW88WCLSkywalkRxAdapter","stop"),
 ("RTW88WCLController","stagedRxFrame"),
 ("RTW88WCLController","recycleStagedRxPackets"),
]
bodies={}; body_lines=["STAGE64_NATIVE_CALLBACK_AND_PACKET_OWNERSHIP_METHOD_BODIES",
 "SOURCE_FILES_SCANNED=%d"%len(source_files)]
body_issues=[]
for cls,name in targets:
 found=find_method(cls,name); key=cls+"::"+name
 body_lines.append("\n===== "+key+" FOUND_COUNT=%d ====="%len(found))
 if len(found)==1:
  path,line,sig,body=found[0]; bodies[key]=body
  body_lines += ["SOURCE="+path+":"+str(line),sig,body[:25000]]
 else:
  body_issues.append(key+"_FOUND_COUNT_"+str(len(found)))
(out/"source-callback-bodies.txt").write_text("\n".join(body_lines)+"\n")

# Extract SDK action typedefs from concrete headers.
sdk_headers={
 "IOSkywalkTxSubmissionQueue.h","IOSkywalkTxCompletionQueue.h",
 "IOSkywalkRxSubmissionQueue.h","IOSkywalkRxCompletionQueue.h"
}
sdk_lines=["STAGE64_SDK_QUEUE_ACTION_TYPEDEFS"]
sdk_found={}
for path,text in texts.items():
 if pathlib.PurePosixPath(path).name not in sdk_headers: continue
 for line_no,line in enumerate(text.splitlines(),1):
  if "QueueAction" in line and ("typedef" in line or "(*" in line):
   sdk_lines.append("%s:%d: %s"%(path,line_no,line.strip()))
   for q in ("TxSubmission","TxCompletion","RxSubmission","RxCompletion"):
    if "IOSkywalk"+q+"QueueAction" in line and "IOReturn" in line:
     sdk_found[q]=True
for q in ("TxSubmission","TxCompletion","RxSubmission","RxCompletion"):
 sdk_lines.append("SDK_ACTION_TYPEDEF_%s=%s"%(q,"PASS" if sdk_found.get(q) else "NOT_FOUND"))
(out/"sdk-action-typedefs.txt").write_text("\n".join(sdk_lines)+"\n")

# Summarize actual callback return expressions and observable packet-handling calls.
def count(pattern,s): return len(re.findall(pattern,s,re.I|re.S))
callback_rows=[]
for name in ("txSubmissionAction","txCompletionAction","rxSubmissionAction","rxCompletionAction"):
 body=bodies.get("RTW88WCLSkywalkQueues::"+name,"")
 callback_rows += [
  "\nCALLBACK="+name,
  "BODY_FOUND="+("YES" if body else "NO"),
  "IOReturn_ZERO_RETURNS=%d"%count(r"return\s+static_cast\s*<\s*IOReturn\s*>\s*\(\s*0\s*\)",body),
  "PACKET_RESOLVER_CALLS=%d"%count(r"RTW88WCLResolveEthernetTxPacket",body),
  "TX_SUBMIT_ADAPTER_CALLS=%d"%count(r"submitPacket\s*\(",body),
  "TX_COMPLETION_DRAIN_CALLS=%d"%count(r"drainCompletions\s*\(",body),
  "PACKET_ENQUEUE_OR_DEALLOC_CALLS=%d"%count(r"enqueue|deallocatePacket|recycle|push\s*\(",body),
  "PARAMETER_IGNORES=%d"%count(r"\(void\)\s*(owner|queue|packets|packetCount|refCon)",body),
 ]
(out/"callback-behavior-matrix.txt").write_text(
 "\n".join([
 "STAGE64_CALLBACK_BEHAVIOR_MATRIX",
 "SDK_CALLBACK_RETURN_TYPE=IOReturn",
 "SDK_ZERO_STATUS=kIOReturnSuccess (not a packet count)",
 "PACKET_COUNT_IS_A_SEPARATE_INPUT_ARGUMENT",
 "CAUTION=IOReturn success alone does not establish how many packets were accepted or whether ownership transferred",
 *callback_rows,
 ""]))

# Resolve the concrete Apple checkForWork methods from the actual 24H32 BootKC.
kc=KC(bootkc)
specs=[
 ("IOSkywalkTxSubmissionQueue","tx_submission_check_for_work"),
 ("IOSkywalkTxCompletionQueue","tx_completion_check_for_work"),
 ("IOSkywalkRxSubmissionQueue","rx_submission_check_for_work"),
 ("IOSkywalkRxCompletionQueue","rx_completion_check_for_work"),
]
resolved=[]; statuses=[]; issues=[]; disassembly=[]
for cls,label in specs:
 hits=[(va,nm) for va,nm in kc.methods(cls) if re.search(r"checkForWork",nm,re.I)]
 if len(hits)!=1:
  statuses.append("APPLE_METHOD class=%s label=%s matches=%d result=REVIEW_REQUIRED"%(cls,label,len(hits)))
  issues.append("APPLE_METHOD_RESOLUTION_"+label)
  continue
 va,nm=hits[0]; owner=kc.owner(va) or kc.sym_owner.get(va)
 if not owner or owner!=kc.sym_owner.get(va):
  statuses.append("APPLE_METHOD class=%s label=%s symbol=%s owner_validation=FAIL"%(cls,label,nm))
  issues.append("APPLE_METHOD_OWNER_"+label); continue
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 resolved.append((cls,label,nm,va,owner,end))
for owner in sorted({x[4] for x in resolved}):
 safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
 carved=cache/(safe+".macho"); kc.carve(owner,str(carved))
 for cls,label,nm,va,owner,end in [x for x in resolved if x[4]==owner]:
  p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn",
   "--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved)],
   text=True,capture_output=True)
  ins=sum(1 for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line))
  ok=p.returncode==0 and ins>0
  statuses.append("APPLE_METHOD class=%s label=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(
   cls,label,nm,va,owner,ins,"PASS" if ok else "REVIEW_REQUIRED"))
  if not ok: issues.append("APPLE_METHOD_DISASSEMBLY_"+label)
  disassembly += ["\n===== METHOD class=%s label=%s symbol=%s address=0x%x owner=%s ====="%(
   cls,label,nm,va,owner),"OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,ins),
   "DISASSEMBLY_BEGIN",p.stdout[:60000].rstrip(),"DISASSEMBLY_END"]
(out/"apple-method-status.txt").write_text("\n".join(statuses)+"\n")
(out/"apple-checkforwork-disassembly.txt").write_text(
 "STAGE64_APPLE_FOUR_QUEUE_CHECKFORWORK_DISASSEMBLY\n"+"\n".join(disassembly)+"\n")

# Determine the present callback implementation status without inferring packet acceptance from IOReturn.
txs=bodies.get("RTW88WCLSkywalkQueues::txSubmissionAction","")
txc=bodies.get("RTW88WCLSkywalkQueues::txCompletionAction","")
rxs=bodies.get("RTW88WCLSkywalkQueues::rxSubmissionAction","")
rxc=bodies.get("RTW88WCLSkywalkQueues::rxCompletionAction","")
checks={
 "SOURCE_CONTINUITY":source_ok,
 "ALL_FOUR_CALLBACK_BODIES_FOUND":all(x in bodies for x in [
  "RTW88WCLSkywalkQueues::txSubmissionAction","RTW88WCLSkywalkQueues::txCompletionAction",
  "RTW88WCLSkywalkQueues::rxSubmissionAction","RTW88WCLSkywalkQueues::rxCompletionAction"]),
 "ALL_FOUR_SDK_ACTION_TYPEDEFS_FOUND":len(sdk_found)==4,
 "TX_SUBMISSION_VALIDATES_NATIVE_PACKET":count(r"RTW88WCLResolveEthernetTxPacket",txs)>=1,
 "TX_SUBMISSION_DOES_NOT_CALL_TX_ADAPTER":count(r"submitPacket\s*\(",txs)==0,
 "TX_COMPLETION_HAS_NO_COMPLETION_DRAIN":count(r"drainCompletions\s*\(",txc)==0,
 "RX_SUBMISSION_HAS_NO_REFILL_OR_ENQUEUE":count(r"enqueue|allocatePacket|copyMbufToSkywalkPacket",rxs)==0,
 "RX_COMPLETION_HAS_NO_PACKET_DELIVERY":count(r"enqueue|deliverPacket|inputPacket|push\s*\(",rxc)==0,
}
callback_matrix=[
 "STAGE64_CALLBACK_OWNERSHIP_FINDINGS",
 "TX_SUBMISSION="+("DESCRIPTOR_VALIDATION_ONLY_NO_TX_ADAPTER_HANDOFF" if checks["TX_SUBMISSION_VALIDATES_NATIVE_PACKET"] and checks["TX_SUBMISSION_DOES_NOT_CALL_TX_ADAPTER"] else "REVIEW_REQUIRED"),
 "TX_COMPLETION="+("SUCCESS_STATUS_STUB_NO_COMPLETION_DRAIN" if checks["TX_COMPLETION_HAS_NO_COMPLETION_DRAIN"] else "REVIEW_REQUIRED"),
 "RX_SUBMISSION="+("NO_REFILL_OR_ENQUEUE_FOUND" if checks["RX_SUBMISSION_HAS_NO_REFILL_OR_ENQUEUE"] else "REVIEW_REQUIRED"),
 "RX_COMPLETION="+("NO_PACKET_DELIVERY_FOUND" if checks["RX_COMPLETION_HAS_NO_PACKET_DELIVERY"] else "REVIEW_REQUIRED"),
 "STATUS_SEMANTICS=callback return is IOReturn; zero denotes kIOReturnSuccess, not a packet count",
 "OWNERSHIP_CONCLUSION=the callback bodies do not yet establish complete TX/RX packet ownership transfer or hardware completion correlation",
 "ACTIVATION_GATE=BLOCKED"
]
(out/"callback-ownership-findings.txt").write_text("\n".join(callback_matrix)+"\n")

required=[
 "SOURCE_CONTINUITY","ALL_FOUR_CALLBACK_BODIES_FOUND","ALL_FOUR_SDK_ACTION_TYPEDEFS_FOUND",
 "TX_SUBMISSION_VALIDATES_NATIVE_PACKET","TX_SUBMISSION_DOES_NOT_CALL_TX_ADAPTER",
 "TX_COMPLETION_HAS_NO_COMPLETION_DRAIN","RX_SUBMISSION_HAS_NO_REFILL_OR_ENQUEUE",
 "RX_COMPLETION_HAS_NO_PACKET_DELIVERY"
]
passed=sum(bool(checks[x]) for x in required)
summary=[
 "STAGE64_QUEUE_CALLBACK_OWNERSHIP_DISPATCH_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE63_PREDECESSOR=6/6_PINS_PASS",
 "STAGE58_CALLBACK_ABI_EVIDENCE=PIN_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "NATIVE_SOURCE_FILES_SCANNED=%d"%len(source_files),
 "REQUIRED_CALLBACK_SOURCE_CHECKS=%d/%d"%(passed,len(required)),
 "SDK_ACTION_TYPEDEFS=%d/4"%len(sdk_found),
 "APPLE_CHECKFORWORK_METHODS_RESOLVED=%d/4"%len(resolved),
 "APPLE_CHECKFORWORK_METHODS_DISASSEMBLED=%d/4"%sum("result=PASS" in x for x in statuses),
 "CALLBACK_RETURN_TYPE=IOReturn",
 "ZERO_STATUS=kIOReturnSuccess_NOT_PACKET_COUNT",
 "TX_SUBMISSION=DESCRIPTOR_VALIDATION_ONLY",
 "TX_COMPLETION=STUB_NO_COMPLETION_DRAIN",
 "RX_SUBMISSION=STUB_NO_REFILL",
 "RX_COMPLETION=STUB_NO_PACKET_DELIVERY",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if passed==len(required) and len(resolved)==4 and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 64 FOUR-QUEUE CALLBACK / OWNERSHIP DISPATCH AUDIT ==========",
 "VERSION="+ "STAGE64_V1_20261102",
 "RUN="+out.name,
 "TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage63 V2 "+ "run-20261102-162123-d7577a1a3dff",
 "PURPOSE=inspect all four native queue callbacks and Apple's four checkForWork implementations without enabling scheduling or registration",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE",
 "",
 *summary,
 "",
 "INTERPRETATION=callbacks returning IOReturn success must not be confused with accepted packet counts; ownership transition must be traced through Apple queue dispatch and the actual packet operations",
 "ACTIVATION_GATE=BLOCKED",
 "========== END STAGE 64 =========="
]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

# Upload artifacts into a unique GitHub folder and verify every blob by read-back.
MAN="$OUT/manifest.txt"
{
 echo "STAGE=64"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only queue callback and ownership dispatch audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage63 V2 $STAGE63_RUN"
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
 "message":"Add Stage64 read-only queue callback ownership audit",
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
  upload_one "$file" "Development/Logs/stage64/$RUN/$base"
 else
  split -b 220k "$file" "$file.part-"
  for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage64/$RUN/$(basename "$part")"; done
 fi
 echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/source-callback-bodies.txt "$OUT"/sdk-action-typedefs.txt "$OUT"/callback-behavior-matrix.txt "$OUT"/callback-ownership-findings.txt "$OUT"/apple-method-status.txt "$OUT"/apple-checkforwork-disassembly.txt; do
 [[ -f "$f" ]] || fail "missing Stage64 artifact: $f"
 upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage64/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 64 FOUR-QUEUE CALLBACK / OWNERSHIP DISPATCH AUDIT ==========\n"
 "STAGE64_RUN: %s\n"%run+
 "STAGE64_VERSION: %s\n"%version+
 "STAGE64_SCOPE: native TX/RX queue callback bodies and Apple checkForWork dispatch paths\n"+
 "STAGE64_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — callbacks do not yet complete TX/RX packet ownership and hardware completion handoff\n"+
 "STAGE64_LOGS: Development/Logs/stage64/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({
 "message":"Append Stage64 queue callback ownership audit to output.log",
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
echo "STAGE64_VERSION=$VERSION"
echo "STAGE64_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE64_RUN=$RUN"
echo "STAGE64_LOCAL_OUTPUT=$OUT"
echo "STAGE64_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage64/$RUN"
echo "STAGE64_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE64_SOURCE_MODIFIED=NO"
echo "STAGE64_BUILD=NOT_RUN"
echo "STAGE64_INSTALL=NOT_RUN"
echo "STAGE64_LOAD=NOT_RUN"
