#!/bin/bash
# Stage167: resolve WorkQueue global dispatch targets and PostOffice call references.
# READ ONLY. No source/build outputs, signing, install/load, AuxKC, or OpenCore changes.
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
EXPECTED_HEAD="3d02ef10e353bb80d032980ffe2e7d28b90fd7da"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE165_PATH="Development/Logs/stage165-kmutil-repository-bundle-discovery-20261107T061052Z.log"
STAGE165_SHA="97a0a664c5ed0f53bcf3f1204bd0c8f2b5a74277"
STAGE166_PATH="Development/Logs/stage166-workqueue-postoffice-timer-ownership-20261107T061706Z.log"
STAGE166_SHA="7ad1c896b9d7ded57c40e0898a02c5c15ce1a28c"
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
STAGE166_ACTUAL="$(gh api "repos/$REPO/contents/$STAGE166_PATH?ref=main" --jq '.sha')"
[[ "$STAGE166_ACTUAL" == "$STAGE166_SHA" ]] || { echo "ERROR: Stage166 report SHA mismatch"; exit 10; }

WORK="$(mktemp -d "$TMPROOT/stage167-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage167-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
STATUS_BEFORE="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE167_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("STOP: pinned KC reader SHA mismatch")
print("STAGE167_READER_INTEGRITY=PASS")
PY

{
  echo "========== STAGE167 WORKQUEUE GLOBAL DISPATCH AND POSTOFFICE XREF AUDIT =========="
  echo "STAGE167_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
  echo "STAGE167_HEAD=$(git rev-parse HEAD)"
  echo "STAGE167_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
  echo "STAGE167_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
  echo "STAGE167_BOOTKC_SHA256=$BOOT_SHA"
  echo "STAGE167_STAGE165_REPORT_SHA=$STAGE165_ACTUAL"
  echo "STAGE167_STAGE166_REPORT_SHA=$STAGE166_ACTUAL"
  echo "STAGE167_READER_COMMIT=$READER_COMMIT"
  echo "STAGE167_SCOPE=READ_ONLY_GLOBAL_POINTER_AND_INDIRECT_DISPATCH_RESOLUTION"
  echo "STAGE167_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE167_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"

  STAGE167_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,re,subprocess,sys,bisect
sys.path.insert(0,os.environ["STAGE167_WORK"])
from kcfile import KC

kc=KC(sys.argv[1])
otool=sys.argv[2]
IO="com.apple.iokit.IO80211Family"
KERNEL="com.apple.kernel"
images={}
for owner in (IO,KERNEL):
    path=os.path.join(os.environ["STAGE167_WORK"],owner.replace(".","_")+".macho")
    try:
        kc.carve(owner,path)
        images[owner]=path
        print("FILESSET_CARVE=PASS OWNER="+owner)
    except Exception as exc:
        print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(exc)[:220]))

def addr_info(addr):
    if addr is None: return ("UNKNOWN","UNKNOWN")
    return (kc.owner(addr) or "UNKNOWN",kc.symname(addr) or "UNNAMED")

def dump_symbol_method(name,tag,limit=0x7000):
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

# For x86_64 REX.W MOV reg,[RIP+disp32], instruction length is seven bytes.
def resolve_rip_movs(rows,tag):
    print("\nRIP_GLOBAL_RESOLUTION TAG="+tag)
    count=0
    for line in rows:
        m=re.match(r"^([0-9a-fA-F]+)\s+movq\s+0x([0-9a-fA-F]+)\(%rip\),\s*(%r[a-z0-9]+)",line)
        if not m: continue
        ins=int(m.group(1),16); disp=int(m.group(2),16); reg=m.group(3)
        target=ins+7+disp
        raw=kc.q(target)
        value=kc.ptr(raw) if raw else 0
        gowner,gsym=addr_info(target)
        vowner,vsym=addr_info(value) if value else ("NULL","NULL")
        print("RIP_GLOBAL TAG=%s INSTRUCTION=0x%x REGISTER=%s GLOBAL=0x%x GLOBAL_OWNER=%s GLOBAL_SYMBOL=%s RAW_VALUE=%s VALUE=%s VALUE_OWNER=%s VALUE_SYMBOL=%s"%(tag,ins,reg,target,gowner,gsym,("0x%x"%raw) if raw else "UNREADABLE",("0x%x"%value) if value else "NULL",vowner,vsym))
        if value:
            vraw=kc.q(value)
            vptr=kc.ptr(vraw) if vraw else 0
            if vptr:
                vo,vs=addr_info(vptr)
                print("GLOBAL_OBJECT_VPTR TAG=%s GLOBAL=0x%x OBJECT=0x%x VPTR=0x%x VPTR_OWNER=%s VPTR_SYMBOL=%s"%(tag,target,value,vptr,vo,vs))
                for off in (0x140,0x148,0x150,0x158,0x230):
                    slotraw=kc.q(vptr+off)
                    slottarget=kc.ptr(slotraw) if slotraw else 0
                    if slottarget:
                        so,ss=addr_info(slottarget)
                        print("GLOBAL_OBJECT_VTABLE_SLOT TAG=%s OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(tag,off,slottarget,so,ss))
        count+=1
    if not count: print("RIP_GLOBALS_NOT_FOUND TAG="+tag)

def dump_address(addr,tag,limit=0x1000):
    owner=kc.owner(addr)
    symbol=kc.symname(addr)
    print("\nADDRESS_TARGET TAG=%s ADDRESS=0x%x OWNER=%s NEAREST_SYMBOL=%s"%(tag,addr,owner or "UNKNOWN",symbol or "UNNAMED"))
    if owner not in images or not symbol: return
    base=addr
    if "+" in symbol:
        i=bisect.bisect_right(kc.addrs,addr)-1
        if i>=0: base=kc.addrs[i]
    name=kc.syms.get(base)
    if not name: return
    end=kc.next_sym(base) or base+limit
    if end<=base or end>base+limit: end=base+limit
    p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,images[owner]],capture_output=True,text=True)
    if p.returncode: return
    rows=[]
    for line in p.stdout.splitlines():
        m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
        if m and base<=int(m.group(1),16)<end: rows.append(line.strip())
    print("ADDRESS_METHOD TAG=%s START=0x%x SYMBOL=%s INSTRUCTIONS=%d"%(tag,base,name,len(rows)))
    for line in rows: print(line)

