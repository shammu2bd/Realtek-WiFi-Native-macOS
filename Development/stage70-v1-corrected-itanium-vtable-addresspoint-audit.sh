#!/bin/bash
# Stage 70 V1 — Correct Itanium vtable address-point indexing for Stages 65–69.
# VERSION_MARKER: STAGE70_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE70_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage70/$RUN"
PREV="$OUT/predecessor-evidence"; TOOLS="$OUT/tools"; CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
CONSOLE_LOG="$OUT/console-output.log"; UPLOAD_ERROR="$OUT/upload-error.txt"
LAST_ERROR_LINE=unknown; LAST_ERROR_COMMAND=unknown
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage70/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=70"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; echo "CONSOLE_TAIL_BEGIN"
  tail -n 300 "$CONSOLE_LOG"; echo "CONSOLE_TAIL_END"
  find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 echo "STAGE70_FAILED=YES"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage70 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json" && echo "STAGE70_FAILURE_REPORT_GITHUB=$rp"
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=("\n========== STAGE 70 FAILURE REPORT ==========\nSTAGE70_FAILURE_RUN: %s\nSTAGE70_VERSION: %s\nSTAGE70_EXIT_CODE: %s\nSTAGE70_FAILED_LINE: %s\nSTAGE70_FAILED_COMMAND: %s\nSTAGE70_FAILURE_REPORT: %s\nSTAGE70_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage70 failure to output.log","sha":obj["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json" && echo "STAGE70_FAILURE_OUTPUT_LOG=UPDATED" || echo "STAGE70_FAILURE_OUTPUT_LOG=FAILED"
  fi
 else echo "STAGE70_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split tee find date tail; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == 15.8.1 && "$BUILD" == 24H32 && "$ARCH" == x86_64 ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
[[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found"
export LLVM_OBJDUMP="$OBJDUMP"

blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ local f="$1" want="$2" got; got="$(blob_sha "$f")"; [[ "$got" == "$want" ]] || fail "pin mismatch: $(basename "$f") expected=$want got=$got"; echo "PIN_PASS=$(basename "$f") SHA=$got"; }

# Stage60 already proved KC.vtable() starts at _ZTV, while the primary object vptr is _ZTV+0x10.
curl -fsSLo "$PREV/stage60-addresspoint-proof.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage60/run-20261102-150246-056583bdc528/vtable-prefix-addresspoint.txt"
pin "$PREV/stage60-addresspoint-proof.txt" 504840c41e4431c3ec909d7fc3bb181fdcbe89bc
grep -q '^ITANIUM_PRIMARY_ADDRESS_POINT=_ZTV+0x10' "$PREV/stage60-addresspoint-proof.txt" || fail "Stage60 address-point precedent missing"

for stage_num in 65 66 67 68 69; do
 case "$stage_num" in
  65) sr="run-20261102-164949-2151a8b9670a"; af="tx-submission-vtable-targets.txt"; ts="350ffc8921a4433d33b16248e887e10383fac90b"; ss="bbd6c2bfc05b2e4d5c2ac5485521275d0a1ca7d3" ;;
  66) sr="run-20261102-170400-52c2a2c1997c"; af="packet-queue-init-vtable-target.txt"; ts="83a3c279b5ac3f3532e64eaf4a1ea9563345ef90"; ss="7ed3e39af4d51a33202f30e0a80221d6d3f1b8bd" ;;
  67) sr="run-20261102-171710-99c47690d787"; af="packet-pool-vtable-targets.txt"; ts="0417c74bc12362b278fd653374dcaab1a395d307"; ss="7b6a5f3cd7a9b4021a6e9bc1eb0caca741d8b28e" ;;
  68) sr="run-20261102-172350-25eb343ad74b"; af="packet-buffer-vtable-targets.txt"; ts="7ef9d29469361f07ba04754eb0c549591eebae7f"; ss="77e89b49a98da73aff8bf1d3e331962e6f112a64" ;;
  69) sr="run-20261102-172739-c3f4b42353af"; af="packet-buffer-lifecycle-vtable-targets.txt"; ts="299f0e51a53b1a554223cf5f1e1c221b649c87d2"; ss="4e96e22ef869d4321aff93e13d3e0246b7b8d503" ;;
 esac
 d="Development/Logs/stage$stage_num/$sr"
 curl -fsSLo "$PREV/stage$stage_num-targets.txt" "https://raw.githubusercontent.com/$REPO/main/$d/$af"
 curl -fsSLo "$PREV/stage$stage_num-summary.txt" "https://raw.githubusercontent.com/$REPO/main/$d/audit-summary.txt"
 pin "$PREV/stage$stage_num-targets.txt" "$ts"
 pin "$PREV/stage$stage_num-summary.txt" "$ss"
 grep -q '^RESULT=PASS$' "$PREV/stage$stage_num-summary.txt" || fail "Stage$stage_num prior summary not PASS"
