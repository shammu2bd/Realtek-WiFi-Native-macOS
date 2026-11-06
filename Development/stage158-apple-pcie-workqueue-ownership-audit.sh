#!/bin/bash
# Stage158: inspect the concrete Apple PCIe bus queue source and ownership path.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload,
# hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE157_PATH="Development/Logs/stage157-apple-bus-workqueue-contract-20261106T214304Z.log"
STAGE157_SHA="46b7200ee8dc3107d3e1f1e3420afe3f53c18bb2"
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
WORK="$(mktemp -d "$TMPROOT/stage158-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage158-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE157_PATH?ref=main" > "$WORK/stage157.json"
python3 - "$WORK/stage157.json" "$STAGE157_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE158_STAGE157_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage157 report blob SHA mismatch")
print("STAGE157_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE158_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE158 APPLE PCIE BUS WORKQUEUE OWNERSHIP AUDIT =========="
 echo "STAGE158_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE158_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE158_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE158_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE158_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE158_STAGE157_REPORT_SHA=$STAGE157_SHA"
 echo "STAGE158_SCOPE=READ_ONLY_PCIE_BUS_QUEUE_CREATION_STORAGE_AND_TEARDOWN"
 echo "STAGE158_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE158_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE158_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE158_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
owners=[
 "com.apple.driver.AppleBCMWLANBusInterfacePCIeMac",
 "com.apple.driver.AppleBCMWLANCoreMac",
 "com.apple.iokit.IO80211Family",
]
images={}
for owner in owners:
 image=os.path.join(os.environ["STAGE158_WORK"],owner.replace(".","_")+".macho")
 try:
  kc.carve(owner,image); images[owner]=image
  print("FILESSET_CARVE=PASS OWNER=%s"%owner)
 except Exception as e:
  print("FILESSET_CARVE=FAIL OWNER=%s ERROR=%s"%(owner,str(e)[:300]))
def own(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def inspect_class(cls, offsets, expected=None):
 vt=kc.vtable(cls); size=kc.metaclass_size(cls)
 a=kc.find("__ZTV%d%s"%(len(cls),cls))
 print("\nCLASS_AUDIT NAME=%s INSTANCE_SIZE=%s VTABLE_WORDS=%d VTABLE_OWNER=%s"%(cls,size if size is not None else "UNKNOWN",len(vt) if vt else 0,own(a) if a else "UNKNOWN"))
 if not vt:
  print("CLASS_VTABLE_NOT_FOUND NAME="+cls); return
 for off in offsets:
  idx=2+off//8
  if idx>=len(vt): print("VTABLE_SLOT_MISSING CLASS=%s OFFSET=0x%x"%(cls,off)); continue
  _i,raw,target,name=vt[idx]
  print("VTABLE_SLOT CLASS=%s OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,idx,raw,target,own(target),name))
  if expected and own(target)!=expected:
   print("VTABLE_SLOT_OWNER_REVIEW CLASS=%s OFFSET=0x%x EXPECTED=%s ACTUAL=%s"%(cls,off,expected,own(target)))
def dump(a,n,tag,owner,limit=0x2400):
 image=images.get(owner)
 if not image or not a or not n:return
 end=kc.next_sym(a) or a+limit
 if end<=a or end>a+limit:end=a+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",n,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,n,p.stderr.strip()[:220]));return
 rows=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   x=int(m.group(1),16)
   if a<=x<end:rows.append((x,line.strip(),m.group(2)))
 if not rows or rows[0][0]!=a:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s ADDRESS=0x%x"%(tag,n,a));return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,n,a,end,len(rows)))
 for i,(x,raw,asm) in enumerate(rows):
  if i<16 or re.search(r"call|jmp|ret|WorkQueue|workQueue|Doorbell|retain|release|0x[0-9a-f]+\(%r",asm,re.I):
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(x,asm))
# Concrete PCIe bus implementation; +0x860/+0x868 resolve whether it overrides
# the common base's false/null callbacks or supplies a device-owned queue.
inspect_class("AppleBCMWLANBusInterfacePCIe",(0x860,0x868,0xC58,0xC68), "com.apple.driver.AppleBCMWLANBusInterfacePCIeMac")
# PCIe doorbell may supply / retain a workqueue used by the bus object.
inspect_class("AppleBCMWLANPCIeDoorbell",(0x20,0x28,0x860,0x868), "com.apple.driver.AppleBCMWLANBusInterfacePCIeMac")
for cls in ("AppleBCMWLANBusInterfacePCIe","AppleBCMWLANPCIeDoorbell"):
 methods=kc.methods(cls)
 print("\nCLASS_METHOD_COUNT NAME=%s COUNT=%d"%(cls,len(methods)))
 chosen=[]
 for a,n in methods:
  if any(k.lower() in n.lower() for k in ("WorkQueue","workQueue","Doorbell","init","start","stop","free","createSubmissionRing","createCompletionRing","enableSubmissionRing","enableCompletionRing","disableSubmissionRing","disableCompletionRing")):
   chosen.append((a,n))
   print("PCIE_RELEVANT_SYMBOL ADDRESS=0x%x OWNER=%s NAME=%s"%(a,own(a),n))
 for a,n in chosen:
  dump(a,n,"PCIE_QUEUE_LIFECYCLE",own(a),0x2400)
# Inventory the entire PCIe fileset for queue, command gate, workloop and doorbell symbols.
syms=sorted((a,n) for a,n in kc.syms.items() if own(a)=="com.apple.driver.AppleBCMWLANBusInterfacePCIeMac")
related=[(a,n) for a,n in syms if any(k.lower() in n.lower() for k in ("workqueue","workloop","do orbell".replace(" ",""),"commandgate","timersource"))]
print("\nPCIE_BUNDLE_SYMBOL_COUNT=%d"%len(syms))
print("PCIE_QUEUE_SYMBOL_COUNT=%d"%len(related))
for a,n in related[:300]:print("PCIE_QUEUE_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
# Recheck the two Apple core branches and their queue member store.
for n in ("__ZN16AppleBCMWLANCore15createWorkQueueEv","__ZNK16AppleBCMWLANCore12getWorkQueueEv"):
 a=kc.find(n); print("CORE_CALLBACK_RECHECK NAME=%s ADDRESS=%s OWNER=%s"%(n,("0x%x"%a) if a else "NOT_FOUND",own(a) if a else "UNKNOWN"))
print("\nSTAGE158_INTERPRETATION=PCIE_PROVIDER_STATIC_ANALYSIS_ONLY; REQUIRE_EXPLICIT_QUEUE_OWNERSHIP_AND_LIFETIME_PROOF_BEFORE_DRIVER_CHANGES")
PY
 echo "STAGE158_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE158_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE158 =========="
} >"$REPORT"
echo "===== STAGE158 SUMMARY ====="
grep -aE '^(STAGE158_|STAGE157_REPORT_INTEGRITY=|FILESSET_CARVE=|CLASS_AUDIT |VTABLE_SLOT |VTABLE_SLOT_OWNER_REVIEW |CLASS_VTABLE_NOT_FOUND |CLASS_METHOD_COUNT |PCIE_RELEVANT_SYMBOL |METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|PCIE_BUNDLE_SYMBOL_COUNT=|PCIE_QUEUE_SYMBOL_COUNT=|PCIE_QUEUE_SYMBOL |CORE_CALLBACK_RECHECK |STAGE158_INTERPRETATION=)' "$REPORT" | head -560 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage158-apple-pcie-workqueue-ownership-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage158: publish read-only Apple PCIe workqueue ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE158_UPLOAD_SHA="+actual);print("STAGE158_GITHUB_PATH="+dest);print("STAGE158_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE158_UPLOAD_SHA="+existing);print("STAGE158_GITHUB_PATH="+dest);print("STAGE158_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE158_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE158_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE158_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
