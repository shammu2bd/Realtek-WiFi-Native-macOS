#!/bin/bash
# Stage170: audit WorkLoop chain insertion, CommandGate/Pool lifetimes and IO80211WorkQueue inheritance.
# READ ONLY. No project source/build outputs, signing, install/load, AuxKC or OpenCore changes.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE165_PATH="Development/Logs/stage165-kmutil-repository-bundle-discovery-20261107T061052Z.log"
STAGE165_SHA="97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277"
STAGE166_PATH="Development/Logs/stage166-workqueue-postoffice-timer-ownership-20261107T061706Z.log"
STAGE166_SHA="7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c"
STAGE167_PATH="Development/Logs/stage167-workqueue-global-dispatch-postoffice-xrefs-20261107T062448Z.log"
STAGE167_SHA="0af39ae31f8519131c8b1fe42cf1835def44e167"
STAGE168_PATH="Development/Logs/stage168-ioworkloop-event-source-ownership-20261107T062809Z.log"
STAGE168_SHA="976cdc2bc96f69706c9257d07bc99f3ae4fd801e"
STAGE169_PATH="Development/Logs/stage169-event-source-dispatch-reference-edges-20261107T063134Z.log"
STAGE169_SHA="65916918e0d1fad4547b2fed8560a9c0b0966a32"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"

[[ "$(git rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || { echo "ERROR: source HEAD mismatch"; exit 3; }
[[ "$(git remote get-url origin 2>/dev/null || true)" == *"Realtek-WiFi-Native-macOS"* ]] || { echo "ERROR: unexpected origin"; exit 4; }
OS="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
  echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 5;
}
for c in curl gh python3 shasum otool; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 6; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 7; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 8; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch"; exit 9; }

for spec in "STAGE165:$STAGE165_PATH:$STAGE165_SHA" "STAGE166:$STAGE166_PATH:$STAGE166_SHA" "STAGE167:$STAGE167_PATH:$STAGE167_SHA" "STAGE168:$STAGE168_PATH:$STAGE168_SHA" "STAGE169:$STAGE169_PATH:$STAGE169_SHA"; do
  IFS=: read -r label path expected <<< "$spec"
  actual="$(gh api "repos/$REPO/contents/$path?ref=main" --jq '.sha')"
  [[ "$actual" == "$expected" ]] || { echo "ERROR: $label report SHA mismatch"; exit 10; }
  printf '%s_REPORT_SHA=%s\n' "$label" "$actual"
done

WORK="$(mktemp -d "$TMPROOT/stage170-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage170-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE170_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("STOP: pinned KC reader SHA mismatch")
print("STAGE170_READER_INTEGRITY=PASS")
PY

{
  echo "========== STAGE170 WORKLOOP CHAIN AND COMMAND-OBJECT OWNERSHIP AUDIT =========="
  echo "STAGE170_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE170_HEAD=$(git rev-parse HEAD)"
  echo "STAGE170_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE170_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE170_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE170_STAGE165_REPORT_SHA=$STAGE165_SHA"
  echo "STAGE170_STAGE166_REPORT_SHA=$STAGE166_SHA"
  echo "STAGE170_STAGE167_REPORT_SHA=$STAGE167_SHA"
  echo "STAGE170_STAGE168_REPORT_SHA=$STAGE168_SHA"
  echo "STAGE170_STAGE169_REPORT_SHA=$STAGE169_SHA"
  echo "STAGE170_READER_COMMIT=$READER_COMMIT"
  echo "STAGE170_SCOPE=READ_ONLY_EVENT_CHAIN_REFERENCE_ACQUISITION_AND_COMMAND_GATE_POOL_LIFETIME"
  echo "STAGE170_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE170_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE170_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE170_WORK"])
from kcfile import KC

kc=KC(sys.argv[1])
otool=sys.argv[2]
KERNEL="com.apple.kernel"
IO="com.apple.iokit.IO80211Family"
images={}
for owner in (KERNEL,IO):
    path=os.path.join(os.environ["STAGE170_WORK"],owner.replace(".","_")+".macho")
    try:
        kc.carve(owner,path)
        images[owner]=path
        print("FILESSET_CARVE=PASS OWNER="+owner)
    except Exception as exc:
        print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(exc)[:220]))

