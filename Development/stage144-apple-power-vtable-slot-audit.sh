#!/bin/bash
# Stage144: resolve Apple POWER controller dispatch vtable slots against 24H32 BootKC ABI.
# READ ONLY. No source edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || echo /tmp)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage144-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage144-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE144_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE144 APPLE POWER VTABLE SLOT RESOLUTION =========="
 echo "STAGE144_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE144_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE144_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE144_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE144_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE144_SCOPE=READ_ONLY_EXACT_CONTROLLER_AND_INTERFACE_VTABLE_SLOT_RESOLUTION"
 echo "STAGE144_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE144_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE144_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$ROOT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE144_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; root=pathlib.Path(sys.argv[3])
slots={
 "IO80211SkywalkInterface":(0xBA8,0xCC0),
 "IO80211InfraInterface":(0xBA8,0xCC0),
 "IO80211Controller":(0xCD8,0xCE0,0xB10)
}
resolved={}
print("STAGE144_FILES_BASE=0x%x"%kc.base)
print("STAGE144_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE144_SYMBOL_COUNT=%d"%len(kc.syms))
for cls,offsets in slots.items():
 vt=kc.vtable(cls)
 print("\nCLASS=%s VTABLE_STATUS=%s"%(cls,"FOUND" if vt is not None else "NOT_FOUND"))
 if vt is None: continue
 for off in offsets:
  word=2+off//8
  entry=next((x for x in vt if x[0]==word),None)
  if not entry:
   print("VTABLE_SLOT CLASS=%s OBJECT_OFFSET=0x%x STATUS=NOT_FOUND"%(cls,off));continue
  idx,raw,target,name=entry
  owner=kc.owner(target); exact=kc.syms.get(target); symowner=kc.sym_owner.get(target)
  print("VTABLE_SLOT CLASS=%s OBJECT_OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL_OWNER=%s EXACT_SYMBOL=%s NEAREST=%s"%(cls,off,idx,raw,target,owner or "UNATTRIBUTED",symowner or "UNATTRIBUTED",exact or "NONE",name))
  if exact and symowner:
   resolved[target]=(exact,symowner)
print("\n--- Controller callback declaration review in local 24H32 ABI source ---")
abi=root/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
controller_abi=root/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32ABI.hpp"
controller=root/"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp"
if abi.exists() and controller_abi.exists() and controller.exists():
 for p in (abi,controller_abi,controller):
  d=p.read_bytes();print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(p.relative_to(root),hashlib.sha256(d).hexdigest(),len(d)))
 text=controller_abi.read_text(errors="replace")
 m=re.search(r"\bclass\s+IO80211Controller\b",text)
 if m:
  op=text.find("{",m.end()); depth=0; end=None
  for i in range(op,len(text)):
   if text[i]=="{":depth+=1
   elif text[i]=="}":
    depth-=1
    if depth==0:end=i;break
  body=text[m.start():end+1] if end else text[m.start():]
  lines=body.splitlines()
  for i,line in enumerate(lines):
   if re.search(r"\b(getPOWER|setPOWER)\s*\(",line):
    print("ABI_CONTROLLER_DECLARATION="+line.strip())
 else: print("ABI_CONTROLLER_CLASS=NOT_FOUND_IN_RT WCL24H32ABI")
 h=controller.read_text(errors="replace")
 m=re.search(r"\bclass\s+RTW88WCLController\b",h)
 if m:
  op=h.find("{",m.end());depth=0;end=None
  for i in range(op,len(h)):
   if h[i]=="{":depth+=1
   elif h[i]=="}":
    depth-=1
    if depth==0:end=i;break
  body=h[m.start():end+1] if end else h[m.start():]
  for line in body.splitlines():
   if re.search(r"\b(getPOWER|setPOWER)\s*\(",line):print("DRIVER_CONTROLLER_DECLARATION="+line.strip())
 else:print("DRIVER_CONTROLLER_CLASS=NOT_FOUND")
else:
 print("LOCAL_ABI_SOURCE_FILES=NOT_AVAILABLE")
print("\n--- Bounded disassembly for resolved controller dispatch targets ---")
owner_paths={}
for bid,_,_ in kc.entries:
 if bid in {v[1] for v in resolved.values()}:owner_paths[bid]=pathlib.Path(os.environ["STAGE144_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",bid)+".macho")
for owner,dest in owner_paths.items():
 kc.carve(owner,str(dest))
 for addr,(name,_) in sorted(resolved.items()):
  if kc.sym_owner.get(addr)!=owner:continue
  if name.startswith("_") and not name.startswith("__Z"):continue
  end=kc.next_sym(addr) or addr+0x1000
  if end<=addr or end>addr+0x1000:end=addr+0x1000
  p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,str(dest)],capture_output=True,text=True)
  print("\nMETHOD_SYMBOL="+name)
  print("METHOD_ADDRESS=0x%x"%addr);print("METHOD_OWNER="+owner)
  print("METHOD_END_BOUND=0x%x"%end);print("OTOOL_EXIT=%d"%p.returncode)
  if p.returncode:print("METHOD_DISASSEMBLY=FAILED");continue
  ins=[]
  for line in p.stdout.splitlines():
   mm=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
   if mm:
    a=int(mm.group(1),16)
    if addr<=a<end:ins.append((a,line.strip(),mm.group(2)))
  if not ins or ins[0][0]!=addr:print("METHOD_DISASSEMBLY=NOT_VERIFIED");continue
  print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("INSTRUCTION_COUNT=%d"%len(ins))
  for a,raw,asm in ins:
   print(raw)
   if re.search(r"\b(call|jmp)q?\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
else:
 print("STAGE144_DISPATCH_IDENTITY_POLICY=EXACT_VTABLE_ENTRY_AND_SYMBOL_OWNERSHIP")
print("STAGE144_INTERPRETATION=STATIC_ABI_MAPPING_ONLY")
PY
 echo "STAGE144_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE144_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE144 =========="
} >"$REPORT"
echo "===== STAGE144 SUMMARY ====="
grep -aE '^(STAGE144_|CLASS=|VTABLE_SLOT |SOURCE_FILE=|ABI_CONTROLLER_DECLARATION=|DRIVER_CONTROLLER_DECLARATION=|METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=)' "$REPORT" | head -220 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage144-apple-power-vtable-slots-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage144: publish read-only Apple POWER vtable slot resolution","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE144_UPLOAD_SHA="+actual);print("STAGE144_GITHUB_PATH="+dest);print("STAGE144_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE144_UPLOAD_SHA="+existing);print("STAGE144_GITHUB_PATH="+dest);print("STAGE144_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE144_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE144_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE144_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
