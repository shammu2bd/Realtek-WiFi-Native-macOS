#!/bin/bash
# Stage153: trace IO80211PostOffice send/queue/delivery methods and controller ownership lifecycle.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE152_PATH="Development/Logs/stage152-postoffice-common-glue-20261106T213032Z.log"
STAGE152_SHA="e4f7baab619ec0c4236cda34b1490eb50045f332"
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
WORK="$(mktemp -d "$TMPROOT/stage153-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage153-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE152_PATH?ref=main" > "$WORK/stage152.json"
python3 - "$WORK/stage152.json" "$STAGE152_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE153_STAGE152_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage152 report blob SHA mismatch")
print("STAGE152_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE153_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE153 POST OFFICE MESSAGE DELIVERY AND OWNERSHIP AUDIT =========="
 echo "STAGE153_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE153_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE153_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE153_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE153_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE153_STAGE152_REPORT_SHA=$STAGE152_SHA"
 echo "STAGE153_SCOPE=READ_ONLY_POSTOFFICE_SEND_QUEUE_DELIVER_WORKQUEUE_AND_CONTROLLER_OWNERSHIP"
 echo "STAGE153_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE153_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE153_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE153_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; owner="com.apple.iokit.IO80211Family"
print("STAGE153_FILES_BASE=0x%x"%kc.base)
print("STAGE153_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE153_SYMBOL_COUNT=%d"%len(kc.syms))
# Resolve the virtual controller hooks used by CreatePostOffice and the start/stop paths.
vt=kc.vtable("IO80211Controller")
print("CONTROLLER_VTABLE_STATUS=%s"%("FOUND" if vt else "NOT_FOUND"))
slot_targets=[]
if vt:
 for off in (0xC58,0xC60,0xC68,0xDC0):
  idx=2+off//8
  if idx<len(vt):
   _i,raw,target,name=vt[idx]
   own=kc.owner(target) or "UNATTRIBUTED"
   print("CONTROLLER_VTABLE_SLOT OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(off,idx,raw,target,own,name))
   if own==owner and kc.syms.get(target): slot_targets.append((target,kc.syms[target],"CONTROLLER_SLOT_0x%x"%off))
# Audit exact PostOffice and controller symbols. Full method instructions are printed for PostOffice
# operations; controller lifetime methods print call/branch and +0xB08/+0x120 references.
exact=[
("__ZN17IO80211PostOffice15allocWithParamsEP16IO80211WorkQueue","POSTOFFICE_ALLOC"),
("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
("__ZN17IO80211PostOffice8sendMailEP23IO80211SkywalkInterfacejPvmb","POSTOFFICE_SEND"),
("__ZN17IO80211PostOffice12sendMailSyncEP23IO80211SkywalkInterfacejPvmb","POSTOFFICE_SEND_SYNC"),
("__ZN17IO80211PostOffice14deliverMessageEP23IO80211SkywalkInterfacejPvmb","POSTOFFICE_DELIVER"),
("__ZN17IO80211PostOffice14outForDeliveryEv","POSTOFFICE_DRAIN"),
("__ZN17IO80211PostOffice19outForDeliveryTimerEP18IO80211TimerSource","POSTOFFICE_TIMER"),
("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE"),
("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_FACTORY"),
("__ZN17IO80211Controller13getPostOfficeEv","CONTROLLER_GET_POSTOFFICE"),
("__ZN17IO80211Controller5startEP9IOService","CONTROLLER_START"),
("__ZN17IO80211Controller4stopEP9IOService","CONTROLLER_STOP"),
("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
("__ZN17IO80211Controller11postMessageEP23IO80211SkywalkInterfacejPvmb","CONTROLLER_POST_MESSAGE"),
("__ZN17IO80211Controller15postMessageSyncEP23IO80211SkywalkInterfacejPvmb","CONTROLLER_POST_MESSAGE_SYNC"),
("__ZN16IO80211WorkQueue9workQueueEv","WORKQUEUE_GETTER"),
]
image=os.path.join(os.environ["STAGE153_WORK"],"IO80211Family.macho")
kc.carve(owner,image)
def dump(mangled,tag,limit=0x3000):
 addr=kc.find(mangled)
 if not addr:
  print("METHOD_NOT_FOUND TAG=%s SYMBOL=%s"%(tag,mangled)); return
 end=kc.next_sym(addr) or addr+limit
 if end<=addr or end>addr+limit: end=addr+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",mangled,image],capture_output=True,text=True)
 if p.returncode:
  print("METHOD_DISASSEMBLY_FAILED TAG=%s SYMBOL=%s ERROR=%s"%(tag,mangled,p.stderr.strip()[:300])); return
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr:
  print("METHOD_NOT_VERIFIED TAG=%s SYMBOL=%s ADDRESS=0x%x"%(tag,mangled,addr));return
 print("\nMETHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x END=0x%x INSTRUCTIONS=%d"%(tag,mangled,addr,end,len(ins)))
 for i,(a,raw,asm) in enumerate(ins):
  keep=(tag.startswith("POSTOFFICE") or tag.startswith("WORKQUEUE") or
        i<20 or re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b|0xb08|0x120|0xc68|retain|release|PostOffice|WorkQueue",asm,re.I))
  if keep:
   print(raw)
   if re.search(r"\b(call|jmp|je|jne|j[a-z]+|ret)\b",asm):
    print("CONTROL_FLOW=0x%x %s"%(a,asm))
for mangled,tag in exact: dump(mangled,tag)
# Disassemble exact vtable targets to resolve any indirect dispatches.
for addr,name,tag in slot_targets:
 if name not in [x[0] for x in exact]: dump(name,tag)
# Inventory additional exact symbols that mention workqueue, post office, or queue callbacks.
related=sorted((a,n) for a,n in kc.syms.items()
 if kc.sym_owner.get(a)==owner and (("PostOffice" in n) or ("IO80211WorkQueue" in n and any(k in n for k in ("workQueue","init","start","stop","free","dispatch")))))
print("\nRELATED_SYMBOL_COUNT=%d"%len(related))
for a,n in related[:180]: print("RELATED_SYMBOL ADDRESS=0x%x NAME=%s"%(a,n))
print("\nSTAGE153_INTERPRETATION=STATIC_CALLGRAPH_AND_VTABLE_ONLY; RETAIN_COUNTS_RUNTIME_QUEUE_ORDER_AND_EXECUTION_NOT_PROVEN")
PY
 echo "STAGE153_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE153_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE153 =========="
} >"$REPORT"
echo "===== STAGE153 SUMMARY ====="
grep -aE '^(STAGE153_|STAGE152_REPORT_INTEGRITY=|CONTROLLER_VTABLE_STATUS=|CONTROLLER_VTABLE_SLOT |METHOD_TAG=|METHOD_NOT_FOUND |METHOD_NOT_VERIFIED |METHOD_DISASSEMBLY_FAILED |CONTROL_FLOW=|RELATED_SYMBOL_COUNT=|RELATED_SYMBOL |STAGE153_INTERPRETATION=)' "$REPORT" | head -420 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage153-postoffice-delivery-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage153: publish read-only PostOffice delivery and ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE153_UPLOAD_SHA="+actual);print("STAGE153_GITHUB_PATH="+dest);print("STAGE153_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE153_UPLOAD_SHA="+existing);print("STAGE153_GITHUB_PATH="+dest);print("STAGE153_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE153_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE153_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE153_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