work_add=dump_symbol_method("__ZN16IO80211WorkQueue13addWorkSourceEP17IO80211WorkSource","WORKQUEUE_ADD_SOURCE")
resolve_rip_movs(work_add,"WORKQUEUE_ADD_SOURCE")
work_remove=dump_symbol_method("__ZN16IO80211WorkQueue16removeWorkSourceEP17IO80211WorkSource","WORKQUEUE_REMOVE_SOURCE")
resolve_rip_movs(work_remove,"WORKQUEUE_REMOVE_SOURCE")
timer_init=dump_symbol_method("__ZN18IO80211TimerSource4initE26IO80211TimerSourcePriorityP8OSObjectP16IO80211WorkQueuePFvS2_PS_E","TIMER_SOURCE_INIT")
resolve_rip_movs(timer_init,"TIMER_SOURCE_INIT")
timer_free=dump_symbol_method("__ZN18IO80211TimerSource4freeEv","TIMER_SOURCE_FREE")
resolve_rip_movs(timer_free,"TIMER_SOURCE_FREE")

dump_address(0xffffff8000a49ab0,"WORKSOURCE_PREPARATION_HELPER",0x900)

work_vt=kc.vtable("IO80211WorkQueue") or []
for off in (0x140,0x148,0x150,0x158,0x230):
    idx=2+off//8
    entry=next((e for e in work_vt if e[0]==idx),None)
    if entry:
        print("WORKQUEUE_VTABLE_SLOT OFFSET=0x%x TARGET=0x%x OWNER=%s SYMBOL=%s"%(off,entry[2],kc.owner(entry[2]) or "UNKNOWN",entry[3]))
for global_name in ("__ZL23IO80211DefaultWorkQueue","__ZN16IO80211WorkQueue10gMetaClassE"):
    a=kc.find(global_name)
    if a:
        raw=kc.q(a); val=kc.ptr(raw) if raw else 0
        print("STATIC_GLOBAL NAME=%s ADDRESS=0x%x OWNER=%s RAW_VALUE=%s VALUE=%s VALUE_OWNER=%s VALUE_SYMBOL=%s"%(global_name,a,kc.owner(a) or "UNKNOWN",("0x%x"%raw) if raw else "UNREADABLE",("0x%x"%val) if val else "NULL",(kc.owner(val) or "UNKNOWN") if val else "NULL",(kc.symname(val) or "UNNAMED") if val else "NULL"))
        if val:
            vraw=kc.q(val); vptr=kc.ptr(vraw) if vraw else 0
            print("STATIC_GLOBAL_OBJECT_VPTR NAME=%s VPTR=%s VPTR_SYMBOL=%s"%(global_name,("0x%x"%vptr) if vptr else "NULL",(kc.symname(vptr) or "UNNAMED") if vptr else "NULL"))
    else:
        print("STATIC_GLOBAL_NOT_FOUND NAME="+global_name)

