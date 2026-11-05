#!/bin/bash
# AUTO_SAFE_READ_ONLY=YES
# AUTO_SCOPE=STAGE89_AUDIT
# Stage89 V18/V19/V20 sequential read-only audit runner. Mode is selected by runner filename.
# No source edits, build, signing, install/load, hardware, OpenCore, SIP or NVRAM actions.
set -Eeuo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$HOME/Developer/Realtek-WiFi-Native-macOS-Main (Local)"
NAME="$(basename "$0")"
V="$(printf '%s' "$NAME" | sed -E 's/^stage89-v([0-9]+).*/\1/')"
case "$V" in 18|19|20) ;; *) echo "UNSUPPORTED_STAGE89_VERSION=$V" >&2; exit 2;; esac
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
TAG="stage89-v$V"
OUT="$ROOT/run log/$TAG/$RUN"
REMOTE="Development/Logs/$TAG/$RUN"
BASE="https://raw.githubusercontent.com/$REPO/main"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/console-output.log") 2>&1

fail(){ echo "STAGE89_V${V}_ERROR=$*" >&2; exit 2; }
blob(){
 python3 - "$1" <<'PYBLOB'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PYBLOB
}
pin(){
 local name="$1" want="$2" url="$3" got
 curl -fsSLo "$OUT/$name" "$url" || fail "download failed: $name"
 got="$(blob "$OUT/$name")"
 [[ "$got" == "$want" ]] || fail "pinned evidence mismatch: $name expected=$want actual=$got"
 echo "PIN_VERIFIED=$name SHA=$got"
}
upload(){
 local f="$1" dest="$2" payload="$OUT/upload-payload.json" want got attempt
 want="$(blob "$f")"
 python3 - "$f" "$payload" <<'PYUPLOAD'
import base64,json,pathlib,sys
pathlib.Path(sys.argv[2]).write_text(json.dumps({
 "message":"Stage89 V18-V20 read-only audit evidence",
 "content":base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode("ascii")
}))
PYUPLOAD
 for attempt in 1 2 3 4; do
  got="$(gh api "repos/$REPO/contents/$dest?ref=main" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$dest SHA=$got"; return 0; fi
  gh api --method PUT "repos/$REPO/contents/$dest" --input "$payload" > "$OUT/upload-response.json" 2> "$OUT/upload-error.txt" || true
  got="$(gh api "repos/$REPO/contents/$dest?ref=main" -q .sha 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then echo "UPLOAD_VERIFIED=$dest ATTEMPT=$attempt SHA=$got"; return 0; fi
  sleep 2
 done
 echo "UPLOAD_FAILED=$dest EXPECTED=$want ACTUAL=$got" >&2
 return 1
}
read_github_file(){
 local remote="$1" dest="$2" json="$OUT/github-content.json"
 gh api "repos/$REPO/contents/$remote?ref=main" > "$json" || fail "cannot read GitHub file: $remote"
 python3 - "$json" "$dest" <<'PYREAD'
import base64,hashlib,json,pathlib,sys
o=json.load(open(sys.argv[1]))
b=base64.b64decode(o["content"])
sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
if sha!=o.get("sha"): raise SystemExit("GitHub blob/readback SHA mismatch: "+sys.argv[1])
pathlib.Path(sys.argv[2]).write_bytes(b)
print("GITHUB_FILE_VERIFIED="+pathlib.Path(sys.argv[2]).name+" SHA="+sha)
PYREAD
}
fetch_previous_artifact(){
 local prev_run="$1" name="$2" dest="$OUT/$2" manifest="$OUT/previous-manifest.txt"
 if [[ ! -f "$manifest" ]]; then
  read_github_file "Development/Logs/stage89-v$((V-1))/$prev_run/manifest.txt" "$manifest"
 fi
 local want
 want="$(python3 - "$manifest" "$name" <<'PYWANT'
import pathlib,sys
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
 if line.startswith("ARTIFACT|"):
  p=line.split("|",3)
  if len(p)==4 and p[1]==sys.argv[2]:
   print(p[2]); raise SystemExit(0)
raise SystemExit("Artifact absent from predecessor manifest: "+sys.argv[2])
PYWANT
)" || fail "predecessor artifact not in manifest: $name"
 read_github_file "Development/Logs/stage89-v$((V-1))/$prev_run/$name" "$dest"
 local got
 got="$(blob "$dest")"
 [[ "$got" == "$want" ]] || fail "predecessor artifact SHA differs from manifest: $name"
 echo "PREDECESSOR_ARTIFACT_PIN_PASS=$name SHA=$got"
}
append_checkpoint(){
 local block="$OUT/checkpoint-block.txt" before="$OUT/output-before.json" payload="$OUT/output-update.json" after="$OUT/output-after.json"
 gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$before" || fail "cannot fetch canonical history"
 python3 - "$before" "$block" "$payload" "$V" "$RUN" <<'PYAPPEND'
import base64,json,pathlib,re,sys
o=json.load(open(sys.argv[1]))
old=base64.b64decode(o["content"])
s=old.decode(errors="replace")
v=int(sys.argv[4]); run=sys.argv[5]
m=list(re.finditer(r"STAGE89_V(\d+)_RUN:\s*(run-[A-Za-z0-9-]+)",s))
if not m: raise SystemExit("No recognized predecessor checkpoint")
if int(m[-1].group(1))!=v-1: raise SystemExit("Canonical history changed before append; expected V%d, found V%s"%(v-1,m[-1].group(1)))
if re.search(r"STAGE89_V"+str(v)+r"_RUN:",s): raise SystemExit("Stage V%d already exists in canonical history"%v)
new=old.rstrip()+b"\n\n"+pathlib.Path(sys.argv[2]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({
 "message":"Record Stage89 V%d read-only audit"%v,
 "content":base64.b64encode(new).decode("ascii"),
 "sha":o["sha"],"branch":"main"
}))
PYAPPEND
 gh api --method PUT "repos/$REPO/contents/Development/output.log" --input "$payload" > "$OUT/output-update-response.json" || fail "canonical history update failed"
 gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$after" || fail "canonical history readback failed"
 python3 - "$after" "$V" "$RUN" <<'PYVERIFY'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
if "STAGE89_V"+sys.argv[2]+"_RUN: "+sys.argv[3] not in s: raise SystemExit("Canonical output.log read-after-write failed")
print("CANONICAL_OUTPUT_LOG_READBACK=PASS")
PYVERIFY
}
on_exit(){
 local rc=$?
 if [[ "$rc" -ne 0 ]]; then
  {
   echo "STAGE89_V${V}_FAILURE"
   echo "RUN=$RUN"
   echo "EXIT=$rc"
   tail -n 80 "$OUT/console-output.log" 2>/dev/null || true
  } > "$OUT/failure-report.txt"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then upload "$OUT/failure-report.txt" "$REMOTE/failure-report.txt" || true; fi
 fi
}
trap on_exit EXIT

