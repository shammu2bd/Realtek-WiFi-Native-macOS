#!/bin/bash
# Stage 67 V1 — Apple packet and pool vtable completion/recycle contract audit.
# VERSION_MARKER: STAGE67_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE67_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE66_RUN="run-20261102-170400-52c2a2c1997c"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage67/$RUN"
PREV="$OUT/predecessor-evidence"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"
LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1

capture_error(){
 local rc=$?
 LAST_ERROR_LINE="$LINENO"
 LAST_ERROR_COMMAND="$BASH_COMMAND"
 return 0
}
fail(){
 LAST_ERROR_LINE="${BASH_LINENO[0]:-$LINENO}"
 LAST_ERROR_COMMAND="fail: $*"
 echo "ERROR: $*" >&2
 exit 2
}
on_exit(){
 local rc="$1" report_path="Development/Logs/stage67/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR
 set +e
 {
  echo "STAGE=67"
  echo "VERSION=$VERSION"
  echo "RUN=$RUN"
  echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"
  printf 'FAILED_COMMAND=%s\n' "$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"
  echo "BUILD=NOT_RUN"
  echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"
  echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  echo
  echo "========== CAPTURED CONSOLE OUTPUT (last 300 lines) =========="
  [[ ! -f "$CONSOLE_LOG" ]] || tail -n 300 "$CONSOLE_LOG"
  echo
  echo "========== GENERATED FILES =========="
  find "$OUT" -maxdepth 2 -type f -print 2>/dev/null
 } > "$OUT/failure-report.txt"

 echo "STAGE67_FAILED=YES"
 echo "STAGE67_FAILURE_REPORT_LOCAL=$OUT/failure-report.txt"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
src,dst=sys.argv[1:]
pathlib.Path(dst).write_text(json.dumps({
 "message":"Upload Stage67 automatic failure report",
 "content":base64.b64encode(pathlib.Path(src).read_bytes()).decode()
}))
PY
  if gh api --method PUT "repos/$REPO/contents/$report_path" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then
   echo "STAGE67_FAILURE_REPORT_GITHUB=Development/Logs/stage67/$RUN/failure-report.txt"
  else
   echo "STAGE67_FAILURE_REPORT_UPLOAD=FAILED" >> "$OUT/failure-report.txt"
   echo "STAGE67_FAILURE_REPORT_UPLOAD=FAILED"
  fi

  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$report_path" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,version,rc,report,line,command=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 67 FAILURE REPORT ==========\n"
 "STAGE67_FAILURE_RUN: %s\n"%run+
 "STAGE67_VERSION: %s\n"%version+
 "STAGE67_EXIT_CODE: %s\n"%rc+
 "STAGE67_FAILED_LINE: %s\n"%line+
 "STAGE67_FAILED_COMMAND: %s\n"%command+
 "STAGE67_FAILURE_REPORT: %s\n"%report+
 "STAGE67_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
 "==============================================\n").encode()
pathlib.Path(payload).write_text(json.dumps({
 "message":"Append Stage67 failure details to output.log",
 "sha":obj["sha"],
 "content":base64.b64encode(old.rstrip()+entry).decode()
}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then
    echo "STAGE67_FAILURE_OUTPUT_LOG=UPDATED"
   else
    echo "STAGE67_FAILURE_OUTPUT_LOG=FAILED"
   fi
  else
   echo "STAGE67_FAILURE_OUTPUT_LOG=FETCH_FAILED"
  fi
 else
  echo "STAGE67_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"
 fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

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
RAW66="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage66/$STAGE66_RUN"
for name in audit-summary.txt report.txt source-fingerprint.txt symbol-discovery.txt packet-queue-init-vtable-target.txt callback-registration-contract.txt method-status.txt apple-queue-lifecycle-disassembly.txt dispatch-edge-inventory.txt manifest.txt; do
 curl -fsSLo "$PREV/$name" "$RAW66/$name"
done
verify_pin(){
 local file="$1" expected="$2" got
 got="$(blob_sha "$PREV/$file")"
 [[ "$got" == "$expected" ]] || fail "Stage66 predecessor pin mismatch: $file expected=$expected got=$got"
 echo "STAGE66_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt 7ed3e39af4d51a33202f30e0a80221d6d3f1b8bd
verify_pin report.txt 1922567308fdebb08f8816f718369913501b2102
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin symbol-discovery.txt 1a34f6f12014e3f2f996078db8f1a7d6ac3c5fb5
verify_pin packet-queue-init-vtable-target.txt 83a3c279b5ac3f3532e64eaf4a1ea9563345ef90
verify_pin callback-registration-contract.txt 562917e2c7d9c9e24baeceec5a0715bc653f1541
verify_pin method-status.txt d938005c9c3954b6e2eefc64f04d1f42ba5883a6
verify_pin apple-queue-lifecycle-disassembly.txt cb0474b85e2e9132adc93ccf16c15deb8b547bfe
verify_pin dispatch-edge-inventory.txt 3279f7365c788575ff7b8586bba80c0f72d25a95
verify_pin manifest.txt fdcd95ea075b448f62863916313addc5ad480d12
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage66 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage66 source continuity is not PASS"

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
sys.path.insert(0,str(out/"tools"))
from kcfile import KC
os.environ["LLVM_OBJDUMP"]=objdump

def as_addr(value):
 if isinstance(value,int): return value
 if value is None: return 0
 raw=str(value).strip()
 if raw.lower().startswith("0x"): return int(raw,16)
 if re.fullmatch(r"[0-9a-fA-F]+",raw): return int(raw,16)
 return int(raw,0)

fingerprint_items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"}
fp=[]; source_ok=True
for rel,want in fingerprint_items.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 ok=got==want; source_ok &= ok
 fp += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if ok else "MISMATCH")]
fp.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(fp)+"\n")

