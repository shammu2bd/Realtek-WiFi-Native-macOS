#!/bin/bash
# Stage130: read-only Apple 24H32 getAssocState / setInterfaceEnable dispatch audit.
# No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PIN="8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878"
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
TC="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
NM="$TC/llvm-nm"
OTOOL="$(command -v otool 2>/dev/null || true)"
if [[ ! -x "$NM" || -z "$OTOOL" || ! -x "$OTOOL" ]]; then echo "ERROR: required Apple/Xcode tools missing"; exit 4; fi
KC="$(printenv STAGE130_KC_MACHO 2>/dev/null || true)"
if [[ -z "$KC" ]]; then KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"; fi
if [[ -z "$KC" || ! -f "$KC" ]]; then echo "ERROR: pinned Stage120 IO80211Family Mach-O not found; set STAGE130_KC_MACHO"; exit 5; fi
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
if [[ "$KC_SHA" != "$PIN" ]]; then echo "ERROR: Mach-O SHA mismatch EXPECTED=$PIN ACTUAL=$KC_SHA"; exit 6; fi
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TMPROOT" ]]; then TMPROOT="/tmp"; fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp "$TMPROOT/stage130-report-XXXXXX")"
NMF="$(mktemp "$TMPROOT/stage130-nm-XXXXXX")"
DUMPF="$(mktemp "$TMPROOT/stage130-dump-XXXXXX")"
trap 'rm -f "$NMF" "$DUMPF"' EXIT
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
"$NM" -n --defined-only "$KC" >"$NMF" 2>&1
SYMBOL_RE='^(__ZN23IO80211SkywalkInterface13getAssocStateEv|__ZN21IO80211InfraInterface13getAssocStateEv|__ZN21IO80211InfraInterface18setInterfaceEnableEb|__ZN23IO80211SkywalkInterface18setInterfaceEnableEb)$'
FIRST_SYMBOL="$(python3 - "$NMF" "$SYMBOL_RE" <<'PY'
import pathlib,re,sys
found=[]
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]) and re.fullmatch(sys.argv[2],f[-1]):
  found.append((int(f[0],16),f[-1]))
if len(found)<4: raise SystemExit("Expected all four Apple methods in numeric nm listing")
print(min(found)[1])
PY
)"
"$OTOOL" -arch x86_64 -tvV -p "$FIRST_SYMBOL" "$KC" >"$DUMPF" 2>&1
if ! grep -Fq "$FIRST_SYMBOL" "$DUMPF"; then echo "ERROR: otool output does not contain first exact symbol"; exit 7; fi
{
 echo "========== STAGE130 APPLE getAssocState / POWER DISPATCH AUDIT =========="
 echo "STAGE130_SOURCE_COMMIT=$SOURCE"
 echo "STAGE130_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE130_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE130_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE130_SCOPE=READ_ONLY_EXACT_METHOD_DISASSEMBLY_AND_CALLSITE_VALIDATION"
 echo "STAGE130_KC_MACHO_SHA256=$KC_SHA"
 echo "STAGE130_KC_MACHO_PATH=$KC"
 echo "STAGE130_DUMP_TOOL=$OTOOL"
 echo "STAGE130_DUMP_START_SYMBOL=$FIRST_SYMBOL"
 echo "STAGE130_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE130_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 echo "--- Exact address-bounded Apple methods ---"
 python3 - "$NMF" "$DUMPF" "$SYMBOL_RE" <<'PY'
import pathlib,re,sys
nmfile,dumpfile,pattern=sys.argv[1:]
entries=[]
for line in pathlib.Path(nmfile).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]):
  try: entries.append((int(f[0],16),f[-2],f[-1]))
  except ValueError: pass
targets=[(a,n) for a,t,n in entries if re.fullmatch(pattern,n)]
lines=pathlib.Path(dumpfile).read_text(errors="replace").splitlines()
for start,name in sorted(targets):
 following=[a for a,t,n in entries if a>start and t.upper()=="T"]
 next_addr=min(following) if following else start+0x600
 stop=min(next_addr,start+0x600)
 selected=[]
 for line in lines:
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):\s*(.*)$",line)
  if not m: continue
  a=int(m.group(1),16)
  if start<=a<stop: selected.append((a,line.strip(),m.group(2)))
 print("===== METHOD "+name+" =====")
 print("STAGE130_METHOD_START=0x"+format(start,"x"))
 print("STAGE130_METHOD_STOP=0x"+format(stop,"x"))
 if not selected or selected[0][0]!=start:
  print("STAGE130_METHOD_DISASSEMBLY=NOT_VERIFIED")
  print("STAGE130_METHOD_INSTRUCTION_COUNT=0")
  continue
 print("STAGE130_METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
 print("STAGE130_METHOD_INSTRUCTION_COUNT="+str(len(selected)))
 for _,line,asm in selected:
  print(line)
  if re.search(r"\bcallq?\b",asm): print("STAGE130_CALL_IN_METHOD="+asm)
PY
 echo
 echo "--- Exact Stage126 call-site revalidation ---"
 python3 - "$DUMPF" <<'PY'
import pathlib,re,sys
target=0xffffff80022dc483
found=[]
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
 m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):\s*(.*)$",line)
 if m and int(m.group(1),16)==target: found.append(line.strip())
print("STAGE130_STAGE126_CALLSITE_0xffffff80022dc483="+("FOUND" if found else "NOT_FOUND"))
for line in found: print("KNOWN_CALLSITE_LINE="+line)
PY
 echo
 echo "--- Direct references to Skywalk setInterfaceEnable ---"
 grep -nF "callq $SKYWALK" "$DUMPF" || true
 echo
 echo "--- Direct references to Infra setInterfaceEnable ---"
 grep -nF "callq __ZN21IO80211InfraInterface18setInterfaceEnableEb" "$DUMPF" || true
 echo
 echo "STAGE130_VTABLE_SLOT_0xD58_IDENTIFIED_AS=getAssocState"
 echo "STAGE130_DRIVER_POWER_SEQUENCE=NOT_PROVEN_BY_STATIC_METHOD_DISASSEMBLY_ALONE"
 echo "STAGE130_POWER_CALL_GRAPH=REVIEW_REQUIRED"
 echo "STAGE130_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE130_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE130_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE130 =========="
} >"$REPORT"
echo "===== STAGE130 SUMMARY ====="
grep -aE '^(STAGE130_|===== METHOD|STAGE130_METHOD_|STAGE130_STAGE126|KNOWN_CALLSITE_LINE|STAGE130_CALL_IN_METHOD)' "$REPORT" | tail -140 || true
echo "STAGE130_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage130-apple-assoc-state-"+stamp+".log"
payload={"message":"Stage130: publish read-only Apple 24H32 association-state method audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE130_UPLOAD=PASS"); print("STAGE130_UPLOAD_SHA="+actual); print("STAGE130_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE130_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE130_UPLOAD_SHA="+existing); print("STAGE130_GITHUB_PATH="+dest); break
  print("STAGE130_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE130_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE130_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
