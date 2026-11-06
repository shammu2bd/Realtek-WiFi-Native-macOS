#!/bin/bash
# Stage135: resolve and disassemble the exact virtual targets called by Stage134.
# Read-only BootKC analysis. No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
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
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: expected macOS 15.8.1 24H32 x86_64; found $OSVER $BUILD $ARCH"; exit 3; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC not readable"; exit 4; }
for cmd in curl gh python3 shasum file; do command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd"; exit 5; }; done
OTOOL="$(command -v otool 2>/dev/null || true)"
[[ -x "$OTOOL" ]] || { echo "ERROR: otool missing"; exit 6; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI unauthenticated"; exit 7; }
BOOTKC_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOTKC_SHA" == "$EXPECTED_BOOTKC_SHA" ]] || { echo "ERROR: BootKC SHA mismatch expected=$EXPECTED_BOOTKC_SHA actual=$BOOTKC_SHA"; exit 8; }
TMPROOT="$(printenv TMPDIR 2>/dev/null || echo /tmp)"
WORK="$(mktemp -d "$TMPROOT/stage135-tools-XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage135-report-XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$UPSTREAM_KCFILE_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
h=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE135_KCFILE_GIT_BLOB_SHA="+h)
if h!=sys.argv[2]: raise SystemExit("Pinned reader SHA mismatch")
PY
SOURCE="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE135 APPLE SKYWALK VIRTUAL TARGET RESOLUTION =========="
 echo "STAGE135_SOURCE_COMMIT=$SOURCE"
 echo "STAGE135_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE135_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE135_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE135_SCOPE=READ_ONLY_EXACT_VTABLE_TARGET_RESOLUTION_AND_DISASSEMBLY"
 echo "STAGE135_BOOTKC_SHA256=$BOOTKC_SHA"
 echo "STAGE135_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE135_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 STAGE135_READER="$WORK" STAGE135_CACHE="$WORK/carved" python3 - "$BOOTKC" "$OTOOL" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE135_READER"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
pathlib.Path(os.environ["STAGE135_CACHE"]).mkdir(parents=True,exist_ok=True)
print("STAGE135_FILES_BASE=0x%x"%kc.base)
print("STAGE135_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE135_SYMBOL_COUNT=%d"%len(kc.syms))
# Byte offsets are from the receiver's vtable address point, as evidenced by
# Stage134's exact call instructions. kc.vtable() indexes include the 0x10 header.
requests=[
 ("ENABLE_IFNET_PROVIDER","IOSkywalkEthernetInterface",0x8f8),
 ("ENABLE_NETWORK_BASE","IOSkywalkNetworkInterface",0x860),
 ("ENABLE_POST_MULTICAST","IOSkywalkEthernetInterface",0xa90),
 ("DISABLE_NETWORK_BASE","IOSkywalkNetworkInterface",0x928),
]
resolved=[]
print("\n--- Exact virtual slot resolution ---")
for label,cls,offset in requests:
 vt=kc.vtable(cls)
 print("\nVIRTUAL_REQUEST=%s CLASS=%s ADDRESS_POINT_OFFSET=0x%x"%(label,cls,offset))
 if vt is None:
  print("VIRTUAL_RESOLUTION=VTABLE_NOT_FOUND"); continue
 idx=(0x10+offset)//8
 item=next((x for x in vt if x[0]==idx),None)
 if item is None:
  print("VIRTUAL_RESOLUTION=SLOT_NOT_FOUND INDEX=%d"%idx); continue
 index,raw,target,name=item
 owner=kc.owner(target)
 exact=kc.syms.get(target)
 nearest=kc.symname(target)
 print("VTABLE_INDEX=%d SYMBOL_RELATIVE_OFFSET=0x%x"%(index,index*8))
 print("VTABLE_RAW_QWORD=0x%x"%raw)
 print("VIRTUAL_TARGET=0x%x"%target)
 print("VIRTUAL_EXACT_SYMBOL="+str(exact or "NONE"))
 print("VIRTUAL_NEAREST_SYMBOL="+str(nearest or "UNRESOLVED"))
 print("VIRTUAL_OWNER="+str(owner or "UNATTRIBUTED"))
 segs=[s for s in kc.entry_segs.get(owner,[]) if s[1]<=target<s[1]+s[2]] if owner else []
 executable=any(s[5]&4 for s in segs)
 print("VIRTUAL_EXECUTABLE="+("YES" if executable else "NO_OR_UNKNOWN"))
 if exact and owner and executable:
  end=kc.next_sym(target) or target+0x1000
  if end<=target or end>target+0x1000: end=target+0x1000
  resolved.append((label,cls,offset,target,exact,owner,end))
 else:
  print("VIRTUAL_TARGET_STATUS=REVIEW_REQUIRED")
print("\nSTAGE135_EXPECTED_VIRTUAL_TARGETS=%d"%len(requests))
print("STAGE135_EXACT_EXECUTABLE_TARGETS=%d"%len(resolved))
owners=sorted({x[5] for x in resolved})
for owner in owners:
 dest=pathlib.Path(os.environ["STAGE135_CACHE"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
 kc.carve(owner,str(dest))
 print("CARVED_OWNER=%s"%owner)
 print("CARVED_BYTES=%d"%dest.stat().st_size)
 print("CARVED_FILE_TYPE="+subprocess.run(["file",str(dest)],capture_output=True,text=True).stdout.strip())
for owner in owners:
 local=[x for x in resolved if x[5]==owner]
 dest=pathlib.Path(os.environ["STAGE135_CACHE"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
 cmd=[otool,"-arch","x86_64","-tvV","-p",local[0][4],str(dest)]
 p=subprocess.run(cmd,capture_output=True,text=True)
 print("\nOTOOL_OWNER_DUMP=%s EXIT=%d"%(owner,p.returncode))
 if p.returncode:
  print("OTOOL_STDERR="+p.stderr[:4000]); continue
 lines=p.stdout.splitlines()
 for label,cls,offset,va,sym,own,end in local:
  print("\n===== VIRTUAL TARGET %s ====="%label)
  print("VIRTUAL_METHOD_CLASS=%s"%cls)
  print("VIRTUAL_METHOD_SYMBOL=%s"%sym)
  print("VIRTUAL_METHOD_RANGE=0x%x..0x%x"%(va,end))
  selected=[]
  for line in lines:
   m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
   if m:
    a=int(m.group(1),16)
    if va<=a<end: selected.append((a,line.strip(),m.group(2)))
  if not selected or selected[0][0]!=va:
   print("VIRTUAL_METHOD_DISASSEMBLY=NOT_VERIFIED"); continue
  print("VIRTUAL_METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("VIRTUAL_METHOD_INSTRUCTION_COUNT=%d"%len(selected))
  for a,raw,asm in selected:
   print(raw)
   if re.search(r"\b(call|jmp)q?\b",asm):
    print("VIRTUAL_METHOD_CONTROL_FLOW=0x%x %s"%(a,asm))
print("\nSTAGE135_RESOLUTION_POLICY=EXACT_SYMBOL_AND_EXECUTABLE_OWNER_REQUIRED")
PY
 echo
 echo "STAGE135_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE135_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE135 =========="
} >"$REPORT"
echo "===== STAGE135 SUMMARY ====="
grep -aE '^(STAGE135_|VIRTUAL_REQUEST=|VIRTUAL_TARGET=|VIRTUAL_EXACT_SYMBOL=|VIRTUAL_NEAREST_SYMBOL=|VIRTUAL_OWNER=|VIRTUAL_EXECUTABLE=|===== VIRTUAL TARGET|VIRTUAL_METHOD_DISASSEMBLY=|VIRTUAL_METHOD_INSTRUCTION_COUNT=|VIRTUAL_METHOD_CONTROL_FLOW=|OTOOL_OWNER_DUMP=)' "$REPORT" | tail -220 || true
echo "STAGE135_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage135-skywalk-virtual-targets-"+stamp+".log"
payload={"message":"Stage135: publish read-only Skywalk virtual target resolution","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE135_UPLOAD=PASS"); print("STAGE135_UPLOAD_SHA="+actual); print("STAGE135_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE135_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE135_UPLOAD_SHA="+existing); print("STAGE135_GITHUB_PATH="+dest); break
  print("STAGE135_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE135_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE135_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