stage66_dis=(pathlib.Path(sys.argv[5])/"predecessor-evidence"/"apple-queue-lifecycle-disassembly.txt").read_text()
kc=KC(bootkc)
disasm_lines=["STAGE67_PACKET_AND_POOL_VTABLE_COMPLETION_RECYCLE_DISASSEMBLY"]
status=[]; discovered=[]; issues=[]; methods={}

# Core direct methods establish the state changes surrounding packet completion,
# source-queue notifications, and RX packet publication.
direct_patterns=[
 ("IOSkywalkPacketQueue",r"initialize|finalize|free|disable|packetCompletionEjjb|packetSubmissionEjj|notifySrcQueue"),
 ("IOSkywalkTxCompletionQueue",r"completePackets"),
 ("IOSkywalkRxCompletionQueue",r"enqueuePacketsForNetworking|enqueuePacketsForKPipe"),
 ("IOSkywalkPacket",r"getSourceQueue"),
 ("IOSkywalkPacketBufferPool",r"checkInPacketQueue")]
direct_counts={}
for cls,pat in direct_patterns:
 hits=[]
 try:
  for va,nm in kc.methods(cls):
   va=as_addr(va)
   if re.search(pat,nm,re.I) and not re.search(r"(?:metaClass|superClass|gMetaClass)E$",nm,re.I):
    hits.append((va,nm))
    methods[va]=(cls,nm,"ownership-method")
 except Exception as e:
  discovered.append("CLASS_SCAN_ERROR class=%s error=%s"%(cls,str(e)))
  issues.append("CLASS_SCAN_ERROR_"+cls)
 direct_counts[cls]=len(hits)
 discovered.append("DIRECT_METHOD_DISCOVERY class=%s pattern=%s count=%d"%(cls,pat,len(hits)))
 for va,nm in hits: discovered.append("DIRECT_METHOD class=%s address=0x%x symbol=%s"%(cls,va,nm))

# Resolve the exact virtual targets used by Stage66's disassembled completion/recycle paths.
slot_specs=[
 ("IOSkywalkPacket",0x140,"packet object method invoked before source-queue lookup"),
 ("IOSkywalkPacket",0x198,"packet object method invoked with completion queue and flags"),
 ("IOSkywalkPacket",0x1e0,"packet object method called from RX networking enqueue"),
 ("IOSkywalkPacketBufferPool",0x148,"packet-buffer-pool target called with packet array/count")]
slot_lines=["STAGE67_PACKET_AND_POOL_VTABLE_TARGETS",
 "SOURCE=Stage66 IOSkywalkPacketQueue/TxCompletionQueue/RxCompletionQueue disassembly"]
slot_pass={"IOSkywalkPacket":0,"IOSkywalkPacketBufferPool":0}
for cls,off,observed in slot_specs:
 slot_lines.append("\nCLASS="+cls+" SLOT_OFFSET=0x%x OBSERVED_USE=%s"%(off,observed))
 try:
  vt=kc.vtable(cls); idx=off//8
  if len(vt)<=idx: raise RuntimeError("vtable too short for index %d"%idx)
  word,raw,tgt,nm=vt[idx]; tgt=as_addr(tgt)
  owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
  okay=bool(tgt) and owner!="UNKNOWN"
  slot_lines.append("SLOT offset=0x%x index=%d target=0x%x owner=%s symbol=%s result=%s"%(
   off,idx,tgt,owner,nm or "UNNAMED","PASS" if okay else "REVIEW_REQUIRED"))
  if okay:
   slot_pass[cls]+=1
   methods[tgt]=(cls,nm or "vtable@0x%x"%off,"vtable-target")
  else: issues.append("VTABLE_TARGET_UNRESOLVED_%s_0x%x"%(cls,off))
 except Exception as e:
  slot_lines.append("SLOT offset=0x%x result=ERROR error=%s"%(off,str(e)))
  issues.append("VTABLE_RESOLUTION_ERROR_%s_0x%x"%(cls,off))
