#!/bin/bash
# Stage 66 V1 — Apple queue callback registration and packet lifecycle contract audit.
# VERSION_MARKER: STAGE66_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE66_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
STAGE65_RUN="run-20261102-164949-2151a8b9670a"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage66/$RUN"
PREV="$OUT/predecessor-evidence"
TOOLS="$OUT/tools"
CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE66_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -60 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
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
RAW65="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage65/$STAGE65_RUN"
for name in audit-summary.txt report.txt source-fingerprint.txt symbol-discovery.txt tx-submission-vtable-targets.txt method-status.txt apple-queue-helper-disassembly.txt dispatch-edge-inventory.txt manifest.txt; do
 curl -fsSLo "$PREV/$name" "$RAW65/$name"
done
verify_pin(){
 local file="$1" expected="$2" got
 got="$(blob_sha "$PREV/$file")"
 [[ "$got" == "$expected" ]] || fail "Stage65 predecessor pin mismatch: $file expected=$expected got=$got"
 echo "STAGE65_PIN_PASS=$file SHA=$got"
}
verify_pin audit-summary.txt bbd6c2bfc05b2e4d5c2ac5485521275d0a1ca7d3
verify_pin report.txt bc546ac7a3129a47f731f376c4efc56393fcb77b
verify_pin source-fingerprint.txt 67bfe72603cd4316bd9a9107de5c97e1c37f625c
verify_pin symbol-discovery.txt 24d8628124a15af55562109a7f744f78e552c0ed
verify_pin tx-submission-vtable-targets.txt 350ffc8921a4433d33b16248e887e10383fac90b
verify_pin method-status.txt 32e772b0a0f2b1961f5670e2ef362b26081cb0a0
verify_pin apple-queue-helper-disassembly.txt f743677ff038f8211285cebefcc443da210174f2
verify_pin dispatch-edge-inventory.txt 9b92b153e6e6a9c056d5b10b5f5d411e9639b984
verify_pin manifest.txt fd713c48e172e63b3808adb2ea3406277ed9c36f
grep -q '^RESULT=PASS$' "$PREV/audit-summary.txt" || fail "Stage65 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/source-fingerprint.txt" || fail "Stage65 source continuity is not PASS"

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
 return int(raw,16) if re.fullmatch(r"(?:0x)?[0-9a-fA-F]+",raw) else int(raw,0)

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
disasm_lines=["STAGE66_APPLE_QUEUE_CALLBACK_REGISTRATION_AND_PACKET_LIFECYCLE_DISASSEMBLY"]
status=[]; discovered=[]; issues=[]; methods={}
queue_classes=("IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue",
               "IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue")
# The initWithPool methods call IOSkywalkPacketQueue's vtable slot 0x240.
for cls in queue_classes:
 for va,nm in kc.methods(cls):
  va=as_addr(va)
  if re.search(r"initWithPool",nm,re.I):
   methods[va]=(cls,nm,"queue-init")
   discovered.append("QUEUE_INIT class=%s address=0x%x symbol=%s"%(cls,va,nm))
# Directly follow the base Queue vtable target used by all four initWithPool bodies.
base_vtable_lines=["STAGE66_IOSKYWALK_PACKET_QUEUE_INIT_DISPATCH",
 "SOURCE=initWithPool disassembly calls IOSkywalkPacketQueue vtable slot offset 0x240",
 "SLOT_OFFSET=0x240"]
try:
 vt=kc.vtable("IOSkywalkPacketQueue")
 idx=0x240//8
 if len(vt)<=idx: raise RuntimeError("vtable too short")
 word,raw,tgt,nm=vt[idx]
 tgt=as_addr(tgt)
 owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"
 base_vtable_lines.append("SLOT offset=0x240 index=%d target=0x%x owner=%s symbol=%s"%(idx,tgt,owner,nm))
 if not tgt or owner=="UNKNOWN": issues.append("PACKET_QUEUE_INIT_TARGET_UNRESOLVED")
 else: methods[tgt]=("IOSkywalkPacketQueue","vtable@0x240:"+nm,"base-init-target")
except Exception as e:
 base_vtable_lines.append("VTABLE_ERROR="+str(e)); issues.append("PACKET_QUEUE_INIT_VTABLE_ERROR")
