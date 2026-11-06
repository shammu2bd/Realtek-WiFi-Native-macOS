#!/bin/bash
# Stage134: read-only disassembly of the resolved Apple Skywalk enable/disable callbacks.
# No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
UPSTREAM_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
UPSTREAM_KCFILE_SHA="5d31e8a73e5cb175851e7407529456f223683589"
EXPECTED_BOOTKC_SHA="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
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
if [[ ! -r "$BOOTKC" ]]; then echo "ERROR: BootKC not readable"; exit 4; fi
for cmd in curl gh python3 shasum file; do command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd"; exit 5; }; done
OTOOL="$(command -v otool 2>/dev/null || true)"
if [[ -z "$OTOOL" || ! -x "$OTOOL" ]]; then echo "ERROR: otool missing"; exit 6; fi
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI unauthenticated"; exit 7; }
BOOTKC_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
if [[ "$BOOTKC_SHA" != "$EXPECTED_BOOTKC_SHA" ]]; then
 echo "ERROR: BootKC SHA mismatch EXPECTED=$EXPECTED_BOOTKC_SHA ACTUAL=$BOOTKC_SHA"; exit 8
fi
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TMPROOT" ]]; then TMPROOT="/tmp"; fi
WORK="$(mktemp -d "$TMPROOT/stage134-tools-XXXXXX")"
CACHE="$WORK/carved"
mkdir -p "$CACHE"
REPORT="$(mktemp "$TMPROOT/stage134-report-XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
UPSTREAM_RAW="https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$UPSTREAM_COMMIT"
curl -fsSLo "$WORK/kcfile.py" "$UPSTREAM_RAW/kcfile.py"
python3 - "$WORK/kcfile.py" "$UPSTREAM_KCFILE_SHA" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); data=p.read_bytes()
actual=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
print("STAGE134_KCFILE_GIT_BLOB_SHA="+actual)
if actual!=sys.argv[2]: raise SystemExit("Pinned kcfile.py Git blob SHA mismatch")
PY
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE134 APPLE SKYWALK ENABLE / DISABLE CALLBACK DISASSEMBLY =========="
 echo "STAGE134_SOURCE_COMMIT=$SOURCE"
 echo "STAGE134_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE134_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE134_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE134_SCOPE=READ_ONLY_FILESSET_AWARE_CALLBACK_METHOD_DISASSEMBLY"
 echo "STAGE134_BOOTKC_PATH=$BOOTKC"
 echo "STAGE134_BOOTKC_SHA256=$BOOTKC_SHA"
 echo "STAGE134_OTOOL=$OTOOL"
 echo "STAGE134_UPSTREAM_READER=watchthelight-labs/WTLKcAbi@$UPSTREAM_COMMIT"
 echo "STAGE134_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE134_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 STAGE134_READER_PATH="$WORK" STAGE134_CACHE="$CACHE" python3 - "$BOOTKC" "$OTOOL" <<'PY'
import os,pathlib,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE134_READER_PATH"])
from kcfile import KC
bootkc,otool=sys.argv[1:]
kc=KC(bootkc)
print("STAGE134_FILES_BASE=0x%x"%kc.base)
print("STAGE134_FILESET_ENTRY_COUNT=%d"%len(kc.entries))
print("STAGE134_SYMBOL_COUNT=%d"%len(kc.syms))
expected={
 "__ZN26IOSkywalkEthernetInterface6enableEj":("com.apple.iokit.IOSkywalkFamily","ENABLE"),
 "__ZN25IOSkywalkNetworkInterface7disableEj":("com.apple.iokit.IOSkywalkFamily","DISABLE"),
}
resolved=[]
print("\n--- Exact callback owner and target identity ---")
for sym,(expected_owner,label) in expected.items():
 va=kc.find(sym)
 if va is None:
  print("CALLBACK_"+label+"_SYMBOL=NOT_FOUND"); continue
 owner=kc.owner(va)
 exact=kc.syms.get(va)
 print("CALLBACK_"+label+"_ADDRESS=0x%x"%va)
 print("CALLBACK_"+label+"_SYMBOL="+str(exact))
 print("CALLBACK_"+label+"_OWNER="+str(owner))
 print("CALLBACK_"+label+"_OWNER_CHECK="+("PASS" if owner==expected_owner else "REVIEW_REQUIRED"))
 segs=[s for s in kc.entry_segs.get(owner,[]) if s[1]<=va<s[1]+s[2]] if owner else []
 if not segs:
  print("CALLBACK_"+label+"_EXECUTABLE_SEGMENT=NOT_FOUND"); continue
 seg=segs[0]
 print("CALLBACK_"+label+"_SEGMENT=%s VMADDR=0x%x VMSIZE=0x%x FILEOFF=0x%x FILESIZE=0x%x INITPROT=0x%x"%(seg[0],seg[1],seg[2],seg[3],seg[4],seg[5]))
 print("CALLBACK_"+label+"_EXECUTABLE="+("YES" if seg[5]&4 else "NO"))
 if owner!=expected_owner or not (seg[5]&4): continue
 end=kc.next_sym(va) or va+0x1000
 if end<=va or end>va+0x1000: end=va+0x1000
 resolved.append((label,sym,va,owner,end))
