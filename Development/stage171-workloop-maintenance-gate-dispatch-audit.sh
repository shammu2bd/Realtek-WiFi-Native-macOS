#!/bin/bash
# Stage171: resolve WorkLoop maintenance callback and CommandGate indirect dispatch.
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
STAGE170_PATH="Development/Logs/stage170-workloop-chain-command-object-ownership-20261107T063501Z.log"
STAGE170_SHA="8759f897a49144478bd3d9a3879fb4314394e401"
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

for spec in "STAGE165:$STAGE165_PATH:$STAGE165_SHA" "STAGE166:$STAGE166_PATH:$STAGE166_SHA" "STAGE167:$STAGE167_PATH:$STAGE167_SHA" "STAGE168:$STAGE168_PATH:$STAGE168_SHA" "STAGE169:$STAGE169_PATH:$STAGE169_SHA" "STAGE170:$STAGE170_PATH:$STAGE170_SHA"; do
  IFS=: read -r label path expected <<< "$spec"
  actual="$(gh api "repos/$REPO/contents/$path?ref=main" --jq '.sha')"
  [[ "$actual" == "$expected" ]] || { echo "ERROR: $label report SHA mismatch"; exit 10; }
  printf '%s_REPORT_SHA=%s\n' "$label" "$actual"
done

WORK="$(mktemp -d "$TMPROOT/stage171-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage171-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE171_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("STOP: pinned KC reader SHA mismatch")
print("STAGE171_READER_INTEGRITY=PASS")
PY

{
  echo "========== STAGE171 WORKLOOP MAINTENANCE CALLBACK AND GATE DISPATCH AUDIT =========="
  echo "STAGE171_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE171_HEAD=$(git rev-parse HEAD)"
  echo "STAGE171_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE171_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE171_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE171_STAGE165_REPORT_SHA=$STAGE165_SHA"
  echo "STAGE171_STAGE166_REPORT_SHA=$STAGE166_SHA"
  echo "STAGE171_STAGE167_REPORT_SHA=$STAGE167_SHA"
  echo "STAGE171_STAGE168_REPORT_SHA=$STAGE168_SHA"
  echo "STAGE171_STAGE169_REPORT_SHA=$STAGE169_SHA"
  echo "STAGE171_STAGE170_REPORT_SHA=$STAGE170_SHA"
  echo "STAGE171_READER_COMMIT=$READER_COMMIT"
  echo "STAGE171_SCOPE=READ_ONLY_MAINTENANCE_CALLBACK_CHAIN_MUTATION_AND_GATE_DISPATCH"
  echo "STAGE171_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE171_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE171_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE171_WORK"])
from kcfile import KC

kc=KC(sys.argv[1])
otool=sys.argv[2]
KERNEL="com.apple.kernel"
IO="com.apple.iokit.IO80211Family"
images={}
for owner in (KERNEL,IO):
    path=os.path.join(os.environ["STAGE171_WORK"],owner.replace(".","_")+".macho")
    try:
        kc.carve(owner,path)
        images[owner]=path
        print("FILESSET_CARVE=PASS OWNER="+owner)
    except Exception as exc:
        print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(exc)[:220]))

def dump_method(name,tag,limit=0x6000):
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

# Exact object-vptr offsets are used here: unlike the IO80211WorkQueue
# static __ZTV dispatch in Stage167, these calls load (%object) first.
offsets=(0x28,0x88,0xa0,0x118,0x120,0x128,0x130,0x138,0x140,0x148,0x150,0x158,0x168,0x170,0x178,0x180,0x188,0x1b8,0x1c0)
for cls in ("IOWorkLoop","IOCommandGate","IOCommandPool","IOEventSource","IOTimerEventSource","IO80211WorkQueue"):
    report_vtable(cls,offsets)

