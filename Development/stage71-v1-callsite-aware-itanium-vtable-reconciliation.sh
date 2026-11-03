#!/bin/bash
# Stage 71 V1 — Callsite-aware mixed static/object Itanium vtable reconciliation.
# VERSION_MARKER: STAGE71_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM or OpenCore changes.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE71_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
STAGE70_RUN="run-20261102-173755-eb9da21f3b1c"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage71/$RUN"
PREV="$OUT/predecessor-evidence"; TOOLS="$OUT/tools"; CACHE="$OUT/kc-cache"
mkdir -p "$OUT" "$PREV" "$TOOLS" "$CACHE"
UPLOAD_ERROR="$OUT/upload-error.txt"; CONSOLE_LOG="$OUT/console-output.log"
LAST_ERROR_LINE="unknown"; LAST_ERROR_COMMAND="unknown"
exec > >(tee -a "$CONSOLE_LOG") 2>&1
fail(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="fail: $*"; echo "ERROR: $*" >&2; exit 2; }
capture_error(){ LAST_ERROR_LINE="$LINENO"; LAST_ERROR_COMMAND="$BASH_COMMAND"; return 0; }
on_exit(){
 local rc="$1" rp="Development/Logs/stage71/$RUN/failure-report.txt"
 [[ "$rc" -ne 0 ]] || return 0
 trap - EXIT ERR; set +e
 {
  echo "STAGE=71"; echo "VERSION=$VERSION"; echo "RUN=$RUN"; echo "EXIT_CODE=$rc"
  echo "FAILED_LINE=$LAST_ERROR_LINE"; echo "FAILED_COMMAND=$LAST_ERROR_COMMAND"
  echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "INSTALL=NOT_RUN"; echo "LOAD=NOT_RUN"; echo "OPENCORE_MODIFIED=NO"
  echo "TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "========== CONSOLE TAIL =========="; tail -n 300 "$CONSOLE_LOG"
  echo "========== GENERATED FILES =========="; find "$OUT" -maxdepth 2 -type f -print
 } > "$OUT/failure-report.txt"
 echo "STAGE71_FAILED=YES"
 if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  python3 - "$OUT/failure-report.txt" "$OUT/failure-payload.json" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Upload Stage71 failure report","content":base64.b64encode(p.read_bytes()).decode()}))
PY
  if gh api --method PUT "repos/$REPO/contents/$rp" --input "$OUT/failure-payload.json" > "$OUT/failure-put.json"; then echo "STAGE71_FAILURE_REPORT_GITHUB=$rp"; else echo "STAGE71_FAILURE_REPORT_UPLOAD=FAILED"; fi
  if gh api "repos/$REPO/contents/Development/output.log" > "$OUT/failure-remote-output.json"; then
   python3 - "$OUT/failure-remote-output.json" "$OUT/failure-output-payload.json" "$RUN" "$VERSION" "$rc" "$rp" "$LAST_ERROR_LINE" "$LAST_ERROR_COMMAND" <<'PY'
import base64,json,pathlib,sys
remote,payload,run,ver,rc,rp,line,cmd=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 71 FAILURE REPORT ==========\nSTAGE71_FAILURE_RUN: %s\nSTAGE71_VERSION: %s\nSTAGE71_EXIT_CODE: %s\nSTAGE71_FAILED_LINE: %s\nSTAGE71_FAILED_COMMAND: %s\nSTAGE71_FAILURE_REPORT: %s\nSTAGE71_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n==============================================\n"%(run,ver,rc,line,cmd,rp)).encode()
pathlib.Path(payload).write_text(json.dumps({"message":"Append Stage71 failure to output.log","sha":o["sha"],"content":base64.b64encode(old.rstrip()+entry).decode()}))
PY
   if gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/failure-output-payload.json" > "$OUT/failure-output-put.json"; then echo "STAGE71_FAILURE_OUTPUT_LOG=UPDATED"; else echo "STAGE71_FAILURE_OUTPUT_LOG=FAILED"; fi
  else echo "STAGE71_FAILURE_OUTPUT_LOG=FETCH_FAILED"; fi
 else echo "STAGE71_FAILURE_REPORT_UPLOAD=SKIPPED_GITHUB_AUTH_UNAVAILABLE"; fi
 exit "$rc"
}
trap 'capture_error' ERR
trap 'on_exit $?' EXIT

