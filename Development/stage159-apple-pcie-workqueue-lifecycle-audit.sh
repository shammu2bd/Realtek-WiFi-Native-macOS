#!/bin/bash
# Stage159: verify Apple PCIe's concrete WorkQueue construction, use, and release sequence.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload,
# hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE158_PATH="Development/Logs/stage158-apple-pcie-workqueue-ownership-20261106T214534Z.log"
STAGE158_SHA="f7d153bca56a1552160e46c4c61b3214b1670fda"
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
WORK="$(mktemp -d "$TMPROOT/stage159-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage159-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE158_PATH?ref=main" > "$WORK/stage158.json"
python3 - "$WORK/stage158.json" "$STAGE158_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE159_STAGE158_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage158 report blob SHA mismatch")
print("STAGE158_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE159_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE159 APPLE PCIE WORKQUEUE LIFECYCLE CONFIRMATION =========="
 echo "STAGE159_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE159_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE159_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE159_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE159_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE159_STAGE158_REPORT_SHA=$STAGE158_SHA"
 echo "STAGE159_SCOPE=READ_ONLY_QUEUE_FACTORY_CREATION_RETENTION_AND_RELEASE_CORRELATION"
 echo "STAGE159_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE159_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE159_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE159_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
io_owner="com.apple.iokit.IO80211Family"
core_owner="com.apple.driver.AppleBCMWLANCoreMac"
pcie_owner="com.apple.driver.AppleBCMWLANBusInterfacePCIeMac"
owners=(io_owner,core_owner,pcie_owner)
images={}
for o in owners:
 p=os.path.join(os.environ["STAGE159_WORK"],o.replace(".","_")+".macho")
 kc.carve(o,p); images[o]=p
 print("FILESSET_CARVE=PASS OWNER="+o)
def own(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def dump(a,n,tag,o,limit=0x2000,focus=None):
 image=images.get(o)
 if not image or not a or not n:return
 end=kc.next_sym(a) or a+limit
 if end<=a or end>a+limit:end=a+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",n,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,n,p.stderr.strip()[:250]));return
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
  keep=(focus is None and (i<20 or re.search(r"call|jmp|ret|WorkQueue|workQueue|retain|release|0xdd0|0x7898|0x860|0x868",asm,re.I)))
  keep=(keep or (focus is not None and any(lo<=x<=hi for lo,hi in focus)))
  if keep:
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(x,asm))
# Exact Apple PCIe bus sequence: allocation, store into its expansion, later use, and release.
targets=[
("__ZN28AppleBCMWLANBusInterfacePCIe5startEP9IOService","PCIE_START",pcie_owner,0x2400,[(0xffffff80014eac42,0xffffff80014ead20),(0xffffff80014ebd00,0xffffff80014ebe30)]),
("__ZN28AppleBCMWLANBusInterfacePCIe13freeResourcesEv","PCIE_FREE_RESOURCES",pcie_owner,0x2400,[(0xffffff80014f69a0,0xffffff80014f6a10)]),
("__ZNK28AppleBCMWLANBusInterfacePCIe12getWorkQueueEv","PCIE_QUEUE_GETTER",pcie_owner,0x300,None),
("__ZN24AppleBCMWLANBusInterfacePCIe13needWorkQueueEv","BUS_NEED_QUEUE_BASE",core_owner,0x300,None),
("__ZNK24AppleBCMWLANBusInterface12getWorkQueueEv","BUS_GET_QUEUE_BASE",core_owner,0x300,None),
("__ZN16IO80211WorkQueue9workQueueEv","IO80211_WORKQUEUE_FACTORY",io_owner,0x500,None),
("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_POSTOFFICE_FACTORY",io_owner,0x900,None),
("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE",io_owner,0x1800,None),
("__ZN16AppleBCMWLANCore15createWorkQueueEv","APPLE_CORE_QUEUE_CREATE",core_owner,0x700,None),
("__ZN16AppleBCMWLANCore13freeResourcesEv","APPLE_CORE_FREE_RESOURCES",core_owner,0x2400,None),
]
for n,tag,o,limit,focus in targets:
 a=kc.find(n)
 print("\nTARGET_SYMBOL TAG=%s NAME=%s ADDRESS=%s OWNER=%s"%(tag,n,("0x%x"%a) if a else "NOT_FOUND",own(a) if a else "UNKNOWN"))
 if a:dump(a,n,tag,o,limit,focus)
# Search direct symbol users for queue factories/providers, using disassembly of the known concrete functions.
print("\nQUEUE_FIELD_SEQUENCE_SUMMARY")
print("EXPECTED_PCIE_EXPANSION_QUEUE_FIELD=0xdd0")
print("EXPECTED_PCIE_START_QUEUE_FACTORY_CALL=0xffffff8002258fcc")
print("EXPECTED_PCIE_GETTER_LOAD=expansion[0x90]+0xdd0")
print("EXPECTED_PCIE_FREE_RELEASE_AND_CLEAR=expansion[0x90]+0xdd0")
print("EXPECTED_APPLE_CORE_RETAIN_PATH=bus.getWorkQueue()->retain()")
# Confirm exact symbol owner / field access sites.
for n in ("__ZN16IO80211WorkQueue9workQueueEv","__ZNK28AppleBCMWLANBusInterfacePCIe12getWorkQueueEv","__ZN28AppleBCMWLANBusInterfacePCIe5startEP9IOService","__ZN28AppleBCMWLANBusInterfacePCIe13freeResourcesEv","__ZN16AppleBCMWLANCore15createWorkQueueEv","__ZN17IO80211Controller16CreatePostOfficeEv"):
 a=kc.find(n);print("SYMBOL_OWNER_CHECK NAME=%s ADDRESS=%s OWNER=%s"%(n,("0x%x"%a) if a else "NOT_FOUND",own(a) if a else "UNKNOWN"))
print("\nSTAGE159_INTERPRETATION=APPLE_PCIE_QUEUE_PATH_STATICALLY_CORRELATED; NOT_A_PUBLIC_DRIVER_API_OR_AUTHORIZATION_TO_COPY_PRIVATE_LAYOUTS")
PY
 echo "STAGE159_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE159_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE159 =========="
} >"$REPORT"
echo "===== STAGE159 SUMMARY ====="
grep -aE '^(STAGE159_|STAGE158_REPORT_INTEGRITY=|FILESSET_CARVE=|TARGET_SYMBOL |METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|QUEUE_FIELD_SEQUENCE_SUMMARY|EXPECTED_PCIE_|EXPECTED_APPLE_|SYMBOL_OWNER_CHECK |STAGE159_INTERPRETATION=)' "$REPORT" | head -560 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage159-apple-pcie-workqueue-lifecycle-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage159: publish read-only Apple PCIe workqueue lifecycle audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE159_UPLOAD_SHA="+actual);print("STAGE159_GITHUB_PATH="+dest);print("STAGE159_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE159_UPLOAD_SHA="+existing);print("STAGE159_GITHUB_PATH="+dest);print("STAGE159_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE159_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE159_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE159_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