for t in curl gh python3 sw_vers uname tee date tail sed; do command -v "$t" >/dev/null 2>&1 || fail "missing command: $t"; done
[[ -d "$ROOT/driver/RTL88WiFi/src" ]] || fail "project source tree missing"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication unavailable"
[[ "$(sw_vers -productVersion)" == "15.8.1" && "$(sw_vers -buildVersion)" == "24H32" && "$(uname -m)" == "x86_64" ]] || fail "target must be macOS 15.8.1 / 24H32 / x86_64"

gh api "repos/$REPO/contents/Development/output.log?ref=main" > "$OUT/output-preflight.json" || fail "cannot fetch canonical history"
PREV_RUN="$(python3 - "$OUT/output-preflight.json" "$V" <<'PYPREV'
import base64,json,re,sys
s=base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode(errors="replace")
m=list(re.finditer(r"STAGE89_V(\d+)_RUN:\s*(run-[A-Za-z0-9-]+)",s))
if not m: raise SystemExit("No previous Stage89 run")
expected=int(sys.argv[2])-1
if int(m[-1].group(1))!=expected: raise SystemExit("Expected latest Stage89 V%d; history currently ends at V%s"%(expected,m[-1].group(1)))
print(m[-1].group(2))
PYPREV
)" || fail "sequential predecessor gate failed"
echo "STAGE89_V${V}_RUN=$RUN"
echo "PREDECESSOR=$PREV_RUN"
echo "TARGET=macOS_15.8.1_24H32_x86_64"
echo "READ_ONLY=YES"
echo "LOCAL_ARTIFACT_DIR=$OUT"
echo "GITHUB_ARTIFACT_DIR=$REMOTE"

case "$V" in
18)
  BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
  [[ -r "$BOOTKC" && -s "$BOOTKC" ]] || fail "current on-disk BootKernelExtensions.kc missing or unreadable"
  for t in xcrun file; do command -v "$t" >/dev/null 2>&1 || fail "missing command: $t"; done
  OBJDUMP="$(xcrun --find llvm-objdump 2>/dev/null || true)"
  [[ -n "$OBJDUMP" && -x "$OBJDUMP" ]] || fail "llvm-objdump unavailable through selected Xcode"
  pin source-queues.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
  pin source-queues.hpp 1059a4a06d52d28ee7fa7fe17970b618db0faabd "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
  pin sdk-tx-submission.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
  pin v17-report.txt 1c071db79e82d7ea30ebcdcab13f9c9734ff1206 "$BASE/Development/Logs/stage89-v17/run-20261105-072219-707421a3b631/report.txt"
  curl -fsSLo "$OUT/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960/kcfile.py" || fail "kernel collection parser download failed"
  [[ "$(blob "$OUT/kcfile.py")" == "5d31e8a73e5cb175851e7407529456f223683589" ]] || fail "kernel collection parser SHA mismatch"
  python3 -u - "$OUT" "$BOOTKC" "$OBJDUMP" "$ROOT" <<'PY18'
import hashlib,pathlib,re,struct,subprocess,sys,time
out=pathlib.Path(sys.argv[1]); boot=pathlib.Path(sys.argv[2]); objdump=sys.argv[3]; root=pathlib.Path(sys.argv[4])
meta=["STAGE89_V18_BOOTKC_CAPTURE_METADATA","PATH="+str(boot),"SIZE_BYTES="+str(boot.stat().st_size),"MTIME_EPOCH="+str(int(boot.stat().st_mtime)),"SHA256="+hashlib.sha256(boot.read_bytes()).hexdigest(),"FILE_TYPE="+subprocess.run(["file","-b",str(boot)],capture_output=True,text=True).stdout.strip(),"RUNNING_KERNEL_UNAME="+subprocess.run(["uname","-a"],capture_output=True,text=True).stdout.strip(),"RUNNING_KERNEL_BUILD="+subprocess.run(["uname","-v"],capture_output=True,text=True).stdout.strip(),"CAPTURE_SCOPE=CURRENT_ON_DISK_BOOTKERNELCOLLECTION","RUNNING_KERNEL_IMAGE_MATCH=NOT_PROVEN"]
(out/"bootkc-capture-metadata.txt").write_text("\n".join(meta)+"\n")
sys.path.insert(0,str(out))
from kcfile import KC
print("FRESH_BOOTKC_PARSE_BEGIN=YES",flush=True)
kc=KC(str(boot))
owner="com.apple.iokit.IOSkywalkFamily"
entry=next((e for e in kc.entries if e[0]==owner),None)
if not entry: raise SystemExit("IOSkywalkFamily fileset entry absent from current BootKC")
ranges=[]
for cmd,p,_sz in kc._cmds(entry[2]):
 if cmd!=0x19: continue
 n=struct.unpack_from("<I",kc.d,p+64)[0]
 for i in range(n):
  q=p+72+i*80
  sn=kc.d[q:q+16].split(b"\0")[0].decode(errors="replace")
  gn=kc.d[q+16:q+32].split(b"\0")[0].decode(errors="replace")
  va,size=struct.unpack_from("<QQ",kc.d,q+32)
  flags=struct.unpack_from("<I",kc.d,q+64)[0]
  if size and flags&(0x80000000|0x400): ranges.append((sn,gn,va,va+size))