done

curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" <<'PY'
import hashlib,pathlib,sys
r=pathlib.Path(sys.argv[1]); e={"kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589","disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"}
for n,w in e.items():
 b=(r/n).read_bytes(); g=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 print("PARSER_PIN_%s=%s"%(n,"PASS" if g==w else "FAIL"))
 if g!=w: raise SystemExit("Pinned parser mismatch: "+n)
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1]); boot=sys.argv[2]; cache=pathlib.Path(sys.argv[3]); obj=sys.argv[4]; out=pathlib.Path(sys.argv[5])
sys.path.insert(0,str(out/"tools")); from kcfile import KC
os.environ["LLVM_OBJDUMP"]=obj
def addr(x):
 if isinstance(x,int): return x
 s=str(x).strip()
 if s.lower().startswith("0x"): return int(s,16)
 if re.fullmatch(r"[0-9a-fA-F]+",s): return int(s,16)
 return int(s,0)
fps={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"}
fpl=[]; source_ok=True
for rel,want in fps.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"; ok=got==want; source_ok &= ok
 fpl += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if ok else "MISMATCH")]
fpl.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(fpl)+"\n")
if not source_ok: raise SystemExit("Stage43 source baseline changed")

# Every offset below comes from the pinned callsite target tables in Stages65–69.
# Because KC.vtable() starts at _ZTV+0, correct index is (object-vptr offset + 0x10)/8.
specs=[
 ("STAGE65","IOSkywalkTxSubmissionQueue",0x1d8,"TX synchronize dispatch"),
 ("STAGE65","IOSkywalkTxSubmissionQueue",0x1e0,"TX packetSubmission dispatch"),
 ("STAGE66","IOSkywalkPacketQueue",0x240,"PacketQueue initWithPool dispatch"),
 ("STAGE67","IOSkywalkPacket",0x140,"packet completion/source-queue dispatch"),
 ("STAGE67","IOSkywalkPacket",0x198,"packet completion dispatch"),
 ("STAGE67","IOSkywalkPacket",0x1e0,"RX networking packet dispatch"),
 ("STAGE67","IOSkywalkPacketBufferPool",0x148,"pool packet-array/count dispatch"),
 ("STAGE68","IOSkywalkPacketBuffer",0x140,"packet preparation buffer dispatch"),
 ("STAGE68","IOSkywalkPacket",0x190,"packet preparation tail dispatch"),
 ("STAGE69","IOSkywalkPacketBuffer",0x120,"prepareWithMemorySegment wrapper dispatch"),
 ("STAGE69","IOSkywalkPacketBuffer",0x128,"completeWithMemorySegment wrapper dispatch"),
 ("STAGE69","IOSkywalkPacketBuffer",0x148,"pool buffer deallocation dispatch")]