methods=(
    ("__ZN10IOWorkLoop13_maintRequestEPvS0_S0_S0_","IOWORKLOOP_MAINT_REQUEST"),
    ("__ZN10IOWorkLoop9runActionEPFiP8OSObjectPvS2_S2_S2_ES1_S2_S2_S2_S2_","IOWORKLOOP_RUN_ACTION"),
    ("__ZN10IOWorkLoop14addEventSourceEP13IOEventSource","IOWORKLOOP_ADD_EVENT_SOURCE"),
    ("__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource","IOWORKLOOP_REMOVE_EVENT_SOURCE"),
    ("__ZN10IOWorkLoop17releaseEventChainEP13IOEventSource","IOWORKLOOP_RELEASE_EVENT_CHAIN"),
    ("__ZN10IOWorkLoop18setMaximumLockTimeEyj","IOWORKLOOP_SET_MAX_LOCK_TIME"),
    ("__ZN10IOWorkLoop17signalWorkAvailableEv","IOWORKLOOP_SIGNAL_WORK"),
    ("__ZN10IOWorkLoop8openGateEv","IOWORKLOOP_OPEN_GATE"),
    ("__ZN10IOWorkLoop9closeGateEv","IOWORKLOOP_CLOSE_GATE"),
    ("__ZN10IOWorkLoop12tryCloseGateEv","IOWORKLOOP_TRY_CLOSE_GATE"),
    ("__ZN10IOWorkLoop9runActionEPFiP8OSObjectPvS2_S2_S2_ES1_S2_S2_S2_S2_","IOWORKLOOP_RUN_ACTION"),
    ("__ZN13IOCommandGate11setWorkLoopEP10IOWorkLoop","IOCOMMANDGATE_SET_WORKLOOP"),
    ("__ZN13IOCommandGate10runCommandEPvS0_S0_S0_","IOCOMMANDGATE_RUN_COMMAND"),
    ("__ZN13IOCommandGate9runActionEPFiP8OSObjectPvS2_S2_S2_ES2_S2_S2_S2_S2_","IOCOMMANDGATE_RUN_ACTION"),
    ("__ZN13IOCommandGate14attemptCommandEPvS0_S0_S0_","IOCOMMANDGATE_ATTEMPT_COMMAND"),
    ("__ZN13IOCommandGate13attemptActionEPFiP8OSObjectPvS2_S2_S2_ES2_S2_S2_S2_S2_","IOCOMMANDGATE_ATTEMPT_ACTION"),
    ("__ZN13IOCommandGate4initEP8OSObjectPFiS1_PvS2_S2_S2_E","IOCOMMANDGATE_INIT"),
    ("__ZN13IOCommandGate4freeEv","IOCOMMANDGATE_FREE"),
    ("__ZN13IOCommandPool16initWithWorkLoopEP10IOWorkLoop","IOCOMMANDPOOL_INIT_WITH_WORKLOOP"),
    ("__ZN13IOCommandPool4freeEv","IOCOMMANDPOOL_FREE"),
    ("__ZN13IOCommandPool12withWorkLoopEP10IOWorkLoop","IOCOMMANDPOOL_WITH_WORKLOOP"),
    ("__ZN13IOCommandPool11commandPoolEP9IOServiceP10IOWorkLoopj","IOCOMMANDPOOL_FACTORY"),
    ("__ZN16IO80211WorkQueueC1Ev","IO80211_WORKQUEUE_CTOR_C1"),
    ("__ZN16IO80211WorkQueueC2Ev","IO80211_WORKQUEUE_CTOR_C2"),
    ("__ZN16IO80211WorkQueueD1Ev","IO80211_WORKQUEUE_DTOR_D1"),
    ("__ZN16IO80211WorkQueueD0Ev","IO80211_WORKQUEUE_DTOR_D0"),
)
seen=set()
for name,tag in methods:
    if name in seen: continue
    seen.add(name)
    dump_method(name,tag,0xa000 if tag in ("IOWORKLOOP_MAINT_REQUEST","IOWORKLOOP_RUN_ACTION","IOCOMMANDGATE_RUN_COMMAND","IOCOMMANDGATE_RUN_ACTION") else 0x6000)