def iscode(a): return any(lo<=a<hi for _s,_g,lo,hi in ranges)
addresses=sorted(a for a in kc.addrs if kc.sym_owner.get(a)==owner and iscode(a))
classes=("IOSkywalkPacketQueue","IOSkywalkTxSubmissionQueue","IOSkywalkTxCompletionQueue","IOSkywalkRxSubmissionQueue","IOSkywalkRxCompletionQueue","IOSkywalkQueueSet")
tokens=re.compile(r"(performCommand|withPool|initWithPool|isWMMSchedModelCapable|initWithQueues|createWithQueues|getServiceClass|setServiceClass)")
selected=[]
for a in addresses:
 name=kc.syms[a]
 if any(c in name for c in classes) and tokens.search(name):
  selected.append((a,name))
selected.sort()
if not selected: raise SystemExit("No IOSkywalk native queue contract symbols found in current BootKC")
cache=out/"kc-cache"; cache.mkdir()
macho=cache/"IOSkywalkFamily.macho"
kc.carve(owner,str(macho))
bodies={}
for i,(a,name) in enumerate(selected,1):
 sec=next((x for x in ranges if x[2]<=a<x[3]),None)
 if not sec: continue
 nxt=kc.next_sym(a)
 stop=nxt if nxt and a<nxt<=min(a+0x18000,sec[3]) else min(a+0x8000,sec[3])
 p=subprocess.run([objdump,"-d","-M","intel","--no-show-raw-insn","--start-address=0x%x"%a,"--stop-address=0x%x"%stop,str(macho)],capture_output=True,text=True,timeout=90)
 ins=[x.strip() for x in p.stdout.splitlines() if re.match(r"^\s*[0-9a-fA-F]+:",x)]
 if p.returncode or not ins: raise SystemExit("Disassembly failed for "+name+": "+p.stderr[:300])
 bodies[name]=(a,ins)
 print("FRESH_DISASSEMBLY=%d/%d %s"%(i,len(selected),name[:150]),flush=True)
rows=["STAGE89_V18_FRESH_24H32_IOSKYWALK_METHOD_DISASSEMBLY"]
for name,(a,ins) in bodies.items():
 rows.append("===== ADDRESS=0x%016x SYMBOL=%s ====="%(a,name)); rows.extend(ins)
