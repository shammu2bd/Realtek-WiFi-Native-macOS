#!/bin/bash
# Stage143: trace Apple 24H32 Wi-Fi power selector dispatch from interface to controller.
# READ ONLY. No source edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || echo /tmp)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage143-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage143-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE143_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE143 APPLE WIFI POWER SELECTOR DISPATCH AUDIT =========="
 echo "STAGE143_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE143_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE143_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE143_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE143_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE143_SCOPE=READ_ONLY_APPLE_INTERFACE_COMMAND_TO_CONTROLLER_POWER_CALLBACK_DISPATCH"
 echo "STAGE143_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE143_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE143_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE143_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
classes=("IO80211Controller","IO80211SkywalkInterface","IO80211InfraInterface",
         "IOSkywalkEthernetInterface","IOSkywalkNetworkInterface")
tokens=("getpower","setpower","processinterfacecommand","processbsdcommand",
        "setinterfaceenable","interfaceadvisoryenable","getpowerstate","setpowerstate")
selected={}
owners=set()
print("STAGE143_FILES_BASE=0x%x"%kc.base)
print("STAGE143_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE143_SYMBOL_COUNT=%d"%len(kc.syms))
for cls in classes:
    methods=kc.methods(cls)
    print("\nCLASS=%s METHOD_COUNT=%d"%(cls,len(methods)))
    hits=0
    for addr,nm in methods:
        if any(t in nm.lower() for t in tokens):
            owner=kc.sym_owner.get(addr)
            print("CLASS_METHOD=0x%x OWNER=%s SYMBOL=%s"%(addr,owner or "UNATTRIBUTED",nm))
            if owner:
                selected[addr]=nm; owners.add(owner); hits+=1
    print("CLASS_RELEVANT_METHOD_COUNT=%d"%hits)
    vt=kc.vtable(cls)
    if vt is None:
        print("VTABLE_CLASS=%s STATUS=NOT_FOUND"%cls)
        continue
    vhits=0
    for word,raw,target,nm in vt:
        if any(t in nm.lower() for t in tokens):
            owner=kc.owner(target)
            objoff=(word-2)*8
            print("VTABLE_TARGET CLASS=%s WORD=%d OBJECT_VPTR_OFFSET=0x%x RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%
                  (cls,word,objoff,raw,target,owner or "UNATTRIBUTED",nm))
            vhits+=1
    print("VTABLE_CLASS=%s RELEVANT_TARGET_COUNT=%d"%(cls,vhits))
# Include Apple-family owner-wide power/command symbols, including controller callback
# implementations not matched by an individual class method parser.
for addr,nm in sorted(kc.syms.items()):
    owner=kc.sym_owner.get(addr)
    if owner=="com.apple.iokit.IO80211Family" and any(t in nm.lower() for t in tokens):
        selected.setdefault(addr,nm); owners.add(owner)
print("\nSTAGE143_UNIQUE_CANDIDATES=%d"%len(selected))
for owner in sorted(owners):
    if owner not in kc.entry_segs:
        print("OWNER_IMAGE=%s STATUS=NO_FILESET_ENTRY"%owner); continue
    dest=pathlib.Path(os.environ["STAGE143_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
    kc.carve(owner,str(dest))
    print("\nOWNER_IMAGE=%s STATUS=CARVED"%owner)
    count=0
    for addr,nm in sorted(selected.items()):
        if kc.sym_owner.get(addr)!=owner: continue
        end=kc.next_sym(addr) or addr+0x1000
        if end<=addr or end>addr+0x1000: end=addr+0x1000
        p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",nm,str(dest)],capture_output=True,text=True)
        print("\nMETHOD_SYMBOL="+nm)
        print("METHOD_ADDRESS=0x%x"%addr)
        print("METHOD_OWNER="+owner)
        print("METHOD_END_BOUND=0x%x"%end)
        print("OTOOL_EXIT=%d"%p.returncode)
        if p.returncode:
            print("METHOD_DISASSEMBLY=FAILED")
            print("OTOOL_ERROR="+p.stderr[:1000].replace("\n"," | "))
            continue
        ins=[]
        for line in p.stdout.splitlines():
            m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
            if m:
                a=int(m.group(1),16)
                if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
        if not ins or ins[0][0]!=addr:
            print("METHOD_DISASSEMBLY=NOT_VERIFIED")
            continue
        print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
        print("INSTRUCTION_COUNT=%d"%len(ins))
        for a,rawline,asm in ins:
            print(rawline)
            if re.search(r"\b(call|jmp)q?\b",asm):
                print("CONTROL_FLOW=0x%x %s"%(a,asm))
        count+=1
    print("OWNER_DISASSEMBLED_COUNT=%d"%count)
print("STAGE143_DISASSEMBLY_POLICY=EXACT_SYMBOL_START_AND_NEXT_SYMBOL_BOUND")
print("STAGE143_INTERPRETATION=STATIC_APPLE_BOOTKC_ONLY; NO_DRIVER_RUNTIME_CLAIM")
PY
 echo "STAGE143_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE143_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE143 =========="
} >"$REPORT"
echo "===== STAGE143 SUMMARY ====="
grep -aE '^(STAGE143_|CLASS=|CLASS_METHOD=|CLASS_RELEVANT_METHOD_COUNT=|VTABLE_TARGET |VTABLE_CLASS=|OWNER_IMAGE=|METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=|OWNER_DISASSEMBLED_COUNT=)' "$REPORT" | head -260 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage143-apple-wifi-power-dispatch-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage143: publish read-only Apple Wi-Fi POWER dispatch audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE143_UPLOAD_SHA="+actual);print("STAGE143_GITHUB_PATH="+dest);print("STAGE143_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE143_UPLOAD_SHA="+existing);print("STAGE143_GITHUB_PATH="+dest);print("STAGE143_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE143_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE143_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE143_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
