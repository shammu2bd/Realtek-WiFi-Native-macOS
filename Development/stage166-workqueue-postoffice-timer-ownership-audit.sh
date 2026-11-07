#!/bin/bash
# Stage166: read-only IO80211WorkQueue / TimerSource / PostOffice lifetime audit.
# No project source/build outputs, signing, install/load, AuxKC or OpenCore changes.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE165_PATH="Development/Logs/stage165-kmutil-repository-bundle-discovery-20261107T061052Z.log"
STAGE165_SHA="97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277"
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
for c in curl gh python3 shasum otool nm; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 6; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 7; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 8; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch"; exit 9; }

STAGE165_ACTUAL="$(gh api "repos/$REPO/contents/$STAGE165_PATH?ref=main" --jq '.sha')"
[[ "$STAGE165_ACTUAL" == "$STAGE165_SHA" ]] || { echo "ERROR: Stage165 report SHA mismatch"; exit 10; }

WORK="$(mktemp -d "$TMPROOT/stage166-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage166-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE166_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("STOP: pinned KC reader SHA mismatch")
print("STAGE166_READER_INTEGRITY=PASS")
PY

{
  echo "========== STAGE166 WORKQUEUE POSTOFFICE TIMER OWNERSHIP AUDIT =========="
  echo "STAGE166_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE166_HEAD=$(git rev-parse HEAD)"
  echo "STAGE166_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE166_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE166_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE166_STAGE165_REPORT_SHA=$STAGE165_ACTUAL"
  echo "STAGE166_READER_COMMIT=$READER_COMMIT"
  echo "STAGE166_SCOPE=READ_ONLY_VTABLE_DISPATCH_AND_REFERENCE_LIFETIME"
  echo "STAGE166_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE166_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE166_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE166_WORK"])
from kcfile import KC

kc=KC(sys.argv[1])
otool=sys.argv[2]
owners=("com.apple.iokit.IO80211Family","com.apple.kernel")
images={}
for owner in owners:
    path=os.path.join(os.environ["STAGE166_WORK"],owner.replace(".","_")+".macho")
    try:
        kc.carve(owner,path)
        images[owner]=path
        print("FILESSET_CARVE=PASS OWNER="+owner)
    except Exception as exc:
        print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(exc)[:220]))

IO="com.apple.iokit.IO80211Family"
def owner_of(name):
    a=kc.find(name)
    return kc.owner(a) if a else None

def dump_method(name,tag,limit=0x5000):
    a=kc.find(name)
    owner=kc.owner(a) if a else None
    print("\nTARGET_SYMBOL TAG=%s NAME=%s ADDRESS=%s OWNER=%s"%(tag,name,("0x%x"%a) if a else "NOT_FOUND",owner or "UNKNOWN"))
    if not a or owner not in images:
        print("METHOD_NOT_VERIFIED TAG="+tag)
        return
    end=kc.next_sym(a) or a+limit
    if end<=a or end>a+limit: end=a+limit
    p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,images[owner]],capture_output=True,text=True)
    if p.returncode:
        print("DISASSEMBLY_FAILED TAG=%s ERROR=%s"%(tag,p.stderr.strip()[:220]))
        return
    rows=[]
    for line in p.stdout.splitlines():
        m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
        if m and a<=int(m.group(1),16)<end:
            rows.append(line.strip())
    if not rows:
        print("METHOD_NOT_VERIFIED TAG="+tag)
        return
    print("METHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x INSTRUCTIONS=%d"%(tag,name,a,len(rows)))
    for line in rows:
        print(line)
    joined="\n".join(rows)
    print("METHOD_EXPLICIT_RETAIN_SYMBOL=%s"%("YES" if re.search(r"OSObject6retain|retainEv",joined) else "NO_DIRECT_NAMED_CALL"))
    print("METHOD_EXPLICIT_RELEASE_SYMBOL=%s"%("YES" if re.search(r"OSObject7release|releaseEv",joined) else "NO_DIRECT_NAMED_CALL"))

