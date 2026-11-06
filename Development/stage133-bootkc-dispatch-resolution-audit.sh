#!/bin/bash
# Stage133: read-only BootKernelExtensions.kc owner/slot/callback resolution.
# No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_KCFILE_SHA="5d31e8a73e5cb175851e7407529456f223683589"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$ROOT" ]]; then echo "ERROR: run inside existing project checkout"; exit 2; fi
cd "$ROOT"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "$BRANCH" ]]; then BRANCH="DETACHED_OR_UNKNOWN"; fi
STATUS="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
if [[ "$OSVER" != "15.8.1" || "$BUILD" != "24H32" || "$ARCH" != "x86_64" ]]; then
 echo "ERROR: expected macOS 15.8.1 24H32 x86_64; found $OSVER $BUILD $ARCH"; exit 3
fi
if [[ ! -r "$BOOTKC" ]]; then echo "ERROR: BootKernelExtensions.kc not readable: $BOOTKC"; exit 4; fi
for cmd in curl gh python3 shasum; do command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd"; exit 5; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI is not authenticated"; exit 6; }

TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TMPROOT" ]]; then TMPROOT="/tmp"; fi
WORK="$(mktemp -d "$TMPROOT/stage133-tools-XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage133-report-XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
curl -fsSLo "$WORK/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
python3 - "$WORK/kcfile.py" "$UPSTREAM_KCFILE_SHA" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); data=p.read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE133_KCFILE_GIT_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned kcfile.py Git blob SHA mismatch")
PY
BOOTKC_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