kc=KC(boot); prefix=["STAGE70_ITANIUM_VTABLE_PREFIX_EVIDENCE","KC.vtable() enumerates _ZTV from index 0","PRIMARY_OBJECT_VPTR_ADDRESS_POINT=_ZTV+0x10"]
matrix=["STAGE70_VTABLE_CORRECTED_TARGET_MATRIX"]; targets=[]; issues=[]; seen_prefix=set()
for stage,cls,off,desc in specs:
 vt=kc.vtable(cls)
 if not vt: issues.append("VTABLE_NOT_FOUND_"+cls); matrix.append("UNRESOLVED stage=%s class=%s offset=0x%x"%(stage,cls,off)); continue
 oi=off//8; ci=(off+0x10)//8
 if len(vt)<=ci: issues.append("VTABLE_TOO_SHORT_"+cls); matrix.append("UNRESOLVED stage=%s class=%s offset=0x%x corrected_index=%d"%(stage,cls,off,ci)); continue
 for pi in (0,1):
  if (cls,pi) not in seen_prefix:
   seen_prefix.add((cls,pi)); _,rawp,tp,nmp=vt[pi]
   prefix.append("PREFIX class=%s index=%d raw=0x%x target=0x%x symbol=%s"%(cls,pi,rawp,tp,nmp))
 old=vt[oi] if len(vt)>oi else (oi,0,0,"OUT_OF_RANGE")
 _,raw,tgt,nm=vt[ci]; tgt=addr(tgt); owner=kc.owner(tgt) or kc.sym_owner.get(tgt) or "UNKNOWN"; sym_owner=kc.sym_owner.get(tgt) or "UNKNOWN"
 ok=bool(tgt) and owner!="UNKNOWN" and owner==sym_owner
 matrix.append("TARGET stage=%s class=%s object_vptr_offset=0x%x old_index=%d old_symbol_offset=0x%x old_target=0x%x old_symbol=%s corrected_index=%d corrected_symbol_offset=0x%x corrected_object_vptr_offset=0x%x target=0x%x owner=%s symbol_owner=%s symbol=%s result=%s"%(stage,cls,off,oi,oi*8,old[2],old[3],ci,ci*8,ci*8-0x10,tgt,owner,sym_owner,nm,"PASS" if ok else "REVIEW_REQUIRED"))
 if ok: targets.append((stage,cls,off,ci,tgt,owner,nm))
 else: issues.append("TARGET_OWNER_UNRESOLVED_"+stage+"_"+cls+"_0x%x"%off)
prefix.append("VIRTUAL_TARGETS_AUDITED=%d"%len(specs))
(out/"vtable-prefix-addresspoint-audit.txt").write_text("\n".join(prefix)+"\n")
(out/"vtable-target-correction-matrix.txt").write_text("\n".join(matrix)+"\n")

unique={}
for t in targets: unique.setdefault(t[4],(t[1],t[6],t[5]))
carved={}
for owner in sorted({v[2] for v in unique.values()}):
 p=cache/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho"); kc.carve(owner,str(p)); carved[owner]=p