for t in curl gh python3 shasum grep awk sw_vers uname xcrun wc tr split tee find date tail; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
[[ -f "$BOOTKC" ]] || fail "BootKernelExtensions.kc not found"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"
OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"; [[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump not found"
export LLVM_OBJDUMP="$OBJDUMP"
blob_sha(){ python3 - "$1" <<'PY'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY
}
pin(){ local f="$1" want="$2" got; got="$(blob_sha "$f")"; [[ "$got" == "$want" ]] || fail "evidence pin mismatch: $(basename "$f") expected=$want got=$got"; echo "PIN_PASS=$(basename "$f") SHA=$got"; }

RAW70="https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage70/$STAGE70_RUN"
for name in audit-summary.txt report.txt source-fingerprint.txt vtable-prefix-addresspoint-audit.txt vtable-target-correction-matrix.txt corrected-vtable-target-disassembly.txt method-status.txt manifest.txt; do curl -fsSLo "$PREV/stage70-$name" "$RAW70/$name"; done
pin "$PREV/stage70-audit-summary.txt" 33a4548ee8d53811951822052acb902918d5f837
pin "$PREV/stage70-report.txt" 7b346f5bbdb277f384be2e6537fca8dff1122dd7
pin "$PREV/stage70-source-fingerprint.txt" 67bfe72603cd4316bd9a9107de5c97e1c37f625c
pin "$PREV/stage70-vtable-prefix-addresspoint-audit.txt" 2712e518eeab275d39262716a35d86051de00ca5
pin "$PREV/stage70-vtable-target-correction-matrix.txt" ee5c389be4ccd6608b227397d2aa5913ebe5cc77
pin "$PREV/stage70-corrected-vtable-target-disassembly.txt" 1afd6370e37522262fe66159afddb5fdf4c7fdf7
pin "$PREV/stage70-method-status.txt" 56b1ed744863f3e822e9f73654c9bf0de6ac0476
pin "$PREV/stage70-manifest.txt" 9f4f32df314121e07a49aa6dc747c3c4153942cd
grep -q '^RESULT=PASS$' "$PREV/stage70-audit-summary.txt" || fail "Stage70 predecessor did not PASS"
grep -q '^STAGE43_SOURCE_CONTINUITY=PASS$' "$PREV/stage70-source-fingerprint.txt" || fail "Stage70 source continuity not PASS"
curl -fsSLo "$PREV/stage60-addresspoint-proof.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage60/run-20261102-150246-056583bdc528/vtable-prefix-addresspoint.txt"
pin "$PREV/stage60-addresspoint-proof.txt" 504840c41e4431c3ec909d7fc3bb181fdcbe89bc
grep -q '^ITANIUM_PRIMARY_ADDRESS_POINT=_ZTV+0x10' "$PREV/stage60-addresspoint-proof.txt" || fail "Stage60 address-point proof missing"

# Exact raw caller-disassembly evidence from each predecessor.
curl -fsSLo "$PREV/stage65-apple-queue-helper-disassembly.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage65/run-20261102-164949-2151a8b9670a/apple-queue-helper-disassembly.txt"
pin "$PREV/stage65-apple-queue-helper-disassembly.txt" f743677ff038f8211285cebefcc443da210174f2
curl -fsSLo "$PREV/stage66-apple-queue-lifecycle-disassembly.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage66/run-20261102-170400-52c2a2c1997c/apple-queue-lifecycle-disassembly.txt"
pin "$PREV/stage66-apple-queue-lifecycle-disassembly.txt" cb0474b85e2e9132adc93ccf16c15deb8b547bfe
curl -fsSLo "$PREV/stage67-apple-packet-ownership-disassembly.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage67/run-20261102-171710-99c47690d787/apple-packet-ownership-disassembly.txt"
pin "$PREV/stage67-apple-packet-ownership-disassembly.txt" 01d2af830640a8f512a4f5c487fe375a11bfb9e5
curl -fsSLo "$PREV/stage68-apple-packet-buffer-disassembly.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage68/run-20261102-172350-25eb343ad74b/apple-packet-buffer-disassembly.txt"
pin "$PREV/stage68-apple-packet-buffer-disassembly.txt" 0c5b16789f67b25cbbdfd7a2164ddd1cf0fc41bb
curl -fsSLo "$PREV/stage69-apple-packet-buffer-lifecycle-disassembly.txt" "https://raw.githubusercontent.com/$REPO/main/Development/Logs/stage69/run-20261102-172739-c3f4b42353af/apple-packet-buffer-lifecycle-disassembly.txt"
pin "$PREV/stage69-apple-packet-buffer-lifecycle-disassembly.txt" 26cf942c66f80c0433e7197219a992382267c5e5