(out/"packet-pool-vtable-targets.txt").write_text("\n".join(slot_lines)+"\n")

resolved=[]
for va,(cls,nm,kind) in sorted(methods.items()):
 owner=kc.owner(va) or kc.sym_owner.get(va)
 if not owner or owner!=kc.sym_owner.get(va):
  status.append("METHOD class=%s kind=%s symbol=%s address=0x%x owner_validation=FAIL"%(cls,kind,nm,va))
  issues.append("OWNER_VALIDATION_"+nm); continue
 end_raw=kc.next_sym(va)
 end=as_addr(end_raw) if end_raw else va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 resolved.append((cls,nm,kind,va,owner,end))
carved={}
for owner in sorted({x[4] for x in resolved}):
 safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
 p=cache/(safe+".macho"); kc.carve(owner,str(p)); carved[owner]=p
for cls,nm,kind,va,owner,end in resolved:
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn",
  "--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],
  text=True,capture_output=True)
 ins=sum(1 for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line))
 ok=p.returncode==0 and ins>0
 status.append("METHOD class=%s kind=%s symbol=%s address=0x%x owner=%s instructions=%d result=%s"%(
  cls,kind,nm,va,owner,ins,"PASS" if ok else "REVIEW_REQUIRED"))
 if not ok: issues.append("DISASSEMBLY_"+nm)
 disasm_lines += ["\n===== METHOD class=%s kind=%s symbol=%s address=0x%x owner=%s ====="%(
  cls,kind,nm,va,owner),"OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,ins),
  "DISASSEMBLY_BEGIN",p.stdout[:70000].rstrip(),"DISASSEMBLY_END"]
(out/"method-status.txt").write_text("\n".join(status)+"\n")
(out/"apple-packet-ownership-disassembly.txt").write_text("\n".join(disasm_lines)+"\n")
(out/"symbol-discovery.txt").write_text("\n".join(discovered)+"\n")

# Build a callsite-to-vtable crosswalk from the exact Stage66 evidence.
blocks=re.split(r"(?=^===== METHOD )",stage66_dis,flags=re.M)
wanted=[
 ("QUEUE_PACKET_COMPLETION",r"symbol=.*IOSkywalkPacketQueue16packetCompletionEjjb"),
 ("TX_COMPLETION_PACKET_DRAIN",r"symbol=.*IOSkywalkTxCompletionQueue15completePackets"),
 ("RX_NETWORK_PACKET_ENQUEUE",r"symbol=.*IOSkywalkRxCompletionQueue27enqueuePacketsForNetworking"),
 ("RX_KPIPE_PACKET_ENQUEUE",r"symbol=.*IOSkywalkRxCompletionQueue22enqueuePacketsForKPipe")]
cross=["STAGE67_PACKET_OWNERSHIP_CALLSITE_CROSSWALK"]
for label,pat in wanted:
 block=next((b for b in blocks if re.search(pat,b,re.M)),None)
 cross.append("\n"+label)
 if block:
  lines=block.splitlines()
  # Preserve call/indirect dispatch and nearby argument preparation without dumping duplicate whole methods.
  selected=[x for x in lines if re.search(r"\bcall\b|\bjmp\s+qword ptr\b|mov\s+.*\[(rbx|rdi|r14|rax) \+ 0x(18|20|28|50|68|e0|e8|f0|f8|140|148|198|1e0)\]",x)]
  cross.extend(selected or ["NO_RELEVANT_INSTRUCTIONS_SELECTED"])
 else:
  cross.append("PREDECESSOR_METHOD_NOT_FOUND")
cross += [
 "\nPACKET_VTABLE_SLOT_MEANINGS=not inferred from offsets; exact target symbols and disassembly are recorded separately",
 "POOL_VTABLE_SLOT_MEANING=not inferred from offset; exact target symbol and disassembly are recorded separately",
 "COMPLETION_HOOK_DYNAMIC_OBJECT=Stage66 TX completion path calls object at queue offset +0xf0 through vtable offset +0x268; dynamic class not established by available pinned evidence",
 "OWNERSHIP_RULE=do not equate callback count with number of packets safely reclaimed until packet vtable targets and pool target bodies are reviewed"]
(out/"packet-ownership-callsite-crosswalk.txt").write_text("\n".join(cross)+"\n")

