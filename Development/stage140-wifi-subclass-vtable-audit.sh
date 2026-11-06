#!/bin/bash
# Stage140: cross-family audit of Wi-Fi subclass virtual overrides for Skywalk enable/advisory state.
# READ ONLY. No source edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
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
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch: $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage140-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage140-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE140_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE140 WIFI SUBCLASS VIRTUAL OVERRIDE AUDIT =========="
 echo "STAGE140_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE140_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE140_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE140_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE140_SCOPE=READ_ONLY_CROSS_FAMILY_VTABLE_AND_METHOD_DISASSEMBLY"
 echo "STAGE140_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE140_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE140_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE140_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
classes=("IO80211SkywalkInterface","IO80211InfraInterface",
         "IOSkywalkNetworkInterface","IOSkywalkNetworkBSDClient")
tokens=("enable","disable","isenabled","advisory","setinterface")
slots=(0x788,0x850,0x858,0x920,0x928)
selected={}
owner_images={}
print("STAGE140_FILES_BASE=0x%x"%kc.base)
print("STAGE140_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE140_SYMBOL_COUNT=%d"%len(kc.syms))
for cls in classes:
    methods=kc.methods(cls)
    print("\nCLASS=%s METHOD_COUNT=%d"% (cls,len(methods)))
    for addr,nm in methods:
        if any(token in nm.lower() for token in tokens):
            owner=kc.sym_owner.get(addr)
            print("CLASS_METHOD=0x%x OWNER=%s SYMBOL=%s"%(addr,owner or "UNATTRIBUTED",nm))
            if owner:
                selected[addr]=nm
                owner_images[owner]=True
    vt=kc.vtable(cls)
    if vt is None:
        print("VTABLE_CLASS=%s STATUS=NOT_FOUND"%cls)
        continue
    print("VTABLE_CLASS=%s STATUS=FOUND"%cls)
    for offset in slots:
        word=2+(offset//8)
        item=next((entry for entry in vt if entry[0]==word),None)
        if item is None:
            print("VTABLE_SLOT CLASS=%s OBJECT_OFFSET=0x%x STATUS=NOT_FOUND"%(cls,offset))
            continue
        idx,raw,target,nm=item
        owner=kc.owner(target)
        exact=kc.syms.get(target)
        print("VTABLE_SLOT CLASS=%s OBJECT_OFFSET=0x%x WORD=%d RAW=0x%x TARGET=0x%x OWNER=%s EXACT_SYMBOL=%s NEAREST=%s"%
              (cls,offset,idx,raw,target,owner or "UNATTRIBUTED",exact or "NONE",nm))
        if exact and owner:
            selected[target]=exact
            owner_images[owner]=True
print("\nSTAGE140_UNIQUE_EXACT_METHODS=%d"%len(selected))
print("\n--- Exact-start, next-symbol-bounded method disassembly ---")
for owner in sorted(owner_images):
    if owner not in kc.entry_segs:
        print("OWNER_IMAGE=%s STATUS=NO_FILESET_ENTRY"%owner)
        continue
    dest=pathlib.Path(os.environ["STAGE140_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
    kc.carve(owner,str(dest))
    print("OWNER_IMAGE=%s STATUS=CARVED"%owner)
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
print("STAGE140_DISASSEMBLY_POLICY=EXACT_SYMBOL_START_AND_NEXT_SYMBOL_BOUND")
PY
 echo "STAGE140_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE140_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE140 =========="
} >"$REPORT"
echo "===== STAGE140 SUMMARY ====="
grep -aE '^(STAGE140_|CLASS=|CLASS_METHOD=|VTABLE_CLASS=|VTABLE_SLOT |OWNER_IMAGE=|METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|CONTROL_FLOW=)' "$REPORT" | head -260 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage140-wifi-subclass-vtables-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage140: publish read-only Wi-Fi subclass virtual override audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE140_UPLOAD_SHA="+actual)
            print("STAGE140_GITHUB_PATH="+dest)
            print("STAGE140_UPLOAD=PASS")
            break
        last="GitHub blob SHA mismatch: "+str(actual)
    else:
        last=r.stderr.strip() or r.stdout.strip()
    chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
    if chk.returncode==0:
        try: existing=json.loads(chk.stdout).get("sha")
        except Exception: existing=None
        if existing==expected:
            print("STAGE140_UPLOAD_SHA="+existing)
            print("STAGE140_GITHUB_PATH="+dest)
            print("STAGE140_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT")
            break
        print("STAGE140_UPLOAD_CONFLICT="+str(existing))
        raise SystemExit(8)
    print("STAGE140_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE140_UPLOAD=FAILED")
    print(last)
    raise SystemExit(9)
PY