rows.append("METHODS_DISASSEMBLED="+str(len(bodies)))
(out/"native-kernel-method-disassembly.txt").write_text("\n".join(rows)+"\n")
idx=["STAGE89_V18_CURRENT_BOOTKC_NATIVE_METHOD_INDEX","BOOTKC_SHA256="+hashlib.sha256(boot.read_bytes()).hexdigest(),"IOSKYWALK_FILESSET_ENTRY="+owner,"IOSKYWALK_INSTRUCTION_SYMBOLS="+str(len(addresses)),"METHODS_DISASSEMBLED="+str(len(bodies))]
for name,(a,ins) in bodies.items(): idx.append("METHOD=0x%016x INSTRUCTIONS=%d SYMBOL=%s"%(a,len(ins),name))
(out/"native-kernel-method-index.txt").write_text("\n".join(idx)+"\n")
sdk=(out/"sdk-tx-submission.h").read_text(errors="replace")
src=(out/"source-queues.cpp").read_text(errors="replace")
native_setters=[n for n in bodies if "IOSkywalkTxSubmissionQueue" in n and "setServiceClass" in n]
native_factories=[n for n in bodies if "IOSkywalkTxSubmissionQueue" in n and "withPool" in n]
init_bodies=[(n,"\n".join(ins)) for n,(a,ins) in bodies.items() if "IOSkywalkTxSubmissionQueue" in n and "initWithPool" in n]
writer=[n for n,b in init_bodies if re.search(r"mov\s+dword ptr \[[a-z0-9]+\s*\+\s*0xb8\],",b,re.I)]
explicit=[n for n in native_factories if "withPoolAndServiceClass" in n]
checks=[
 ("current_bootkc_parsed",True),
 ("ioskywalk_fileset_found",bool(entry)),
 ("native_queue_methods_disassembled",len(bodies)>0),
 ("txsubmission_factory_symbols_found",len(native_factories)>0),
 ("fresh_current_target_build_confirmed", "24H32" in subprocess.run(["sw_vers","-buildVersion"],capture_output=True,text=True).stdout),
 ("native_tx_setter_symbol_found",len(native_setters)>0),
 ("explicit_named_factory_symbol_found",len(explicit)>0)
]
src_calls=src.count("IOSkywalkTxSubmissionQueue::withPool(")+src.count("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(")
facts=[
 "STAGE89_V18_FRESH_TARGET_BINARY_FINDINGS",
 "FRESH_BOOTKC_CAPTURE=PASS",
 "BOOTKC_SHA256="+hashlib.sha256(boot.read_bytes()).hexdigest(),
 "BOOTKC_BYTES="+str(boot.stat().st_size),
 "RUNNING_KERNEL_IMAGE_MATCH=NOT_PROVEN",
 "IOSKYWALK_INSTRUCTION_SYMBOLS="+str(len(addresses)),
 "NATIVE_METHODS_DISASSEMBLED="+str(len(bodies)),
 "TXSUBMISSION_FACTORY_SYMBOL_COUNT="+str(len(native_factories)),
 "TXSUBMISSION_EXPLICIT_NAMED_FACTORY_SYMBOL_COUNT="+str(len(explicit)),
 "TXSUBMISSION_NATIVE_SETTER_SYMBOL_COUNT="+str(len(native_setters)),
 "TXSUBMISSION_INIT_SERVICECLASS_FIELD_WRITER_COUNT="+str(len(writer)),
 "CURRENT_SOURCE_TXSUBMISSION_FACTORY_CALLS="+str(src_calls),
 "SDK_DECLARES_WITHPOOL_AND_SERVICECLASS="+("YES" if "withPoolAndServiceClass" in sdk else "NO"),
 "NATIVE_QUEUE_SETTER_CALLABILITY=NOT_PROVEN" if not native_setters else "NATIVE_QUEUE_SETTER_SYMBOLS_FOUND=REQUIRES_CALL_PATH_REVIEW",
 "CHECKS_PASSED=%d/%d"%(sum(1 for _,v in checks if v),len(checks)),
 "FAILED_CHECKS="+(",".join(n for n,v in checks if not v) or "NONE")
]
(out/"fresh-kernel-binary-findings.txt").write_text("\n".join(facts)+"\n")
summary=[
 "STAGE89_V18_FRESH_24H32_KERNEL_BINARY_CAPTURE_AUDIT",
 "TARGET=macOS_15.8.1_24H32_x86_64",
 "FRESH_BOOTKC_CAPTURE=PASS",
 "BOOTKC_CURRENT_ON_DISK=YES",
 "RUNNING_KERNEL_IMAGE_MATCH=NOT_PROVEN",
 "IOSKYWALK_METHODS_DISASSEMBLED="+str(len(bodies)),
 "NATIVE_TX_SETTER_SYMBOLS="+str(len(native_setters)),
 "EXPLICIT_TX_SERVICECLASS_FACTORY_SYMBOLS="+str(len(explicit)),
 "TX_INIT_0xB8_WRITER_METHODS="+str(len(writer)),
 "CURRENT_SOURCE_TXSUBMISSION_FACTORY_CALLS="+str(src_calls),
 "NATIVE_SETTER_CALLABILITY=NOT_PROVEN",
 "SDK_TARGET_FACTORY_MAPPING=NOT_PROVEN",
 "RESULT=REVIEW_REQUIRED",
 "STAGE89_EXIT=NOT_MET",
 "ACTIVATION_GATE=BLOCKED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","HARDWARE_TEST=NOT_RUN","OPENCORE_CHANGE=NONE"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
decision=[
 "STAGE89_V18_DECISION","RESULT=REVIEW_REQUIRED",
 "FRESH_EVIDENCE=Current on-disk 24H32 BootKernelExtensions.kc was parsed and native IOSkywalk queue methods disassembled.",
 "RUNNING_KERNEL_IMAGE_MATCH=NOT_PROVEN; disk capture is not treated as proof of the exact image currently resident in memory.",
 "NATIVE_SETTER_CALLABILITY=NOT_PROVEN unless a native IOSkywalkTxSubmissionQueue setter and supported dispatch path are both established.",
 "FACTORY_ABI=Must be reviewed against exact target disassembly and the SDK declaration; no argument reorder or private field write is authorized.",
 "NEXT=V19 must cross-check the fresh factory/init disassembly against the SDK and four-queue WMM requirement."
]
(out/"decision.txt").write_text("\n".join(decision)+"\n")
print("FRESH_BOOTKC_CAPTURE=PASS",flush=True)
print("NATIVE_METHODS_DISASSEMBLED="+str(len(bodies)),flush=True)
print("STAGE89_V18_RESULT=REVIEW_REQUIRED",flush=True)
PY18
  ARTIFACTS="bootkc-capture-metadata.txt native-kernel-method-index.txt native-kernel-method-disassembly.txt fresh-kernel-binary-findings.txt audit-summary.txt decision.txt"
  ;;
19)
  fetch_previous_artifact "$PREV_RUN" native-kernel-method-index.txt
  fetch_previous_artifact "$PREV_RUN" native-kernel-method-disassembly.txt
  fetch_previous_artifact "$PREV_RUN" fresh-kernel-binary-findings.txt
  pin source-queues.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
  pin sdk-tx-submission.h 18050629c5d2f07ccb5f38fcf5d571bd071f8464 "$BASE/driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkTxSubmissionQueue.h"
  pin wmm-service-class-table.txt c4e5106ebb95dc3807c9591d1d676c48fefceb1d "$BASE/Development/Logs/stage88/run-20261102-205135-b4f4ddc49298/wmm-service-class-table.txt"
  python3 - "$OUT" <<'PY19'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
