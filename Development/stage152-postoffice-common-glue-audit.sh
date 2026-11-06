#!/bin/bash
# Stage152: inspect IO80211PostOffice class/interface and its CommonGlue relationship.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE151_PATH="Development/Logs/stage151-controller-glue-factory-20261106T212809Z.log"
STAGE151_SHA="d53e563dabadc21ce48b0c2147611f1bc2ab616c"
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
WORK="$(mktemp -d "$TMPROOT/stage152-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage152-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE151_PATH?ref=main" > "$WORK/stage151.json"
python3 - "$WORK/stage151.json" "$STAGE151_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE152_STAGE151_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage151 source report SHA mismatch")
print("STAGE151_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE152_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE152 POST OFFICE COMMONGLUE INTERFACE AUDIT =========="
 echo "STAGE152_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE152_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE152_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE152_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE152_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE152_STAGE151_REPORT_SHA=$STAGE151_SHA"
 echo "STAGE152_SCOPE=READ_ONLY_AUDIT_POSTOFFICE_CLASS_VTABLE_COMMONGLUE_MESSAGE_ABI_AND_LIFETIME"
 echo "STAGE152_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE152_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE152_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE152_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; owner="com.apple.iokit.IO80211Family"
print("STAGE152_FILES_BASE=0x%x"%kc.base)
print("STAGE152_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE152_SYMBOL_COUNT=%d"%len(kc.syms))
classes=[c for c in kc.classes() if "PostOffice" in c]
print("POSTOFFICE_CLASS_COUNT=%d"%len(classes))
for cls in classes:
 va=kc.find("__ZTV%d%s"%(len(cls),cls))
 size=kc.metaclass_size(cls)
 print("POSTOFFICE_CLASS NAME=%s VTABLE=%s INSTANCE_SIZE=%s"%(cls,("0x%x"%va) if va else "NOT_FOUND",size if size is not None else "UNKNOWN"))
 vt=kc.vtable(cls)
 if vt:
  for off in (0x120,0x128,0x130,0x138,0x140,0x148,0x150):
   idx=2+off//8
   if idx<len(vt):
    _i,raw,target,name=vt[idx]
    print("POSTOFFICE_VTABLE_SLOT CLASS=%s OFFSET=0x%x RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,raw,target,kc.owner(target) or "UNATTRIBUTED",name))
  for idx,raw,target,name in vt[:18]:
   print("POSTOFFICE_VTABLE_PREFIX CLASS=%s WORD=%d TARGET=0x%x SYMBOL=%s"%(cls,idx,target,name))
# Compare the message-dispatch slots against CommonGlue and IO80211Glue.
for cls in ("CommonGlue","IO80211Glue"):
 vt=kc.vtable(cls)
 print("REFERENCE_VTABLE CLASS=%s STATUS=%s"%(cls,"FOUND" if vt else "NOT_FOUND"))
 if vt:
  for off in (0x120,0x128):
   idx=2+off//8
   if idx<len(vt):
    _i,raw,target,name=vt[idx]
    print("REFERENCE_VTABLE_SLOT CLASS=%s OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,target,kc.owner(target) or "UNATTRIBUTED",name))
# Inventory all PostOffice symbols, then disassemble important exact methods.
syms=sorted((a,n) for a,n in kc.syms.items() if "PostOffice" in n and kc.sym_owner.get(a)==owner)
print("POSTOFFICE_SYMBOL_COUNT=%d"%len(syms))
for a,n in syms[:220]: print("POSTOFFICE_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
image=os.path.join(os.environ["STAGE152_WORK"],"IO80211Family.macho")
kc.carve(owner,image)
def dump(addr,name,tag,max_bytes=0x1800):
 if not addr or not name: print("METHOD_SKIP TAG=%s"%tag); return
 end=kc.next_sym(addr) or addr+max_bytes
 if end<=addr or end>addr+max_bytes: end=addr+max_bytes
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,image],capture_output=True,text=True)
 if p.returncode: print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s"%(tag,name)); return
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s"%(tag,name)); return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,addr,end,len(ins)))
 for i,(a,raw,asm) in enumerate(ins):
  if i<18 or re.search(r"PostOffice|CommonGlue|WCLGlue|sendMessage|receiveMessage|init|free|stop|start|0xb08|0x120|0x128|workQueue",asm,re.I):
   print(raw)
   if re.search(r"\b(call|jmp)q?\b",asm): print("CONTROL_FLOW=0x%x %s"%(a,asm))
for a,n in syms:
 if any(k in n for k in ("allocWithParams","initWithOptions","initWcl","sendMessage","receiveMessage","free","stop","start","C1E","C2E","D1E","D2E")):
  dump(a,n,"POSTOFFICE_METHOD",0x2400)
for cls in ("CommonGlue","IO80211Glue"):
 for a,n in kc.methods(cls):
  if any(k in n for k in ("sendMessage","initWithOptions","free","stop","receiveMessageInternal")):
   dump(a,n,"REFERENCE_"+cls,0x1800)
# Verify the known controller call site and relay remain as the prior stages recorded.
for mangled,tag in (("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_FACTORY"),("__ZN17IO80211Controller11postMessageEP23IO80211SkywalkInterfacejPvmb","CONTROLLER_RELAY")):
 a=kc.find(mangled)
 print("%s_SYMBOL=%s"%(tag,("0x%x"%a) if a else "NOT_FOUND"))
 if a: dump(a,mangled,tag,0x800)
print("\nSTAGE152_INTERPRETATION=STATIC_ABI_ONLY; CLASS_RELATIONSHIP_REQUIRES_MATCHING_VTABLE_AND_METHOD_EVIDENCE; NO_RUNTIME_OBJECT_IDENTITY")
PY
 echo "STAGE152_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE152_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE152 =========="
} >"$REPORT"
echo "===== STAGE152 SUMMARY ====="
grep -aE '^(STAGE152_|STAGE151_REPORT_INTEGRITY=|POSTOFFICE_CLASS |POSTOFFICE_VTABLE_SLOT |REFERENCE_VTABLE|REFERENCE_VTABLE_SLOT|POSTOFFICE_SYMBOL_COUNT=|POSTOFFICE_SYMBOL |METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|CONTROLLER_FACTORY_SYMBOL=|CONTROLLER_RELAY_SYMBOL=|STAGE152_INTERPRETATION=)' "$REPORT" | head -340 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage152-postoffice-common-glue-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage152: publish read-only PostOffice CommonGlue interface audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE152_UPLOAD_SHA="+actual);print("STAGE152_GITHUB_PATH="+dest);print("STAGE152_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE152_UPLOAD_SHA="+existing);print("STAGE152_GITHUB_PATH="+dest);print("STAGE152_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE152_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE152_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE152_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