def dump_method(name,tag,limit=0x5000):
    addr=kc.find(name)
    owner=kc.owner(addr) if addr else None
    print("\nTARGET_SYMBOL TAG=%s NAME=%s ADDRESS=%s OWNER=%s"%(tag,name,("0x%x"%addr) if addr else "NOT_FOUND",owner or "UNKNOWN"))
    if not addr or owner not in images:
        print("METHOD_NOT_VERIFIED TAG="+tag)
        return []
    end=kc.next_sym(addr) or addr+limit
    if end<=addr or end>addr+limit: end=addr+limit
    p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,images[owner]],capture_output=True,text=True)
    if p.returncode:
        print("DISASSEMBLY_FAILED TAG=%s ERROR=%s"%(tag,p.stderr.strip()[:220]))
        return []
    rows=[]
    for line in p.stdout.splitlines():
        m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
        if m and addr<=int(m.group(1),16)<end: rows.append(line.strip())
    print("METHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x INSTRUCTIONS=%d"%(tag,name,addr,len(rows)))
    for line in rows: print(line)
    return rows

def report_vtable(cls,offsets):
    vt=kc.vtable(cls)
    print("\nVTABLE_CLASS=%s WORDS=%s"%(cls,len(vt) if vt is not None else "NOT_FOUND"))
    if vt is None: return
    for off in offsets:
        idx=2+off//8
        e=next((x for x in vt if x[0]==idx),None)
        if e:
            print("VTABLE_SLOT CLASS=%s VPTR_OFFSET=0x%x RAW_INDEX=%d TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,idx,e[2],kc.owner(e[2]) or "UNKNOWN",e[3]))
        else:
            print("VTABLE_SLOT CLASS=%s VPTR_OFFSET=0x%x RESULT=NO_ENTRY"%(cls,off))

# Map factory init/free dispatch and the slots involved in event-source chains.
offsets=(0x28,0x48,0x50,0x58,0x88,0xa0,0x118,0x120,0x128,0x130,0x138,0x140,0x148,0x150,0x158,0x1b8,0x1c0)
for cls in ("IOWorkLoop","IO80211WorkQueue","IOEventSource","IOCommandGate","IOCommandPool"):
    report_vtable(cls,offsets)

methods=(
    ("__ZN10IOWorkLoop4initEv","IOWORKLOOP_INIT"),
    ("__ZN10IOWorkLoop4freeEv","IOWORKLOOP_FREE"),
    ("__ZN10IOWorkLoop14addEventSourceEP13IOEventSource","IOWORKLOOP_ADD_EVENT_SOURCE"),
    ("__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource","IOWORKLOOP_REMOVE_EVENT_SOURCE"),
    ("__ZN10IOWorkLoop17releaseEventChainEP13IOEventSource","IOWORKLOOP_RELEASE_EVENT_CHAIN"),
    ("__ZN13IOEventSource7setNextEPS_","IOEVENTSOURCE_SET_NEXT"),
    ("__ZNK13IOEventSource7getNextEv","IOEVENTSOURCE_GET_NEXT"),
    ("__ZN13IOEventSource6enableEv","IOEVENTSOURCE_ENABLE"),
    ("__ZN13IOEventSource7disableEv","IOEVENTSOURCE_DISABLE"),
    ("__ZN13IOCommandGate11setWorkLoopEP10IOWorkLoop","IOCOMMANDGATE_SET_WORKLOOP"),
    ("__ZN13IOCommandGate4initEP8OSObjectPFiS1_PvS2_S2_S2_E","IOCOMMANDGATE_INIT"),
    ("__ZN13IOCommandGate4freeEv","IOCOMMANDGATE_FREE"),
    ("__ZN13IOCommandPool16initWithWorkLoopEP10IOWorkLoop","IOCOMMANDPOOL_INIT_WITH_WORKLOOP"),
    ("__ZN13IOCommandPool4initEP9IOServiceP10IOWorkLoopj","IOCOMMANDPOOL_INIT_WITH_SERVICE"),
    ("__ZN13IOCommandPool4freeEv","IOCOMMANDPOOL_FREE"),
    ("__ZN16IO80211WorkQueue9workQueueEv","IO80211_WORKQUEUE_FACTORY"),
    ("__ZN16IO80211WorkQueue19getDefaultWorkQueueEv","IO80211_DEFAULT_GETTER"),
    ("__ZN16IO80211WorkQueue19setDefaultWorkQueueEPS_","IO80211_DEFAULT_SETTER"),
)
for name,tag in methods:
    dump_method(name,tag,0x9000 if tag in ("IOWORKLOOP_INIT","IOWORKLOOP_FREE","IOWORKLOOP_ADD_EVENT_SOURCE","IOCOMMANDPOOL_FREE") else 0x5000)

# Enumerate exact method names for the target classes, so mangled overloads or
# inherited methods that differ from the anticipated signatures are visible.
inventories={}
for cls in ("IOWorkLoop","IO80211WorkQueue","IOEventSource","IOCommandGate","IOCommandPool"):
    try:
        methods=kc.methods(cls)
    except Exception as exc:
        print("METHOD_INVENTORY_FAILED CLASS=%s ERROR=%s"%(cls,str(exc)[:180]))
        continue
    inventories[cls]=methods
    print("\nMETHOD_INVENTORY CLASS=%s TOTAL=%d"%(cls,len(methods)))
    for addr,name in methods:
        print("METHOD_INVENTORY_ENTRY CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,addr,kc.owner(addr) or "UNKNOWN",name))

# Report the implementation that occupies IO80211WorkQueue's virtual init slot
# as called by its factory. Also map the destructor/free slot inherited from
# IOWorkLoop/OSObject when the vtable exposes it.
for cls in ("IO80211WorkQueue","IOWorkLoop"):
    vt=kc.vtable(cls) or []
    for off in (0x28,0x88,0xa0):
        idx=2+off//8
        e=next((x for x in vt if x[0]==idx),None)
        if e:
            print("LIFECYCLE_DISPATCH CLASS=%s VTABLE_OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,e[2],kc.owner(e[2]) or "UNKNOWN",e[3]))
        else:
            print("LIFECYCLE_DISPATCH CLASS=%s VTABLE_OFFSET=0x%x RESULT=NO_ENTRY"%(cls,off))

# Direct xrefs for the key lifecycle functions. Method definitions are emitted
# as labels too; report only instruction lines for caller evidence.
targets=(
    "__ZN10IOWorkLoop14addEventSourceEP13IOEventSource",
    "__ZN10IOWorkLoop17releaseEventChainEP13IOEventSource",
    "__ZN13IOEventSource7setNextEPS_",
    "__ZN13IOCommandGate11setWorkLoopEP10IOWorkLoop",
    "__ZN13IOCommandPool16initWithWorkLoopEP10IOWorkLoop",
    "__ZNK8OSObject6retainEv",
    "__ZNK8OSObject7releaseEv",
)
for owner,path in images.items():
    p=subprocess.run([otool,"-arch","x86_64","-tvV",path],capture_output=True,text=True)
    print("\nDIRECT_XREF_SCAN_OWNER=%s RETURN_CODE=%d"%(owner,p.returncode))
    if p.returncode: continue
    current="UNKNOWN"; count=0
    for line in p.stdout.splitlines():
        if line and not line[0].isspace() and line.endswith(":"): current=line[:-1]
        if any(t in line for t in targets):
            if line.strip().endswith(":"): continue
            print("DIRECT_XREF OWNER=%s FUNCTION=%s INSTRUCTION=%s"%(owner,current,line.strip()))
            count+=1
    print("DIRECT_XREF_MATCH_COUNT OWNER=%s COUNT=%d"%(owner,count))

print("\nSTAGE170_INTERPRETATION=CHAIN_REFERENCE_AND_COMMAND_OBJECT_PATHS_DUMPED; OBJECT_OWNERSHIP_REQUIRES_CALLSITE_ARGUMENT_AND_RELEASE_PATH_CORRELATION")
PY

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 11; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE170_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE170_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE170 =========="
} > "$REPORT" 2>&1

echo "===== STAGE170 SUMMARY ====="
grep -aE '^(STAGE170_|FILESSET_CARVE=|VTABLE_CLASS=|VTABLE_SLOT |TARGET_SYMBOL TAG=|METHOD_TAG=|METHOD_INVENTORY CLASS=|METHOD_INVENTORY_ENTRY CLASS=(IOWorkLoop|IO80211WorkQueue|IOEventSource|IOCommandGate|IOCommandPool)|LIFECYCLE_DISPATCH |DIRECT_XREF OWNER=|DIRECT_XREF_MATCH_COUNT |STAGE170_INTERPRETATION=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage170-workloop-chain-command-object-ownership-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage170: publish read-only WorkLoop chain and command-object ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
    with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
        json.dump(payload,f);f.flush()
        r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
    if r.returncode==0:
        try: actual=json.loads(r.stdout).get("content",{}).get("sha")
        except Exception: actual=None
        if actual==expected:
            verify=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
            if verify.returncode==0 and verify.stdout.strip()==expected:
                print("STAGE170_UPLOAD_SHA="+actual)
                print("STAGE170_GITHUB_PATH="+dest)
                print("STAGE170_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE170_UPLOAD_SHA="+expected)
        print("STAGE170_GITHUB_PATH="+dest)
        print("STAGE170_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE170_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE170_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
