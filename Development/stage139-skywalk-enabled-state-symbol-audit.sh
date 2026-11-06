#!/bin/bash
# Stage139: resolve actual Skywalk enabled-state/advisory symbols and related vtable entries.
# READ ONLY. No source edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"; [[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch: $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage139-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage139-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE139_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE139 SKYWALK ENABLED STATE SYMBOL RESOLUTION =========="
 echo "STAGE139_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE139_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE139_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE139_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE139_SCOPE=READ_ONLY_SYMBOL_ENUMERATION_VTABLE_CORRELATION_AND_BOUNDED_DISASSEMBLY"
 echo "STAGE139_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE139_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE139_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE139_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
owner="com.apple.iokit.IOSkywalkFamily"
classes=("IOSkywalkInterface","IOSkywalkNetworkInterface","IOSkywalkEthernetInterface")
tokens=("isenabled","interfaceadvisory","setinterfaceenable","enable","disable","advisory")
selected={}
print("STAGE139_FILES_BASE=0x%x"%kc.base)
print("STAGE139_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE139_SYMBOL_COUNT=%d"%len(kc.syms))
for bid,vm,fo in kc.entries:
    if bid==owner: print("STAGE139_OWNER_ENTRY=%s VMADDR=0x%x FILEOFF=0x%x"%(bid,vm,fo))
print("\n--- Class method inventory (exact BootKC symbols) ---")
for cls in classes:
    methods=kc.methods(cls)
    print("CLASS=%s METHOD_COUNT=%d"%(cls,len(methods)))
    for addr,nm in methods:
        if any(t in nm.lower() for t in tokens) and kc.sym_owner.get(addr)==owner:
            selected[addr]=nm
            print("CLASS_METHOD=0x%x OWNER=%s SYMBOL=%s"%(addr,kc.sym_owner.get(addr),nm))
print("\n--- Owner-wide enabled/advisory symbol inventory ---")
for addr,nm in sorted(kc.syms.items()):
    if kc.sym_owner.get(addr)==owner and any(t in nm.lower() for t in tokens):
        selected.setdefault(addr,nm)
        print("OWNER_SYMBOL=0x%x SYMBOL=%s"%(addr,nm))
print("STAGE139_UNIQUE_DISASSEMBLY_CANDIDATES=%d"%len(selected))
print("\n--- Relevant vtable targets ---")
for cls in classes:
    vt=kc.vtable(cls)
    if vt is None:
        print("VTABLE_CLASS=%s STATUS=NOT_FOUND"%cls)
        continue
    hits=0
    for absolute_index,raw,target,nm in vt:
        if any(t in nm.lower() for t in tokens):
            hits+=1
            object_offset=(absolute_index-2)*8
            print("VTABLE_TARGET CLASS=%s WORD=%d OBJECT_VPTR_OFFSET=0x%x RAW=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,absolute_index,object_offset,raw,target,kc.owner(target) or "UNATTRIBUTED",nm))
    print("VTABLE_CLASS=%s RELEVANT_TARGET_COUNT=%d"%(cls,hits))
print("\n--- Bounded exact-start disassembly of candidates ---")
dest=pathlib.Path(os.environ["STAGE139_WORK"])/"IOSkywalkFamily.macho"
kc.carve(owner,str(dest))
disassembled=0
for addr,nm in sorted(selected.items()):
    if kc.sym_owner.get(addr)!=owner: continue
    end=kc.next_sym(addr) or addr+0x1000
    if end<=addr or end>addr+0x1000: end=addr+0x1000
    p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",nm,str(dest)],capture_output=True,text=True)
    print("\nMETHOD_SYMBOL="+nm)
    print("METHOD_ADDRESS=0x%x"%addr)
    print("METHOD_OWNER="+str(kc.sym_owner.get(addr)))
    print("METHOD_END_BOUND=0x%x"%end)
    print("OTOOL_EXIT=%d"%p.returncode)
    if p.returncode:
        print("METHOD_DISASSEMBLY=FAILED")
        print("OTOOL_ERROR="+p.stderr[:1200].replace("\n"," | "))
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
    disassembled+=1
print("STAGE139_DISASSEMBLED_METHOD_COUNT=%d"%disassembled)
print("STAGE139_DISASSEMBLY_POLICY=EXACT_SYMBOL_START_AND_NEXT_SYMBOL_BOUND")
PY
 echo "STAGE139_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE139_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE139 =========="
} >"$REPORT"
echo "===== STAGE139 SUMMARY ====="
grep -aE '^(STAGE139_|CLASS=|CLASS_METHOD=|OWNER_SYMBOL=|VTABLE_TARGET |VTABLE_CLASS=|METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=)' "$REPORT" | head -240 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage139-skywalk-enabled-state-symbols-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage139: publish read-only Skywalk enabled-state symbol resolution","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE139_UPLOAD_SHA="+actual)
            print("STAGE139_GITHUB_PATH="+dest)
            print("STAGE139_UPLOAD=PASS")
            break
        last="GitHub blob SHA mismatch: "+str(actual)
    else:
        last=r.stderr.strip() or r.stdout.strip()
    chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
    if chk.returncode==0:
        try: existing=json.loads(chk.stdout).get("sha")
        except Exception: existing=None
        if existing==expected:
            print("STAGE139_UPLOAD_SHA="+existing)
            print("STAGE139_GITHUB_PATH="+dest)
            print("STAGE139_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT")
            break
        print("STAGE139_UPLOAD_CONFLICT="+str(existing))
        raise SystemExit(8)
    print("STAGE139_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE139_UPLOAD=FAILED")
    print(last)
    raise SystemExit(9)
PY