(out/"packet-queue-init-vtable-target.txt").write_text("\n".join(base_vtable_lines)+"\n")

# Follow every state-transition helper reached by Stage65's Apple callback bodies.
patterns=[
 ("IOSkywalkTxSubmissionQueue",r"packetSubmissionForKPipe|packetSubmission|refillTxRingForKPipe|legacyDequeue|getPacketListForKPipe"),
 ("IOSkywalkTxCompletionQueue",r"enqueueAndCompletePackets|completePackets"),
 ("IOSkywalkRxSubmissionQueue",r"gatedDequeue|refillRxRing|legacyDequeue|listDequeue|retryDequeue"),
 ("IOSkywalkRxCompletionQueue",r"gatedEnqueue|enqueuePacketsForKPipe|enqueuePacketsForNetworking")]
for cls,pat in patterns:
 hits=[]
 for va,nm in kc.methods(cls):
  if re.search(pat,nm,re.I): hits.append((as_addr(va),nm))
 discovered.append("LIFECYCLE_DISCOVERY class=%s pattern=%s count=%d"%(cls,pat,len(hits)))
 if not hits: issues.append("LIFECYCLE_HELPER_NOT_FOUND_"+cls)
 for va,nm in hits:
  methods[va]=(cls,nm,"packet-lifecycle")
# Capture base queue methods whose names expose callback registration or dispatch.
base_hits=[]; excluded_base_data=[]
for va,nm in kc.methods("IOSkywalkPacketQueue"):
 va=as_addr(va)
 # kc.methods() can include static class metadata symbols as well as executable methods.
 # These Itanium member-data symbols are not callable code and must not be disassembled.
 if re.search(r"(?:metaClass|superClass|gMetaClass)E$",nm,re.I):
  excluded_base_data.append((va,nm))
  continue
 if re.search(r"init|callback|action|enqueue|dequeue|complete|submit|packet",nm,re.I):
  methods[va]=("IOSkywalkPacketQueue",nm,"base-queue-method")
  base_hits.append((va,nm))
discovered += ["BASE_QUEUE_METHOD address=0x%x symbol=%s"%(va,nm) for va,nm in base_hits]
discovered += ["BASE_QUEUE_NONCODE_METADATA_EXCLUDED address=0x%x symbol=%s"%(va,nm)
               for va,nm in excluded_base_data]

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
(out/"apple-queue-lifecycle-disassembly.txt").write_text("\n".join(disasm_lines)+"\n")
(out/"symbol-discovery.txt").write_text("\n".join(discovered)+"\n")

# Evidence-level callback ABI crosswalk. Distinguish queue packet callbacks (count return)
# from IO80211SkywalkInterface::Action callbacks (IOReturn audited in Stage64).
stage65=(pathlib.Path(sys.argv[5])/"predecessor-evidence"/"apple-queue-helper-disassembly.txt").read_text()
contract=[
 "STAGE66_QUEUE_CALLBACK_REGISTRATION_CONTRACT",
 "PREDECESSOR=Stage65 V1; Stage64 separately pins Action callbacks as IOReturn",
 "BASE_INIT_DISPATCH="+"\n".join(base_vtable_lines),
 "TX_COMPLETION_CALLBACK_CALLSITE=Stage65 enqueueAndCompletePackets",
 "TX_COMPLETION_CALLBACK_FIELD=object offset +0x20 (indirect call qword ptr [rbx+0x20])",
 "TX_COMPLETION_CALLBACK_CONTEXT=object offset +0x18 is passed as first callback argument",
 "TX_COMPLETION_CALLBACK_PACKET_ARRAY=object offset +0xe0 is passed as third callback argument",
 "TX_COMPLETION_CALLBACK_LIMIT=queue capacity at +0xac minus one is passed as fourth callback argument",
 "TX_COMPLETION_CALLBACK_RETURN=EAX is tested and, when nonzero, passed as count to completePackets",
 "RX_COMPLETION_CALLBACK_CALLSITE=Stage65 gatedEnqueue",
 "RX_COMPLETION_CALLBACK_FIELD=loaded from object offset +0x20 then invoked indirectly",
 "RX_COMPLETION_CALLBACK_CONTEXT=object offset +0x18 passed as first callback argument",
 "RX_COMPLETION_CALLBACK_PACKET_ARRAY=packet-table entry pointer passed as third callback argument",
 "RX_COMPLETION_CALLBACK_RETURN=EAX contributes to accepted packet count; nonzero count is passed to enqueuePacketsForKPipe or enqueuePacketsForNetworking",
 "IMPORTANT=these packet-array callback returns are not the IOReturn Action return audited in Stage64"]
