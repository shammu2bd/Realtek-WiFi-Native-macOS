#!/bin/bash
# Stage168: audit kernel IOWorkLoop event-source attach/detach and ownership semantics.
# READ ONLY. No source/build outputs, signing, install/load, AuxKC, or OpenCore changes.
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

for spec in "STAGE165:$STAGE165_PATH:$STAGE165_SHA" "STAGE166:$STAGE166_PATH:$STAGE166_SHA" "STAGE167:$STAGE167_PATH:$STAGE167_SHA"; do
  IFS=: read -r label path expected <<< "$spec"
  actual="$(gh api "repos/$REPO/contents/$path?ref=main" --jq '.sha')"
  [[ "$actual" == "$expected" ]] || { echo "ERROR: $label report SHA mismatch"; exit 10; }
  printf '%s_REPORT_SHA=%s\n' "$label" "$actual"
done

WORK="$(mktemp -d "$TMPROOT/stage168-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage168-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE168_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("STOP: pinned KC reader SHA mismatch")
print("STAGE168_READER_INTEGRITY=PASS")
PY

{
  echo "========== STAGE168 IOWORKLOOP EVENT-SOURCE OWNERSHIP AUDIT =========="
  echo "STAGE168_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE168_HEAD=$(git rev-parse HEAD)"
  echo "STAGE168_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE168_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE168_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE168_STAGE165_REPORT_SHA=$STAGE165_SHA"
  echo "STAGE168_STAGE166_REPORT_SHA=$STAGE166_SHA"
  echo "STAGE168_STAGE167_REPORT_SHA=$STAGE167_SHA"
  echo "STAGE168_READER_COMMIT=$READER_COMMIT"
  echo "STAGE168_SCOPE=READ_ONLY_KERNEL_EVENT_SOURCE_ATTACH_DETACH_AND_REFERENCE_LIFETIME"
  echo "STAGE168_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE168_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE168_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE168_WORK"])
from kcfile import KC

kc=KC(sys.argv[1])
otool=sys.argv[2]
KERNEL="com.apple.kernel"
IO="com.apple.iokit.IO80211Family"
images={}
for owner in (KERNEL,IO):
    path=os.path.join(os.environ["STAGE168_WORK"],owner.replace(".","_")+".macho")
    try:
        kc.carve(owner,path)
        images[owner]=path
        print("FILESSET_CARVE=PASS OWNER="+owner)
    except Exception as exc:
        print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(exc)[:220]))

def addr_info(addr):
    if not addr: return ("NULL","NULL")
    return (kc.owner(addr) or "UNKNOWN",kc.symname(addr) or "UNNAMED")

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

def dump_addr(addr,tag,limit=0x3000):
    name=kc.syms.get(addr)
    if not name:
        print("\nMETHOD_SYMBOL_UNAVAILABLE TAG=%s ADDRESS=0x%x"%(tag,addr))
        return
    dump_method(name,tag,limit)