# The Itanium C++ ABI vtable has two prefix words before the object vptr address point.
# Report raw indices and the corresponding byte offsets relative to the object vptr.
for cls,interesting in (
    ("IO80211WorkQueue",(0x148,0x150)),
    ("IO80211TimerSource",()),
    ("IO80211PostOffice",()),
):
    vt=kc.vtable(cls)
    print("\nVTABLE_CLASS=%s WORDS=%s"%(cls,len(vt) if vt is not None else "NOT_FOUND"))
    if vt is None:
        continue
    for i,raw,target,name in vt:
        if i<2:
            print("VTABLE_PREFIX CLASS=%s RAW_INDEX=%d RAW=0x%x TARGET=0x%x NAME=%s"%(cls,i,raw,target,name))
        else:
            byteoff=(i-2)*8
            mark=" TARGETED" if byteoff in interesting else ""
            print("VTABLE_ENTRY CLASS=%s VTPTR_BYTE_OFFSET=0x%x RAW_INDEX=%d TARGET=0x%x OWNER=%s NAME=%s%s"%(cls,byteoff,i,target,kc.owner(target) or "UNKNOWN",name,mark))
    for off in interesting:
        idx=2+(off//8)
        hit=next((e for e in vt if e[0]==idx),None)
        if hit:
            print("WORKQUEUE_VIRTUAL_DISPATCH OFFSET=0x%x RAW_INDEX=%d TARGET=0x%x SYMBOL=%s"%(off,idx,hit[2],hit[3]))
        else:
            print("WORKQUEUE_VIRTUAL_DISPATCH OFFSET=0x%x RESULT=NO_VTABLE_ENTRY"%off)

for cls in ("IO80211WorkQueue","IO80211TimerSource","IO80211PostOffice","IOEventSource","IOWorkLoop"):
    try:
        methods=kc.methods(cls)
        print("\nMETHOD_INVENTORY CLASS=%s COUNT=%d"%(cls,len(methods)))
        for addr,name in methods:
            if any(k.lower() in name.lower() for k in ("addWorkSource","removeWorkSource","setWorkLoop","addEventSource","removeEventSource","retain","release","init","free","workQueue","postOffice","enableAll","disableAll","cancel","timeout")):
                print("METHOD_INVENTORY_ENTRY CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,addr,kc.owner(addr) or "UNKNOWN",name))
    except Exception as exc:
        print("METHOD_INVENTORY_FAILED CLASS=%s ERROR=%s"%(cls,str(exc)[:180]))

for name,tag in (
    ("__ZN16IO80211WorkQueue13addWorkSourceEP17IO80211WorkSource","WORKQUEUE_ADD_WORK_SOURCE"),
    ("__ZN16IO80211WorkQueue16removeWorkSourceEP17IO80211WorkSource","WORKQUEUE_REMOVE_WORK_SOURCE"),
    ("__ZN18IO80211TimerSource4initE26IO80211TimerSourcePriorityP8OSObjectP16IO80211WorkQueuePFvS2_PS_E","TIMER_SOURCE_INIT"),
    ("__ZN18IO80211TimerSource4freeEv","TIMER_SOURCE_FREE"),
    ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
    ("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE"),
    ("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_CREATE_POSTOFFICE"),
    ("__ZN17IO80211Controller13getPostOfficeEv","CONTROLLER_GET_POSTOFFICE"),
    ("__ZN17IO80211Controller15createWorkQueueEv","CONTROLLER_CREATE_WORKQUEUE"),
    ("__ZNK17IO80211Controller12getWorkQueueEv","CONTROLLER_GET_WORKQUEUE"),
    ("__ZN17IO80211Controller4stopEP9IOService","CONTROLLER_STOP"),
    ("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
    ("__ZN13IOEventSource11setWorkLoopEP10IOWorkLoop","EVENT_SOURCE_SET_WORKLOOP"),
    ("__ZN13IOEventSource4freeEv","EVENT_SOURCE_FREE"),
):
    dump_method(name,tag,0x9000 if tag in ("CONTROLLER_STOP","CONTROLLER_FREE") else 0x5000)

# Exact memory-operand xrefs to displacement +0xB08, restricted to controller methods.
if IO in images:
    p=subprocess.run([otool,"-arch","x86_64","-tvV",images[IO]],capture_output=True,text=True)
    print("\nPOSTOFFICE_FIELD_XREF_SCAN_RETURN_CODE=%d"%p.returncode)
    if p.returncode==0:
        current=""
        hits=[]
        for line in p.stdout.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                current=line[:-1]
            if re.search(r"\b0xb08\(",line,re.I) and "IO80211Controller" in current:
                op="STORE_OR_RMW" if re.search(r",\s*0xb08\(",line,re.I) else "LOAD_OR_COMPARE"
                hits.append((current,op,line.strip()))
        print("CONTROLLER_POSTOFFICE_FIELD_EXACT_XREF_COUNT=%d"%len(hits))
        for fn,op,line in hits:
            print("CONTROLLER_POSTOFFICE_FIELD_XREF FUNCTION=%s CLASSIFICATION=%s INSTRUCTION=%s"%(fn,op,line))
    else:
        print("POSTOFFICE_FIELD_XREF_SCAN_ERROR="+p.stderr.strip()[:300])

work_vt=kc.vtable("IO80211WorkQueue") or []
slot_targets={}
for off in (0x148,0x150):
    idx=2+off//8
    e=next((x for x in work_vt if x[0]==idx),None)
    slot_targets[off]=e[3] if e else "UNKNOWN"
print("\nSTAGE166_WORKQUEUE_SLOT_0X148="+slot_targets[0x148])
print("STAGE166_WORKQUEUE_SLOT_0X150="+slot_targets[0x150])
print("STAGE166_INTERPRETATION=READ_DISASSEMBLY_AND_VTABLE_ABOVE; DO_NOT_INFER_REFERENCE_OWNERSHIP_FROM_RAW_POINTER_STORAGE")
PY

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 11; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE166_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE166_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE166 =========="
} > "$REPORT" 2>&1

echo "===== STAGE166 SUMMARY ====="
grep -aE '^(STAGE166_|FILESSET_CARVE=|VTABLE_CLASS=|WORKQUEUE_VIRTUAL_DISPATCH |METHOD_INVENTORY CLASS=|METHOD_INVENTORY_ENTRY CLASS=(IO80211WorkQueue|IO80211TimerSource|IO80211PostOffice|IOEventSource|IOWorkLoop)|TARGET_SYMBOL TAG=|METHOD_TAG=|METHOD_EXPLICIT_RETAIN_SYMBOL=|METHOD_EXPLICIT_RELEASE_SYMBOL=|CONTROLLER_POSTOFFICE_FIELD_EXACT_XREF_COUNT=|CONTROLLER_POSTOFFICE_FIELD_XREF |STAGE166_WORKQUEUE_SLOT_|STAGE166_INTERPRETATION=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage166-workqueue-postoffice-timer-ownership-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage166: publish read-only workqueue PostOffice TimerSource ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
                print("STAGE166_UPLOAD_SHA="+actual)
                print("STAGE166_GITHUB_PATH="+dest)
                print("STAGE166_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE166_UPLOAD_SHA="+expected)
        print("STAGE166_GITHUB_PATH="+dest)
        print("STAGE166_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE166_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE166_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