curl -fsSLo "$TOOLS/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
curl -fsSLo "$TOOLS/disasm.py" "$UPSTREAM_RAW/disasm.py"
python3 - "$TOOLS" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
expected={"kcfile.py":"5d31e8a73e5cb175851e7407529456f223683589","disasm.py":"d7777456f4700bc9815e765aed2313093ac133e9"}
for n,want in expected.items():
 b=(root/n).read_bytes(); got=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
 print("PARSER_PIN_%s=%s"%(n,"MATCH" if got==want else "MISMATCH"))
 if got!=want: raise SystemExit("Pinned parser mismatch: "+n)
PY

python3 - "$SRC" "$BOOTKC" "$CACHE" "$OBJDUMP" "$OUT" "$PREV" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
src=pathlib.Path(sys.argv[1]); boot=sys.argv[2]; cache=pathlib.Path(sys.argv[3]); obj=sys.argv[4]; out=pathlib.Path(sys.argv[5]); prev=pathlib.Path(sys.argv[6])
sys.path.insert(0,str(out/"tools")); from kcfile import KC
os.environ["LLVM_OBJDUMP"]=obj
def addr(x):
 if isinstance(x,int): return x
 if x is None: return 0
 s=str(x).strip()
 if s.lower().startswith("0x"): return int(s,16)
 if re.fullmatch(r"[0-9a-fA-F]+",s): return int(s,16)
 return int(s,0)
fp_items={
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":"2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":"63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":"9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"}
fp=[]; source_ok=True
for rel,want in fp_items.items():
 p=src/rel; got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"; ok=got==want; source_ok &= ok
 fp += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,"RESULT="+("MATCH" if ok else "MISMATCH")]
fp.append("STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"))
(out/"source-fingerprint.txt").write_text("\n".join(fp)+"\n")
if not source_ok: raise SystemExit("Stage43 source baseline changed")

specs=[
 ("STAGE65","stage65-apple-queue-helper-disassembly.txt",0x1d8,"OBJECT_VPTR","call","IOSkywalkTxSubmissionQueue"),
 ("STAGE65","stage65-apple-queue-helper-disassembly.txt",0x1e0,"OBJECT_VPTR","call","IOSkywalkTxSubmissionQueue"),
 # This operand is the actual _ZTV symbol address in R11/R10, not an object's vptr.
 ("STAGE66","stage65-apple-queue-helper-disassembly.txt",0x240,"STATIC_ZTV_BASE","call","IOSkywalkPacketQueue"),
 ("STAGE67","stage67-apple-packet-ownership-disassembly.txt",0x140,"OBJECT_VPTR","call","IOSkywalkPacket"),
 ("STAGE67","stage67-apple-packet-ownership-disassembly.txt",0x198,"OBJECT_VPTR","call","IOSkywalkPacket"),
 ("STAGE67","stage67-apple-packet-ownership-disassembly.txt",0x1e0,"OBJECT_VPTR","call","IOSkywalkPacket"),
 ("STAGE67","stage67-apple-packet-ownership-disassembly.txt",0x148,"OBJECT_VPTR","call","IOSkywalkPacketBufferPool"),
 ("STAGE68","stage68-apple-packet-buffer-disassembly.txt",0x140,"OBJECT_VPTR","call","IOSkywalkPacketBuffer"),
 ("STAGE68","stage68-apple-packet-buffer-disassembly.txt",0x190,"OBJECT_VPTR","load","IOSkywalkPacket"),
 ("STAGE69","stage69-apple-packet-buffer-lifecycle-disassembly.txt",0x120,"OBJECT_VPTR","load","IOSkywalkPacketBuffer"),
 ("STAGE69","stage69-apple-packet-buffer-lifecycle-disassembly.txt",0x128,"OBJECT_VPTR","load","IOSkywalkPacketBuffer"),
 ("STAGE69","stage69-apple-packet-buffer-lifecycle-disassembly.txt",0x148,"OBJECT_VPTR","call","IOSkywalkPacketBuffer")]
