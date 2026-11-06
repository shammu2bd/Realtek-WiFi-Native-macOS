#!/bin/bash
# Stage151: resolve the controller-expansion +0xDC0 factory dispatch that initializes expansion +0xB08.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE150_PATH="Development/Logs/stage150-controller-glue-lifecycle-20261106T212334Z.log"
STAGE150_SHA="617b4883a151bbf7ec6f82e30c63881faef98609"
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
WORK="$(mktemp -d "$TMPROOT/stage151-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage151-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE150_PATH?ref=main" > "$WORK/stage150.json"
python3 - "$WORK/stage150.json" "$STAGE150_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
actual=obj.get("sha")
print("STAGE151_STAGE150_REPORT_SHA="+str(actual))
if actual!=sys.argv[2]: raise SystemExit("STOP: Stage150 source report blob SHA mismatch")
print("STAGE150_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE151_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE151 CONTROLLER GLUE FACTORY DISPATCH AUDIT =========="
 echo "STAGE151_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE151_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE151_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE151_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE151_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE151_STAGE150_REPORT_SHA=$STAGE150_SHA"
 echo "STAGE151_SCOPE=READ_ONLY_RESOLVE_CONTROLLER_EXPANSION_VTABLE_SLOT_0xDC0_FACTORY_AND_0xB08_GLUE_OWNERSHIP"
 echo "STAGE151_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE151_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE151_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE151_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
owner="com.apple.iokit.IO80211Family"
slot_off=0xDC0
slot_word=2+slot_off//8
print("STAGE151_FILES_BASE=0x%x"%kc.base)
print("STAGE151_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE151_SYMBOL_COUNT=%d"%len(kc.syms))
print("STAGE151_CLASS_COUNT=%d"%len(kc.classes()))
# Enumerate every class vtable with a valid entry at object vtable byte offset +0xDC0.
# KC.vtable() includes two ABI prefix words, so the entry index is 2 + offset/8.
candidates=[]
for cls in kc.classes():
    vt=kc.vtable(cls)
    if not vt or slot_word>=len(vt): continue
    _idx,raw,target,name=vt[slot_word]
    if not target: continue
    own=kc.owner(target) or "UNATTRIBUTED"
    if own==owner or "IO80211" in cls or "Glue" in cls:
        candidates.append((cls,raw,target,own,name,len(vt)))
print("EXPANSION_VTABLE_SLOT_OFFSET=0x%x WORD_INDEX=%d"%(slot_off,slot_word))
print("EXPANSION_VTABLE_CANDIDATE_COUNT=%d"%len(candidates))
for cls,raw,target,own,name,nwords in candidates[:200]:
    size=kc.metaclass_size(cls)
    print("VTV_SLOT_CANDIDATE CLASS=%s VTABLE_WORDS=%d INSTANCE_SIZE=%s RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,nwords,size if size is not None else "UNKNOWN",raw,target,own,name))
# Report likely controller/expansion-related classes even when their vtable is too short.
for cls in kc.classes():
    if "IO80211Controller" in cls or ("IO80211" in cls and ("Expansion" in cls or "IVars" in cls or "Private" in cls)):
        va=kc.find("__ZTV%d%s"%(len(cls),cls))
        size=kc.metaclass_size(cls)
        print("CONTROLLER_CLASS CANDIDATE=%s VTABLE=0x%x INSTANCE_SIZE=%s"%(cls,va or 0,size if size is not None else "UNKNOWN"))
# Disassemble focused symbols from the IO80211Family image.
image=os.path.join(os.environ["STAGE151_WORK"],"IO80211Family.macho")
kc.carve(owner,image)
def dump(addr,name,tag,max_bytes=0x1800):
    if not addr or not name: 
        print("METHOD_SKIP TAG=%s ADDRESS=%s SYMBOL=%s"%(tag,addr,name)); return
    end=kc.next_sym(addr) or addr+max_bytes
    if end<=addr or end>addr+max_bytes: end=addr+max_bytes
    p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,image],capture_output=True,text=True)
    if p.returncode:
        print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,name,p.stderr.strip()[:240])); return
    ins=[]
    for line in p.stdout.splitlines():
        m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
        if m:
            a=int(m.group(1),16)
            if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
    if not ins or ins[0][0]!=addr:
        print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s ADDRESS=0x%x"%(tag,name,addr)); return
    print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,addr,end,len(ins)))
    selected=[]
    for i,item in enumerate(ins):
        a,raw,asm=item
        if i<14 or re.search(r"0xb08|0xdc0|0x120|IO80211Glue|CommonGlue|WCLGlue|postMessage|initWithOptions|freeResources|stop|start|create",asm,re.I):
            selected.append(item)
    for a,raw,asm in selected:
        print(raw)
        if re.search(r"\b(call|jmp)q?\b",asm): print("CONTROL_FLOW=0x%x %s"%(a,asm))
