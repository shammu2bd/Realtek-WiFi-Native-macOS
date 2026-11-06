#!/bin/bash
# Stage137: independently revalidate the IOSkywalkNetworkInterface vtable target used by Stage136 enable().
# READ ONLY: no driver edits/build/sign/install/load/unload/hardware activation/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
BOOTKC_SHA_EXPECTED="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch: $OS $BUILD $ARCH"; exit 2; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null || { echo "ERROR: missing $c"; exit 3; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh auth required"; exit 4; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 5; }
ACTUAL_BOOTKC_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$ACTUAL_BOOTKC_SHA" == "$BOOTKC_SHA_EXPECTED" ]] || { echo "ERROR: BootKC SHA mismatch: $ACTUAL_BOOTKC_SHA"; exit 6; }
TMP="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMP/stage137-work.XXXXXX")"
REPORT="$(mktemp "$TMP/stage137-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
h=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\\0"+d).hexdigest()
print("READER_BLOB_SHA="+h)
if h!=sys.argv[2]: raise SystemExit("reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE137 NETWORK ENABLE VIRTUAL DISPATCH REVALIDATION =========="
 echo "STAGE137_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE137_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE137_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE137_BOOTKC_SHA256=$ACTUAL_BOOTKC_SHA"
 echo "STAGE137_SCOPE=READ_ONLY_OBJECT_VPTR_SLOT_0x928_AND_EXACT_TARGET_DISASSEMBLY"
 echo "STAGE137_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE137_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE137_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE137_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
cls="IOSkywalkNetworkInterface"; off=0x928; expected="__ZN25IOSkywalkNetworkInterface18setInterfaceEnableEb"
vt=kc.vtable(cls)
print("OBJECT_VPTR_SLOT_BYTE_OFFSET=0x928")
idx=(0x10+off)//8
print("VTABLE_INDEX=%d"%idx)
item=next((x for x in vt if x[0]==idx),None) if vt else None
if not item: raise SystemExit("STAGE137_SLOT=NOT_FOUND")
i,raw,target,name=item
owner=kc.owner(target); exact=kc.syms.get(target); nearest=kc.symname(target)
print("SLOT_RAW_QWORD=0x%x"%raw); print("SLOT_TARGET=0x%x"%target)
print("SLOT_EXACT_SYMBOL="+str(exact)); print("SLOT_NEAREST_SYMBOL="+str(nearest))
print("SLOT_OWNER="+str(owner))
if exact!=expected or owner!="com.apple.iokit.IOSkywalkFamily": raise SystemExit("STAGE137_SLOT_IDENTITY=FAIL")
print("STAGE137_SLOT_IDENTITY=PASS")
end=kc.next_sym(target) or target+0x1000
if end<=target or end>target+0x1000: end=target+0x1000
dest=pathlib.Path(os.environ["STAGE137_WORK"])/"IOSkywalkFamily.macho"
kc.carve(owner,str(dest))
p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",expected,str(dest)],capture_output=True,text=True)
print("OTOOL_EXIT=%d"%p.returncode)
if p.returncode: print(p.stderr[:3000]); raise SystemExit("disassembly failed")
selected=[]
for line in p.stdout.splitlines():
 m=re.match(r"^\\s*(?:0x)?([0-9a-fA-F]{8,}):?\\s+(.*)$",line)
 if m:
  a=int(m.group(1),16)
  if target<=a<end: selected.append((a,line.strip(),m.group(2)))
if not selected or selected[0][0]!=target: raise SystemExit("STAGE137_DISASSEMBLY=NOT_VERIFIED")
print("METHOD_RANGE=0x%x..0x%x"%(target,end))
print("STAGE137_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
print("INSTRUCTION_COUNT=%d"%len(selected))
for a,rawline,asm in selected:
 print(rawline)
 if re.search(r"\\b(call|jmp)q?\\b",asm): print("CONTROL_FLOW=0x%x %s"%(a,asm))
PY
 echo "STAGE137_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE137_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE137 =========="
} >"$REPORT"
echo "===== STAGE137 SUMMARY ====="
grep -aE '^(STAGE137_|OBJECT_VPTR|VTABLE_INDEX=|SLOT_|METHOD_RANGE=|INSTRUCTION_COUNT=|STAGE137_DISASSEMBLY=|CONTROL_FLOW=)' "$REPORT" || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile
p=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=p.read_bytes(); path="Development/Logs/stage137-network-enable-dispatch-"+stamp+".log"
sha=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\\0"+data).hexdigest()
payload={"message":"Stage137: publish read-only network enable dispatch audit","branch":"main","content":base64.b64encode(data).decode()}
with tempfile.NamedTemporaryFile(mode="w") as f:
 json.dump(payload,f); f.flush()
 r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+path,"--input",f.name],capture_output=True,text=True)
if r.returncode: print(r.stderr); raise SystemExit(7)
obj=json.loads(r.stdout); actual=obj.get("content",{}).get("sha")
print("STAGE137_UPLOAD_SHA="+str(actual))
print("STAGE137_GITHUB_PATH="+path)
if actual!=sha: raise SystemExit("STAGE137_UPLOAD_SHA_MISMATCH expected="+sha)
print("STAGE137_UPLOAD=PASS")
PY