# Stage167 used vtable-symbol-start offsets. These entries translate those
# offsets to ABI vptr-relative offsets: symbol offset 0x150 -> vptr offset 0x140.
def report_vtable(cls,offsets,call_offsets=()):
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
    for off in call_offsets:
        idx=off//8
        e=next((x for x in vt if x[0]==idx),None)
        if e:
            print("VTABLE_SYMBOL_BASE_DISPATCH CLASS=%s SYMBOL_BASE_OFFSET=0x%x RAW_INDEX=%d EQUIVALENT_VPTR_OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(cls,off,idx,off-0x10,e[2],kc.owner(e[2]) or "UNKNOWN",e[3]))
        else:
            print("VTABLE_SYMBOL_BASE_DISPATCH CLASS=%s SYMBOL_BASE_OFFSET=0x%x RESULT=NO_ENTRY"%(cls,off))

# Verify the actual targets of the statically referenced vtable symbols in Stage167.
for cls, offsets, call_offsets in (
    ("IOWorkLoop",(0x140,0x148),(0x150,0x158)),
    ("IOTimerEventSource",(0x220,),(0x230,)),
    ("IO80211WorkQueue",(0x140,0x148,0x150,0x158),()),
    ("IO80211TimerSource",(0x140,0x148,0x150,0x158,0x220),()),
):
    report_vtable(cls,offsets,call_offsets)

# Decode the core attach/detach implementations and the base event-source
# work-loop setter/free methods. No inference is made from symbols alone.
for name,tag in (
    ("__ZN10IOWorkLoop14addEventSourceEP13IOEventSource","IOWORKLOOP_ADD_EVENT_SOURCE"),
    ("__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource","IOWORKLOOP_REMOVE_EVENT_SOURCE"),
    ("__ZN13IOEventSource11setWorkLoopEP10IOWorkLoop","IOEVENTSOURCE_SET_WORKLOOP"),
    ("__ZN13IOEventSource4freeEv","IOEVENTSOURCE_FREE"),
    ("__ZN10IOWorkLoop4freeEv","IOWORKLOOP_FREE"),
    ("__ZN10IOWorkLoop5startEP9IOService","IOWORKLOOP_START"),
):
    dump_method(name,tag,0x6000)

# Enumerate timer/event-source and OSObject methods so the relevant init,
# cancel/timeout, retain/release and cleanup paths are visible even when
# their exact mangled signatures differ across SDK declarations.
inventory={}
for cls in ("IOTimerEventSource","IOEventSource","IOWorkLoop","OSObject","IO80211TimerSource","IO80211WorkQueue"):
    try:
        methods=kc.methods(cls)
    except Exception as exc:
        print("METHOD_INVENTORY_FAILED CLASS=%s ERROR=%s"%(cls,str(exc)[:180]))
        continue
    selected=[]
    for addr,name in methods:
        if re.search(r"(init|free|setWorkLoop|getWorkLoop|addEventSource|removeEventSource|retain|release|timeout|cancel|enable|disable)",str(name),re.I):
            selected.append((addr,name))
    inventory[cls]=selected
    print("\nMETHOD_INVENTORY CLASS=%s TOTAL=%d SELECTED=%d"%(cls,len(methods),len(selected)))
    for addr,name in selected:
        print("METHOD_INVENTORY_ENTRY CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,addr,kc.owner(addr) or "UNKNOWN",name))

# Dump selected IOTimerEventSource lifecycle methods plus OSObject retain/release
# implementations where present. Limit to avoid repeating methods already dumped.
already={
 "__ZN10IOWorkLoop14addEventSourceEP13IOEventSource",
 "__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource",
 "__ZN13IOEventSource11setWorkLoopEP10IOWorkLoop",
 "__ZN13IOEventSource4freeEv",
 "__ZN10IOWorkLoop4freeEv",
 "__ZN10IOWorkLoop5startEP9IOService",
}
for cls in ("IOTimerEventSource","OSObject","IO80211TimerSource"):
    count=0
    for addr,name in inventory.get(cls,[]):
        sym=kc.syms.get(addr)
        if not sym or sym in already: continue
        if cls=="OSObject" and not re.search(r"(retain|release)",sym,re.I): continue
        if cls!="OSObject" and not re.search(r"(init|free|timeout|cancel)",sym,re.I): continue
        dump_addr(addr,cls.upper()+"_"+str(count),0x2800)
        already.add(sym)
        count+=1
        if count>=8: break
    print("METHOD_DUMP_COUNT CLASS=%s COUNT=%d"%(cls,count))

# Direct-reference scan in both fileset images. Indirect vtable dispatch is
# handled by the method and vtable dumps above, not inferred from xref absence.
targets=set()
for sym in (
    "__ZN10IOWorkLoop14addEventSourceEP13IOEventSource",
    "__ZN10IOWorkLoop17removeEventSourceEP13IOEventSource",
    "__ZN13IOEventSource11setWorkLoopEP10IOWorkLoop",
    "__ZN13IOEventSource4freeEv",
):
    targets.add(sym)
for cls in ("IOTimerEventSource","OSObject","IO80211TimerSource","IO80211WorkQueue"):
    for addr,name in inventory.get(cls,[]):
        sym=kc.syms.get(addr)
        if sym and re.search(r"(retain|release|init|free|timeout|cancel)",sym,re.I):
            targets.add(sym)

for owner,path in images.items():
    p=subprocess.run([otool,"-arch","x86_64","-tvV",path],capture_output=True,text=True)
    print("\nDIRECT_XREF_SCAN_OWNER=%s RETURN_CODE=%d"%(owner,p.returncode))
    if p.returncode: 
        print("DIRECT_XREF_SCAN_ERROR="+p.stderr.strip()[:240])
        continue
    current="UNKNOWN"; count=0
    for line in p.stdout.splitlines():
        if line and not line[0].isspace() and line.endswith(":"):
            current=line[:-1]
        if any(t in line for t in targets):
            print("DIRECT_XREF OWNER=%s FUNCTION=%s INSTRUCTION=%s"%(owner,current,line.strip()))
            count+=1
    print("DIRECT_XREF_MATCH_COUNT OWNER=%s COUNT=%d"%(owner,count))

# Reconfirm the Stage167 controller/PostOffice connection at the point
# relevant to this ownership audit, without asserting an Apple private layout.
for name,tag in (
    ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT_REFERENCE"),
    ("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE_REFERENCE"),
    ("__ZN18IO80211TimerSource4initE26IO80211TimerSourcePriorityP8OSObjectP16IO80211WorkQueuePFvS2_PS_E","IO80211_TIMER_SOURCE_INIT_REFERENCE"),
    ("__ZN18IO80211TimerSource4freeEv","IO80211_TIMER_SOURCE_FREE_REFERENCE"),
):
    dump_method(name,tag,0x4000)

print("\nSTAGE168_INTERPRETATION=ATTACH_DETACH_AND_RETAIN_RELEASE_CODE_DUMPED; APPLY_ONLY_OBJECT_SPECIFIC_EVIDENCE; QUEUE_OWNER_REMAINS_UNRESOLVED_UNLESS_PROVEN")
PY

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 11; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE168_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE168_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE168 =========="
} > "$REPORT" 2>&1

echo "===== STAGE168 SUMMARY ====="
grep -aE '^(STAGE168_|FILESSET_CARVE=|VTABLE_CLASS=|VTABLE_SLOT |VTABLE_SYMBOL_BASE_DISPATCH |TARGET_SYMBOL TAG=|METHOD_TAG=|METHOD_INVENTORY CLASS=|METHOD_INVENTORY_ENTRY CLASS=(IOTimerEventSource|IOEventSource|IOWorkLoop|OSObject|IO80211TimerSource|IO80211WorkQueue)|METHOD_DUMP_COUNT |DIRECT_XREF OWNER=|DIRECT_XREF_MATCH_COUNT |STAGE168_INTERPRETATION=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage168-ioworkloop-event-source-ownership-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage168: publish read-only IOWorkLoop event-source ownership audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
                print("STAGE168_UPLOAD_SHA="+actual)
                print("STAGE168_GITHUB_PATH="+dest)
                print("STAGE168_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE168_UPLOAD_SHA="+expected)
        print("STAGE168_GITHUB_PATH="+dest)
        print("STAGE168_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE168_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE168_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
