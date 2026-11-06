#!/bin/bash
# Stage136: correct the direct-vtable-symbol offset for IOSkywalkNetworkInterface::enable.
# Read-only BootKC audit. No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_KCFILE_SHA="5d31e8a73e5cb175851e7407529456f223683589"
EXPECTED_BOOTKC_SHA="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$ROOT" ]] || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
BRANCH="$(git branch --show-current 2>/dev/null || echo DETACHED_OR_UNKNOWN)"
STATUS="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
OSVER="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: expected macOS 15.8.1 24H32 x86_64"; exit 3; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC not readable"; exit 4; }
for cmd in curl gh python3 shasum file; do command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd"; exit 5; }; done
OTOOL="$(command -v otool 2>/dev/null || true)"; [[ -x "$OTOOL" ]] || { echo "ERROR: otool missing"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI unauthenticated"; exit 7; }
BOOTKC_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOTKC_SHA" == "$EXPECTED_BOOTKC_SHA" ]] || { echo "ERROR: BootKC SHA mismatch"; exit 8; }
TMPROOT="$(printenv TMPDIR 2>/dev/null || echo /tmp)"
WORK="$(mktemp -d "$TMPROOT/stage136-tools-XXXXXX")"; REPORT="$(mktemp "$TMPROOT/stage136-report-XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$UPSTREAM_KCFILE_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
h=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE136_KCFILE_GIT_BLOB_SHA="+h)
if h!=sys.argv[2]: raise SystemExit("Pinned reader SHA mismatch")
PY
SOURCE="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"; STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE136 CORRECTED SKY WALK NETWORK ENABLE SLOT AUDIT =========="
 echo "STAGE136_SOURCE_COMMIT=$SOURCE"
 echo "STAGE136_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE136_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE136_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE136_BOOTKC_SHA256=$BOOTKC_SHA"
 echo "STAGE136_SCOPE=READ_ONLY_DIRECT_VTABLE_SYMBOL_OFFSET_AND_EXACT_ENABLE_METHOD"
 echo "STAGE136_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE136_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 STAGE136_READER="$WORK" STAGE136_CACHE="$WORK/carved" python3 - "$BOOTKC" "$OTOOL" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE136_READER"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
pathlib.Path(os.environ["STAGE136_CACHE"]).mkdir(parents=True,exist_ok=True)
cls="IOSkywalkNetworkInterface"; vtoff=0x860
vt=kc.vtable(cls)
print("VIRTUAL_CALL_SITE=IOSkywalkEthernetInterface::enable(unsigned int) at 0xffffff8002988b25")
print("CALL_INSTRUCTION_USES_ADDRESS=ADDRESS_OF_VTABLE_SYMBOL_NOT_OBJECT_VPTR")
print("VIRTUAL_SLOT_CLASS="+cls)
print("VIRTUAL_SLOT_BYTE_OFFSET_FROM_VTABLE_SYMBOL=0x%x"%vtoff)
idx=vtoff//8
item=next((x for x in vt if x[0]==idx),None) if vt else None
if item is None: raise SystemExit("Corrected vtable symbol-relative slot not found")
index,raw,target,name=item
owner=kc.owner(target); exact=kc.syms.get(target); nearest=kc.symname(target)
print("VIRTUAL_SLOT_INDEX=%d"%index)
print("VIRTUAL_SLOT_RAW_QWORD=0x%x"%raw)
print("VIRTUAL_SLOT_TARGET=0x%x"%target)
print("VIRTUAL_SLOT_EXACT_SYMBOL="+str(exact or "NONE"))
print("VIRTUAL_SLOT_NEAREST_SYMBOL="+str(nearest or "UNRESOLVED"))
print("VIRTUAL_SLOT_OWNER="+str(owner or "UNATTRIBUTED"))
print("VIRTUAL_SLOT_EXPECTED_SYMBOL=__ZN25IOSkywalkNetworkInterface6enableEj")
print("VIRTUAL_SLOT_IDENTITY="+("PASS" if exact=="__ZN25IOSkywalkNetworkInterface6enableEj" else "REVIEW_REQUIRED"))
if not owner: raise SystemExit("Target owner unresolved")
segs=[s for s in kc.entry_segs.get(owner,[]) if s[1]<=target<s[1]+s[2]]
if not any(s[5]&4 for s in segs): raise SystemExit("Target is not in an executable segment")
end=kc.next_sym(target) or target+0x1000
if end<=target or end>target+0x1000: end=target+0x1000
dest=pathlib.Path(os.environ["STAGE136_CACHE"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
kc.carve(owner,str(dest))
print("CARVED_OWNER=%s"%owner); print("CARVED_BYTES=%d"%dest.stat().st_size)
p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",exact,str(dest)],capture_output=True,text=True)
print("OTOOL_EXIT=%d"%p.returncode)
if p.returncode: print("OTOOL_STDERR="+p.stderr[:4000]); raise SystemExit("otool failed")
lines=p.stdout.splitlines(); selected=[]
for line in lines:
 m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
 if m:
  a=int(m.group(1),16)
  if target<=a<end: selected.append((a,line.strip(),m.group(2)))
print("METHOD_SYMBOL="+str(exact)); print("METHOD_RANGE=0x%x..0x%x"%(target,end))
if not selected or selected[0][0]!=target:
 print("METHOD_DISASSEMBLY=NOT_VERIFIED")
else:
 print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
 print("METHOD_INSTRUCTION_COUNT=%d"%len(selected))
 for a,rawline,asm in selected:
  print(rawline)
  if re.search(r"\b(call|jmp)q?\b",asm): print("METHOD_CONTROL_FLOW=0x%x %s"%(a,asm))
print("STAGE136_CORRECTION=Stage135 ENABLE_NETWORK_BASE index was one entry too high because the assembly loads the vtable symbol address directly.")
PY
 echo "STAGE136_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE136_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE136 =========="
} >"$REPORT"
echo "===== STAGE136 SUMMARY ====="
grep -aE '^(STAGE136_|VIRTUAL_|METHOD_|OTOOL_EXIT=|CARVED_OWNER=)' "$REPORT" | tail -140 || true
echo "STAGE136_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage136-skywalk-enable-slot-correction-"+stamp+".log"
payload={"message":"Stage136: publish corrected read-only Skywalk enable slot audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
expected=hashlib.sha1(("blob "+str(len(data))+"\0").encode("ascii")+data).hexdigest()
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f); f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE136_UPLOAD=PASS"); print("STAGE136_UPLOAD_SHA="+actual); print("STAGE136_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE136_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE136_UPLOAD_SHA="+existing); print("STAGE136_GITHUB_PATH="+dest); break
  print("STAGE136_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE136_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE136_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
