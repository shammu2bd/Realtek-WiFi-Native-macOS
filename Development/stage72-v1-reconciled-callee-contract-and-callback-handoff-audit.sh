#!/bin/bash
# Stage 72 V1 — Reconciled callee contract and native callback handoff audit.
# VERSION_MARKER: STAGE72_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE72_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
STAGE71_RUN="run-20261102-175229-49906f891bf4"
STAGE64_RUN="run-20261102-163320-6a2d28788a13"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage72/$RUN"
PREV="$OUT/predecessor-evidence"
mkdir -p "$OUT" "$PREV"
CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage72/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=72"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "========== CONSOLE TAIL =========="; tail -n 250 "$CONSOLE_LOG"
  echo "========== GENERATED FILES =========="; find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage72 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then echo "STAGE72_FAILURE_REPORT_GITHUB=$rp"; else echo "STAGE72_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 72 FAILURE REPORT ==========\nSTAGE72_FAILURE_RUN: %s\nSTAGE72_VERSION: %s\nSTAGE72_EXIT_CODE: %s\nSTAGE72_FAILED_LINE: %s\nSTAGE72_FAILED_COMMAND: %s\nSTAGE72_FAILURE_REPORT: %s\nSTAGE72_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage72 failure to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then echo "STAGE72_FAILURE_OUTPUT_LOG=UPDATED"; else echo "STAGE72_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE72_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE72_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname wc tr tee find date tail; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ local f="$1" want="$2" got; got="$(blob_sha "$f")"; [[ "$got" == "$want" ]] || fail "evidence pin mismatch: $(basename "$f") expected=$want got=$got"; echo "PIN_PASS=$(basename "$f") SHA=$got"; }

RAW71="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage71/$STAGE71_RUN"
for name in audit-summary.txt callsite-pointer-provenance.txt vtable-target-reconciliation-matrix.txt method-status.txt reconciled-vtable-target-disassembly.txt source-fingerprint.txt report.txt manifest.txt; do
 curl -fsSLo "$PREV/stage71-$name" "$RAW71/$name"
done
pin "$PREV/stage71-audit-summary.txt" b432a38027b3fee40ea72accd6949f32927de9ed
pin "$PREV/stage71-callsite-pointer-provenance.txt" 396326ffcb49f546d7c9cc034567cdbaa4c87905
pin "$PREV/stage71-vtable-target-reconciliation-matrix.txt" 4bcaf03e2d63f962be8e30e1225474c7e63a3dab
pin "$PREV/stage71-method-status.txt" d1cb009435180167ff4bf46445fad045c203652c
pin "$PREV/stage71-reconciled-vtable-target-disassembly.txt" 90292b285e0bf89504cfe76ed3e2d88b2efa0f47
pin "$PREV/stage71-source-fingerprint.txt" 67bfe72603cd4316bd9a9107de5c97e1c37f625c
pin "$PREV/stage71-report.txt" 36ca6cd08b0495382a22e5da796a65a824555d65
pin "$PREV/stage71-manifest.txt" ac7bf27247975bff014b41c33f3c7bd206f0103c
grep -q '^RESULT=PASS$' "$PREV/stage71-audit-summary.txt" || fail "Stage71 V2 did not PASS"
grep -q '^VIRTUAL_TARGETS_RECONCILED=12/12$' "$PREV/stage71-audit-summary.txt" || fail "Stage71 target count mismatch"

RAW64="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage64/$STAGE64_RUN"
curl -fsSLo "$PREV/stage64-source-callback-bodies.txt" "$RAW64/source-callback-bodies.txt"
pin "$PREV/stage64-source-callback-bodies.txt" da005f489a8a7548b08d44ccaf33780305f43b91
curl -fsSLo "$PREV/stage64-callback-behavior-matrix.txt" "$RAW64/callback-behavior-matrix.txt"
pin "$PREV/stage64-callback-behavior-matrix.txt" 9c4b083399aed46dbc027fb4457f13c61c890b6b
curl -fsSLo "$PREV/stage64-callback-ownership-findings.txt" "$RAW64/callback-ownership-findings.txt"
pin "$PREV/stage64-callback-ownership-findings.txt" 6b652dde67939a19749bef211284698eb7237be8