# Include exact callback call windows captured from Stage65, not reconstructed pseudocode.
for label,pat in [
 ("TX_COMPLETION_CALLBACK_ASSEMBLY",r"kind=named-helper symbol=.*enqueueAndCompletePackets"),
 ("RX_COMPLETION_CALLBACK_ASSEMBLY",r"kind=named-helper symbol=.*gatedEnqueue")]:
 blocks=re.split(r"(?=^===== METHOD )",stage65,flags=re.M)
 found=next((b for b in blocks if re.search(pat,b,re.M)),None)
 contract.append(label+"_BEGIN")
 if found:
  ls=found.splitlines()
  selected=[x for x in ls if re.search(r"mov\s+.*\[(rbx|rdi) \+ 0x(18|20|e0|ac|e8|78)\]|call\s+(qword ptr \[rbx \+ 0x20\]|r12)|test\s+eax|completePackets|enqueuePacketsFor",x)]
  contract.extend(selected)
 else: contract.append("NOT_FOUND")
 contract.append(label+"_END")
contract += [
 "CLASSIFICATION=Stage64 Action callback function pointer signature returns IOReturn; Stage66 queue packet callbacks return a packet count consumed as such by Apple helpers",
 "OWNERSHIP=actual completion/recycling ownership still requires packet-table and completePackets/refill/enqueue method analysis; no implementation authorization"]
(out/"callback-registration-contract.txt").write_text("\n".join(contract)+"\n")

# Direct call and indirect dispatch inventory for all newly resolved methods.
edges=["STAGE66_QUEUE_LIFECYCLE_CALL_EDGE_INVENTORY"]
for block in re.split(r"(?=^===== METHOD )","\n".join(disasm_lines),flags=re.M):
 header=next((x for x in block.splitlines() if x.startswith("===== METHOD ")),None)
 if not header: continue
 calls=[x.strip() for x in block.splitlines() if re.search(r"\bcall\b|\bjmp\s+qword ptr\b",x)]
 edges.append("\n"+header); edges += calls or ["NO_CALL_EDGES_CAPTURED"]
(out/"dispatch-edge-inventory.txt").write_text("\n".join(edges)+"\n")

helper_expect=[
 ("IOSkywalkTxSubmissionQueue",r"packetSubmissionForKPipe"),
 ("IOSkywalkTxSubmissionQueue",r"packetSubmission"),
 ("IOSkywalkTxSubmissionQueue",r"refillTxRingForKPipe"),
 ("IOSkywalkTxSubmissionQueue",r"legacyDequeue"),
 ("IOSkywalkTxCompletionQueue",r"enqueueAndCompletePackets"),
 ("IOSkywalkTxCompletionQueue",r"completePackets"),
 ("IOSkywalkRxSubmissionQueue",r"gatedDequeue"),
 ("IOSkywalkRxSubmissionQueue",r"refillRxRing"),
 ("IOSkywalkRxSubmissionQueue",r"legacyDequeue"),
 ("IOSkywalkRxSubmissionQueue",r"listDequeue"),
 ("IOSkywalkRxCompletionQueue",r"gatedEnqueue"),
 ("IOSkywalkRxCompletionQueue",r"enqueuePacketsForNetworking")]
missing=[]
for cls,pat in helper_expect:
 if not any(c==cls and re.search(pat,n,re.I) for c,n,k in methods.values()):
  missing.append(cls+"_"+pat)