kc=KC(boot); provenance=["STAGE71_CALLSITE_POINTER_PROVENANCE",
 "RULE=KC.vtable() begins at _ZTV; primary object vptr is _ZTV+0x10",
 "OBJECT_VPTR_INDEX=(object_vptr_offset+0x10)/8",
 "STATIC_ZTV_BASE_INDEX=(symbol_relative_offset)/8"]
matrix=["STAGE71_RECONCILED_VTABLE_TARGET_MATRIX"]; issues=[]; resolved=[]
for stage,file,off,mode,op,cls in specs:
 lines=(prev/file).read_text(errors="replace").splitlines()
 if op=="call": pat=re.compile(r"call\s+qword ptr \[([a-z0-9]+)\s*\+\s*0x%x\]"%off,re.I)
 else: pat=re.compile(r"mov\s+rax,\s*qword ptr \[rax\s*\+\s*0x%x\]"%off,re.I)
 hits=[i for i,x in enumerate(lines) if pat.search(x)]
 if not hits:
  issues.append("CALLSITE_NOT_FOUND_%s_0x%x"%(stage,off))
  provenance.append("PROVENANCE stage=%s class=%s offset=0x%x mode=%s count=0 result=FAIL"%(stage,cls,off,mode))
  continue
 mode_ok=True
 if mode=="STATIC_ZTV_BASE":
  for i in hits:
   reg=pat.search(lines[i]).group(1)
   before="\n".join(lines[max(0,i-16):i])
   if not re.search(r"lea\s+"+reg+r",.*<__ZTV20IOSkywalkPacketQueue>",before,re.I):
    mode_ok=False
  index=off//8
 else:
  for i in hits:
   before="\n".join(lines[max(0,i-12):i])
   if op=="call": reg=pat.search(lines[i]).group(1)
   else: reg="rax"
   if not re.search(r"mov\s+"+reg+r",\s*qword ptr \[[a-z0-9]+\]",before,re.I):
    mode_ok=False
  index=(off+0x10)//8
 provenance.append("PROVENANCE stage=%s class=%s offset=0x%x mode=%s count=%d vptr_or_ZTV_base_verified=%s index=%d result=%s"%(
  stage,cls,off,mode,len(hits),"YES" if mode_ok else "NO",index,"PASS" if mode_ok else "FAIL"))
 if not mode_ok:
  issues.append("POINTER_PROVENANCE_UNPROVEN_%s_0x%x"%(stage,off)); matrix.append("UNRESOLVED stage=%s class=%s offset=0x%x mode=%s"%(stage,cls,off,mode)); continue
 vt=kc.vtable(cls)
 if not vt or len(vt)<=index:
  issues.append("VTABLE_NOT_FOUND_OR_SHORT_%s_0x%x"%(cls,off)); matrix.append("UNRESOLVED class=%s index=%d"%(cls,index)); continue
 stage70_index=(off+0x10)//8
 old_target=vt[stage70_index][2] if len(vt)>stage70_index else 0
 old_symbol=vt[stage70_index][3] if len(vt)>stage70_index else "OUT_OF_RANGE"
 _,raw,target,name=vt[index]; target=addr(target)
 owner=kc.owner(target) or kc.sym_owner.get(target) or "UNKNOWN"; sym_owner=kc.sym_owner.get(target) or "UNKNOWN"
 ok=bool(target) and owner!="UNKNOWN" and owner==sym_owner
 matrix.append("TARGET stage=%s class=%s offset=0x%x mode=%s stage70_index=%d stage70_target=0x%x stage70_symbol=%s reconciled_index=%d reconciled_symbol_offset=0x%x target=0x%x owner=%s symbol_owner=%s symbol=%s result=%s"%(
  stage,cls,off,mode,stage70_index,old_target,old_symbol,index,index*8,target,owner,sym_owner,name,"PASS" if ok else "REVIEW_REQUIRED"))
 if ok: resolved.append((stage,cls,off,mode,index,target,owner,name))
 else: issues.append("TARGET_OWNER_UNRESOLVED_%s_0x%x"%(stage,off))