python3 - "$SRC" "$PREV" "$OUT" <<'PY'
import hashlib,pathlib,re,sys
src=pathlib.Path(sys.argv[1]); prev=pathlib.Path(sys.argv[2]); out=pathlib.Path(sys.argv[3])
def read(n): return (prev/n).read_text(errors="replace")
summary=read("stage71-audit-summary.txt")
prov=read("stage71-callsite-pointer-provenance.txt")
matrix=read("stage71-vtable-target-reconciliation-matrix.txt")
methods=read("stage71-method-status.txt")
dis=read("stage71-reconciled-vtable-target-disassembly.txt")
fp=read("stage71-source-fingerprint.txt")
cb=read("stage64-source-callback-bodies.txt")
cbm=read("stage64-callback-behavior-matrix.txt")
ownership=read("stage64-callback-ownership-findings.txt")
issues=[]
for rel,want in {
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"}.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
 if got!=want: issues.append("SOURCE_FINGERPRINT_MISMATCH:"+rel)
if "RESULT=PASS" not in summary or "VIRTUAL_TARGETS_RECONCILED=12/12" not in summary: issues.append("STAGE71_PREDECESSOR_NOT_PASS")
expected=[
 ("IOSkywalkTxSubmissionQueue","0x1d8","61","packetSubmissionEb"),
 ("IOSkywalkTxSubmissionQueue","0x1e0","62","sendNotificationEj"),
 ("IOSkywalkPacketQueue","0x240","72","initWithPool"),
 ("IOSkywalkPacket","0x140","42","getDataLength"),
 ("IOSkywalkPacket","0x198","53","completeWithQueue"),
 ("IOSkywalkPacket","0x1e0","62","disposePacket"),
 ("IOSkywalkPacketBufferPool","0x148","43","deallocatePackets"),
 ("IOSkywalkPacketBuffer","0x140","42","prepareWithQueue"),
 ("IOSkywalkPacket","0x190","52","prepare"),
 ("IOSkywalkPacketBuffer","0x120","38","prepareEj"),
 ("IOSkywalkPacketBuffer","0x128","39","completeEj"),
 ("IOSkywalkPacketBuffer","0x148","43","completeWithQueue")]
for cls,off,idx,sym in expected:
 pat=r"TARGET stage=.*class="+re.escape(cls)+r" offset="+re.escape(off)+r" mode=.*reconciled_index="+idx+r".*symbol=.*"+re.escape(sym)+r".*result=PASS"
 if not re.search(pat,matrix): issues.append("MATRIX_TARGET_MISMATCH:"+cls+":"+off+":"+sym)
if len(re.findall(r"^PROVENANCE .*result=PASS$",prov,re.M))!=12: issues.append("PROVENANCE_PASS_COUNT_NOT_12")
if len(re.findall(r"^METHOD .*instructions=[1-9][0-9]* result=PASS$",methods,re.M))!=12: issues.append("METHOD_DISASSEMBLY_PASS_COUNT_NOT_12")
blocks=re.split(r"(?=^===== RECONCILED TARGET )",dis,flags=re.M)
parsed={}
for block in blocks:
 m=re.search(r"^===== RECONCILED TARGET class=(\S+) symbol=(\S+) address=(\S+) owner=(\S+) =====",block,re.M)
 if m: parsed[m.group(2)]=block
if len(parsed)!=12: issues.append("RECONCILED_DISASSEMBLY_BLOCK_COUNT_NOT_12")
contracts=[
 ("getDataLength","__ZNK15IOSkywalkPacket13getDataLengthEv",[r"call\s+.*__ZNK21IOSkywalkPacketBuffer13getDataLengthEv",r"add\s+r14d,\s*eax",r"mov\s+eax,\s*r14d"]),
 ("packet prepare","__ZN15IOSkywalkPacket7prepareEP20IOSkywalkPacketQueueyj",[r"test\s+byte ptr \[rdi \+ 0x58\], 0x2",r"getDirectionEv",r"\[rax \+ 0x188\]",r"jmp\s+rax"]),
 ("packet completeWithQueue","__ZN15IOSkywalkPacket17completeWithQueueEP20IOSkywalkPacketQueuejj",[r"\[rax \+ 0x148\]",r"\[rax \+ 0x220\]",r"and\s+byte ptr \[r15 \+ 0x58\], -0x3",r"\[rax \+ 0x1a0\]"]),
 ("packet disposePacket","__ZN15IOSkywalkPacket13disposePacketEv",[r"disposePacketBufferEv",r"mov\s+qword ptr \[rbx \+ 0x28\], rax",r"mov\s+qword ptr \[rbx \+ 0x38\], rax",r"mov\s+dword ptr \[rbx \+ 0x64\], eax"]),
 ("buffer prepare stub","__ZN21IOSkywalkPacketBuffer7prepareEj",[r"xor\s+eax, eax",r"ret"]),
 ("buffer complete stub","__ZN21IOSkywalkPacketBuffer8completeEj",[r"xor\s+eax, eax",r"ret"]),
 ("buffer prepareWithQueue","__ZN21IOSkywalkPacketBuffer16prepareWithQueueEP20IOSkywalkPacketQueuejj",[r"getMemoryDescriptorEv",r"\[r8 \+ 0x128\]",r"mov\s+qword ptr \[rbx \+ 0x48\], r14",r"or\s+byte ptr \[rbx \+ 0x78\], 0x2",r"xor\s+eax, eax"]),
 ("buffer completeWithQueue","__ZN21IOSkywalkPacketBuffer17completeWithQueueEP20IOSkywalkPacketQueuejj",[r"finalizeEv",r"\[rax \+ 0x228\]",r"and\s+byte ptr \[r14 \+ 0x78\], -0x3",r"xor\s+eax, eax"]),
 ("queue initWithPool","__ZN20IOSkywalkPacketQueue12initWithPoolEP25IOSkywalkPacketBufferPooljjjjP8OSObjectPFvS3_zEPv",[r"\[rax \+ 0x128\]",r"\[rax \+ 0x20\]",r"mov\s+byte ptr \[rbx \+ 0x28\], 0x0",r"mov\s+al, 0x1"]),
 ("pool deallocatePackets","__ZN25IOSkywalkPacketBufferPool17deallocatePacketsEPP15IOSkywalkPacketj",[r"completePreparedPacket",r"\[rax \+ 0x1e0\]",r"cmp\s+r13, r15"]),
 ("tx sendNotification","__ZN26IOSkywalkTxSubmissionQueue16sendNotificationEj",[r"\[rdi \+ 0xe0\]",r"0xe00002d8",r"mov\s+eax, ebx"]),
 ("tx packetSubmission","__ZN26IOSkywalkTxSubmissionQueue16packetSubmissionEb",[r"refillTxRingForNetworking",r"getPacketListForNetworking",r"queryByteFreeSpaceEv",r"legacyDequeueEv",r"mov\s+eax, r15d"])]
contract_rows=[]
for label,sym,patterns in contracts:
 b=parsed.get(sym,"")
 missing=[p for p in patterns if not re.search(p,b,re.I)]
 ok=bool(b) and not missing
 contract_rows.append("CONTRACT="+label+"|SYMBOL="+sym+"|CHECKS="+str(len(patterns))+"|MISSING="+(",".join(missing) if missing else "NONE")+"|RESULT="+("PASS" if ok else "REVIEW_REQUIRED"))
 if not ok: issues.append("CALLEE_CONTRACT_REVIEW:"+label)
# This is a deliberately fail-closed source handoff audit: present stubs remain stubs.
callback_specs=[
 ("txSubmissionAction",r"RTW88WCLResolveEthernetTxPacket",r"txAdapter\s*->\s*submitPacket|submitPacket\s*\("),
 ("txCompletionAction",None,r"drainCompletions\s*\("),
 ("rxSubmissionAction",None,r"enqueue|submitPacket|refill.*[Pp]acket"),
 ("rxCompletionAction",None,r"stagedRxFrame|enqueue|deliverPacket|receivePacket")]
handoff=[]
for name,required,forbidden in callback_specs:
 m=re.search(r"===== RTW88WCLSkywalkQueues::"+name+r" FOUND_COUNT=1 =====(.*?)(?=^===== |\Z)",cb,re.S|re.M)
 body=m.group(1) if m else ""
 has_required=(required is None or bool(re.search(required,body)))
 forbidden_hits=re.findall(forbidden,body,re.I) if body else []
 stub_ok=bool(body) and has_required and not forbidden_hits and "return static_cast<IOReturn>(0)" in body
 handoff.append("CALLBACK="+name+"|BODY_FOUND="+("YES" if body else "NO")+"|REQUIRED_EVIDENCE="+("PASS" if has_required else "MISSING")+"|FORBIDDEN_HANDOFF_REFERENCES="+str(len(forbidden_hits))+"|RESULT="+("STUB_CONFIRMED" if stub_ok else "REVIEW_REQUIRED"))
 if not stub_ok: issues.append("CALLBACK_STUB_CLASSIFICATION_REVIEW:"+name)
if "SDK_CALLBACK_RETURN_TYPE=IOReturn" not in cbm or "SDK_ZERO_STATUS=kIOReturnSuccess" not in cbm: issues.append("CALLBACK_RETURN_TYPE_EVIDENCE_MISSING")
if "TX_SUBMISSION=DESCRIPTOR_VALIDATION_ONLY_NO_TX_ADAPTER_HANDOFF" not in ownership: issues.append("TX_HANDOFF_FINDING_MISSING")
if "TX_COMPLETION=SUCCESS_STATUS_STUB_NO_COMPLETION_DRAIN" not in ownership: issues.append("TX_COMPLETION_FINDING_MISSING")
if "RX_SUBMISSION=NO_REFILL_OR_ENQUEUE_FOUND" not in ownership: issues.append("RX_SUBMISSION_FINDING_MISSING")
if "RX_COMPLETION=NO_PACKET_DELIVERY_FOUND" not in ownership: issues.append("RX_COMPLETION_FINDING_MISSING")
(out/"method-contract-matrix.txt").write_text("STAGE72_CALLEE_METHOD_CONTRACT_MATRIX\n" + "\n".join(contract_rows)+"\n")
(out/"callback-handoff-gap-matrix.txt").write_text("STAGE72_NATIVE_CALLBACK_HANDOFF_GAP_MATRIX\n" + "\n".join(handoff)+"\n")
summary=[
 "STAGE72_RECONCILED_CALLEE_CONTRACT_AND_CALLBACK_HANDOFF_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "STAGE71_PREDECESSOR=PASS_12_OF_12_TARGETS",
 "STAGE64_CALLBACK_EVIDENCE=PINS_PASS",
 "CALLEE_METHOD_CONTRACTS=%d/%d_PASS"%(sum("RESULT=PASS" in x for x in contract_rows),len(contract_rows)),
 "CALLBACK_STUBS_CONFIRMED=%d/%d"% (sum("RESULT=STUB_CONFIRMED" in x for x in handoff),len(handoff)),
 "CALLBACK_RETURN_TYPE=IOReturn_ZERO_IS_SUCCESS_STATUS_NOT_PACKET_COUNT",
 "TX_SUBMISSION=VALIDATION_ONLY_NO_ADAPTER_HANDOFF",
 "TX_COMPLETION=STUB_NO_COMPLETION_DRAIN",
 "RX_SUBMISSION=STUB_NO_REFILL_OR_ENQUEUE",
 "RX_COMPLETION=STUB_NO_PACKET_DELIVERY",
 "SOURCE_FINGERPRINTS="+("PASS" if not any(x.startswith("SOURCE_FINGERPRINT_MISMATCH") for x in issues) else "REVIEW_REQUIRED"),
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS" if not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 72 RECONCILED CALLEE CONTRACT / CALLBACK HANDOFF AUDIT ==========",
 "VERSION=STAGE72_V1_20261102","RUN="+out.name,"TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "PREDECESSOR=Stage71 V2 callsite-aware vtable reconciliation",
 "PURPOSE=verify the 12 reconciled Apple callee bodies and cross-check native RTL88WiFi callback bodies for actual TX/RX ownership handoff",
 "KEY_SAFETY_FINDING=an IOReturn success status is not a packet count and does not prove packet ownership transfer",
 "SCOPE=read-only callee behavior and callback handoff classification",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"","CONTRACT_MATRIX=method-contract-matrix.txt","HANDOFF_GAPS=callback-handoff-gap-matrix.txt",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 72 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if issues: raise SystemExit("Stage72 contract/handoff audit requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=72"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=reconciled Apple callee contracts plus native TX/RX callback handoff gap verification"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage71 V2 run $STAGE71_RUN and Stage64 run $STAGE64_RUN"
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
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage72 callee contract audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/method-contract-matrix.txt "$OUT"/callback-handoff-gap-matrix.txt; do
 [[ -f "$f" ]] || fail "missing Stage72 artifact: $f"
 upload_one "$f" "Development/Logs/stage72/$RUN/$(basename "$f")"
done
upload_one "$MAN" "Development/Logs/stage72/$RUN/manifest.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 72 CALLEE CONTRACT / CALLBACK HANDOFF AUDIT ==========\n"
 "STAGE72_RUN: %s\n"%run+
 "STAGE72_VERSION: %s\n"%version+
 "STAGE72_SCOPE: verify 12 reconciled Apple callee bodies and RTL88WiFi callback ownership handoff gaps\n"+
 "STAGE72_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — callback TX/RX ownership handoff and queue registration remain incomplete\n"+
 "STAGE72_LOGS: Development/Logs/stage72/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(o["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage72 callee contract audit","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE72_VERSION=$VERSION"
echo "STAGE72_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE72_RUN=$RUN"
echo "STAGE72_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE72_LOCAL_OUTPUT=$OUT"
echo "STAGE72_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage72/$RUN"
echo "STAGE72_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE72_SOURCE_MODIFIED=NO"
echo "STAGE72_BUILD=NOT_RUN"
echo "STAGE72_INSTALL=NOT_RUN"
echo "STAGE72_LOAD=NOT_RUN"