{
 echo "========== STAGE133 BOOT KERNEL COLLECTION DISPATCH TABLE AUDIT =========="
 echo "STAGE133_SOURCE_COMMIT=$SOURCE"
 echo "STAGE133_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE133_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE133_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE133_SCOPE=READ_ONLY_BOOTKC_FILES_OWNER_AND_CALLBACK_POINTER_RESOLUTION"
 echo "STAGE133_BOOTKC_PATH=$BOOTKC"
 echo "STAGE133_BOOTKC_SHA256=$BOOTKC_SHA"
 echo "STAGE133_UPSTREAM_READER=watchthelight-labs/WTLKcAbi@$UPSTREAM_COMMIT"
 echo "STAGE133_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE133_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 STAGE133_READER_PATH="$WORK" python3 - "$BOOTKC" <<'PY'
import os,sys
sys.path.insert(0,os.environ["STAGE133_READER_PATH"])
from kcfile import KC

path=sys.argv[1]
kc=KC(path)
print("STAGE133_BOOTKC_SHA256="+kc.sha256())
print("STAGE133_FILES_BASE=0x%x"%kc.base)
print("STAGE133_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE133_SYMBOL_COUNT=%d"%len(kc.syms))
print("STAGE133_KERNEL_COLLECTION_POINTER_BASE0=0x%x"%kc.base)

for bid,vm,fo in kc.entries:
    if any(term in bid.lower() for term in ("skywalk","80211","network")):
        print("RELEVANT_FILESET_ENTRY=%s VMADDR=0x%x FILEOFF=0x%x"%(bid,vm,fo))

GOT=0xffffff80023bc108
SLOT_ENABLE=0x860
SLOT_DISABLE=0x868
EXPECTED={
 "IO80211SkywalkInterface":"__ZN23IO80211SkywalkInterface13getAssocStateEv",
 "IO80211InfraInterface":"__ZN21IO80211InfraInterface13getAssocStateEv",
}
print("\n--- Verify Stage129/132 vtable address-point entries ---")
for cls,wanted in EXPECTED.items():
    vt=kc.vtable(cls)
    if vt is None:
        print("VTABLE_%s=NOT_FOUND"%cls); continue
    index=(0x10+0xD58)//8
    item=next((x for x in vt if x[0]==index),None)
    if item is None:
        print("VTABLE_%s_SLOT=NOT_FOUND"%cls); continue
    idx,raw,target,name=item
    print("VTABLE_CLASS=%s INDEX=%d BYTE_OFFSET_FROM_SYMBOL=0x%x"%(cls,idx,idx*8))
    print("VTABLE_RAW=0x%x TARGET=0x%x SYMBOL=%s"%(raw,target,name))
    print("VTABLE_EXPECTED=%s RESULT=%s"%(wanted,"PASS" if kc.syms.get(target)==wanted else "REVIEW_REQUIRED"))

print("\n--- Locate GOT pointer and dispatch table in full BootKC ---")
got_raw=kc.q(GOT)
print("STAGE133_GOT_ADDRESS=0x%x"%GOT)
if got_raw is None:
    print("STAGE133_GOT_RAW=UNREADABLE")
    raise SystemExit(0)
table=kc.ptr(got_raw)
print("STAGE133_GOT_RAW_QWORD=0x%x"%got_raw)
print("STAGE133_GOT_DECODED_TABLE=0x%x"%table)
print("STAGE133_GOT_OWNER="+str(kc.owner(GOT) or "TOP_LEVEL_OR_UNATTRIBUTED"))
print("STAGE133_TABLE_OWNER="+str(kc.owner(table) or "TOP_LEVEL_OR_UNATTRIBUTED"))
print("STAGE133_TABLE_NEAREST_SYMBOL="+str(kc.symname(table) or "UNRESOLVED"))
print("STAGE133_TABLE_EXACT_SYMBOL="+str(kc.syms.get(table) or "NONE"))

for label,offset in (("ENABLE",SLOT_ENABLE),("DISABLE",SLOT_DISABLE)):
    slot_addr=table+offset
    raw=kc.q(slot_addr)
    print("\nDISPATCH_SLOT=%s"%label)
    print("DISPATCH_SLOT_ADDRESS=0x%x"%slot_addr)
    if raw is None:
        print("DISPATCH_SLOT_RAW=UNREADABLE")
        print("DISPATCH_SLOT_RESOLUTION=FAILED")
        continue
    target=kc.ptr(raw)
    owner=kc.owner(target)
    exact=kc.syms.get(target)
    nearest=kc.symname(target)
    print("DISPATCH_SLOT_RAW_QWORD=0x%x"%raw)
    print("DISPATCH_SLOT_TARGET=0x%x"%target)
    print("DISPATCH_SLOT_OWNER="+str(owner or "TOP_LEVEL_OR_UNATTRIBUTED"))
    print("DISPATCH_SLOT_EXACT_SYMBOL="+str(exact or "NONE"))
    print("DISPATCH_SLOT_NEAREST_SYMBOL="+str(nearest or "UNRESOLVED"))
    print("DISPATCH_SLOT_RESOLUTION="+("EXACT_SYMBOL" if exact else ("ADDRESS_WITHOUT_EXACT_SYMBOL" if kc.va2off(target) is not None else "UNMAPPED_TARGET")))

    if owner:
        segs=kc.entry_segs.get(owner,[])
        matches=[s for s in segs if s[1]<=target<s[1]+s[2]]
        for s in matches:
            print("CALLBACK_OWNER_SEGMENT=%s VMADDR=0x%x VMSIZE=0x%x FILEOFF=0x%x FILESIZE=0x%x INITPROT=0x%x"%(s[0],s[1],s[2],s[3],s[4],s[5]))
            print("CALLBACK_OWNER_EXECUTABLE="+("YES" if s[5]&4 else "NO"))

print("\n--- Full collection address ownership summary ---")
for label,address in (("GOT",GOT),("TABLE",table),("ENABLE_SLOT",table+SLOT_ENABLE),("DISABLE_SLOT",table+SLOT_DISABLE)):
    print("ADDRESS_OWNER_%s=%s"%(label,kc.owner(address) or "TOP_LEVEL_OR_UNATTRIBUTED"))
print("STAGE133_CALLBACK_RESOLUTION_POLICY=ONLY_EXACT_KC_SYMBOL_COUNTS_AS_RESOLVED")
print("STAGE133_SOURCE_READ_ONLY=YES")
PY
 echo
 echo "STAGE133_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE133_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE133_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE133 =========="
} >"$REPORT"

echo "===== STAGE133 SUMMARY ====="
grep -aE '^(STAGE133_|RELEVANT_FILESET_ENTRY=|VTABLE_CLASS=|VTABLE_RAW=|DISPATCH_SLOT=|DISPATCH_SLOT_(ADDRESS|RAW|TARGET|OWNER|EXACT|NEAREST|RESOLUTION)=|CALLBACK_OWNER_|ADDRESS_OWNER_)' "$REPORT" | tail -180 || true
echo "STAGE133_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage133-bootkc-dispatch-resolution-"+stamp+".log"
payload={"message":"Stage133: publish read-only BootKC dispatch table owner and callback resolution","branch":"main","content":base64.b64encode(data).decode("ascii")}
expected=hashlib.sha1(("blob "+str(len(data))+"\0").encode("ascii")+data).hexdigest()
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f); f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE133_UPLOAD=PASS"); print("STAGE133_UPLOAD_SHA="+actual); print("STAGE133_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE133_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE133_UPLOAD_SHA="+existing); print("STAGE133_GITHUB_PATH="+dest); break
  print("STAGE133_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE133_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE133_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
