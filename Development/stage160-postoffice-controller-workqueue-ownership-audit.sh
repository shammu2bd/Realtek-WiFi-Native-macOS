#!/bin/bash
# Stage160: audit PostOffice and controller ownership of the native IO80211WorkQueue.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload,
# hardware activation, OpenCore/EFI/SIP/NVRAM changes, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE159_PATH="Development/Logs/stage159-apple-pcie-workqueue-lifecycle-20261106T214754Z.log"
STAGE159_SHA="58469c3e1e1b06c3b6f06a072f6278b044650196"
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
WORK="$(mktemp -d "$TMPROOT/stage160-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage160-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE159_PATH?ref=main" > "$WORK/stage159.json"
python3 - "$WORK/stage159.json" "$STAGE159_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE160_STAGE159_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage159 report blob SHA mismatch")
print("STAGE159_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE160_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE160 POSTOFFICE AND CONTROLLER QUEUE OWNERSHIP AUDIT =========="
 echo "STAGE160_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE160_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE160_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE160_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE160_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE160_STAGE159_REPORT_SHA=$STAGE159_SHA"
 echo "STAGE160_SCOPE=READ_ONLY_POSTOFFICE_CONTROLLER_QUEUE_REFERENCE_AND_TEARDOWN"
 echo "STAGE160_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE160_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE160_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE160_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
owners=("com.apple.iokit.IO80211Family","com.apple.driver.AppleBCMWLANCoreMac")
images={}
for owner in owners:
 path=os.path.join(os.environ["STAGE160_WORK"],owner.replace(".","_")+".macho")
 kc.carve(owner,path);images[owner]=path
 print("FILESSET_CARVE=PASS OWNER="+owner)
def own(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def disasm(name,tag,owner,limit=0x4000,match=None,context=6):
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
 chosen=set()
 if match:
  for i,(x,raw,asm) in enumerate(rows):
   if match.search(asm):
    chosen.update(range(max(0,i-context),min(len(rows),i+context+1)))
 else:
  chosen.update(range(len(rows)))
 for i in sorted(chosen):
  x,raw,asm=rows[i]
  print(raw)
  if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(x,asm))
def class_audit(cls,owner,offsets=()):
 vt=kc.vtable(cls); size=kc.metaclass_size(cls);v=kc.find("__ZTV%d%s"%(len(cls),cls))
 print("\nCLASS_AUDIT NAME=%s SIZE=%s VTABLE_WORDS=%d OWNER=%s"%(cls,size if size is not None else "UNKNOWN",len(vt) if vt else 0,own(v) if v else "UNKNOWN"))
 if vt:
  for off in offsets:
   idx=2+off//8
   if idx<len(vt):
    _i,raw,target,sym=vt[idx]
    print("VTABLE_SLOT CLASS=%s OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,target,own(target),sym))
# Inventory PostOffice and controller relevant symbols before disassembly.
for cls,owner in (("IO80211PostOffice","com.apple.iokit.IO80211Family"),("IO80211Controller","com.apple.iokit.IO80211Family")):
 methods=kc.methods(cls)
 print("\nCLASS_METHOD_COUNT NAME=%s COUNT=%d"%(cls,len(methods)))
 for a,n in methods:
  if any(k.lower() in n.lower() for k in ("postoffice","sendmail","deliverMessage","outForDelivery","initWithParams","free","createPostOffice","workQueue","start","stop")):
   print("CLASS_RELEVANT_SYMBOL CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,a,own(a),n))
# PostOffice stores the WorkQueue and creates a timer source from it. Inspect all lifecycle
# methods and message dispatch entry points, including free/destructor paths.
class_audit("IO80211PostOffice","com.apple.iokit.IO80211Family",(0x20,0x28,0x88,0x90,0x120,0x128,0x130))
post=kc.methods("IO80211PostOffice")
for a,n in post:
 if any(k.lower() in n.lower() for k in ("initWithParams","free","sendMail","deliverMessage","outForDelivery","MetaClass5alloc")):
  disasm(n,"POSTOFFICE_LIFECYCLE","com.apple.iokit.IO80211Family",0x3000)
# Controller setup and teardown: locate PostOffice expansion storage, release, and queue object.
for n,tag in (
 ("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_CREATE_POSTOFFICE"),
 ("__ZN17IO80211Controller5startEP9IOService","CONTROLLER_START"),
 ("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
):
 disasm(n,tag,"com.apple.iokit.IO80211Family",0x5000,re.compile(r"0xb08|0x120\(%r|post.?office|PostOffice|0x28\(%rax\)|0x118\(%rax\)|0x128\(%rax\)"),5)
# Apple core private queue ref and teardown: extract every reference to 0x7898 and relevant releases.
for n,tag in (
 ("__ZN16AppleBCMWLANCore15createWorkQueueEv","APPLE_CORE_QUEUE_CREATE"),
 ("__ZN16AppleBCMWLANCore4freeEv","APPLE_CORE_FREE"),
 ("__ZN16AppleBCMWLANCore13freeResourcesEv","APPLE_CORE_FREE_RESOURCES"),
):
 disasm(n,tag,"com.apple.driver.AppleBCMWLANCoreMac",0x9000,re.compile(r"0x7898|0x28\(%rax\)|0x118\(%rax\)|0x128\(%rax\)|0x158\(%rax\)|release"),6)
# WorkQueue factory and PostOffice allocator/init symbols.
for n,tag in (
 ("__ZN16IO80211WorkQueue9workQueueEv","WORKQUEUE_FACTORY"),
 ("__ZN17IO80211PostOffice15allocWithParamsEP16IO80211WorkQueue","POSTOFFICE_ALLOC"),
 ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
):
 disasm(n,tag,"com.apple.iokit.IO80211Family",0x3000)
print("\nSTAGE160_INTERPRETATION=STATIC_REFCOUNT_AND_TEARDOWN_AUDIT_ONLY; DO_NOT_IMPLEMENT_UNTIL_QUEUE_AND_POSTOFFICE_OWNERSHIP_IS_EXPLICIT")
PY
 echo "STAGE160_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE160_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE160 =========="
} >"$REPORT"
echo "===== STAGE160 SUMMARY ====="
grep -aE '^(STAGE160_|STAGE159_REPORT_INTEGRITY=|FILESSET_CARVE=|CLASS_AUDIT |VTABLE_SLOT |CLASS_METHOD_COUNT |CLASS_RELEVANT_SYMBOL |TARGET_SYMBOL |METHOD_TAG=|METHOD_NOT_VERIFIED |DISASSEMBLY_FAILED |CONTROL_FLOW=|STAGE160_INTERPRETATION=)' "$REPORT" | head -620 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage160-postoffice-controller-workqueue-ownership-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage160: publish read-only PostOffice and controller workqueue ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE160_UPLOAD_SHA="+actual);print("STAGE160_GITHUB_PATH="+dest);print("STAGE160_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE160_UPLOAD_SHA="+existing);print("STAGE160_GITHUB_PATH="+dest);print("STAGE160_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE160_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE160_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE160_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