# Full but compact method inventory for WorkLoop and CommandGate to identify
# any differently named gated callback/chain helper in this exact BootKC.
for cls in ("IOWorkLoop","IOCommandGate","IOCommandPool","IO80211WorkQueue"):
    try:
        inventory=kc.methods(cls)
    except Exception as exc:
        print("METHOD_INVENTORY_FAILED CLASS=%s ERROR=%s"%(cls,str(exc)[:180]))
        continue
    print("\nMETHOD_INVENTORY CLASS=%s TOTAL=%d"%(cls,len(inventory)))
    for addr,name in inventory:
        if re.search(r"(maint|event|gate|action|command|release|retain|init|free|add|remove|workloop|thread)",str(name),re.I):
            print("METHOD_INVENTORY_ENTRY CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,addr,kc.owner(addr) or "UNKNOWN",name))

# Map virtual offsets used by the exact caller methods back to concrete targets.
for cls,offs in (
    ("IOCommandGate",(0x128,0x158,0x1b8,0x1c0,0x168)),
    ("IOWorkLoop",(0x118,0x128,0x138,0x140,0x148,0x158,0x180,0x178)),
    ("IOEventSource",(0x28,0x128,0x130,0x138)),
    ("IOCommandPool",(0x118,0x128,0x130,0x138,0x140)),
):
    vt=kc.vtable(cls) or []
    for off in offs:
        idx=2+off//8
        e=next((x for x in vt if x[0]==idx),None)
        if e:
            print("CALLSITE_VTABLE_TARGET CLASS=%s OBJECT_VPTR_OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,e[2],kc.owner(e[2]) or "UNKNOWN",e[3]))
        else:
            print("CALLSITE_VTABLE_TARGET CLASS=%s OBJECT_VPTR_OFFSET=0x%x RESULT=NO_ENTRY"%(cls,off))

# Collect direct instruction references to maintenance/gate/callback methods;
# labels are intentionally excluded from the count.
targets=(
    "__ZN10IOWorkLoop13_maintRequestEPvS0_S0_S0_",
    "__ZN10IOWorkLoop9runActionEPFiP8OSObjectPvS2_S2_S2_ES1_S2_S2_S2_S2_",
    "__ZN13IOCommandGate10runCommandEPvS0_S0_S0_",
    "__ZN13IOCommandGate9runActionEPFiP8OSObjectPvS2_S2_S2_ES2_S2_S2_S2_S2_",
    "__ZN10IOWorkLoop14addEventSourceEP13IOEventSource",
    "__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource",
)
for owner,path in images.items():
    p=subprocess.run([otool,"-arch","x86_64","-tvV",path],capture_output=True,text=True)
    print("\nDIRECT_XREF_SCAN_OWNER=%s RETURN_CODE=%d"%(owner,p.returncode))
    if p.returncode: continue
    current="UNKNOWN"; count=0
    for line in p.stdout.splitlines():
        if line and not line[0].isspace() and line.endswith(":"):
            current=line[:-1]
            continue
        if any(t in line for t in targets):
            print("DIRECT_XREF OWNER=%s FUNCTION=%s INSTRUCTION=%s"%(owner,current,line.strip()))
            count+=1
    print("DIRECT_XREF_MATCH_COUNT OWNER=%s COUNT=%d"%(owner,count))

print("\nSTAGE171_INTERPRETATION=GATED_CHAIN_MUTATION_TARGETS_AND_CALLER_PATHS_REPORTED; DO_NOT_INFER_EXTRA_RETAIN_WITHOUT_A_MATCHING_OBJECT_REFERENCE_EDGE")
PY

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 11; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE171_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE171_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE171 =========="
} > "$REPORT" 2>&1

echo "===== STAGE171 SUMMARY ====="
grep -aE '^(STAGE171_|FILESSET_CARVE=|VTABLE_CLASS=|VTABLE_SLOT |TARGET_SYMBOL TAG=|METHOD_TAG=|METHOD_INVENTORY CLASS=|METHOD_INVENTORY_ENTRY CLASS=(IOWorkLoop|IOCommandGate|IOCommandPool|IO80211WorkQueue)|CALLSITE_VTABLE_TARGET |DIRECT_XREF OWNER=|DIRECT_XREF_MATCH_COUNT |STAGE171_INTERPRETATION=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage171-workloop-maintenance-gate-dispatch-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage171: publish read-only WorkLoop maintenance and gate-dispatch audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
                print("STAGE171_UPLOAD_SHA="+actual)
                print("STAGE171_GITHUB_PATH="+dest)
                print("STAGE171_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE171_UPLOAD_SHA="+expected)
        print("STAGE171_GITHUB_PATH="+dest)
        print("STAGE171_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE171_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE171_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
