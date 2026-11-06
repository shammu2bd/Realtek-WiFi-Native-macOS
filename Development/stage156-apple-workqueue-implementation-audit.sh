#!/bin/bash
# Stage156: inspect AppleBCMWLANCore's concrete IO80211WorkQueue implementation and lifetime.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE155_PATH="Development/Logs/stage155-workqueue-abi-20261106T213725Z.log"
STAGE155_SHA="558c1444ddc90924ef06dcf134fa48eaeb79b20e"
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
WORK="$(mktemp -d "$TMPROOT/stage156-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage156-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE155_PATH?ref=main" > "$WORK/stage155.json"
python3 - "$WORK/stage155.json" "$STAGE155_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE156_STAGE155_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage155 report blob SHA mismatch")
print("STAGE155_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE156_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE156 APPLE BCMWLAN WORKQUEUE IMPLEMENTATION AUDIT =========="
 echo "STAGE156_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE156_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE156_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE156_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE156_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE156_STAGE155_REPORT_SHA=$STAGE155_SHA"
 echo "STAGE156_SCOPE=READ_ONLY_DISASSEMBLE_APPLEBCMWLANCORE_WORKQUEUE_OVERRIDES_AND_LIFETIME"
 echo "STAGE156_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE156_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE156_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE156_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]);otool=sys.argv[2]
cls="AppleBCMWLANCore"
owner="com.apple.driver.AppleBCMWLANCoreMac"
actual=kc.find("__ZTV%d%s"%(len(cls),cls))
size=kc.metaclass_size(cls)
print("APPLE_CORE_VTABLE=%s"%("0x%x"%actual if actual else "NOT_FOUND"))
print("APPLE_CORE_INSTANCE_SIZE=%s"%(size if size is not None else "UNKNOWN"))
print("APPLE_CORE_OWNER_SYMBOL=%s"%(kc.sym_owner.get(actual,"UNKNOWN") if actual else "UNKNOWN"))
vt=kc.vtable(cls)
print("APPLE_CORE_VTABLE_WORDS=%d"%(len(vt) if vt else 0))
if vt:
 for off in (0xC58,0xC68,0xDC0):
  idx=2+off//8
  if idx<len(vt):
   _i,raw,target,name=vt[idx]
   print("APPLE_CORE_VTABLE_SLOT OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(off,idx,raw,target,kc.owner(target) or "UNATTRIBUTED",name))
# Exact expected overrides.
names=[
"__ZN16AppleBCMWLANCore15createWorkQueueEv",
"__ZNK16AppleBCMWLANCore12getWorkQueueEv",
]
# Inventory AppleBCMWLANCore methods and relevant superclass/queue methods.
all_core=kc.methods(cls)
print("APPLE_CORE_METHOD_COUNT=%d"%len(all_core))
for a,n in all_core:
 if any(k in n for k in ("WorkQueue","workQueue","start","stop","free","init","C1E","C2E","D1E","D2E","MetaClass")):
  print("APPLE_CORE_RELEVANT_SYMBOL ADDRESS=0x%x NAME=%s OWNER=%s"%(a,n,kc.sym_owner.get(a,"UNKNOWN")))
for n in names:
 a=kc.find(n)
 print("APPLE_CORE_OVERRIDE_SYMBOL NAME=%s ADDRESS=%s OWNER=%s"%(n,("0x%x"%a) if a else "NOT_FOUND",kc.sym_owner.get(a,"UNKNOWN") if a else "UNKNOWN"))
 if a and kc.sym_owner.get(a)!=owner:
  print("APPLE_CORE_OVERRIDE_OWNER_MISMATCH NAME=%s EXPECTED=%s ACTUAL=%s"%(n,owner,kc.sym_owner.get(a)))
# Confirm the actual fileset owner before carving.
if not any(kc.sym_owner.get(kc.find(n))==owner for n in names if kc.find(n)):
 raise SystemExit("Expected AppleBCMWLANCore override not found in expected fileset")
image=os.path.join(os.environ["STAGE156_WORK"],"AppleBCMWLANCore.macho")
kc.carve(owner,image)
def dump(addr,name,tag,limit=0x3000,full=True):
 if not addr or not name: print("METHOD_SKIP TAG=%s"%tag);return
 end=kc.next_sym(addr) or addr+limit
 if end<=addr or end>addr+limit:end=addr+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,name,p.stderr.strip()[:300]));return
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end:ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s ADDRESS=0x%x"%(tag,name,addr));return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,addr,end,len(ins)))
 for i,(a,raw,asm) in enumerate(ins):
  if full or i<16 or re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b|WorkQueue|workQueue|retain|release|0xc58|0xc68",asm,re.I):
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
for n in names:
 a=kc.find(n)
 if a:dump(a,n,"APPLE_CORE_WORKQUEUE_OVERRIDE",0x1800,True)
