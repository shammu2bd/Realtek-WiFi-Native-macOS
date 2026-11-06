#!/bin/bash
# Stage157: trace Apple bus-interface workqueue callbacks and IO80211WorkQueue lifecycle.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload,
# hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE156_PATH="Development/Logs/stage156-apple-workqueue-implementation-20261106T213942Z.log"
STAGE156_SHA="3f0b188f672f2c290787dad2c701bd48a0becb63"
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
WORK="$(mktemp -d "$TMPROOT/stage157-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage157-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE156_PATH?ref=main" > "$WORK/stage156.json"
python3 - "$WORK/stage156.json" "$STAGE156_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE157_STAGE156_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage156 report blob SHA mismatch")
print("STAGE156_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE157_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE157 APPLE BUS WORKQUEUE CONTRACT AUDIT =========="
 echo "STAGE157_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE157_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE157_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE157_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE157_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE157_STAGE156_REPORT_SHA=$STAGE156_SHA"
 echo "STAGE157_SCOPE=READ_ONLY_BUS_CALLBACKS_WORKQUEUE_VTABLE_AND_LIFECYCLE"
 echo "STAGE157_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE157_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE157_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE157_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
core_owner="com.apple.driver.AppleBCMWLANCoreMac"
io_owner="com.apple.iokit.IO80211Family"
def owner(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def dump(addr,name,tag,image,limit=0x1800):
 if not addr or not name:
  print("METHOD_SKIP TAG=%s SYMBOL=%s"%(tag,name)); return
 end=kc.next_sym(addr) or addr+limit
 if end<=addr or end>addr+limit:end=addr+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,name,p.stderr.strip()[:250])); return
 rows=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end: rows.append((a,line.strip(),m.group(2)))
 if not rows or rows[0][0]!=addr:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s ADDRESS=0x%x"%(tag,name,addr));return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,addr,end,len(rows)))
 for i,(a,raw,asm) in enumerate(rows):
  if i<12 or re.search(r"call|jmp|ret|release|retain|WorkQueue|workQueue|0x7898|0x1510",asm,re.I):
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm): print("CONTROL_FLOW=0x%x %s"%(a,asm))
def inspect_class(cls, offsets, image, expected_owner=None):
 vt=kc.vtable(cls)
 size=kc.metaclass_size(cls)
 print("\nCLASS_AUDIT NAME=%s INSTANCE_SIZE=%s VTABLE_WORDS=%d VTABLE_OWNER=%s"%(cls,size if size is not None else "UNKNOWN",len(vt) if vt else 0,owner(kc.find("__ZTV%d%s"%(len(cls),cls))) if kc.find("__ZTV%d%s"%(len(cls),cls)) else "UNKNOWN"))
 if not vt:
  print("CLASS_VTABLE_NOT_FOUND NAME="+cls); return
 for off in offsets:
  idx=2+off//8
  if idx>=len(vt):
   print("VTABLE_SLOT_MISSING CLASS=%s OFFSET=0x%x"%(cls,off)); continue
  _i,raw,target,name=vt[idx]
  print("VTABLE_SLOT CLASS=%s OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,idx,raw,target,owner(target),name))
  if expected_owner and owner(target)!=expected_owner:
   print("VTABLE_SLOT_OWNER_REVIEW CLASS=%s OFFSET=0x%x EXPECTED=%s ACTUAL=%s"%(cls,off,expected_owner,owner(target)))
core_img=os.path.join(os.environ["STAGE157_WORK"],"AppleBCMWLANCore.macho")
io_img=os.path.join(os.environ["STAGE157_WORK"],"IO80211Family.macho")
kc.carve(core_owner,core_img); kc.carve(io_owner,io_img)
# The exact callbacks invoked by AppleBCMWLANCore::createWorkQueue through its bus object.
inspect_class("AppleBCMWLANBusInterface",(0x860,0x868),core_img,core_owner)
bus_methods=kc.methods("AppleBCMWLANBusInterface")
print("APPLE_BUS_METHOD_COUNT=%d"%len(bus_methods))
bus_selected=[]
for a,n in bus_methods:
 if any(k in n for k in ("needWorkQueue","getWorkQueue","WorkQueue","workQueue","C1E","C2E","D0E","D1E","D2E","init","start","stop","free")):
  bus_selected.append((a,n))
  print("APPLE_BUS_RELEVANT_SYMBOL ADDRESS=0x%x OWNER=%s NAME=%s"%(a,owner(a),n))
for a,n in bus_selected:
 dump(a,n,"APPLE_BUS_LIFECYCLE",core_img,0x1200)
# WorkQueue vtable mapping is needed for Apple's indirect call through vtable +0x20.
inspect_class("IO80211WorkQueue",(0x20,0x28,0x88,0x90,0xA0),io_img,io_owner)
wq_methods=kc.methods("IO80211WorkQueue")
print("IO80211_WORKQUEUE_METHOD_COUNT=%d"%len(wq_methods))
for a,n in wq_methods:
 if any(k in n for k in ("workQueue","WorkQueue","init","free","C1E","C2E","D0E","D1E","D2E","enable","disable","runAction")):
  print("IO80211_WORKQUEUE_RELEVANT_SYMBOL ADDRESS=0x%x OWNER=%s NAME=%s"%(a,owner(a),n))
  dump(a,n,"IO80211_WORKQUEUE_LIFECYCLE",io_img,0x1000)
# Trace the exact producer and the controller teardown routines in the Apple core image.
core_methods=kc.methods("AppleBCMWLANCore")
for a,n in core_methods:
 if any(k in n for k in ("createWorkQueue","getWorkQueue","freeResources","stopResources","stopAndFreeResources","freeEv")):
  print("APPLE_CORE_QUEUE_LIFECYCLE_SYMBOL ADDRESS=0x%x OWNER=%s NAME=%s"%(a,owner(a),n))
  dump(a,n,"APPLE_CORE_QUEUE_LIFECYCLE",core_img,0x1800)
# Global symbol inventory for similarly named queue callbacks, including possible implementations in sibling bundles.
matches=sorted((a,n) for a,n in kc.syms.items() if any(k in n for k in ("needWorkQueue","getWorkQueue","createWorkQueue","IO80211WorkQueue")) and (("WorkQueue" in n) or ("workQueue" in n)))
print("\nKERNEL_WORKQUEUE_SYMBOL_COUNT=%d"%len(matches))
for a,n in matches[:260]: print("KERNEL_WORKQUEUE_SYMBOL ADDRESS=0x%x OWNER=%s NAME=%s"%(a,owner(a),n))
# Validate Stage156's Apple-core dispatch choice and record the interpretation boundary.
for n in ("__ZN16AppleBCMWLANCore15createWorkQueueEv","__ZNK16AppleBCMWLANCore12getWorkQueueEv"):
 a=kc.find(n)
 print("STAGE156_CORE_CALLBACK_RECHECK NAME=%s ADDRESS=%s OWNER=%s"%(n,("0x%x"%a) if a else "NOT_FOUND",owner(a) if a else "UNKNOWN"))
print("\nSTAGE157_INTERPRETATION=STATIC_ABI_AND_CALLGRAPH_ONLY; DO_NOT_IMPLEMENT_QUEUE_CREATION_OR_OWNERSHIP_FROM_THIS_REPORT_ALONE")
PY
 echo "STAGE157_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE157_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE157 =========="
} >"$REPORT"
echo "===== STAGE157 SUMMARY ====="
grep -aE '^(STAGE157_|STAGE156_REPORT_INTEGRITY=|CLASS_AUDIT |VTABLE_SLOT |VTABLE_SLOT_OWNER_REVIEW |CLASS_VTABLE_NOT_FOUND |APPLE_BUS_METHOD_COUNT=|APPLE_BUS_RELEVANT_SYMBOL |METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|IO80211_WORKQUEUE_METHOD_COUNT=|IO80211_WORKQUEUE_RELEVANT_SYMBOL |APPLE_CORE_QUEUE_LIFECYCLE_SYMBOL |KERNEL_WORKQUEUE_SYMBOL_COUNT=|KERNEL_WORKQUEUE_SYMBOL |STAGE156_CORE_CALLBACK_RECHECK |STAGE157_INTERPRETATION=)' "$REPORT" | head -520 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage157-apple-bus-workqueue-contract-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage157: publish read-only Apple bus workqueue contract audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE157_UPLOAD_SHA="+actual);print("STAGE157_GITHUB_PATH="+dest);print("STAGE157_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE157_UPLOAD_SHA="+existing);print("STAGE157_GITHUB_PATH="+dest);print("STAGE157_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE157_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE157_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE157_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