(out/"callsite-pointer-provenance.txt").write_text("\n".join(provenance)+"\n")
(out/"vtable-target-reconciliation-matrix.txt").write_text("\n".join(matrix)+"\n")

unique={}
for r in resolved: unique.setdefault(r[5],(r[1],r[7],r[6]))
carved={}
for owner in sorted({v[2] for v in unique.values()}):
 p=cache/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho"); kc.carve(owner,str(p)); carved[owner]=p
dis=[]; status=[]
for va,(cls,nm,owner) in sorted(unique.items()):
 nxt=kc.next_sym(va); end=addr(nxt) if nxt else va+0x1000
 if end<=va or end>va+0x20000: end=va+0x1000
 p=subprocess.run([obj,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%va,"--stop-address=0x%x"%end,str(carved[owner])],capture_output=True,text=True)
 n=sum(1 for line in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",line)); ok=p.returncode==0 and n>0
 status.append("METHOD address=0x%x class=%s symbol=%s owner=%s instructions=%d result=%s"%(va,cls,nm,owner,n,"PASS" if ok else "REVIEW_REQUIRED"))
 if not ok: issues.append("DISASSEMBLY_FAILED_0x%x"%va)
 dis += ["\n===== RECONCILED TARGET class=%s symbol=%s address=0x%x owner=%s ====="%(cls,nm,va,owner),"OBJDUMP_EXIT=%d INSTRUCTIONS=%d"%(p.returncode,n),"DISASSEMBLY_BEGIN",p.stdout[:70000].rstrip(),"DISASSEMBLY_END"]
(out/"method-status.txt").write_text("\n".join(status)+"\n")
(out/"reconciled-vtable-target-disassembly.txt").write_text("\n".join(dis)+"\n")
all_dis=bool(status) and all("result=PASS" in x for x in status)
summary=[
 "STAGE71_CALLSITE_AWARE_ITANIUM_VTABLE_RECONCILIATION_AUDIT","TARGET=15.8.1/24H32/x86_64",
 "STAGE70_PREDECESSOR=8/8_PINS_PASS","STAGE60_ADDRESSPOINT_PRECEDENT=PIN_PASS",
 "STAGE65_TO_69_CALLSITE_DISASSEMBLIES=5/5_PINS_PASS",
 "STAGE43_SOURCE_CONTINUITY="+("PASS" if source_ok else "REVIEW_REQUIRED"),
 "VIRTUAL_TARGETS_RECONCILED=%d/%d"%(len(resolved),len(specs)),
 "OBJECT_VPTR_TARGETS=%d"%sum(x[3]=="OBJECT_VPTR" for x in resolved),
 "STATIC_ZTV_BASE_TARGETS=%d"%sum(x[3]=="STATIC_ZTV_BASE" for x in resolved),
 "STAGE66_STATIC_ZTV_PLUS_0x240=INDEX_72_INITWITHPOOL_EXPECTED",
 "UNIQUE_TARGETS_DISASSEMBLED=%d"%len(unique),
 "TARGET_DISASSEMBLY_PASS=%d"%sum("result=PASS" in x for x in status),
 "STAGE70_STAGE66_TARGET=SUPERSEDED_STATIC_BASE_NOT_OBJECT_VPTR",
 "ISSUES="+(",".join(issues) if issues else "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN","KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN",
 "RESULT="+("PASS" if source_ok and len(resolved)==len(specs) and all_dis and not issues else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE=BLOCKED"]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
report=[
 "========== STAGE 71 CALLSITE-AWARE ITANIUM VTABLE RECONCILIATION ==========",
 "VERSION=STAGE71_V1_20261102","RUN="+out.name,"TARGET=15.8.1/24H32/x86_64",
 "PREDECESSOR=Stage70 corrected-index audit plus pinned Stage65–69 raw caller disassemblies",
 "PURPOSE=classify each vtable operand as an object-vptr displacement or direct _ZTV-base displacement before index correction",
 "KEY_CORRECTION=Stage65 queue initialization loads __ZTV20IOSkywalkPacketQueue directly and calls [ZTV+0x240]; use index 72 without another +0x10",
 "SCOPE=read-only pointer provenance, target reconciliation and corrected target disassembly",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE","",
 *summary,"",
 "CAUTION=only callsites with verified operand provenance are accepted; target semantics remain grounded in their exact method bodies",
 "ACTIVATION_GATE=BLOCKED","========== END STAGE 71 =========="]
(out/"report.txt").write_text("\n".join(report)+"\n")
print("\n".join(summary))
if not source_ok or len(resolved)!=len(specs) or not all_dis or issues: raise SystemExit("Stage71 callsite-aware vtable reconciliation requires review")
PY

MAN="$OUT/manifest.txt"
{
 echo "STAGE=71"; echo "VERSION=$VERSION"; echo "RUN=$RUN"
 echo "PURPOSE=callsite pointer-provenance and mixed static/object Itanium vtable reconciliation"
 echo "TARGET=$OSVER/$BUILD/$ARCH"; echo "PREDECESSOR=Stage70 plus Stage65-69 raw caller disassemblies"
 echo "SOURCE_MODIFIED=NO"; echo "BUILD=NOT_RUN"; echo "ACTIVATION_GATE=BLOCKED"; echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"
PAYLOAD_INDEX=0
upload_one(){
 local file="$1" path="$2" expected payload response put got
 expected="$(blob_sha "$file")"; PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"; response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$payload" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Add Stage71 callsite-aware vtable audit","content":base64.b64encode(p.read_bytes()).decode()}))
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
 if (( bytes <= 225280 )); then upload_one "$f" "Development/Logs/stage71/$RUN/$base"
 else split -b 220k "$f" "$f.part-"; for part in "$f".part-*; do [[ -f "$part" ]] || continue; upload_one "$part" "Development/Logs/stage71/$RUN/$(basename "$part")"; done; fi
 echo "$base SHA256=$(shasum -a 256 "$f" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/callsite-pointer-provenance.txt "$OUT"/vtable-target-reconciliation-matrix.txt "$OUT"/reconciled-vtable-target-disassembly.txt "$OUT"/method-status.txt; do
 [[ -f "$f" ]] || fail "missing Stage71 artifact: $f"; upload_artifact "$f"
done
upload_one "$MAN" "Development/Logs/stage71/$RUN/manifest.txt"
gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
o=json.load(open(remote)); old=base64.b64decode(o["content"])
entry=("\n========== STAGE 71 CALLSITE-AWARE ITANIUM VTABLE RECONCILIATION ==========\n"
 "STAGE71_RUN: %s\n"%run+
 "STAGE71_VERSION: %s\n"%version+
 "STAGE71_SCOPE: distinguish object-vptr offsets from direct _ZTV-base offsets and reconcile Stage65–69 virtual targets\n"+
 "STAGE71_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — ABI target reconciliation only; native registration and TX/RX ownership implementation remain open\n"+
 "STAGE71_LOGS: Development/Logs/stage71/%s/\n"%run+
 "==================================================================\n").encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry); pathlib.Path(dst+".sha").write_text(o["sha"])
PY
python3 - "$OUT/output.log" "$OUT/output-payload.json" "$(cat "$OUT/output.log.sha")" <<'PY'
import base64,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); pathlib.Path(sys.argv[2]).write_text(json.dumps({"message":"Append Stage71 callsite-aware vtable reconciliation","sha":sys.argv[3],"content":base64.b64encode(p.read_bytes()).decode()}))
PY
gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$OUT/output-payload.json" > "$OUT/output-put.json"
PUT_SHA="$(python3 - "$OUT/output-put.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY
)"
REMOTE_SHA="$(gh api "repos/$REPO/contents/Development/output.log" -q .sha)"
[[ "$PUT_SHA" == "$REMOTE_SHA" ]] || fail "output.log readback SHA mismatch"
echo "STAGE71_VERSION=$VERSION"
echo "STAGE71_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE71_RUN=$RUN"
echo "STAGE71_AUDIT_RESULT=$(grep '^RESULT=' "$OUT/audit-summary.txt" | cut -d= -f2)"
echo "STAGE71_LOCAL_OUTPUT=$OUT"
echo "STAGE71_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage71/$RUN"
echo "STAGE71_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE71_SOURCE_MODIFIED=NO"
echo "STAGE71_BUILD=NOT_RUN"
echo "STAGE71_INSTALL=NOT_RUN"
echo "STAGE71_LOAD=NOT_RUN"