# Exact Apple call site and controller lifetime methods.
controller_methods=kc.methods("IO80211Controller")
focused=[(a,n) for a,n in controller_methods if any(k in n for k in ("5start","4stop","4free","4init","D1E","D2E","postMessage"))]
print("\nCONTROLLER_FOCUSED_METHOD_COUNT=%d"%len(focused))
for a,n in focused[:60]: dump(a,n,"CONTROLLER_LIFETIME",0x2200)
start=kc.find("__ZN17IO80211Controller5startEP9IOService")
print("CONTROLLER_START_SYMBOL=0x%x"% (start or 0))
if start: dump(start,"__ZN17IO80211Controller5startEP9IOService","CONTROLLER_START_FACTORY_CALL",0x5000)
# Resolve and disassemble every vtable target discovered above that has an exact Apple symbol.
seen=set()
for cls,raw,target,own,name,nwords in candidates:
    sym=kc.syms.get(target)
    if own==owner and sym and target not in seen:
        seen.add(target)
        dump(target,sym,"EXPANSION_SLOT_TARGET:"+cls,0x2200)
# Glue lifecycle sequence (allocation/init/free/stop) and dispatch interface.
glue_methods=kc.methods("IO80211Glue")
glue_focused=[(a,n) for a,n in glue_methods if any(k in n for k in ("initWithOptions","freeResources","4stop","4start","postMessage","sendIOUCToWcl","receiveMessageInternal"))]
print("\nGLUE_FOCUSED_METHOD_COUNT=%d"%len(glue_focused))
for a,n in glue_focused[:50]: dump(a,n,"GLUE_LIFECYCLE",0x2600)
print("\nSTAGE151_INTERPRETATION=STATIC_ABI_AND_SYMBOL_MAPPING_ONLY; NO_RUNTIME_POINTER_VALUE_OR_OBJECT_IDENTITY")
PY
 echo "STAGE151_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE151_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE151 =========="
} >"$REPORT"
echo "===== STAGE151 SUMMARY ====="
grep -aE '^(STAGE151_|STAGE150_REPORT_INTEGRITY=|STAGE151_READER_BLOB_SHA=|EXPANSION_VTABLE_|VTV_SLOT_CANDIDATE |CONTROLLER_CLASS |CONTROLLER_START_SYMBOL=|CONTROLLER_FOCUSED_METHOD_COUNT=|GLUE_FOCUSED_METHOD_COUNT=|METHOD_TAG=|METHOD_SKIP |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|STAGE151_INTERPRETATION=)' "$REPORT" | head -320 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage151-controller-glue-factory-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage151: publish read-only controller glue factory dispatch audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE151_UPLOAD_SHA="+actual);print("STAGE151_GITHUB_PATH="+dest);print("STAGE151_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE151_UPLOAD_SHA="+existing);print("STAGE151_GITHUB_PATH="+dest);print("STAGE151_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE151_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE151_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE151_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