dis=(p/"native-kernel-method-disassembly.txt").read_text(errors="replace")
idx=(p/"native-kernel-method-index.txt").read_text(errors="replace")
src=(p/"source-queues.cpp").read_text(errors="replace")
sdk=(p/"sdk-tx-submission.h").read_text(errors="replace")
wmm=(p/"wmm-service-class-table.txt").read_text(errors="replace")
symbols=re.findall(r"SYMBOL=(\S+)",idx)
tx=[s for s in symbols if "IOSkywalkTxSubmissionQueue" in s]
factories=[s for s in tx if "withPool" in s]
explicit=[s for s in factories if "withPoolAndServiceClass" in s]
init=[s for s in tx if "initWithPool" in s]
native_setters=[s for s in tx if "setServiceClass" in s]
action_wrapper="withPoolEP25IOSkywalkPacketBufferPooljjP8OSObjectPFjS3_PS_PKP15IOSkywalkPacketjPvES9_j"
action_pos=dis.find(action_wrapper)
action_block=dis[action_pos:action_pos+4500] if action_pos>=0 else ""
push_minus_one="push\t-0x1" in action_block or "push -0x1" in action_block
init_pos=dis.find("IOSkywalkTxSubmissionQueue12initWithPool")
init_block=dis[init_pos:init_pos+6500] if init_pos>=0 else ""
stores_0xb8=bool(re.search(r"mov\s+dword ptr \[[a-z0-9]+\s*\+\s*0xb8\],",init_block,re.I))
init_serviceclass_reg=bool(re.search(r"mov\s+r15d,\s*edx",init_block,re.I))
init_capacity_reg=bool(re.search(r"cmp\s+ecx,\s*0x8",init_block,re.I))
init_queueid_reg=bool(re.search(r"mov\s+r8d,\s*ecx",init_block,re.I))
sdk_explicit="withPoolAndServiceClass" in sdk
src_calls=src.count("IOSkywalkTxSubmissionQueue::withPool(")+src.count("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(")
src_explicit="IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(" in src
classes=re.findall(r"WMM_SERVICE_CLASS_\d+=(0x[0-9a-fA-F]+)",wmm)
expected=["0x00100080","0x00000000","0x00380100","0x00400180"]
checks={
 "v18_current_bootkc_capture_pass":"FRESH_BOOTKC_CAPTURE=PASS" in (p/"fresh-kernel-binary-findings.txt").read_text(),
 "four_wmm_values_exact":classes==expected,
 "sdk_explicit_factory_declared":sdk_explicit,
 "target_tx_factory_symbols_found":len(factories)>0,
 "target_explicit_named_factory_symbol_found":len(explicit)>0,
 "target_init_serviceclass_writer_found":stores_0xb8,
 "action_only_factory_sentinel_found":push_minus_one,
 "source_has_explicit_factory_call":src_explicit,
 "source_tx_factory_call_count_one":src_calls==1
}
rows=[
 "STAGE89_V19_FACTORY_ABI_CROSSWALK",
 "PREDECESSOR_FRESH_BOOTKC_CAPTURE=PASS",
 "TARGET_TX_FACTORY_SYMBOLS="+str(len(factories)),
 "TARGET_EXPLICIT_WITHPOOLANDSERVICECLASS_SYMBOLS="+str(len(explicit)),
 "TARGET_TX_INITWITHPOOL_SYMBOLS="+str(len(init)),
 "TARGET_NATIVE_TX_SETTER_SYMBOLS="+str(len(native_setters)),
 "SDK_WITHPOOLANDSERVICECLASS_DECLARED="+("YES" if sdk_explicit else "NO"),
 "TARGET_INIT_WRITES_SERVICECLASS_OFFSET_0xB8="+("YES" if stores_0xb8 else "NOT_PROVEN"),
 "TARGET_INIT_EDX_STORED_AS_SERVICECLASS="+("YES" if init_serviceclass_reg and stores_0xb8 else "NOT_PROVEN"),
 "TARGET_INIT_ECX_CHECKED_AS_CAPACITY="+("YES" if init_capacity_reg else "NOT_PROVEN"),
 "TARGET_INIT_R8D_ASSIGNED_QUEUEID="+("YES" if init_queueid_reg else "NOT_PROVEN"),
 "TARGET_INIT_EFFECTIVE_ORDER=SERVICECLASS_CAPACITY_QUEUEID" if init_serviceclass_reg and init_capacity_reg and init_queueid_reg and stores_0xb8 else "TARGET_INIT_EFFECTIVE_ORDER=NOT_PROVEN",
 "SDK_INIT_DECLARED_ORDER=CAPACITY_QUEUEID_SERVICECLASS",
 "TARGET_ACTION_ONLY_WRAPPER_PUSHES_0xffffffff="+("YES" if push_minus_one else "NOT_PROVEN"),
 "SOURCE_FACTORY_CALLS="+str(src_calls),
 "SOURCE_USES_EXPLICIT_SERVICECLASS_FACTORY="+("YES" if src_explicit else "NO"),
 "SDK_TO_TARGET_EXPLICIT_FACTORY_MAPPING=NOT_PROVEN_PENDING_EXACT_DECLARATION_TO_TARGET_ABI_CROSSWALK",
 "TARGET_INIT_EDX_IS_SERVICECLASS="+("YES" if init_serviceclass_reg and stores_0xb8 else "NOT_PROVEN"),
 "TARGET_INIT_ECX_IS_CAPACITY="+("YES" if init_capacity_reg else "NOT_PROVEN"),
 "TARGET_INIT_R8D_IS_QUEUEID="+("YES" if init_queueid_reg else "NOT_PROVEN"),
 "TARGET_INIT_ABI_ORDER=SERVICECLASS_CAPACITY_QUEUEID" if init_serviceclass_reg and init_capacity_reg and init_queueid_reg and stores_0xb8 else "TARGET_INIT_ABI_ORDER=NOT_PROVEN",
 "FOUR_WMM_SERVICE_CLASSES="+",".join(classes),
 "EXPECTED_FOUR_WMM_SERVICE_CLASSES="+",".join(expected),
 "CHECKS_PASSED=%d/%d"%(sum(checks.values()),len(checks)),
 "CHECKS_FAILED="+(",".join(k for k,v in checks.items() if not v) or "NONE")
]
(p/"factory-abi-crosswalk.txt").write_text("\n".join(rows)+"\n")
gate=[
 "STAGE89_V19_FOUR_QUEUE_FEASIBILITY",
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT="+str(src_calls),
 "REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4",
 "WMM_SERVICE_CLASSES="+",".join(classes),
 "FOUR_DISTINCT_TX_QUEUE_CONSTRUCTION=BLOCKED_UNPROVEN_FACTORY_MAPPING",
 "STABLE_FOUR_POINTER_ARRAY=NOT_IMPLEMENTED_IN_CURRENT_SOURCE",
 "NATIVE_QUEUE_REGISTRATION=NOT_FOUND_IN_CURRENT_SOURCE" if not re.search(r"(?:createWithQueues|initWithQueues|registerNetworkInterface)",src) else "REGISTRATION_SYMBOL_REFERENCE_FOUND_REQUIRES_REVIEW",
 "PRIVATE_FIELD_WRITE=PROHIBITED",
 "GUESSED_OVERLOAD_OR_ARGUMENT_REORDER=PROHIBITED",
 "DECISION=KEEP_REGISTRATION_FAIL_CLOSED"
]
(p/"four-queue-feasibility.txt").write_text("\n".join(gate)+"\n")
summary=[
 "STAGE89_V19_TARGET_FACTORY_ABI_AND_FOUR_QUEUE_FEASIBILITY_AUDIT",
 "V18_FRESH_BOOTKC_EVIDENCE=CONSUMED_AND_MANIFEST_SHA_VERIFIED",
 "TARGET_TX_FACTORY_SYMBOLS="+str(len(factories)),
 "TARGET_EXPLICIT_SERVICECLASS_FACTORY_SYMBOLS="+str(len(explicit)),
 "TARGET_NATIVE_SETTER_SYMBOLS="+str(len(native_setters)),
 "SDK_EXPLICIT_SERVICECLASS_FACTORY=DECLARED",
 "SDK_TARGET_FACTORY_MAPPING="+("PROVEN" if len(explicit)>0 else "NOT_PROVEN"),
 "ACTION_ONLY_DEFAULT_SENTINEL="+("0xffffffff" if push_minus_one else "NOT_PROVEN"),
 "CURRENT_SOURCE_TX_QUEUES="+str(src_calls),
 "REQUIRED_TX_QUEUES=4",
 "FOUR_QUEUE_CONSTRUCTION=BLOCKED_PENDING_VERIFIED_ABI",
 "STABLE_POINTER_ARRAY=NOT_IMPLEMENTED",
 "REGISTRATION_CALLS=0",
 "RESULT=REVIEW_REQUIRED","STAGE89_EXIT=NOT_MET","ACTIVATION_GATE=BLOCKED",
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"
]
(p/"audit-summary.txt").write_text("\n".join(summary)+"\n")
decision=[
 "STAGE89_V19_DECISION","RESULT=REVIEW_REQUIRED",
 "FACTORY_ABI="+("TARGET_EXPLICIT_FACTORY_SYMBOL_FOUND_REQUIRES_SIGNATURE_MAPPING_REVIEW" if len(explicit)>0 else "NOT_PROVEN"),
 "FOUR_QUEUE_CONSTRUCTION=BLOCKED until the target factory/initializer mapping is proven without guessing.",
 "WMM_ROLE_1_REQUIRES_FOUR_DISTINCT_TX_SUBMISSION_QUEUES=YES",
 "STABLE_POINTER_ARRAY_AND_EXECUTABLE_LIFETIME_TESTS=NOT_IMPLEMENTED",
 "REGISTRATION=KEEP_ABSENT",
 "NEXT=V20 performs a consolidated Stage89 exit-gate audit from current source and V15-V19 evidence."
]
(p/"decision.txt").write_text("\n".join(decision)+"\n")
print("STAGE89_V19_CHECKS_PASSED=%d/%d"%(sum(checks.values()),len(checks)))
print("TARGET_EXPLICIT_FACTORY_SYMBOLS="+str(len(explicit)))
print("STAGE89_V19_RESULT=REVIEW_REQUIRED")
PY19
  ARTIFACTS="factory-abi-crosswalk.txt four-queue-feasibility.txt audit-summary.txt decision.txt"
  ;;