# The required call-edge artifact is generated from the captured method disassembly.
edge_lines=["STAGE67_PACKET_AND_POOL_CALL_EDGE_INVENTORY"]
for block in re.split(r"(?=^===== METHOD )","\n".join(disasm_lines),flags=re.M):
 header=next((x for x in block.splitlines() if x.startswith("===== METHOD ")),None)
 if not header: continue
 calls=[x.strip() for x in block.splitlines() if re.search(r"\bcall\b|\bjmp\s+qword ptr\b",x)]
 edge_lines.append("\n"+header)
 edge_lines += calls or ["NO_CALL_EDGES_CAPTURED"]
(out/"dispatch-edge-inventory.txt").write_text("\n".join(edge_lines)+"\n")

expected_slots=(slot_pass["IOSkywalkPacket"]==3 and slot_pass["IOSkywalkPacketBufferPool"]==1)
all_ok=len(resolved)>0 and len(status)==len(resolved) and all("result=PASS" in x for x in status)
missing=[]
for cls,pat in [
 ("IOSkywalkPacketQueue",r"packetCompletionEjjb"),
 ("IOSkywalkTxCompletionQueue",r"completePackets"),
 ("IOSkywalkRxCompletionQueue",r"enqueuePacketsForNetworking"),
 ("IOSkywalkPacket",r"getSourceQueue"),
 ("IOSkywalkPacketBufferPool",r"checkInPacketQueue")]:
 if direct_counts.get(cls,0)<1: missing.append(cls+"_"+pat)
summary=[
 "STAGE67_PACKET_AND_POOL_VTABLE_COMPLETION_RECYCLE_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE66_PREDECESSOR=10/10_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "PACKET_VTABLE_SLOTS_RESOLVED=%d/3"%slot_pass["IOSkywalkPacket"],
 "PACKET_BUFFER_POOL_VTABLE_SLOTS_RESOLVED=%d/1"%slot_pass["IOSkywalkPacketBufferPool"],
 "PACKET_QUEUE_DIRECT_METHODS=%d"%direct_counts.get("IOSkywalkPacketQueue",0),
 "PACKET_SOURCE_METHODS=%d"%direct_counts.get("IOSkywalkPacket",0),
 "POOL_RECYCLE_METHODS=%d"%direct_counts.get("IOSkywalkPacketBufferPool",0),
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "MISSING_REQUIRED_METHODS="+(",".join(missing) if missing else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if source_ok and expected_slots and all_ok and not missing and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 67 PACKET / POOL VTABLE COMPLETION AND RECYCLE AUDIT ==========",
 "VERSION=STAGE67_V1_20261102","RUN="+out.name,"TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage66 V1 run-20261102-170400-52c2a2c1997c",
 "PURPOSE=resolve packet and packet-buffer-pool virtual targets reached by Stage66 TX completion and RX enqueue paths; disassemble queue completion and pool recycle methods",
 "SCOPE=read-only kernel collection vtable resolution, method disassembly and packet ownership callsite crosswalk",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "CAUTION=vtable offsets are not assigned semantic names without corroborating symbols and method bodies; no packet ownership implementation is authorized by this audit",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 67 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=67"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only Apple packet and pool vtable completion/recycle contract audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage66 V1 $STAGE66_RUN"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1)); payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
f,d=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Add Stage67 read-only Apple packet ownership audit",
 "content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}))
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
 base="$(basename "$file")"; bytes="$(wc -c < "$file" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$file" "Development/Logs/stage67/$RUN/$base"
 else
  split -b 220k "$file" "$file.part-"
  for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage67/$RUN/$(basename "$part")"; done
 fi
 echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/symbol-discovery.txt "$OUT"/packet-pool-vtable-targets.txt "$OUT"/packet-ownership-callsite-crosswalk.txt "$OUT"/method-status.txt "$OUT"/apple-packet-ownership-disassembly.txt "$OUT"/dispatch-edge-inventory.txt; do
 [[ -f "$f" ]] || fail "missing Stage67 artifact: $f"
 upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage67/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 67 PACKET / POOL VTABLE COMPLETION AND RECYCLE AUDIT ==========\n"
 "STAGE67_RUN: %s\n"%run+
 "STAGE67_VERSION: %s\n"%version+
 "STAGE67_SCOPE: packet vtable targets, pool recycle dispatch, packet completion and RX enqueue lifecycle methods\n"+
 "STAGE67_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — packet ownership implementation and hardware testing remain unauthorized\n"+
 "STAGE67_LOGS: Development/Logs/stage67/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Append Stage67 Apple packet ownership audit",
 "sha":sha,"content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}))
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
echo "STAGE67_VERSION=$VERSION"
echo "STAGE67_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE67_RUN=$RUN"
echo "STAGE67_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE67_LOCAL_OUTPUT=$OUT"
echo "STAGE67_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage67/$RUN"
echo "STAGE67_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE67_SOURCE_MODIFIED=NO"
echo "STAGE67_BUILD=NOT_RUN"
echo "STAGE67_INSTALL=NOT_RUN"
echo "STAGE67_LOAD=NOT_RUN"
