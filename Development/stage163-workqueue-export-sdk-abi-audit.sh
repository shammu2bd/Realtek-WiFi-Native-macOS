#!/bin/bash
# Stage163: read-only IO80211WorkQueue factory export / SDK ABI audit.
# Never modify sources, index, worktree, OpenCore, or security settings.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run in existing project checkout"; exit 2; }
cd "$ROOT"
[[ "$(git rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || { echo "ERROR: checkout HEAD mismatch"; exit 3; }
[[ "$(git remote get-url origin 2>/dev/null || true)" == *"Realtek-WiFi-Native-macOS"* ]] || { echo "ERROR: unexpected git origin"; exit 4; }

OS="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
  echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 5;
}
for c in curl gh python3 shasum otool nm git xcrun; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing tool $c"; exit 6; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 7; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 8; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch: $BOOT_SHA"; exit 9; }

WORK="$(mktemp -d "$TMPROOT/stage163-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage163-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE163_READER_BLOB_SHA="+actual)
if actual != sys.argv[2]:
    raise SystemExit("STOP: pinned KC reader blob mismatch")
PY

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
  echo "========== STAGE163 IO80211WORKQUEUE FACTORY EXPORT AND SDK ABI AUDIT =========="
  echo "STAGE163_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE163_HEAD=$(git rev-parse HEAD)"
  echo "STAGE163_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE163_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE163_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE163_SDK_PATH=${SDK:-UNAVAILABLE}"
  echo "STAGE163_SCOPE=READ_ONLY_WORKQUEUE_FACTORY_SYMBOL_VISIBILITY_AND_SDK_DECLARATION"
  echo "STAGE163_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE163_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE163_WORK="$WORK" STAGE163_BOOTKC="$BOOTKC" STAGE163_SDK="$SDK" python3 - "$WORK/kcfile.py" "$(command -v otool)" "$(command -v nm)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.path.dirname(sys.argv[1]))
from kcfile import KC

otool,nm=sys.argv[2],sys.argv[3]
kc=KC(os.environ["STAGE163_BOOTKC"])
owner="com.apple.iokit.IO80211Family"
image=os.path.join(os.environ["STAGE163_WORK"],"IO80211Family.macho")
try:
    kc.carve(owner,image)
    print("FILESSET_CARVE=PASS OWNER="+owner)
except Exception as e:
    raise SystemExit("FILESSET_CARVE=FAIL ERROR="+str(e)[:400])

symbols={
 "FACTORY":"__ZN16IO80211WorkQueue9workQueueEv",
 "DEFAULT_GET":"__ZN16IO80211WorkQueue19getDefaultWorkQueueEv",
 "DEFAULT_SET":"__ZN16IO80211WorkQueue19setDefaultWorkQueueEPS_",
 "DEFAULT_CTOR":"__ZN16IO80211WorkQueueC1Ev",
 "META_ALLOC":"__ZNK16IO80211WorkQueue9MetaClass5allocEv",
 "META_OBJECT":"__ZN16IO80211WorkQueue10gMetaClassE",
 "POSTOFFICE_ALLOC":"__ZN17IO80211PostOffice15allocWithParamsEP16IO80211WorkQueue",
}
def run(args):
    return subprocess.run(args,capture_output=True,text=True)
m=run([nm,"-arch","x86_64","-m",image])
g=run([nm,"-arch","x86_64","-gU",image])
print("NM_M_RETURN_CODE=%d"%m.returncode)
print("NM_GLOBAL_DEFINED_RETURN_CODE=%d"%g.returncode)
if m.stderr.strip(): print("NM_M_STDERR="+m.stderr.strip()[:500])
if g.stderr.strip(): print("NM_GLOBAL_STDERR="+g.stderr.strip()[:500])
if m.returncode or g.returncode:
    print("NM_VISIBILITY_AUDIT=INCOMPLETE")
else:
    for label,sym in symbols.items():
        matches=[x.strip() for x in m.stdout.splitlines() if sym in x]
        global_matches=[x.strip() for x in g.stdout.splitlines() if sym in x]
        print("SYMBOL_"+label+"="+sym)
        print("SYMBOL_"+label+"_NM_M_MATCHES="+str(len(matches)))
        for line in matches[:5]: print("NM_M "+label+" "+line)
        print("SYMBOL_"+label+"_GLOBAL_DEFINED_MATCHES="+str(len(global_matches)))
        for line in global_matches[:5]: print("NM_GLOBAL "+label+" "+line)
        private=any("private external" in x.lower() for x in matches)
        external=any("external" in x.lower() and "private external" not in x.lower() for x in matches)
        print("SYMBOL_"+label+"_PRIVATE_EXTERNAL="+("YES" if private else "NO_OR_NOT_SHOWN"))
        print("SYMBOL_"+label+"_ORDINARY_EXTERNAL="+("YES" if external else "NO_OR_NOT_SHOWN"))

# Link-edit command metadata is evidence only; no assumptions are made if absent.
loads=run([otool,"-l",image])
print("OTOOL_LOAD_COMMANDS_RETURN_CODE=%d"%loads.returncode)
if loads.returncode==0:
    relevant=[]
    rows=loads.stdout.splitlines()
    for i,line in enumerate(rows):
        if "LC_DYLD_EXPORTS_TRIE" in line or "LC_DYLD_INFO_ONLY" in line or "LC_SYMTAB" in line or "LC_DYSYMTAB" in line:
            relevant.extend(rows[i:min(i+8,len(rows))])
    for line in relevant: print("LINKEDIT "+line.strip())
else:
    print("OTOOL_LOAD_COMMANDS_ERROR="+loads.stderr.strip()[:400])