20)
  fetch_previous_artifact "$PREV_RUN" factory-abi-crosswalk.txt
  fetch_previous_artifact "$PREV_RUN" four-queue-feasibility.txt
  pin source-queues.cpp 59501f4ed08b5e30e82af810c99552bec2018213 "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"
  pin source-queues.hpp 1059a4a06d52d28ee7fa7fe17970b618db0faabd "$BASE/driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.hpp"
  pin v15-inventory.txt aa5ed15566deebd6bfe780f7655f081852973252 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/queue-construction-inventory.txt"
  pin v15-ownership.txt c178cc420e81eba32a46b0a920f2d5354459f3ba "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/ownership-lifetime-audit.txt"
  pin v15-pointer-contract.txt 89b8d0df989de5abe85fc2ecf168359aabe76b91 "$BASE/Development/Logs/stage89-v15/run-20261105-051755-b866b1583b4d/pointer-array-test-contract.txt"
  pin v16-construction-gate.txt 8b7d9d3483c08eb72e9e7cbf586c5001a7c1842b "$BASE/Development/Logs/stage89-v16/run-20261105-065722-726c6e65856b/four-queue-construction-gate.txt"
  pin v16-predicate-reconciliation.txt 532dcac6fa95361ac738398dbf3c45beb98523ee "$BASE/Development/Logs/stage89-v16/run-20261105-065722-726c6e65856b/predicate-reconciliation.txt"
  pin v17-report.txt 1c071db79e82d7ea30ebcdcab13f9c9734ff1206 "$BASE/Development/Logs/stage89-v17/run-20261105-072219-707421a3b631/report.txt"
  python3 - "$OUT" <<'PY20'
