#!/bin/bash
# Stage161: complete controller/PostOffice/timer-source borrowed workqueue lifetime audit.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload,
# hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE160_PATH="Development/Logs/stage160-postoffice-controller-workqueue-ownership-20261106T214941Z.log"
STAGE160_SHA="9d352ed3378320bb666df884f36bbc8c4ed2bce7"
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
WORK="$(mktemp -d "$TMPROOT/stage161-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage161-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE160_PATH?ref=main" > "$WORK/stage160.json"
python3 - "$WORK/stage160.json" "$STAGE160_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE161_STAGE160_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage160 report blob SHA mismatch")
print("STAGE160_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE161_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE161 CONTROLLER POSTOFFICE TIMER WORKQUEUE LIFETIME AUDIT =========="
 echo "STAGE161_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE161_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE161_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE161_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE161_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE161_STAGE160_REPORT_SHA=$STAGE160_SHA"
 echo "STAGE161_SCOPE=READ_ONLY_CONTROLLER_STOP_POSTOFFICE_RELEASE_AND_TIMER_SOURCE_QUEUE_OWNERSHIP"
 echo "STAGE161_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE161_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE161_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE161_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
io_owner="com.apple.iokit.IO80211Family"
core_owner="com.apple.driver.AppleBCMWLANCoreMac"
images={}
for owner in (io_owner,core_owner):
 path=os.path.join(os.environ["STAGE161_WORK"],owner.replace(".","_")+".macho")
 kc.carve(owner,path);images[owner]=path
 print("FILESSET_CARVE=PASS OWNER="+owner)
def own(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def disasm(name,tag,owner,limit=0x4000,pattern=None,context=7):
 a=kc.find(name)
 print("\nTARGET_SYMBOL TAG=%s NAME=%s ADDRESS=%s OWNER=%s"%(tag,name,("0x%x"%a) if a else "NOT_FOUND",own(a) if a else "UNKNOWN"))
 if not a:return
 end=kc.next_sym(a) or a+limit
 if end<=a or end>a+limit:end=a+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,images[owner]],capture_output=True,text=True)
 if p.returncode:
  print("DISASSEMBLY_FAILED TAG=%s ERROR=%s"%(tag,p.stderr.strip()[:250]));return
 rows=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   x=int(m.group(1),16)
   if a<=x<end:rows.append((x,line.strip(),m.group(2)))
 if not rows or rows[0][0]!=a:
  print("METHOD_NOT_VERIFIED TAG=%s ADDRESS=0x%x"%(tag,a));return
 print("METHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,a,end,len(rows)))
 if pattern is None: chosen=set(range(len(rows)))
 else:
  chosen=set()
  for i,(_,_,asm) in enumerate(rows):
   if pattern.search(asm):chosen.update(range(max(0,i-context),min(len(rows),i+context+1)))
 for i in sorted(chosen):
  x,raw,asm=rows[i];print(raw)
  if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(x,asm))
# Enumerate controller / timer class methods, including methods which may contain no "PostOffice" in name.
for cls in ("IO80211Controller","IO80211TimerSource","IO80211PostOffice"):
 methods=kc.methods(cls)
 print("\nCLASS_METHOD_COUNT NAME=%s COUNT=%d"%(cls,len(methods)))
 for a,n in methods:
  if cls=="IO80211Controller" and any(k.lower() in n.lower() for k in ("start","stop","free","postoffice","workqueue","createpostoffice")):
   print("CLASS_RELEVANT_SYMBOL CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,a,own(a),n))
  elif cls=="IO80211TimerSource" and any(k.lower() in n.lower() for k in ("init","free","start","cancel","timeout","allocwithparams","setworkqueue")):
   print("CLASS_RELEVANT_SYMBOL CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,a,own(a),n))
  elif cls=="IO80211PostOffice" and any(k.lower() in n.lower() for k in ("initwithparams","free","sendmail","outfordelivery")):
   print("CLASS_RELEVANT_SYMBOL CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,a,own(a),n))
# Controller stop is the missing lifecycle leg: inspect all references to PostOffice field +0xB08.
pattern=re.compile(r"0xb08|post.?office|PostOffice|0x28\(%rax\)|0x118\(%rax\)|0x128\(%rax\)")
for name,tag in (
 ("__ZN17IO80211Controller5startEP9IOService","CONTROLLER_START"),
 ("__ZN17IO80211Controller4stopEP9IOService","CONTROLLER_STOP"),
 ("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
 ("__ZN17IO80211Controller13getPostOfficeEv","CONTROLLER_GET_POSTOFFICE"),
):
 disasm(name,tag,io_owner,0x8000,pattern,9)
# TimerSource allocation/init/free and every queue-related symbol in that class.
timer=kc.methods("IO80211TimerSource")
for a,n in timer:
 if any(k.lower() in n.lower() for k in ("allocWithParams","init","free","start","cancel","setWorkQueue")):
  disasm(n,"TIMER_SOURCE_LIFECYCLE",io_owner,0x3000,None,5)
# PostOffice free and init, plus its exact stored queue/timer fields.
for name,tag in (
 ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
 ("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE"),
):
 disasm(name,tag,io_owner,0x2000,None,5)
# Confirm the Apple's core independently owns/releases its queue field.
disasm("__ZN16AppleBCMWLANCore15createWorkQueueEv","APPLE_CORE_QUEUE_CREATE",core_owner,0x1000,re.compile(r"0x7898|callq.*0x20|callq.*0x28"),5)
disasm("__ZN16AppleBCMWLANCore13freeResourcesEv","APPLE_CORE_QUEUE_RELEASE",core_owner,0x9000,re.compile(r"0x7898|callq.*0x28|release"),5)
print("\nSTAGE161_INTERPRETATION=STATIC_LIFETIME_CORRELATION_ONLY; QUEUE_POINTER_IS_BORROWED_BY_POSTOFFICE_UNLESS_TIMER_API_PROVES_ADDITIONAL_RETENTION")
PY
 echo "STAGE161_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE161_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE161 =========="
} >"$REPORT"
echo "===== STAGE161 SUMMARY ====="
grep -aE '^(STAGE161_|STAGE160_REPORT_INTEGRITY=|FILESSET_CARVE=|CLASS_METHOD_COUNT |CLASS_RELEVANT_SYMBOL |TARGET_SYMBOL |METHOD_TAG=|METHOD_NOT_VERIFIED |DISASSEMBLY_FAILED |CONTROL_FLOW=|STAGE161_INTERPRETATION=)' "$REPORT" | head -700 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage161-controller-postoffice-timer-workqueue-lifetime-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage161: publish read-only controller PostOffice timer workqueue lifetime audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE161_UPLOAD_SHA="+actual);print("STAGE161_GITHUB_PATH="+dest);print("STAGE161_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE161_UPLOAD_SHA="+existing);print("STAGE161_GITHUB_PATH="+dest);print("STAGE161_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE161_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE161_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE161_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