# Dump all lifecycle methods in class to identify queue construction/storage/destruction.
for a,n in all_core:
 if any(k in n for k in ("C1E","C2E","D0E","D1E","D2E","init","start","stop","free","WorkQueue","workQueue")):
  if n in names: continue
  dump(a,n,"APPLE_CORE_LIFECYCLE",0x1800,False)
# Search entire AppleBCMWLANCore symbol map for workqueue-related methods even if class methods have different owner naming.
bundle_syms=sorted((a,n) for a,n in kc.syms.items() if kc.sym_owner.get(a)==owner)
related=[(a,n) for a,n in bundle_syms if "WorkQueue" in n or "workQueue" in n]
print("\nAPPLE_CORE_BUNDLE_SYMBOL_COUNT=%d"%len(bundle_syms))
print("APPLE_CORE_WORKQUEUE_SYMBOL_COUNT=%d"%len(related))
for a,n in related[:160]:print("APPLE_CORE_WORKQUEUE_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
# Verify base class returns null and shared IO80211WorkQueue allocator exists in IO80211Family.
io_owner="com.apple.iokit.IO80211Family"
io_img=os.path.join(os.environ["STAGE156_WORK"],"IO80211Family.macho")
kc.carve(io_owner,io_img)
for n in ("__ZN17IO80211Controller15createWorkQueueEv","__ZNK17IO80211Controller12getWorkQueueEv","__ZN16IO80211WorkQueue9workQueueEv"):
 a=kc.find(n)
 print("APPLE_BASE_OR_FACTORY_SYMBOL NAME=%s ADDRESS=%s OWNER=%s"%(n,("0x%x"%a) if a else "NOT_FOUND",kc.sym_owner.get(a,"UNKNOWN") if a else "UNKNOWN"))
 if a:
  p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",n,io_img],capture_output=True,text=True)
  if p.returncode==0:
   print("APPLE_BASE_OR_FACTORY_DISASSEMBLY NAME=%s\n%s"%(n,"\n".join(p.stdout.splitlines()[:100])))
print("\nSTAGE156_INTERPRETATION=APPLE_DRIVER_STATIC_IMPLEMENTATION_ONLY; DO_NOT_COPY_PRIVATE_DRIVER_OWNERSHIP_PATTERN_WITHOUT_FULL_RUNTIME_AND_API_VALIDATION")
PY
 echo "STAGE156_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE156_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE156 =========="
} >"$REPORT"
echo "===== STAGE156 SUMMARY ====="
grep -aE '^(STAGE156_|STAGE155_REPORT_INTEGRITY=|APPLE_CORE_VTABLE=|APPLE_CORE_INSTANCE_SIZE=|APPLE_CORE_OWNER_SYMBOL=|APPLE_CORE_VTABLE_WORDS=|APPLE_CORE_VTABLE_SLOT |APPLE_CORE_METHOD_COUNT=|APPLE_CORE_RELEVANT_SYMBOL |APPLE_CORE_OVERRIDE_SYMBOL |APPLE_CORE_OVERRIDE_OWNER_MISMATCH |METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|APPLE_CORE_BUNDLE_SYMBOL_COUNT=|APPLE_CORE_WORKQUEUE_SYMBOL_COUNT=|APPLE_CORE_WORKQUEUE_SYMBOL |APPLE_BASE_OR_FACTORY_SYMBOL |APPLE_BASE_OR_FACTORY_DISASSEMBLY |STAGE156_INTERPRETATION=)' "$REPORT" | head -480 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage156-apple-workqueue-implementation-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage156: publish read-only Apple workqueue implementation audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE156_UPLOAD_SHA="+actual);print("STAGE156_GITHUB_PATH="+dest);print("STAGE156_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE156_UPLOAD_SHA="+existing);print("STAGE156_GITHUB_PATH="+dest);print("STAGE156_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE156_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE156_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE156_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
