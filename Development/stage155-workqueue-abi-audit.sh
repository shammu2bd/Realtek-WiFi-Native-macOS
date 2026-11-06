#!/bin/bash
# Stage155: inspect Apple IO80211WorkQueue construction/API and controller workqueue override examples.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE154_PATH="Development/Logs/stage154-controller-workqueue-audit-20261106T213530Z.log"
STAGE154_SHA="2bbe123afdcf9919b41db8dd53de40f2edb0cb50"
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
WORK="$(mktemp -d "$TMPROOT/stage155-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage155-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE154_PATH?ref=main" > "$WORK/stage154.json"
python3 - "$WORK/stage154.json" "$STAGE154_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE155_STAGE154_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage154 report blob SHA mismatch")
print("STAGE154_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE155_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE155 APPLE IO80211WORKQUEUE API AND OVERRIDE AUDIT =========="
 echo "STAGE155_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE155_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE155_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE155_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE155_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE155_STAGE154_REPORT_SHA=$STAGE154_SHA"
 echo "STAGE155_SCOPE=READ_ONLY_TRACE_IO80211WORKQUEUE_VTABLE_FACTORY_LIFECYCLE_AND_CONTROLLER_OVERRIDE_EXAMPLES"
 echo "STAGE155_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE155_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE155_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE155_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; owner="com.apple.iokit.IO80211Family"
print("STAGE155_FILES_BASE=0x%x"%kc.base)
print("STAGE155_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE155_SYMBOL_COUNT=%d"%len(kc.syms))
# Resolve IO80211WorkQueue class size and vtable.
cls="IO80211WorkQueue"
vt=kc.vtable(cls)
va=kc.find("__ZTV%d%s"%(len(cls),cls))
size=kc.metaclass_size(cls)
print("WORKQUEUE_CLASS_VTABLE=%s"%("0x%x"%va if va else "NOT_FOUND"))
print("WORKQUEUE_CLASS_INSTANCE_SIZE=%s"%(size if size is not None else "UNKNOWN"))
print("WORKQUEUE_VTABLE_WORDS=%d"%(len(vt) if vt else 0))
if vt:
 for idx,raw,target,name in vt:
  if idx<70:
   off=(idx-2)*8
   print("WORKQUEUE_VTABLE_SLOT WORD=%d OFFSET=%s RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(idx,("0x%x"%off) if idx>=2 else "ABI_PREFIX",raw,target,kc.owner(target) or "UNATTRIBUTED",name))
# Collect all exact workqueue symbols.
ws=sorted((a,n) for a,n in kc.syms.items() if "WorkQueue" in n and kc.sym_owner.get(a)==owner)
print("WORKQUEUE_SYMBOL_COUNT=%d"%len(ws))
for a,n in ws[:260]: print("WORKQUEUE_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
# Scan IO80211 and Apple WLAN class vtables at controller slots createWorkQueue(+0xC58), getWorkQueue(+0xC68).
slot_words={0xC58:2+0xC58//8,0xC68:2+0xC68//8}
seen_targets=set()
for off,word in slot_words.items():
 print("\nCONTROLLER_OVERRIDE_SCAN OFFSET=0x%x WORD=%d"%(off,word))
 found=0
 for c in kc.classes():
  if not (c.startswith("IO80211") or c.startswith("AppleBCMWLAN") or c.startswith("AppleBCM")): continue
  cv=kc.vtable(c)
  if not cv or word>=len(cv): continue
  _i,raw,target,name=cv[word]
  sym=kc.syms.get(target)
  if not sym or "Controller" not in sym and "WorkQueue" not in sym: continue
  own=kc.owner(target) or "UNATTRIBUTED"
  print("CONTROLLER_SLOT_CANDIDATE CLASS=%s OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(c,off,target,own,sym))
  found+=1
  if own==owner: seen_targets.add((target,sym,"OVERRIDE_SLOT_0x%x_CLASS_%s"%(off,c)))
 print("CONTROLLER_OVERRIDE_CANDIDATE_COUNT=%d"%found)
image=os.path.join(os.environ["STAGE155_WORK"],"IO80211Family.macho")
kc.carve(owner,image)
def dump(addr,name,tag,limit=0x2200,all_body=False):
 if not addr or not name: return
 end=kc.next_sym(addr) or addr+limit
 if end<=addr or end>addr+limit: end=addr+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,name,p.stderr.strip()[:200]));return
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end:ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s"%(tag,name));return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,name,addr,end,len(ins)))
 for i,(a,raw,asm) in enumerate(ins):
  if all_body or i<16 or re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b|WorkQueue|workQueue|0xc58|0xc68|0x88|0x98|0xa0|0x10\(",asm,re.I):
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
# Core construction/factory methods and all meaningful WorkQueue APIs.
focused=[(a,n) for a,n in ws if any(k in n for k in ("workQueue","init","start","stop","free","dispatch","schedule","addEvent","removeEvent","run","perform"))]
print("\nWORKQUEUE_FOCUSED_METHOD_COUNT=%d"%len(focused))
for a,n in focused[:100]: dump(a,n,"WORKQUEUE_METHOD",0x1800,all_body=False)
# Base controller methods and each derived override target from the candidate scan.
for mangled,tag in (
 ("__ZN17IO80211Controller15createWorkQueueEv","BASE_CREATE_WORKQUEUE"),
 ("__ZNK17IO80211Controller12getWorkQueueEv","BASE_GET_WORKQUEUE"),
 ("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_POSTOFFICE_FACTORY"),
 ("__ZN17IO80211Controller13getPostOfficeEv","CONTROLLER_GET_POSTOFFICE")):
 a=kc.find(mangled)
 print("%s_SYMBOL=%s"%(tag,("0x%x"%a) if a else "NOT_FOUND"))
 if a:dump(a,mangled,tag,0x1000,all_body=True)
for a,n,tag in sorted(seen_targets):
 dump(a,n,tag,0x1800,all_body=True)
# Search Apple source symbols for calls/constructors mentioning IO80211WorkQueue, including method names
# whose mangling does not contain WorkQueue.
interesting=sorted((a,n) for a,n in kc.syms.items()
 if kc.sym_owner.get(a)==owner and any(k in n for k in ("IO80211Controller","IO80211Glue","IO80211PostOffice","IO80211WorkQueue")))
print("\nRELATED_IO80211_SYMBOL_COUNT=%d"%len(interesting))
for a,n in interesting:
 if any(k in n for k in ("createWorkQueue","getWorkQueue","CreatePostOffice","getPostOffice","workQueue","WorkQueue")):
  print("RELATED_IO80211_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
print("\nSTAGE155_INTERPRETATION=STATIC_ABI_AND_OVERRIDES_ONLY; DO_NOT_INFER_A_DRIVER_WORKQUEUE_IMPLEMENTATION_WITHOUT_MATCHING_CONSTRUCTOR_AND_LIFETIME_CONTRACT")
PY
 echo "STAGE155_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE155_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE155 =========="
} >"$REPORT"
echo "===== STAGE155 SUMMARY ====="
grep -aE '^(STAGE155_|STAGE154_REPORT_INTEGRITY=|WORKQUEUE_CLASS_|WORKQUEUE_VTABLE_|WORKQUEUE_SYMBOL_COUNT=|WORKQUEUE_SYMBOL |CONTROLLER_OVERRIDE_SCAN|CONTROLLER_SLOT_CANDIDATE |CONTROLLER_OVERRIDE_CANDIDATE_COUNT=|WORKQUEUE_FOCUSED_METHOD_COUNT=|METHOD_TAG=|METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|BASE_CREATE_WORKQUEUE_SYMBOL=|BASE_GET_WORKQUEUE_SYMBOL=|CONTROLLER_POSTOFFICE_FACTORY_SYMBOL=|CONTROLLER_GET_POSTOFFICE_SYMBOL=|RELATED_IO80211_SYMBOL_COUNT=|RELATED_IO80211_SYMBOL |STAGE155_INTERPRETATION=)' "$REPORT" | head -480 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage155-workqueue-abi-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage155: publish read-only IO80211WorkQueue ABI and override audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE155_UPLOAD_SHA="+actual);print("STAGE155_GITHUB_PATH="+dest);print("STAGE155_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE155_UPLOAD_SHA="+existing);print("STAGE155_GITHUB_PATH="+dest);print("STAGE155_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE155_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE155_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE155_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