print("STAGE134_EXPECTED_CALLBACKS=%d"%len(expected))
print("STAGE134_CALLBACKS_OWNER_VALIDATED=%d"%len(resolved))

print("\n--- Related enable/disable methods in callback owner classes ---")
for cls in ("IOSkywalkEthernetInterface","IOSkywalkNetworkInterface","IOSkywalkInterface"):
 try: methods=kc.methods(cls)
 except Exception as e:
  print("CLASS_%s_SCAN=ERROR:%s"%(cls,str(e))); continue
 hits=[(va,nm) for va,nm in methods if re.search(r"(?:enable|disable|setInterfaceEnable|isInterfaceEnabled)",nm,re.I)]
 print("CLASS=%s RELATED_METHOD_COUNT=%d"%(cls,len(hits)))
 for va,nm in hits[:70]:
  print("RELATED_METHOD class=%s address=0x%x owner=%s symbol=%s"%(cls,va,kc.owner(va) or "UNKNOWN",nm))

print("\n--- Carve and disassemble exact owning fileset image ---")
owners=sorted({x[3] for x in resolved})
for owner in owners:
 safe=re.sub(r"[^A-Za-z0-9_.-]","_",owner)
 carved=pathlib.Path(os.environ["STAGE134_CACHE"])/(safe+".macho")
 kc.carve(owner,str(carved))
 print("CARVED_OWNER=%s"%owner)
 print("CARVED_PATH=%s"%carved)
 print("CARVED_BYTES=%d"%carved.stat().st_size)
 print("CARVED_FILE_TYPE="+subprocess.run(["file",str(carved)],capture_output=True,text=True).stdout.strip())

for owner in owners:
 local=[x for x in resolved if x[3]==owner]
 first=min(local,key=lambda x:x[2])
 carved=pathlib.Path(os.environ["STAGE134_CACHE"])/(re.sub(r"[^A-Za-z0-9_.-]","_",owner)+".macho")
 cmd=[otool,"-arch","x86_64","-tvV","-p",first[1],str(carved)]
 p=subprocess.run(cmd,capture_output=True,text=True)
 print("OTOOL_OWNER_DUMP=%s EXIT=%d START=%s"%(owner,p.returncode,first[1]))
 if p.returncode!=0:
  print("OTOOL_STDERR="+p.stderr[:5000]); continue
 lines=p.stdout.splitlines()
 for label,sym,va,own,end in local:
  print("\n===== METHOD %s ====="%label)
  print("METHOD_SYMBOL=%s"%sym)
  print("METHOD_RANGE=0x%x..0x%x"%(va,end))
  selected=[]
  for line in lines:
   m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
   if not m: continue
   a=int(m.group(1),16)
   if va<=a<end: selected.append((a,line.strip(),m.group(2)))
  if not selected or selected[0][0]!=va:
   print("METHOD_DISASSEMBLY=NOT_VERIFIED")
   print("METHOD_INSTRUCTION_COUNT=0")
   continue
  print("METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
  print("METHOD_INSTRUCTION_COUNT=%d"%len(selected))
  for a,raw,asm in selected:
   print(raw)
   if re.search(r"\b(call|jmp)q?\b",asm):
    print("METHOD_CONTROL_FLOW=0x%x %s"%(a,asm))
PY
 echo
 echo "STAGE134_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE134_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE134_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE134 =========="
} >"$REPORT"
echo "===== STAGE134 SUMMARY ====="
grep -aE '^(STAGE134_|CALLBACK_|RELATED_METHOD|===== METHOD|METHOD_DISASSEMBLY=|METHOD_INSTRUCTION_COUNT=|METHOD_CONTROL_FLOW=|OTOOL_OWNER_DUMP=|ERROR:)' "$REPORT" | tail -200 || true
echo "STAGE134_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage134-skywalk-callback-disassembly-"+stamp+".log"
payload={"message":"Stage134: publish read-only Apple Skywalk callback disassembly","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE134_UPLOAD=PASS"); print("STAGE134_UPLOAD_SHA="+actual); print("STAGE134_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE134_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE134_UPLOAD_SHA="+existing); print("STAGE134_GITHUB_PATH="+dest); break
  print("STAGE134_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE134_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE134_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