for name,tag in (
    ("__ZN16IO80211WorkQueue9workQueueEv","WORKQUEUE_FACTORY"),
    ("__ZN16IO80211WorkQueue19getDefaultWorkQueueEv","DEFAULT_QUEUE_GETTER"),
    ("__ZN16IO80211WorkQueue19setDefaultWorkQueueEPS_","DEFAULT_QUEUE_SETTER"),
    ("__ZN17IO80211PostOffice15allocWithParamsEP16IO80211WorkQueue","POSTOFFICE_ALLOC"),
    ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
    ("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE"),
    ("__ZN17IO80211Controller16CreatePostOfficeEv","CONTROLLER_CREATE_POSTOFFICE"),
    ("__ZN17IO80211Controller13getPostOfficeEv","CONTROLLER_GET_POSTOFFICE"),
    ("__ZN17IO80211Controller5startEP9IOService","CONTROLLER_START"),
    ("__ZN17IO80211Controller4stopEP9IOService","CONTROLLER_STOP"),
    ("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
):
    dump_symbol_method(name,tag,0x9000)

if IO in images:
    p=subprocess.run([otool,"-arch","x86_64","-tvV",images[IO]],capture_output=True,text=True)
    print("\nFULL_TEXT_XREF_SCAN_RETURN_CODE=%d"%p.returncode)
    if p.returncode==0:
        targets=(
            "__ZN16IO80211WorkQueue19setDefaultWorkQueueEPS_",
            "__ZN16IO80211WorkQueue19getDefaultWorkQueueEv",
            "__ZN16IO80211WorkQueue9workQueueEv",
            "__ZN17IO80211PostOffice15allocWithParamsEP16IO80211WorkQueue",
            "__ZN17IO80211PostOffice4freeEv",
            "__ZN17IO80211Controller13getPostOfficeEv",
        )
        current="UNKNOWN"
        emitted=0
        for line in p.stdout.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                current=line[:-1]
            if any(t in line for t in targets):
                print("FULL_TEXT_XREF FUNCTION=%s INSTRUCTION=%s"%(current,line.strip()))
                emitted+=1
        print("FULL_TEXT_XREF_MATCH_COUNT=%d"%emitted)
    else:
        print("FULL_TEXT_XREF_SCAN_ERROR="+p.stderr.strip()[:300])

print("\nSTAGE167_INTERPRETATION=GLOBAL_VALUES_AND_INDIRECT_TARGETS_REPORTED; DO_NOT_CLAIM_OWNERSHIP_WHERE_ONLY_RAW_POINTER_OR_INDIRECT_DISPATCH_IS_VISIBLE")
PY

  echo
  echo "===== PROJECT PRESERVATION CHECK ====="
  STATUS_AFTER="$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
  echo "PROJECT_STATUS_BEFORE_SHA=$STATUS_BEFORE"
  echo "PROJECT_STATUS_AFTER_SHA=$STATUS_AFTER"
  [[ "$STATUS_BEFORE" == "$STATUS_AFTER" ]] || { echo "PROJECT_WORKTREE_PRESERVATION=FAIL"; exit 11; }
  echo "PROJECT_WORKTREE_PRESERVATION=PASS"
  echo "STAGE167_PROJECT_SOURCE_MODIFIED=NO PROJECT_BUILD_OUTPUTS=NO"
  echo "STAGE167_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN AUXKC=UNCHANGED OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
  echo "========== END STAGE167 =========="
} > "$REPORT" 2>&1

echo "===== STAGE167 SUMMARY ====="
grep -aE '^(STAGE167_|FILESSET_CARVE=|RIP_GLOBAL TAG=|GLOBAL_OBJECT_VPTR |GLOBAL_OBJECT_VTABLE_SLOT |ADDRESS_TARGET |ADDRESS_METHOD |WORKQUEUE_VTABLE_SLOT |STATIC_GLOBAL |STATIC_GLOBAL_OBJECT_VPTR |TARGET_SYMBOL TAG=|METHOD_TAG=|FULL_TEXT_XREF FUNCTION=|FULL_TEXT_XREF_MATCH_COUNT=|STAGE167_INTERPRETATION=|PROJECT_WORKTREE_PRESERVATION=)' "$REPORT" || true

python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage167-workqueue-global-dispatch-postoffice-xrefs-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage167: publish read-only workqueue global dispatch and PostOffice xref audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
                print("STAGE167_UPLOAD_SHA="+actual)
                print("STAGE167_GITHUB_PATH="+dest)
                print("STAGE167_UPLOAD=PASS_VERIFIED")
                break
    last=r.stderr.strip() or r.stdout.strip()
    check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main","--jq",".sha"],capture_output=True,text=True)
    if check.returncode==0 and check.stdout.strip()==expected:
        print("STAGE167_UPLOAD_SHA="+expected)
        print("STAGE167_GITHUB_PATH="+dest)
        print("STAGE167_UPLOAD=PASS_RECOVERED")
        break
    if check.returncode==0 and check.stdout.strip():
        print("STAGE167_UPLOAD_CONFLICT="+check.stdout.strip())
        raise SystemExit(20)
    if attempt<3: time.sleep(attempt*3)
else:
    print("STAGE167_UPLOAD=FAILED")
    print(last)
    raise SystemExit(21)
PY