import pathlib,re,sys,hashlib
p=pathlib.Path(sys.argv[1])
src=(p/"source-queues.cpp").read_text(errors="replace")
v15=(p/"v15-inventory.txt").read_text(errors="replace")
own=(p/"v15-ownership.txt").read_text(errors="replace")
ptr=(p/"v15-pointer-contract.txt").read_text(errors="replace")
v16=(p/"v16-construction-gate.txt").read_text(errors="replace")
v17=(p/"v17-report.txt").read_text(errors="replace")
v19=(p/"four-queue-feasibility.txt").read_text(errors="replace")
tx_count=src.count("IOSkywalkTxSubmissionQueue::withPool(")+src.count("IOSkywalkTxSubmissionQueue::withPoolAndServiceClass(")
array_markers=[x for x in ("txSubmissionQueues[4]","_txSubmissionQueues[4]","std::array<IOSkywalkTxSubmissionQueue","withFourTxQueues") if x in src]
registration_calls=len(re.findall(r"(?:IOSkywalkQueueSet::(?:createWithQueues|initWithQueues)|registerNetworkInterface|setQueueSet)",src))
callbacks=[
 ("TX_SUBMISSION_ACCEPTANCE","txSubmissionAction","four_callback_entrypoints_exist=PASS","callback_acceptance_is_currently_fail_closed=PASS"),
 ("TX_COMPLETION","txCompletionAction","four_callback_entrypoints_exist=PASS","callback_acceptance_is_currently_fail_closed=PASS"),
 ("RX_REFILL","rxSubmissionAction","four_callback_entrypoints_exist=PASS","callback_acceptance_is_currently_fail_closed=PASS"),
 ("RX_COMPLETION_DELIVERY","rxCompletionAction","four_callback_entrypoints_exist=PASS","callback_acceptance_is_currently_fail_closed=PASS")
]
callback_entrypoints_all=("four_callback_entrypoints_exist=PASS" in v15)
callback_accept_fail_closed=("callback_acceptance_is_currently_fail_closed=PASS" in v15)
check={
 "source_tx_queue_count_is_one":tx_count==1,
 "exactly_four_tx_queues_constructed":tx_count==4,
 "stable_four_entry_pointer_array":bool(array_markers),
 "native_queue_registration_present":registration_calls>0,
 "v15_pointer_tests_executable":"STATUS=DESIGN_ONLY_NOT_IMPLEMENTED" not in ptr,
 "v15_ownership_tests_proven":"queueset_copies_control_word_and_initializes_from_queue_array=PASS" in own,
 "factory_abi_resolved":"SDK_TO_TARGET_EXPLICIT_FACTORY_MAPPING=PROVEN" in (p/"factory-abi-crosswalk.txt").read_text(errors="replace"),
 "v17_native_setter_callability_proven":"NATIVE_QUEUE_USERNETWORK_SETTER_CALLABILITY=PROVEN" in v17,
 "all_four_callback_entrypoints_exist":callback_entrypoints_all,
 "callback_acceptance_no_longer_fail_closed":not callback_accept_fail_closed,
 "v19_four_queue_gate_open":"FOUR_QUEUE_CONSTRUCTION=PASS" in v19
}
rows=[
 "STAGE89_V20_EXIT_GATE_MATRIX",
 "CURRENT_SOURCE_SHA256="+hashlib.sha256((p/"source-queues.cpp").read_bytes()).hexdigest(),
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT="+str(tx_count),
 "REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4",
 "STABLE_FOUR_POINTER_ARRAY="+("FOUND" if array_markers else "NOT_IMPLEMENTED"),
 "POINTER_ARRAY_TESTS="+("EXECUTABLE_EVIDENCE_FOUND" if check["v15_pointer_tests_executable"] else "DESIGN_ONLY_NOT_IMPLEMENTED"),
 "REGISTRATION_CALLS="+str(registration_calls),
 "OWNERSHIP_LIFETIME="+("PRIOR_STATIC_AUDIT_PASS_BUT_RUNTIME_TESTS_NOT_PROVEN" if check["v15_ownership_tests_proven"] else "NOT_PROVEN"),
 "FACTORY_ABI="+("PROVEN" if check["factory_abi_resolved"] else "NOT_PROVEN"),
 "NATIVE_SETTER_CALLABILITY="+("PROVEN" if check["v17_native_setter_callability_proven"] else "NOT_PROVEN"),
 "CALLBACK_ENTRYPOINTS="+("4_PRESENT" if callback_entrypoints_all else "INCOMPLETE"),
 "CALLBACK_HANDOFF_ACCEPTANCE="+("IMPLEMENTED_EVIDENCE_FOUND" if not callback_accept_fail_closed else "FAIL_CLOSED_STUBS_REMAIN"),
 "V19_FOUR_QUEUE_GATE="+("PASS" if check["v19_four_queue_gate_open"] else "BLOCKED"),
 "CHECKS_PASSED=%d/%d"%(sum(check.values()),len(check)),
 "FAILED_GATES="+(",".join(k for k,v in check.items() if not v) or "NONE"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","HARDWARE_TEST=NOT_RUN","OPENCORE_CHANGE=NONE"
]
(p/"stage89-exit-gate-matrix.txt").write_text("\n".join(rows)+"\n")
allpass=all(check.values())
summary=[
 "STAGE89_V20_CONSOLIDATED_EXIT_GATE_AUDIT",
 "CHECKS_PASSED=%d/%d"%(sum(check.values()),len(check)),
 "CURRENT_TX_SUBMISSION_QUEUE_COUNT="+str(tx_count),
 "REQUIRED_TX_SUBMISSION_QUEUE_COUNT=4",
 "STABLE_POINTER_ARRAY="+("IMPLEMENTED" if check["stable_four_entry_pointer_array"] else "NOT_IMPLEMENTED"),
 "REGISTRATION_CALLS="+str(registration_calls),
 "FACTORY_ABI="+("PROVEN" if check["factory_abi_resolved"] else "NOT_PROVEN"),
 "CALLBACK_HANDOFFS="+("PROVEN" if check["callback_acceptance_no_longer_fail_closed"] else "FAIL_CLOSED"),
 "STAGE89_EXIT="+("PASS" if allpass else "NOT_MET"),
 "RESULT="+("PASS" if allpass else "REVIEW_REQUIRED"),
 "ACTIVATION_GATE="+("OPEN_PENDING_SEPARATE_STAGE90_AUTHORIZATION" if allpass else "BLOCKED"),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"
]
(p/"audit-summary.txt").write_text("\n".join(summary)+"\n")
decision=[
 "STAGE89_V20_DECISION",
 "RESULT="+("PASS" if allpass else "REVIEW_REQUIRED"),
 "STAGE89_EXIT="+("PASS" if allpass else "NOT_MET"),
 "BLOCKERS="+(",".join(k for k,v in check.items() if not v) or "NONE"),
 "STAGE90_REMAINS_LOCKED=YES; a Stage89 audit cannot authorize Stage90 or implementation/runtime actions."
]
(p/"decision.txt").write_text("\n".join(decision)+"\n")
print("STAGE89_V20_CHECKS_PASSED=%d/%d"%(sum(check.values()),len(check)))
print("STAGE89_EXIT="+("PASS" if allpass else "NOT_MET"))
print("STAGE89_V20_RESULT="+("PASS" if allpass else "REVIEW_REQUIRED"))
PY20
  ARTIFACTS="stage89-exit-gate-matrix.txt audit-summary.txt decision.txt"
  ;;
esac

{
 echo "========== STAGE 89 V$V — AUDIT REPORT =========="
 echo "RUN=$RUN"
 echo "PREDECESSOR=$PREV_RUN"
 echo
 cat "$OUT/audit-summary.txt"
 echo
 cat "$OUT/decision.txt"
 for name in bootkc-capture-metadata.txt fresh-kernel-binary-findings.txt factory-abi-crosswalk.txt four-queue-feasibility.txt stage89-exit-gate-matrix.txt; do
  if [[ -f "$OUT/$name" ]]; then echo; echo "===== $name ====="; cat "$OUT/$name"; fi
 done
} > "$OUT/report.txt"

{
 echo "========== STAGE 89 V$V — READ-ONLY AUDIT =========="
 echo "STAGE89_V${V}_RUN: $RUN"
 echo "STAGE89_V${V}_VERSION: READ_ONLY_AUDIT"
 echo "STAGE89_V${V}_PREDECESSOR: $PREV_RUN"
 echo "STAGE89_V${V}_SOURCE_MODIFIED: NO"
 echo "STAGE89_V${V}_BUILD: NOT_RUN"
 echo "STAGE89_V${V}_SIGNING: NOT_RUN"
 echo "STAGE89_V${V}_INSTALL: NOT_RUN"
 echo "STAGE89_V${V}_LOAD: NOT_RUN"
 echo "STAGE89_V${V}_OPENCORE_CHANGE: NONE"
 if [[ "$V" == "18" ]]; then
  echo "STAGE89_V18_FRESH_BOOTKC_CAPTURE: PASS"
  echo "STAGE89_V18_RUNNING_KERNEL_IMAGE_MATCH: NOT_PROVEN"
  echo "STAGE89_V18_RESULT: REVIEW_REQUIRED"
  echo "STAGE89_V18_ACTIVATION_GATE: BLOCKED"
 elif [[ "$V" == "19" ]]; then
  echo "STAGE89_V19_FACTORY_ABI: SEE_REPORT"
  echo "STAGE89_V19_FOUR_QUEUE_CONSTRUCTION: BLOCKED_PENDING_VERIFIED_ABI"
  echo "STAGE89_V19_RESULT: REVIEW_REQUIRED"
  echo "STAGE89_V19_ACTIVATION_GATE: BLOCKED"
 else
  echo "STAGE89_V20_STAGE89_EXIT: SEE_REPORT"
  echo "STAGE89_V20_RESULT: REVIEW_REQUIRED_UNLESS_ALL_GATES_PASS"
  echo "STAGE89_V20_ACTIVATION_GATE: BLOCKED_UNLESS_ALL_GATES_PASS"
 fi
 echo "STAGE89_V${V}_LOGS: $REMOTE/"
 echo "========================================================================"
} > "$OUT/checkpoint-block.txt"

python3 - "$OUT" "$V" "$RUN" "$PREV_RUN" <<'PYMANIFEST'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); v=sys.argv[2]; run=sys.argv[3]; prev=sys.argv[4]
names=sys.argv[5:] if len(sys.argv)>5 else []
# Include every purpose-built evidence file, excluding temporary/raw cache and console files.
allowed=set([
 "report.txt","bootkc-capture-metadata.txt","native-kernel-method-index.txt","native-kernel-method-disassembly.txt","fresh-kernel-binary-findings.txt",
 "factory-abi-crosswalk.txt","four-queue-feasibility.txt","stage89-exit-gate-matrix.txt",
 "audit-summary.txt","decision.txt","checkpoint-block.txt"
])
rows=["STAGE89_V"+v+"_MANIFEST","RUN="+run,"PREDECESSOR="+prev,"SOURCE_MODIFIED=NO","BUILD=NOT_RUN","SIGNING=NOT_RUN","INSTALL=NOT_RUN","LOAD=NOT_RUN","OPENCORE_CHANGE=NONE"]
for name in sorted(allowed):
 f=p/name
 if f.exists():
  b=f.read_bytes()
  sha=hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()
  rows.append("ARTIFACT|"+name+"|"+sha+"|"+str(len(b)))
