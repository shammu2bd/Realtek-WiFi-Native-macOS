#!/bin/bash
# Stage146: correlate Apple POWER wrappers with InfraInterface::postMessage and local driver ABI/source.
# READ ONLY. No checkout/source/index changes, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
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
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage146-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage146-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
actual=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE146_READER_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE146 APPLE POWER MESSAGE SEMANTICS AUDIT =========="
 echo "STAGE146_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE146_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE146_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE146_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE146_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE146_SCOPE=READ_ONLY_POWER_WRAPPER_ARGUMENTS_MESSAGE_DISPATCH_AND_DRIVER_SOURCE_CORRELATION"
 echo "STAGE146_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE146_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE146_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$ROOT" <<'PY'
import hashlib,os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE146_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; root=pathlib.Path(sys.argv[3])
wanted={
 "__Z18apple80211getPOWERP23IO80211SkywalkInterfaceP21apple80211_power_data":"APPLE_GET_POWER",
 "__Z18apple80211setPOWERP23IO80211SkywalkInterfaceP21apple80211_power_data":"APPLE_SET_POWER",
 "__ZN23IO80211SkywalkInterface11postMessageEjPvmb":"SKYWALK_POST_MESSAGE",
 "__ZN21IO80211InfraInterface11postMessageEjPvmb":"INFRA_POST_MESSAGE",
 "__ZN23IO80211SkywalkInterface19postMessageInternalEjPvmb":"SKYWALK_POST_MESSAGE_INTERNAL"
}
found={}
for addr,name in kc.syms.items():
 if name in wanted:
  found[addr]=(name,wanted[name],kc.sym_owner.get(addr),kc.owner(addr))
print("STAGE146_FILES_BASE=0x%x"%kc.base)
print("STAGE146_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE146_SYMBOL_COUNT=%d"%len(kc.syms))
for name,tag in wanted.items():
 matches=[(a,v) for a,v in found.items() if v[0]==name]
 if not matches: print("METHOD_LOOKUP TAG=%s SYMBOL=%s STATUS=NOT_FOUND"%(tag,name))
 for a,(n,t,so,o) in matches:
  print("METHOD_LOOKUP TAG=%s SYMBOL=%s ADDRESS=0x%x OWNER=%s SYMBOL_OWNER=%s"%(tag,n,a,o or "UNATTRIBUTED",so or "UNATTRIBUTED"))
owners={v[2] for v in found.values() if v[2]}
paths={}
for bid,_,_ in kc.entries:
 if bid in owners:
  paths[bid]=pathlib.Path(os.environ["STAGE146_WORK"])/(re.sub(r"[^A-Za-z0-9_.-]","_",bid)+".macho")
for owner,dest in paths.items():
 if owner not in kc.entry_segs:
  print("OWNER_IMAGE=%s STATUS=NOT_A_CARVED_FILESET_ENTRY"%owner); continue
 kc.carve(owner,str(dest))
 for addr,(name,tag,symowner,_) in sorted(found.items()):
  if symowner!=owner: continue
  end=kc.next_sym(addr) or addr+0x4000
  if end<=addr: end=addr+0x4000
  cap=min(end,addr+0x4000)
  p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,str(dest)],capture_output=True,text=True)
  print("\\n--- METHOD %s ---"%tag)
  print("METHOD_SYMBOL="+name);print("METHOD_ADDRESS=0x%x"%addr)
  print("METHOD_OWNER="+owner);print("METHOD_NEXT_SYMBOL_BOUND=0x%x"%end)
  print("METHOD_AUDIT_BOUND=0x%x"%cap);print("OTOOL_EXIT=%d"%p.returncode)
  if p.returncode: print("METHOD_DISASSEMBLY=FAILED");continue
  ins=[]
  for line in p.stdout.splitlines():
   m=re.match(r"^\\s*(?:0x)?([0-9a-fA-F]{8,}):?\\s+(.*)$",line)
   if m:
    a=int(m.group(1),16)
    if addr<=a<cap: ins.append((a,line.strip(),m.group(2)))
  if not ins or ins[0][0]!=addr: print("METHOD_DISASSEMBLY=NOT_VERIFIED");continue
  print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("INSTRUCTION_COUNT=%d"%len(ins))
  if tag in ("APPLE_GET_POWER","APPLE_SET_POWER","SKYWALK_POST_MESSAGE","SKYWALK_POST_MESSAGE_INTERNAL"):
   selected=ins
  else:
   # The Infra dispatcher is large. Retain entry, comparisons/branches, event calls, and tail.
   selected=[]
   for i,item in enumerate(ins):
    a,raw,asm=item
    if i<42 or i>=max(0,len(ins)-18) or re.search(r"\\b(cmp|test)",asm) or re.search(r"\\b(call|jmp)",asm):
     selected.append(item)
   # stable de-duplication
   seen=set();selected=[x for x in selected if not (x[0] in seen or seen.add(x[0]))]
  for a,raw,asm in selected:
   print(raw)
   if tag=="APPLE_SET_POWER" and ("0xb10" in asm.lower() or re.search(r"\\$0x1, %r[89]d",asm)):
    print("POWER_POST_MESSAGE_ARGUMENT_TRACE=0x%x %s"%(a,asm))
   if re.search(r"\\b(call|jmp)q?\\b",asm):
    print("CONTROL_FLOW=0x%x %s"%(a,asm))
print("\\n--- Local driver POWER / postMessage source correlation ---")
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
files=[]
for p in base.rglob("*"):
 if p.is_file() and p.suffix in (".h",".hpp",".c",".cc",".cpp"):
  try:
   d=p.read_bytes()
   if b"postMessage" in d or b"apple80211_power_data" in d or b"getPOWER(" in d or b"setPOWER(" in d:
    files.append((p,d))
  except OSError: pass
for p,d in files:
 lines=d.decode("utf-8","replace").splitlines()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(p.relative_to(root),hashlib.sha256(d).hexdigest(),len(d)))
 matched=[i for i,x in enumerate(lines) if re.search(r"postMessage|apple80211_power_data|getPOWER\\s*\\(|setPOWER\\s*\\(",x)]
 for i in matched:
  print("SOURCE_MATCH file=%s line=%d text=%s"%(p.name,i+1,lines[i].strip()))
if not files: print("DRIVER_POWER_MESSAGE_SOURCE_MATCHES=NONE")
print("STAGE146_MESSAGE_DISPATCH_POLICY=STATIC_ARGUMENT_AND_EXACT_SYMBOL_CORRELATION")
print("STAGE146_INTERPRETATION=NO_HARDWARE_OR_RUNTIME_CLAIM")
PY
 echo "STAGE146_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE146_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE146 =========="
} >"$REPORT"
echo "===== STAGE146 SUMMARY ====="
grep -aE '^(STAGE146_|METHOD_LOOKUP |METHOD_SYMBOL=|METHOD_ADDRESS=|METHOD_OWNER=|METHOD_DISASSEMBLY=|INSTRUCTION_COUNT=|POWER_POST_MESSAGE_ARGUMENT_TRACE=|SOURCE_FILE=|SOURCE_MATCH |DRIVER_POWER_MESSAGE_SOURCE_MATCHES=)' "$REPORT" | head -240 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage146-apple-power-message-semantics-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage146: publish read-only Apple POWER message semantics audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE146_UPLOAD_SHA="+actual);print("STAGE146_GITHUB_PATH="+dest);print("STAGE146_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE146_UPLOAD_SHA="+existing);print("STAGE146_GITHUB_PATH="+dest);print("STAGE146_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE146_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE146_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE146_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
