#!/bin/bash
# Stage138: audit IOSkywalkNetworkInterface enabled-state reader and advisory path.
# READ ONLY. No source edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 2; }
for c in curl gh python3 shasum otool; do command -v "$c" >/dev/null || exit 3; done
gh auth status >/dev/null 2>&1 || exit 4
[[ -r "$BOOTKC" ]] || exit 5
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 6; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stage138-work.XXXXXX")"
REPORT="$(mktemp "${TMPDIR:-/tmp}/stage138-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
h=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
if h!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
print("READER_SHA=PASS")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE138 SKYWALK ENABLED STATE AUDIT =========="
 echo "STAGE138_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE138_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE138_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE138_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE138_SCOPE=READ_ONLY_IS_ENABLED_AND_ADVISORY_METHODS"
 echo "STAGE138_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE138_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE138_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE138_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]
owner="com.apple.iokit.IOSkywalkFamily"
methods=[
 "__ZN25IOSkywalkNetworkInterface9isEnabledEv",
 "__ZN25IOSkywalkNetworkInterface23interfaceAdvisoryEnableEb",
 "__ZN25IOSkywalkNetworkInterface6enableEj",
 "__ZN25IOSkywalkNetworkInterface7disableEj",
]
dest=pathlib.Path(os.environ["STAGE138_WORK"])/"IOSkywalkFamily.macho"
kc.carve(owner,str(dest))
print("CARVED_OWNER="+owner)
for sym in methods:
 addr=kc.syms.get(sym)
 print("\nMETHOD_SYMBOL="+sym)
 if addr is None: print("METHOD_STATUS=SYMBOL_NOT_FOUND"); continue
 actual_owner=kc.owner(addr)
 print("METHOD_ADDRESS=0x%x"%addr); print("METHOD_OWNER="+str(actual_owner))
 if actual_owner!=owner: print("METHOD_STATUS=OWNER_MISMATCH"); continue
 end=kc.next_sym(addr) or addr+0x1000
 if end<=addr or end>addr+0x1000: end=addr+0x1000
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",sym,str(dest)],capture_output=True,text=True)
 print("OTOOL_EXIT=%d"%p.returncode)
 if p.returncode: print(p.stderr[:2000]); continue
 ins=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m:
   a=int(m.group(1),16)
   if addr<=a<end: ins.append((a,line.strip(),m.group(2)))
 if not ins or ins[0][0]!=addr: print("METHOD_DISASSEMBLY=NOT_VERIFIED"); continue
 print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
 print("METHOD_RANGE=0x%x..0x%x"%(addr,end))
 print("INSTRUCTION_COUNT=%d"%len(ins))
 for a,raw,asm in ins:
  print(raw)
  if re.search(r"\b(call|jmp)q?\b",asm): print("CONTROL_FLOW=0x%x %s"%(a,asm))
PY
 echo "STAGE138_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE138_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE138 =========="
} >"$REPORT"
echo "===== STAGE138 SUMMARY ====="
grep -aE '^(STAGE138_|METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_STATUS=|METHOD_DISASSEMBLY=|METHOD_RANGE=|INSTRUCTION_COUNT=|CONTROL_FLOW=)' "$REPORT" || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile
p=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=p.read_bytes(); dest="Development/Logs/stage138-skywalk-enabled-state-"+stamp+".log"
sha=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage138: publish read-only Skywalk enabled-state audit","branch":"main","content":base64.b64encode(data).decode()}
with tempfile.NamedTemporaryFile(mode="w") as f:
 json.dump(payload,f); f.flush()
 r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
if r.returncode: print(r.stderr); raise SystemExit(7)
actual=json.loads(r.stdout).get("content",{}).get("sha")
print("STAGE138_UPLOAD_SHA="+str(actual)); print("STAGE138_GITHUB_PATH="+dest)
if actual!=sha: raise SystemExit("STAGE138_UPLOAD_SHA_MISMATCH expected="+sha)
print("STAGE138_UPLOAD=PASS")
PY