import shutil
dyld_info=shutil.which("dyld_info") or shutil.which("dyldinfo")
if dyld_info:
    exp=run([dyld_info,"-exports",image])
    print("DYLD_INFO_EXPORTS_RETURN_CODE=%d"%exp.returncode)
    for line in exp.stdout.splitlines():
        if any(s in line for s in symbols.values()): print("DYLD_EXPORT "+line.strip())
    if exp.stderr.strip(): print("DYLD_INFO_EXPORTS_STDERR="+exp.stderr.strip()[:400])
else:
    print("DYLD_INFO_EXPORTS=UNAVAILABLE")

# Preserve the precise factory implementation for review.
factory=symbols["FACTORY"]
addr=kc.find(factory)
print("FACTORY_ADDRESS="+("0x%x"%addr if addr else "NOT_FOUND"))
print("FACTORY_OWNER="+(kc.owner(addr) or "UNKNOWN" if addr else "UNKNOWN"))
if addr:
    dis=run([otool,"-arch","x86_64","-tvV","-p",factory,image])
    print("FACTORY_DISASSEMBLY_RETURN_CODE=%d"%dis.returncode)
    if dis.returncode==0:
        kept=[]
        for line in dis.stdout.splitlines():
            if re.match(r"^\s*(?:0x)?[0-9a-fA-F]{8,}",line): kept.append(line.strip())
        for line in kept[:180]: print("FACTORY_ASM "+line)
    else:
        print("FACTORY_DISASSEMBLY_ERROR="+dis.stderr.strip()[:400])
for label in ("DEFAULT_GET","DEFAULT_SET"):
    sym=symbols[label]
    a=kc.find(sym)
    print(label+"_ADDRESS="+("0x%x"%a if a else "NOT_FOUND"))
    if a:
        d=run([otool,"-arch","x86_64","-tvV","-p",sym,image])
        print(label+"_DISASSEMBLY_RETURN_CODE=%d"%d.returncode)
        if d.returncode==0:
            kept=[]
            for line in d.stdout.splitlines():
                if re.match(r"^\s*(?:0x)?[0-9a-fA-F]{8,}",line): kept.append(line.strip())
            for line in kept[:100]: print(label+"_ASM "+line)

# Search the installed SDK's IOKit and Kernel headers only (bounded, read-only).
sdk=os.environ.get("STAGE163_SDK","")
header_roots=[]
if sdk:
    for rel in ("System/Library/Frameworks/IOKit.framework/Headers",
                "System/Library/Frameworks/Kernel.framework/Headers"):
        p=os.path.join(sdk,rel)
        if os.path.isdir(p): header_roots.append(p)
print("SDK_HEADER_ROOT_COUNT=%d"%len(header_roots))
hits=[]
for root in header_roots:
    for base,dirs,files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git","PrivateHeaders")]
        for name in files:
            if not name.endswith((".h",".hpp",".tbd",".modulemap")): continue
            p=os.path.join(base,name)
            try:
                data=open(p,encoding="utf-8",errors="ignore").read()
            except OSError:
                continue
            if "IO80211WorkQueue" in data:
                hits.append(p)
                for n,line in enumerate(data.splitlines(),1):
                    if "IO80211WorkQueue" in line:
                        print("SDK_DECLARATION_CANDIDATE %s:%d:%s"%(p,n,line.strip()[:240]))
if not hits:
    print("SDK_IO80211WORKQUEUE_DECLARATION=NOT_FOUND_IN_SELECTED_PUBLIC_HEADER_ROOTS")
else:
    print("SDK_IO80211WORKQUEUE_HEADER_FILES=%d"%len(set(hits)))

print("STAGE163_INTERPRETATION=REPORT_VISIBILITY_AND_SDK_FACTS_SEPARATELY; THIS_AUDIT_DOES_NOT_PROVE_SUPPORTED_KEXT_LINKABILITY_OR_QUEUE_OWNERSHIP")
PY

  echo "STAGE163_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
  echo "STAGE163_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE163 =========="
} > "$REPORT"

echo "===== STAGE163 SUMMARY ====="
grep -aE '^(STAGE163_|FILESSET_CARVE=|NM_|SYMBOL_.*(MATCHES|PRIVATE_EXTERNAL|ORDINARY_EXTERNAL)=|DYLD_INFO_EXPORTS=|DYLD_INFO_EXPORTS_RETURN_CODE=|DYLD_EXPORT |LINKEDIT |FACTORY_ADDRESS=|FACTORY_OWNER=|FACTORY_DISASSEMBLY_RETURN_CODE=|FACTORY_ASM |DEFAULT_(GET|SET)_ADDRESS=|SDK_HEADER_ROOT_COUNT=|SDK_DECLARATION_CANDIDATE |SDK_IO80211WORKQUEUE_DECLARATION=|SDK_IO80211WORKQUEUE_HEADER_FILES=|STAGE163_INTERPRETATION=)' "$REPORT" | head -260 || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage163-workqueue-export-sdk-abi-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage163: publish read-only workqueue factory export and SDK ABI audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f); f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE163_UPLOAD_SHA="+actual); print("STAGE163_GITHUB_PATH="+dest); print("STAGE163_UPLOAD=PASS"); break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
    if check.returncode==0:
        try: actual=json.loads(check.stdout).get("sha")
        except Exception: actual=None
        if actual==expected:
            print("STAGE163_UPLOAD_SHA="+actual); print("STAGE163_GITHUB_PATH="+dest); print("STAGE163_UPLOAD=PASS_RECOVERED"); break
        if actual:
            print("STAGE163_UPLOAD_CONFLICT="+str(actual)); raise SystemExit(10)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE163_UPLOAD=FAILED"); print(last); raise SystemExit(11)
PY