if missing: issues += ["EXPECTED_METHOD_MISSING_"+x for x in missing]
base_ok=any(x.startswith("SLOT offset=0x240") and "target=0x" in x and "owner=UNKNOWN" not in x for x in base_vtable_lines)
all_ok=len(resolved)>0 and len(status)==len(resolved) and all("result=PASS" in x for x in status)
setup_count=sum(1 for _,_,k,_,_,_ in resolved if k=="queue-init")
life_count=sum(1 for _,_,k,_,_,_ in resolved if k=="packet-lifecycle")
summary=[
 "STAGE66_APPLE_QUEUE_CALLBACK_REGISTRATION_AND_PACKET_LIFECYCLE_AUDIT",
 "TARGET=15.8.1/24H32/x86_64",
 "STAGE65_PREDECESSOR=9/9_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "QUEUE_INIT_METHODS_RESOLVED=%d/4"%setup_count,
 "PACKET_QUEUE_BASE_INIT_VTABLE_TARGET="+("RESOLVED" if base_ok else "UNRESOLVED"),
 "PACKET_LIFECYCLE_METHODS_RESOLVED=%d"%life_count,
 "APPLE_METHODS_RESOLVED=%d"%len(resolved),
 "APPLE_METHODS_DISASSEMBLED_PASS=%d"%sum("result=PASS" in x for x in status),
 "PACKET_CALLBACK_RETURN_CLASSIFICATION=COUNT_RETURN_DISTINCT_FROM_IOReturn_ACTION",
 "MISSING_EXPECTED_METHODS="+(",".join(missing) if missing else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN",
 "KEXT_LOAD=NOT_RUN","OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "RESULT="+("PASS" if source_ok and setup_count==4 and base_ok and all_ok and not missing and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 66 APPLE QUEUE CALLBACK REGISTRATION / PACKET LIFECYCLE AUDIT ==========",
 "VERSION="+ "STAGE66_V1_20261102","RUN="+out.name,"TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage65 V1 run-20261102-164949-2151a8b9670a",
 "PURPOSE=trace four initWithPool paths through IOSkywalkPacketQueue base init and inspect the concrete TX/RX packet state-transition helpers called by Apple queue callbacks",
 "SCOPE=read-only kernel collection vtable resolution, method disassembly and callback callsite crosswalk",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "CAUTION=queue packet callback count-return ABI is distinct from the IOReturn Action ABI; packet ownership conclusions remain limited to disassembled call paths",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 66 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not source_ok or setup_count!=4 or not base_ok or not all_ok or missing or issues:
 raise SystemExit("Stage66 callback/lifecycle audit requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=66"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=read-only Apple queue packet callback registration and lifecycle helper audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage65 V1 $STAGE65_RUN"
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
pathlib.Path(d).write_text(json.dumps({"message":"Add Stage66 read-only Apple queue callback lifecycle audit",
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
 if (( bytes <= 225280 )); then upload_one "$file" "Development/Logs/stage66/$RUN/$base"
 else
  split -b 220k "$file" "$file.part-"
  for part in "$file".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage66/$RUN/$(basename "$part")"; done
 fi
 echo "$base SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/symbol-discovery.txt "$OUT"/packet-queue-init-vtable-target.txt "$OUT"/callback-registration-contract.txt "$OUT"/method-status.txt "$OUT"/apple-queue-lifecycle-disassembly.txt "$OUT"/dispatch-edge-inventory.txt; do
 [[ -f "$f" ]] || fail "missing Stage66 artifact: $f"
 upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage66/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 66 APPLE QUEUE CALLBACK REGISTRATION / PACKET LIFECYCLE AUDIT ==========\n"
 "STAGE66_RUN: %s\n"%run+
 "STAGE66_VERSION: %s\n"%version+
 "STAGE66_SCOPE: four queue initWithPool callbacks, PacketQueue base init dispatch and TX/RX packet lifecycle methods\n"+
 "STAGE66_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — packet ownership/hardware completion implementation still requires a separate reviewed change\n"+
 "STAGE66_LOGS: Development/Logs/stage66/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
f,d,sha=sys.argv[1:]
pathlib.Path(d).write_text(json.dumps({"message":"Append Stage66 Apple queue callback lifecycle audit",
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
echo "STAGE66_VERSION=$VERSION"
echo "STAGE66_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE66_RUN=$RUN"
echo "STAGE66_LOCAL_OUTPUT=$OUT"
echo "STAGE66_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage66/$RUN"
echo "STAGE66_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE66_SOURCE_MODIFIED=NO"
echo "STAGE66_BUILD=NOT_RUN"
echo "STAGE66_INSTALL=NOT_RUN"
echo "STAGE66_LOAD=NOT_RUN"
