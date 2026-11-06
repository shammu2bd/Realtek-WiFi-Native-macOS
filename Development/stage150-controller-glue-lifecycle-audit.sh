#!/bin/bash
# Stage150: trace Apple controller expansion glue-pointer initialization/lifecycle and IO80211Glue creation.
# READ ONLY. No checkout/source/index changes, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage150-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage150-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE150_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE150 CONTROLLER GLUE LIFECYCLE AUDIT =========="
 echo "STAGE150_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE150_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE150_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE150_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE150_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE150_SCOPE=READ_ONLY_TRACE_CONTROLLER_EXPANSION_B08_GLUE_POINTER_SETUP_AND_GLUE_LIFECYCLE"
 echo "STAGE150_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE150_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE150_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$ROOT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE150_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]);otool=sys.argv[2];root=pathlib.Path(sys.argv[3])
all_symbols=[]
for addr,name in kc.syms.items():
 if ("IO80211Controller" in name or "IO80211Glue" in name) and kc.sym_owner.get(addr)=="com.apple.iokit.IO80211Family":
  all_symbols.append((addr,name,kc.sym_owner[addr]))
def interesting(name):
 return any(x in name for x in ("C1","C2","D1","D2","init","start","free","stop","setup","create","postMessage"))
candidates=[x for x in all_symbols if interesting(x[1])]
print("STAGE150_FILES_BASE=0x%x"%kc.base)
print("STAGE150_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE150_SYMBOL_COUNT=%d"%len(kc.syms))
print("APPLE_CONTROLLER_GLUE_SYMBOL_COUNT=%d"%len(all_symbols))
print("APPLE_LIFECYCLE_CANDIDATE_COUNT=%d"%len(candidates))
for addr,name,owner in candidates:
 group="CONTROLLER" if "IO80211Controller" in name else "GLUE"
 print("LIFECYCLE_CANDIDATE GROUP=%s ADDRESS=0x%x SYMBOL=%s OWNER=%s"%(group,addr,name,owner))
# Vtable identities relevant to the controller's base postMessage relay.
for cls in ("IO80211Glue","CommonGlue","IO80211Controller"):
 vt=kc.vtable(cls)
 print("VTABLE CLASS=%s STATUS=%s"%(cls,"FOUND" if vt is not None else "NOT_FOUND"))
 if vt:
  for off in (0x120,0x128):
   word=2+off//8;e=next((x for x in vt if x[0]==word),None)
   if e:
    idx,raw,target,near=e
    print("VTABLE_SLOT CLASS=%s OFFSET=0x%x TARGET=0x%x OWNER=%s EXACT=%s NEAREST=%s"%(cls,off,target,kc.owner(target) or "UNATTRIBUTED",kc.syms.get(target) or "NONE",near))
# Disassemble only bounded candidate methods; print complete instructions that touch expansion offsets,
# construct/init/release glue, or call other relevant glue/controller methods.
owner="com.apple.iokit.IO80211Family"
dest=pathlib.Path(os.environ["STAGE150_WORK"])/"IO80211Family.macho"
kc.carve(owner,str(dest))
for addr,name,symowner in candidates:
 end=kc.next_sym(addr) or addr+0x3000
 if end<=addr or end>addr+0x3000:end=addr+0x3000
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,str(dest)],capture_output=True,text=True)
 if p.returncode: print("METHOD_SYMBOL=%s DISASSEMBLY=FAILED"%name);continue
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end:ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr:
  print("METHOD_SYMBOL=%s DISASSEMBLY=NOT_VERIFIED"%name);continue
 selected=[]
 for i,item in enumerate(ins):
  a,raw,asm=item
  if (i<12 or re.search(r"0xb08|0x120|IO80211Glue|IO80211Controller|CommonGlue|postMessage|create|release|setObject|set.*Glue|Glue.*set",asm,re.I)
      or re.search(r"\b(call|jmp)q?\b",asm)):
   selected.append(item)
 print("\nMETHOD_SYMBOL="+name)
 print("METHOD_ADDRESS=0x%x"%addr)
 print("METHOD_END_BOUND=0x%x"%end)
 print("METHOD_INSTRUCTION_COUNT=%d"%len(ins))
 print("METHOD_SELECTED_INSTRUCTIONS=%d"%len(selected))
 for a,raw,asm in selected:
  print(raw)
  if re.search(r"\b(call|jmp)q?\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
# Local source only inventories references, useful to establish no accidental edits to the tree.
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
for filename in ("RTW88WCL24H32ABI.hpp","RTW88WCLController.hpp","RTW88WCLController.cpp","RTW88WCLInfraInterface.cpp"):
 p=base/filename
 if not p.exists():continue
 data=p.read_bytes();lines=data.decode("utf-8","replace").splitlines()
 print("\nSOURCE_FILE=%s SHA256=%s BYTES=%d"%(filename,hashlib.sha256(data).hexdigest(),len(data)))
 for i,line in enumerate(lines):
  if re.search(r"IO80211Glue|postMessage|postWCLMessage|b08|B08",line,re.I):
   print("SOURCE_MATCH=%s:%d:%s"%(filename,i+1,line.strip()))
print("STAGE150_INTERPRETATION=STATIC_APPLE_LIFECYCLE_MAPPING_ONLY; NO_RUNTIME_POINTER_VALUE")
PY
 echo "STAGE150_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE150_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE150 =========="
} >"$REPORT"
echo "===== STAGE150 SUMMARY ====="
grep -aE '^(STAGE150_|APPLE_CONTROLLER_GLUE_SYMBOL_COUNT=|APPLE_LIFECYCLE_CANDIDATE_COUNT=|LIFECYCLE_CANDIDATE |VTABLE CLASS=|VTABLE_SLOT |METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_END_BOUND=|METHOD_INSTRUCTION_COUNT=|METHOD_SELECTED_INSTRUCTIONS=|CONTROL_FLOW=|SOURCE_FILE=|SOURCE_MATCH=)' "$REPORT" | head -260 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage150-controller-glue-lifecycle-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage150: publish read-only controller glue lifecycle audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE150_UPLOAD_SHA="+actual);print("STAGE150_GITHUB_PATH="+dest);print("STAGE150_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE150_UPLOAD_SHA="+existing);print("STAGE150_GITHUB_PATH="+dest);print("STAGE150_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE150_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE150_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE150_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
