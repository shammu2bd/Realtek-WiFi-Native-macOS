#!/bin/bash
# Stage149: resolve the internal object/method relay used by Apple IO80211Controller::postMessage.
# READ ONLY. No checkout/source/index changes, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
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
WORK="$(mktemp -d "$TMPROOT/stage149-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage149-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE149_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE149 CONTROLLER POSTMESSAGE RELAY AUDIT =========="
 echo "STAGE149_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE149_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE149_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE149_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE149_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE149_SCOPE=READ_ONLY_RESOLVE_CONTROLLER_EXPANSION_0xB08_AND_RECEIVER_VTABLE_SLOT_0x120"
 echo "STAGE149_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE149_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE149_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$ROOT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE149_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]);otool=sys.argv[2];root=pathlib.Path(sys.argv[3])
wanted=[
 "__ZN17IO80211Controller11postMessageEP23IO80211SkywalkInterfacejPvmb",
 "__ZN17IO80211Controller15postMessageSyncEP23IO80211SkywalkInterfacejPvmb",
 "__ZN11IO80211Glue15routeEventToWclEjPvm",
 "__ZN11IO80211Glue13sendIOUCToWclEjjPvmRb"
]
symbols={}
for addr,name in kc.syms.items():
 if name in wanted or ("IO80211Controller" in name and any(k in name for k in ("init","start","free","postMessage"))):
  symbols[addr]=(name,kc.sym_owner.get(addr),kc.owner(addr))
print("STAGE149_FILES_BASE=0x%x"%kc.base)
print("STAGE149_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE149_SYMBOL_COUNT=%d"%len(kc.syms))
for target in wanted:
 found=[(a,n,o,so) for a,(n,so,o) in symbols.items() if n==target]
 if not found: print("SYMBOL_LOOKUP NAME=%s STATUS=NOT_FOUND"%target)
 for a,n,o,so in found: print("SYMBOL_LOOKUP NAME=%s ADDRESS=0x%x OWNER=%s SYMBOL_OWNER=%s"%(n,a,o or "UNATTRIBUTED",so or "UNATTRIBUTED"))
print("\n--- IO80211Glue virtual-table receiver candidates ---")
for cls in ("IO80211Glue","IO80211Controller","IO80211InfraInterface","IO80211SkywalkInterface"):
 vt=kc.vtable(cls)
 print("VTABLE CLASS=%s STATUS=%s"%(cls,"FOUND" if vt is not None else "NOT_FOUND"))
 if vt is None: continue
 for off in (0x120,0xB08):
  word=2+off//8
  e=next((x for x in vt if x[0]==word),None)
  if e:
   idx,raw,target,name=e
   print("VTABLE_SLOT CLASS=%s OBJECT_OFFSET=0x%x WORD=%d TARGET=0x%x OWNER=%s SYMBOL_OWNER=%s EXACT_SYMBOL=%s NEAREST=%s"%(cls,off,idx,target,kc.owner(target) or "UNATTRIBUTED",kc.sym_owner.get(target) or "UNATTRIBUTED",kc.syms.get(target) or "NONE",name))
print("\n--- Exact bounded method disassembly ---")
owners={v[1] for v in symbols.values() if v[1]}
paths={}
for bid,_,_ in kc.entries:
 if bid in owners:
  paths[bid]=pathlib.Path(os.environ["STAGE149_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",bid)+".macho")
for owner,dest in paths.items():
 if owner not in kc.entry_segs:
  print("OWNER_IMAGE=%s STATUS=NOT_A_CARVED_FILESET_ENTRY"%owner);continue
 kc.carve(owner,str(dest))
 for addr,(name,symowner,_) in sorted(symbols.items()):
  if symowner!=owner:continue
  if not (name in wanted or any(k in name for k in ("IO80211Controller.*init","IO80211Controller.*start","IO80211Controller.*postMessage"))):continue
  end=kc.next_sym(addr) or addr+0x1800
  if end<=addr or end>addr+0x1800:end=addr+0x1800
  p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,str(dest)],capture_output=True,text=True)
  print("\nMETHOD_SYMBOL="+name);print("METHOD_ADDRESS=0x%x"%addr);print("METHOD_OWNER="+owner)
  print("METHOD_NEXT_SYMBOL_BOUND=0x%x"%end);print("OTOOL_EXIT=%d"%p.returncode)
  if p.returncode:print("METHOD_DISASSEMBLY=FAILED");continue
  ins=[]
  for line in p.stdout.splitlines():
   m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
   if m:
    a=int(m.group(1),16)
    if addr<=a<end:ins.append((a,line.strip(),m.group(2)))
  if not ins or ins[0][0]!=addr:print("METHOD_DISASSEMBLY=NOT_VERIFIED");continue
  print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("INSTRUCTION_COUNT=%d"%len(ins))
  for a,raw,asm in ins:
   if name in wanted or re.search(r"0xb08|0x120|0x120\\(",asm,re.I) or re.search(r"postMessage|routeEvent|sendIOUC",asm):
    print(raw)
    if re.search(r"\b(call|jmp)q?\b",asm):print("CONTROL_FLOW=0x%x %s"%(a,asm))
print("\n--- Local source ownership of controller helper and postWCLMessage ---")
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
for filename in ("RTW88WCL24H32ABI.hpp","RTW88WCLInfraInterface.hpp","RTW88WCLInfraInterface.cpp","RTW88WCLController.hpp","RTW88WCLController.cpp"):
 p=base/filename
 if not p.exists():continue
 d=p.read_bytes();lines=d.decode("utf-8","replace").splitlines()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(filename,hashlib.sha256(d).hexdigest(),len(d)))
 for i,line in enumerate(lines):
  if re.search(r"postMessage|postWCLMessage|routeEventToWcl|sendIOUCToWcl",line):
   print("SOURCE_MATCH=%s:%d:%s"%(filename,i+1,line.strip()))
print("STAGE149_INTERPRETATION=STATIC_RELAY_MAPPING_ONLY; INTERNAL_RECEIVER_IDENTITY_REQUIRES_EXACT_SYMBOL_OR_LAYOUT_EVIDENCE")
PY
 echo "STAGE149_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE149_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE149 =========="
} >"$REPORT"
echo "===== STAGE149 SUMMARY ====="
grep -aE '^(STAGE149_|SYMBOL_LOOKUP |VTABLE CLASS=|VTABLE_SLOT |METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=|SOURCE_FILE=|SOURCE_MATCH=)' "$REPORT" | head -220 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage149-controller-postmessage-relay-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage149: publish read-only controller postMessage relay audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE149_UPLOAD_SHA="+actual);print("STAGE149_GITHUB_PATH="+dest);print("STAGE149_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE149_UPLOAD_SHA="+existing);print("STAGE149_GITHUB_PATH="+dest);print("STAGE149_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE149_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE149_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE149_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
