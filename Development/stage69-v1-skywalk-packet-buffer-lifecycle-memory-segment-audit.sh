#!/bin/bash
# Stage 69 V1 — Skywalk packet-buffer lifecycle and memory-segment dispatch audit.
# VERSION_MARKER: STAGE69_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE69_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE68_RUN="run-20261102-172350-25eb343ad74b"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage69/$RUN"
PREV="$OUT/predecessor-evidence"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"
LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1

fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" report_path="Development/Logs/stage69/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR
 set +e
 {
  echo "STAGE=69"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
  echo "EXIT_CODE=$rc"; echo "FAILED_LINE=$LAST_ERROR_LINE"
  printf 'FAILED_COMMAND=%s\n' "$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"
  echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  echo; echo "========== CAPTURED CONSOLE OUTPUT (last 300 lines) =========="
  [[ ! -f "$CONSOLE_LOG" ]] || tail -n 300 "$CONSOLE_LOG"
  echo; echo "========== GENERATED FILES =========="
  find "$OUT" -maxdepth 2 -type f -print 2>/dev/null
 } > "$OUT/failure-report.txt"
 echo "STAGE69_FAILED=YES"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
src,dst=sys.argv[1:]
pathlib.Path(dst).write_text(json.dumps({"message":"Upload Stage69 automatic failure report",
 "content":base64.b64encode(pathlib.Path(src).read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$report_path" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then
   echo "STAGE69_FAILURE_REPORT_GITHUB=$report_path"
  else echo "STAGE69_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$report_path" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,version,rc,report,line,command=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 69 FAILURE REPORT ==========\n"
 "STAGE69_FAILURE_RUN: %s\n"%run+
 "STAGE69_VERSION: %s\n"%version+
 "STAGE69_EXIT_CODE: %s\n"%rc+
 "STAGE69_FAILED_LINE: %s\n"%line+
 "STAGE69_FAILED_COMMAND: %s\n"%command+
 "STAGE69_FAILURE_REPORT: %s\n"%report+
 "STAGE69_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"
 "==============================================\n").encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage69 failure to output.log",
 "sha":obj["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then
    echo "STAGE69_FAILURE_OUTPUT_LOG=UPDATED"
   else echo "STAGE69_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE69_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE69_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split tee find date tail; do
 command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
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
RAW68="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage68/$STAGE68_RUN"
for name in audit-summary.txt report.txt source-fingerprint.txt symbol-discovery.txt packet-buffer-vtable-targets.txt packet-buffer-callsite-crosswalk.txt method-status.txt apple-packet-buffer-disassembly.txt manifest.txt; do
 curl -fsSLo "$PREV/$name" "$RAW68/$name"
done
verify_pin(){
 local file="$1" expected="$2" got
 got="$(blob_sha "$PREV/$file")"
 [[ "$got" == "$expected" ]] || fail "Stage68 predecessor pin mismatch: $file expected=$expected got=$got"
 echo "STAGE68_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt 77e89b49a98da73aff8bf1d3e331962e6f112a64
verify_pin report.txt 8c1bec1f735f65d1d4d4b72189c2191e0b7814cc
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin symbol-discovery.txt 3774ec39392125a9c3a13761402a2091e31cc84d
verify_pin packet-buffer-vtable-targets.txt 7ef9d29469361f07ba04754eb0c549591eebae7f
verify_pin packet-buffer-callsite-crosswalk.txt aba1d507c5037ffa94db6e7b95a29344c16f0e6f
verify_pin method-status.txt faad1cdee334b15854fe0ca1b8d86c9f79220aa6
verify_pin apple-packet-buffer-disassembly.txt 0c5b16789f67b25cbbdfd7a2164ddd1cf0fc41bb
verify_pin manifest.txt 3703b2833e6ad0c3658113684989900313790389
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage68 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage68 source continuity is not PASS"

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
if not source_ok: raise SystemExit("Stage43 source baseline changed")

kc=KC(bootkc)
disasm_lines=["STAGE69_SKYWALK_PACKET_BUFFER_LIFECYCLE_AND_MEMORY_SEGMENT_DISASSEMBLY"]
status=[]; discovered=[]; issues=[]; methods={}
classes={
 "IOSkywalkPacketBuffer":r"finalize|disposePacketBuffer|getBufferHandle|acquireWithBufferHandle|acquireWithBufletHandle|setPacket|prepareWithMemorySegment|completeWithMemorySegment|prepareWithQueue|completeWithQueue",
 "IOSkywalkPacketBufferPool":r"getPacketBufferWithSegmentInfo|getPacketBufferWithBufletHandle|allocatePacketBuffer|allocatePacketBuffers|deallocatePacketBuffer|deallocatePacketBuffers|deallocatePacket|deallocatePackets|releaseAllPackets|releaseAllMemorySegments|checkInPacketQueue|initWithName|free",
 "IOSkywalkMemorySegment":r"getMemoryDescriptor|prepare|complete|init|release|free"}
found={}
for cls,pat in classes.items():
 hits=[]
 try:
  for va,nm in kc.methods(cls):
   va=as_addr(va)
   if re.search(pat,nm,re.I) and not re.search(r"(?:metaClass|superClass|gMetaClass)E$",nm,re.I):
    hits.append((va,nm)); methods[va]=(cls,nm,"lifecycle-method")
 except Exception as e:
  issues.append("CLASS_SCAN_ERROR_"+cls)
  discovered.append("CLASS_SCAN_ERROR class=%s error=%s"%(cls,str(e)))
 found[cls]=hits
 discovered.append("METHOD_DISCOVERY class=%s pattern=%s count=%d"%(cls,pat,len(hits)))
 discovered += ["METHOD class=%s address=0x%x symbol=%s"%(cls,va,nm) for va,nm in hits]

# Resolve only slots directly evidenced by Stage68 wrappers/callers.
slot_specs=[
 ("IOSkywalkPacketBuffer",0x120,"prepareWithMemorySegment wrapper dispatches here"),
 ("IOSkywalkPacketBuffer",0x128,"completeWithMemorySegment wrapper dispatches here"),
 ("IOSkywalkPacketBuffer",0x148,"pool deallocatePacketBuffer dispatches here when buffer state bit 1 is set")]
slot_lines=["STAGE69_PACKET_BUFFER_LIFECYCLE_VTABLE_TARGETS",
 "SOURCE=Stage68 IOSkywalkPacketBuffer wrappers and IOSkywalkPacketBufferPool::deallocatePacketBuffer"]
slot_pass=0
for cls,off,observed in slot_specs:
 slot_lines.append("\nCLASS=%s SLOT_OFFSET=0x%x OBSERVED_USE=%s"%(cls,off,observed))
 try:
  vt=kc.vtable(cls); idx=off//8
  if len(vt)<=idx: raise RuntimeError("vtable too short for index %d"%idx)
  word,raw,tgt,nm=vt[idx]; tgt=as_addr(tgt)
  owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
  okay=bool(tgt) and owner!="UNKNOWN"
  slot_lines.append("SLOT offset=0x%x index=%d target=0x%x owner=%s symbol=%s result=%s"%(
   off,idx,tgt,owner,nm or "UNNAMED","PASS" if okay else "REVIEW_REQUIRED"))
  if okay:
   slot_pass+=1; methods[tgt]=(cls,nm or "vtable@0x%x"%off,"vtable-target")
  else: issues.append("VTABLE_TARGET_UNRESOLVED_%s_0x%x"%(cls,off))
 except Exception as e:
  slot_lines.append("SLOT offset=0x%x result=ERROR error=%s"%(off,str(e)))
  issues.append("VTABLE_RESOLUTION_ERROR_%s_0x%x"%(cls,off))
(out/"packet-buffer-lifecycle-vtable-targets.txt").write_text("\n".join(slot_lines)+"\n")

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
(out/"apple-packet-buffer-lifecycle-disassembly.txt").write_text("\n".join(disasm_lines)+"\n")
(out/"symbol-discovery.txt").write_text("\n".join(discovered)+"\n")

# Crosswalk preserves the exact Stage68 call paths; indirect slots remain unnamed until resolved.
stage68=(pathlib.Path(sys.argv[5])/"predecessor-evidence"/"apple-packet-buffer-disassembly.txt").read_text()
blocks=re.split(r"(?=^===== METHOD )",stage68,flags=re.M)
wanted=[
 ("PACKET_BUFFER_PREPARE_WITH_MEMORY_SEGMENT",r"symbol=.*IOSkywalkPacketBuffer24prepareWithMemorySegment"),
 ("PACKET_BUFFER_COMPLETE_WITH_MEMORY_SEGMENT",r"symbol=.*IOSkywalkPacketBuffer25completeWithMemorySegment"),
 ("PACKET_BUFFER_PREPARE_WITH_QUEUE",r"symbol=.*IOSkywalkPacketBuffer16prepareWithQueue"),
 ("PACKET_BUFFER_COMPLETE_WITH_QUEUE",r"symbol=.*IOSkywalkPacketBuffer17completeWithQueue"),
 ("POOL_GET_BUFFER_BY_BUFLET",r"symbol=.*IOSkywalkPacketBufferPool31getPacketBufferWithBufletHandle"),
 ("POOL_ALLOCATE_BUFFER",r"symbol=.*IOSkywalkPacketBufferPool20allocatePacketBuffer"),
 ("POOL_DEALLOCATE_BUFFER",r"symbol=.*IOSkywalkPacketBufferPool22deallocatePacketBuffer")]
cross=["STAGE69_PACKET_BUFFER_LIFECYCLE_AND_MEMORY_SEGMENT_CROSSWALK"]
for label,pat in wanted:
 block=next((b for b in blocks if re.search(pat,b,re.M)),None)
 cross.append("\n"+label)
 if block:
  selected=[x for x in block.splitlines() if re.search(r"\bcall\b|\bjmp\s+qword ptr\b|call\s+qword ptr|mov\s+.*\[(rbx|rdi|r14|r15|rax|rcx) \+ 0x(18|28|30|38|40|48|58|68|70|78|7c|80|88|a8|120|128|140|148|1e8)\]",x)]
  cross.extend(selected or ["NO_RELEVANT_INSTRUCTIONS_SELECTED"])
 else: cross.append("PREDECESSOR_METHOD_NOT_FOUND")
cross += [
 "\nSLOT_0x120_0x128_0x148=targets resolved from IOSkywalkPacketBuffer vtable; no semantic labels inferred from offsets alone",
 "POOL_SEGMENT_DISPATCH=Stage68 getPacketBufferWithBufletHandle calls vtable +0x1e8 on objects at pool+0x68 and returned-object+0x40; dynamic class identity is not assumed here",
 "LIFETIME_RULE=allocation, handle acquisition, buffer preparation, packet attachment, completion, dispose and handle release must be reviewed as one lifecycle; successful disassembly alone is not proof of safe driver ownership"]
(out/"packet-buffer-lifecycle-crosswalk.txt").write_text("\n".join(cross)+"\n")

required=[
 ("IOSkywalkPacketBuffer",r"finalize"),
 ("IOSkywalkPacketBuffer",r"disposePacketBuffer"),
 ("IOSkywalkPacketBuffer",r"getBufferHandle"),
 ("IOSkywalkPacketBuffer",r"acquireWithBufferHandle"),
 ("IOSkywalkPacketBufferPool",r"getPacketBufferWithSegmentInfo"),
 ("IOSkywalkPacketBufferPool",r"getPacketBufferWithBufletHandle"),
 ("IOSkywalkPacketBufferPool",r"allocatePacketBuffer"),
 ("IOSkywalkPacketBufferPool",r"deallocatePacketBuffer"),
 ("IOSkywalkMemorySegment",r"getMemoryDescriptor")]
missing=[]
for cls,pat in required:
 if not any(re.search(pat,nm,re.I) for _,nm in found.get(cls,[])):
  missing.append(cls+"_"+pat)
if missing: issues += ["REQUIRED_METHOD_MISSING_"+x for x in missing]
all_ok=len(resolved)>0 and len(status)==len(resolved) and all("result=PASS" in x for x in status)
summary=[
 "STAGE69_SKYWALK_PACKET_BUFFER_LIFECYCLE_AND_MEMORY_SEGMENT_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE68_PREDECESSOR=9/9_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "PACKET_BUFFER_METHODS_RESOLVED=%d"%len(found.get("IOSkywalkPacketBuffer",[])),
 "PACKET_BUFFER_POOL_METHODS_RESOLVED=%d"%len(found.get("IOSkywalkPacketBufferPool",[])),
 "MEMORY_SEGMENT_METHODS_RESOLVED=%d"%len(found.get("IOSkywalkMemorySegment",[])),
 "PACKET_BUFFER_LIFECYCLE_VTABLE_TARGETS=%d/3"%slot_pass,
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "MISSING_REQUIRED_METHODS="+(",".join(missing) if missing else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if source_ok and slot_pass==3 and all_ok and not missing and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 69 SKYWALK PACKET-BUFFER LIFECYCLE / MEMORY-SEGMENT AUDIT ==========",
 "VERSION=STAGE69_V1_20261102","RUN="+out.name,"TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage68 V1 run-20261102-172350-25eb343ad74b",
 "PURPOSE=resolve packet-buffer prepare/complete memory-segment vtable targets and trace buffer allocation, handle acquisition, packet attachment, disposal and pool release",
 "SCOPE=read-only kernel collection method/vtable resolution and disassembly",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "CAUTION=dynamic pool/segment dispatch and ownership semantics remain subject to review; vtable offsets alone do not establish a callable driver contract",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 69 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not source_ok or slot_pass!=3 or not all_ok or missing or issues:
 raise SystemExit("Stage69 packet-buffer lifecycle audit requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=69"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only packet buffer lifecycle and memory segment dispatch audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage68 V1 $STAGE68_RUN"
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
pathlib.Path(d).write_text(json.dumps({"message":"Add Stage69 read-only packet buffer lifecycle audit",
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
 if (( bytes <= 225280 )); then upload_one "$file" "Development/Logs/stage69/$RUN/$base"
 else
  split -b 220k "$file" "$file.part-"
  for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage69/$RUN/$(basename "$part")"; done
 fi
 echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/symbol-discovery.txt "$OUT"/packet-buffer-lifecycle-vtable-targets.txt "$OUT"/packet-buffer-lifecycle-crosswalk.txt "$OUT"/method-status.txt "$OUT"/apple-packet-buffer-lifecycle-disassembly.txt; do
 [[ -f "$f" ]] || fail "missing Stage69 artifact: $f"
 upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage69/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 69 SKYWALK PACKET-BUFFER LIFECYCLE / MEMORY-SEGMENT AUDIT ==========\n"
 "STAGE69_RUN: %s\n"%run+
 "STAGE69_VERSION: %s\n"%version+
 "STAGE69_SCOPE: packet-buffer prepare/complete vtable targets, handle lookup/acquire, packet attachment, disposal and pool release lifecycle\n"+
 "STAGE69_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — packet ownership and device queue handoff still require a reviewed implementation\n"+
 "STAGE69_LOGS: Development/Logs/stage69/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Append Stage69 packet buffer lifecycle audit",
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
echo "STAGE69_VERSION=$VERSION"
echo "STAGE69_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE69_RUN=$RUN"
echo "STAGE69_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE69_LOCAL_OUTPUT=$OUT"
echo "STAGE69_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage69/$RUN"
echo "STAGE69_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE69_SOURCE_MODIFIED=NO"
echo "STAGE69_BUILD=NOT_RUN"
echo "STAGE69_INSTALL=NOT_RUN"
echo "STAGE69_LOAD=NOT_RUN"