dis=[]; method=[]
for va,(cls,nm,owner) in sorted(unique.items()):
 end=addr(kc.next_sym(va)) if kc.next_sym(va) else va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 r=subprocess.run([obj,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],capture_output=True,text=True)
 count=sum(1 for line in r.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line)); ok=r.returncode==0 and count>0
 method.append("METHOD address=0x%x class=%s symbol=%s owner=%s instructions=%d result=%s"%(va,cls,nm,owner,count,"PASS" if ok else "REVIEW_REQUIRED"))
 if not ok: issues.append("DISASSEMBLY_FAILED_0x%x"%va)
 dis += ["\n===== TARGET class=%s symbol=%s address=0x%x owner=%s ====="%(cls,nm,va,owner),"OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(r.returncode,count),"DISASSEMBLY_BEGIN",r.stdout[:70000].rstrip(),"DISASSEMBLY_END"]
(out/"method-status.txt").write_text("\n".join(method)+"\n")
(out/"corrected-vtable-target-disassembly.txt").write_text("\n".join(dis)+"\n")
all_dis=bool(method) and all("result=PASS" in x for x in method)
summary=[
 "STAGE70_CORRECTED_ITANIUM_VTABLE_ADDRESS_POINT_AUDIT","TARGET=15.8.1/24H32/x86_64",
 "STAGE60_ADDRESSPOINT_PRECEDENT=PIN_PASS","STAGE65_TO_69_TARGET_EVIDENCE=10/10_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "PRIMARY_OBJECT_VPTR_PREFIX_BYTES=0x10",
 "CORRECTED_VTABLE_TARGETS_RESOLVED=%d/%d"%(len(targets),len(specs)),
 "UNIQUE_CORRECTED_TARGETS_DISASSEMBLED=%d"%len(unique),
 "CORRECTED_TARGET_DISASSEMBLY_PASS=%d"%sum("result=PASS" in x for x in method),
 "STAGE65_TO_69_OLD_SLOT_LABELS=SUPERSEDED_UNTIL_RECONCILED",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS" if source_ok and len(targets)==len(specs) and all_dis and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=["========== STAGE 70 CORRECTED ITANIUM VTABLE ADDRESS-POINT AUDIT ==========",
 "VERSION=STAGE70_V1_20261102","RUN="+out.name,"TARGET=15.8.1/24H32/x86_64",
 "PREDECESSORS=Stages65–69 target tables pinned; Stage60 address-point proof pinned",
 "PURPOSE=recalculate every Stage65–69 virtual target using complete _ZTV layout and the +0x10 primary object-vptr address point",
 "SCOPE=read-only vtable target correction and corrected target disassembly","SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "INTERPRETATION=corrected slot targets are raw ABI evidence; semantics require review of target bodies and callsite arguments",
 "CAUTION=Stage65–69 vtable target labels are superseded until reconciled against this corrected address-point audit",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 70 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not source_ok or len(targets)!=len(specs) or not all_dis or issues: raise SystemExit("Stage70 corrected vtable audit requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=70"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=corrected Itanium vtable address-point audit for Stage65–69 virtual call offsets"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stages65-69 plus pinned Stage60 address-point proof"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"; PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage70 corrected vtable audit","content":base64.b64encode(p.read_bytes()).decode()}))
PY
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
 got="$(gh api "repos/$REPO/contents/$path" -q .sha)"
 [[ "$put" == "$expected" && "$got" == "$expected" ]] || { echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1; }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}
upload_artifact(){
 local f="$1" base bytes
 base="$(basename "$f")"; bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then upload_one "$f" "Development/Logs/stage70/$RUN/$base"
 else split -b 220k "$f" "$f.part-"; for part in "$f".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage70/$RUN/$(basename "$part")"; done; fi
 echo "$base SHA256=$(shasum -a 256 "$f" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/vtable-prefix-addresspoint-audit.txt "$OUT"/vtable-target-correction-matrix.txt "$OUT"/corrected-vtable-target-disassembly.txt "$OUT"/method-status.txt; do
 [[ -f "$f" ]] || fail "missing Stage70 artifact: $f"; upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage70/$RUN/manifest.txt"

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote)); old=base64.b64decode(obj["content"])
entry=("\n========== STAGE 70 CORRECTED ITANIUM VTABLE ADDRESS-POINT AUDIT ==========\n"
 "STAGE70_RUN: %s\n"%run+
 "STAGE70_VERSION: %s\n"%version+
 "STAGE70_SCOPE: corrected all Stage65–69 virtual call target indices using Itanium _ZTV+0x10 primary address-point rule\n"+
 "STAGE70_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — ABI target correction only; native registration and TX/RX ownership implementation remain open\n"+
 "STAGE70_LOGS: Development/Logs/stage70/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(obj["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage70 corrected vtable audit","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE70_VERSION=$VERSION"
echo "STAGE70_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE70_RUN=$RUN"
echo "STAGE70_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE70_LOCAL_OUTPUT=$OUT"
echo "STAGE70_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage70/$RUN"
echo "STAGE70_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE70_SOURCE_MODIFIED=NO"
echo "STAGE70_BUILD=NOT_RUN"
echo "STAGE70_INSTALL=NOT_RUN"
echo "STAGE70_LOAD=NOT_RUN"
