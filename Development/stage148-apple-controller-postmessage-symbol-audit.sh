#!/bin/bash
# Stage148: resolve the Apple IO80211Controller::postMessage base-class method used by postWCLMessage.
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
WORK="$(mktemp -d "$TMPROOT/stage148-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage148-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE148_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE148 APPLE CONTROLLER POSTMESSAGE SYMBOL AUDIT =========="
 echo "STAGE148_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE148_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE148_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE148_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE148_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE148_SCOPE=READ_ONLY_RESOLVE_APPLE_BASE_POSTMESSAGE_SYMBOL_AND_FORWARDING_DECLARATION"
 echo "STAGE148_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE148_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE148_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$ROOT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE148_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; root=pathlib.Path(sys.argv[3])
needle="postMessage"
candidates=[]
for addr,name in kc.syms.items():
 if needle in name and ("IO80211Controller" in name or name=="__ZN17IO80211Controller11postMessageEP23IO80211SkywalkInterfacejPvmb"):
  candidates.append((addr,name,kc.sym_owner.get(addr),kc.owner(addr)))
print("STAGE148_FILES_BASE=0x%x"%kc.base)
print("STAGE148_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE148_SYMBOL_COUNT=%d"%len(kc.syms))
print("APPLE_CONTROLLER_POSTMESSAGE_CANDIDATE_COUNT=%d"%len(candidates))
for addr,name,symowner,owner in sorted(candidates):
 print("APPLE_POSTMESSAGE_SYMBOL ADDRESS=0x%x NAME=%s SYMBOL_OWNER=%s OWNER=%s"%(addr,name,symowner or "UNATTRIBUTED",owner or "UNATTRIBUTED"))
target="__ZN17IO80211Controller11postMessageEP23IO80211SkywalkInterfacejPvmb"
exact=[x for x in candidates if x[1]==target]
print("APPLE_CONTROLLER_POSTMESSAGE_EXACT_SYMBOL=%s"%("FOUND" if exact else "NOT_FOUND"))
owners={x[2] for x in exact if x[2]}
for bid,_,_ in kc.entries:
 if bid not in owners: continue
 dest=pathlib.Path(os.environ["STAGE148_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",bid)+".macho")
 if bid not in kc.entry_segs:
  print("APPLE_POSTMESSAGE_OWNER_IMAGE=%s STATUS=NOT_A_CARVED_FILESET_ENTRY"%bid); continue
 kc.carve(bid,str(dest))
 for addr,name,symowner,owner in exact:
  end=kc.next_sym(addr) or addr+0x1000
  if end<=addr or end>addr+0x1000: end=addr+0x1000
  p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,str(dest)],capture_output=True,text=True)
  print("METHOD_SYMBOL="+name);print("METHOD_ADDRESS=0x%x"%addr)
  print("METHOD_OWNER="+bid);print("METHOD_NEXT_SYMBOL_BOUND=0x%x"%end)
  print("OTOOL_EXIT=%d"%p.returncode)
  if p.returncode: print("METHOD_DISASSEMBLY=FAILED");continue
  ins=[]
  for line in p.stdout.splitlines():
   m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
   if m:
    a=int(m.group(1),16)
    if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
  if not ins or ins[0][0]!=addr: print("METHOD_DISASSEMBLY=NOT_VERIFIED");continue
  print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("INSTRUCTION_COUNT=%d"%len(ins))
  for a,raw,asm in ins:
   print(raw)
   if re.search(r"\b(call|jmp)q?\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
print("\n--- Local ABI declaration and helper call context ---")
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
checks=[
 ("RTW88WCL24H32ABI.hpp",r"\bpostMessage\s*\(",12),
 ("RTW88WCLInfraInterface.hpp",r"\bpostWCLMessage\s*\(",12),
 ("RTW88WCLInfraInterface.cpp",r"RTW88WCLInfraInterface::postWCLMessage\s*\(",14),
 ("RTW88WCLController.hpp",r"\bclass\s+RTW88WCLController\b",12)
]
for filename,pattern,radius in checks:
 p=base/filename
 if not p.exists(): print("SOURCE_FILE=%s STATUS=NOT_FOUND"%filename);continue
 data=p.read_bytes();lines=data.decode("utf-8","replace").splitlines()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(filename,hashlib.sha256(data).hexdigest(),len(data)))
 for i,line in enumerate(lines):
  if re.search(pattern,line):
   print("SOURCE_MATCH=%s:%d:%s"%(filename,i+1,line.strip()))
   for j in range(max(0,i-3),min(len(lines),i+radius)):
    print("%05d %s"%(j+1,lines[j]))
   print("SOURCE_CONTEXT_END")
abi=(base/"RTW88WCL24H32ABI.hpp").read_text(errors="replace")
m=re.search(r"(?m)^\s*(virtual\s+)?IOReturn\s+postMessage\s*\(",abi)
print("APPLE_BASE_POSTMESSAGE_DECLARATION=%s"%("FOUND" if m else "NOT_FOUND"))
print("APPLE_BASE_POSTMESSAGE_DECLARATION_VIRTUAL=%s"%("YES" if m and m.group(1) else "NO" if m else "UNKNOWN"))
impl=(base/"RTW88WCLController.cpp").read_text(errors="replace")
print("DRIVER_CONTROLLER_POSTMESSAGE_OVERRIDE=%s"%("YES" if re.search(r"RTW88WCLController::postMessage\s*\(",impl) else "NO"))
print("STAGE148_INTERPRETATION=SYMBOL_AND_SOURCE_CORRELATION_ONLY; NO_COMPILED_DRIVER_CALLSITE_OR_RUNTIME_PROOF")
PY
 echo "STAGE148_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE148_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE148 =========="
} >"$REPORT"
echo "===== STAGE148 SUMMARY ====="
grep -aE '^(STAGE148_|APPLE_CONTROLLER_POSTMESSAGE|APPLE_POSTMESSAGE_SYMBOL |METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=|SOURCE_FILE=|SOURCE_MATCH=|APPLE_BASE_POSTMESSAGE|DRIVER_CONTROLLER_POSTMESSAGE_OVERRIDE=)' "$REPORT" | head -180 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage148-apple-controller-postmessage-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage148: publish read-only Apple controller postMessage symbol audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE148_UPLOAD_SHA="+actual);print("STAGE148_GITHUB_PATH="+dest);print("STAGE148_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE148_UPLOAD_SHA="+existing);print("STAGE148_GITHUB_PATH="+dest);print("STAGE148_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE148_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE148_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE148_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