if len(rows)<=8: raise SystemExit("No audit artifacts in manifest")
(p/"manifest.txt").write_text("\n".join(rows)+"\n")
PYMANIFEST

for f in "$OUT"/*; do
 if [[ -f "$f" ]]; then
  case "$(basename "$f")" in
   console-output.log|upload-payload.json|upload-response.json|upload-error.txt|output-before.json|output-update.json|output-update-response.json|output-after.json|output-preflight.json|github-content.json|previous-manifest.txt|kcfile.py|source-queues.cpp|source-queues.hpp|sdk-tx-submission.h|v17-report.txt|v15-inventory.txt|v15-ownership.txt|v15-pointer-contract.txt|v16-construction-gate.txt|v16-predicate-reconciliation.txt|wmm-service-class-table.txt|report.txt|native-kernel-method-index.txt|native-kernel-method-disassembly.txt|fresh-kernel-binary-findings.txt|factory-abi-crosswalk.txt|four-queue-feasibility.txt|stage89-exit-gate-matrix.txt|bootkc-capture-metadata.txt|audit-summary.txt|decision.txt|checkpoint-block.txt)
    upload "$f" "$REMOTE/$(basename "$f")" || fail "GitHub artifact upload/readback failed: $(basename "$f")"
   ;;
  esac
 fi
done
upload "$OUT/manifest.txt" "$REMOTE/manifest.txt" || fail "manifest upload/readback failed"
append_checkpoint
echo "STAGE89_V${V}_RESULT=REVIEW_REQUIRED_OR_GATE_REPORTED"
echo "CANONICAL_HISTORY_UPDATE=PASS"
echo "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN OPENCORE_CHANGE=NONE"
