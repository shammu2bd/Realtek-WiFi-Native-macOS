#!/bin/bash
# Stage131: read-only Apple 24H32 Skywalk enable/disable dispatch audit.
# No driver edits/build/sign/install/load/unload/hardware/OC/EFI/SIP/NVRAM/reboot.
set -euo pipefail
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
if [[ ! -x "$NM" || -z "$OTOOL" || ! -x "$OTOOL" ]]; then echo "ERROR: required tools missing"; exit 4; fi
KC="$(printenv STAGE131_KC_MACHO 2>/dev/null || true)"
if [[ -z "$KC" ]]; then KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"; fi
if [[ -z "$KC" || ! -f "$KC" ]]; then echo "ERROR: Stage120 IO80211Family Mach-O not found; set STAGE131_KC_MACHO"; exit 5; fi
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
if [[ "$KC_SHA" != "$PIN" ]]; then echo "ERROR: Mach-O SHA mismatch EXPECTED=$PIN ACTUAL=$KC_SHA"; exit 6; fi
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TMPROOT" ]]; then TMPROOT="/tmp"; fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp "$TMPROOT/stage131-report-XXXXXX")"
NMF="$(mktemp "$TMPROOT/stage131-nm-XXXXXX")"
DUMPF="$(mktemp "$TMPROOT/stage131-dump-XXXXXX")"
LOADF="$(mktemp "$TMPROOT/stage131-load-XXXXXX")"
trap 'rm -f "$NMF" "$DUMPF" "$LOADF"' EXIT
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
"$NM" -n --defined-only "$KC" >"$NMF" 2>&1
"$OTOOL" -l "$KC" >"$LOADF" 2>&1
SYMBOL_RE='^(__ZN23IO80211SkywalkInterface6enableEj|__ZN23IO80211SkywalkInterface7disableEj|__ZN23IO80211SkywalkInterface14enableDatapathEv|__ZN23IO80211SkywalkInterface15disableDatapathEv|__ZN23IO80211SkywalkInterface18isInterfaceEnabledEv|__ZN23IO80211SkywalkInterface18setInterfaceEnableEb|__ZN22IO80211MacAddressAgent18setInterfaceEnableEb|__ZN21IO80211InfraInterface18setInterfaceEnableEb)$'
FIRST_SYMBOL="$(python3 - "$NMF" "$SYMBOL_RE" <<'PY'
import pathlib,re,sys
found=[]
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]) and re.fullmatch(sys.argv[2],f[-1]):
  found.append((int(f[0],16),f[-1]))
if len(found)!=8:
 print("EXPECTED_METHODS=8 FOUND="+str(len(found)))
 raise SystemExit(2)
print(min(found)[1])
PY
)"
"$OTOOL" -arch x86_64 -tvV -p "$FIRST_SYMBOL" "$KC" >"$DUMPF" 2>&1
if ! grep -Fq "$FIRST_SYMBOL" "$DUMPF"; then echo "ERROR: exact-symbol disassembly did not include first symbol"; exit 7; fi

{
 echo "========== STAGE131 APPLE SKYWALK ENABLE / DISABLE DISPATCH AUDIT =========="
 echo "STAGE131_SOURCE_COMMIT=$SOURCE"
 echo "STAGE131_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE131_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE131_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE131_SCOPE=READ_ONLY_SKYWALK_ENABLE_DISABLE_AND_GLOBAL_DISPATCH_AUDIT"
 echo "STAGE131_KC_MACHO_SHA256=$KC_SHA"
 echo "STAGE131_KC_MACHO_PATH=$KC"
 echo "STAGE131_DUMP_START_SYMBOL=$FIRST_SYMBOL"
 echo "STAGE131_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE131_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 echo "--- Exact Apple Skywalk and related method bodies ---"
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
verified=0
for start,name in sorted(targets):
 following=[a for a,t,n in entries if a>start and t.upper()=="T"]
 stop=min(following) if following else start+0x600
 stop=min(stop,start+0x600)
 selected=[]
 for line in lines:
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if not m: continue
  a=int(m.group(1),16)
  if start<=a<stop: selected.append((a,line.strip(),m.group(2)))
 print("===== METHOD "+name+" =====")
 print("STAGE131_METHOD_START=0x"+format(start,"x"))
 print("STAGE131_METHOD_STOP=0x"+format(stop,"x"))
 if not selected or selected[0][0]!=start:
  print("STAGE131_METHOD_DISASSEMBLY=NOT_VERIFIED")
  print("STAGE131_METHOD_INSTRUCTION_COUNT=0")
  continue
 verified+=1
 print("STAGE131_METHOD_DISASSEMBLY=VERIFIED_EXACT_START_BOUNDED")
 print("STAGE131_METHOD_INSTRUCTION_COUNT="+str(len(selected)))
 for _,line,asm in selected: print(line)
print("STAGE131_METHOD_COUNT="+str(len(targets)))
print("STAGE131_METHOD_VERIFIED_COUNT="+str(verified))
if verified!=len(targets): print("STAGE131_METHODS=INCOMPLETE")
else: print("STAGE131_METHODS=ALL_VERIFIED")
PY
 echo
 echo "--- Resolve RIP-relative function-table globals used by enable/disable ---"
 python3 - "$DUMPF" "$NMF" "$LOADF" "$KC" <<'PY'
import pathlib,re,struct,sys
dump,nmfile,loadfile,macho=sys.argv[1:]
nm=[]; symbols={}
for line in pathlib.Path(nmfile).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]):
  try:
   a=int(f[0],16); nm.append((a,f[-2],f[-1])); symbols[f[-1]]=a
  except ValueError: pass
lines=pathlib.Path(dump).read_text(errors="replace").splitlines()
allins=[]
for i,line in enumerate(lines):
 m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
 if m: allins.append((int(m.group(1),16),m.group(2),line.strip()))
wanted={"__ZN23IO80211SkywalkInterface6enableEj":"ENABLE",
        "__ZN23IO80211SkywalkInterface7disableEj":"DISABLE"}
starts={n:a for a,t,n in nm if n in wanted}
found=[]
for idx,(addr,asm,line) in enumerate(allins):
 for name,label in wanted.items():
  start=starts.get(name)
  if start is None or not (start<=addr<start+0x80): continue
  m=re.search(r"\bmovq\s+(0x[0-9a-fA-F]+)\(%rip\),\s*%rax",asm)
  if not m: continue
  nxt=next((x[0] for x in allins[idx+1:] if x[0]>addr),None)
  if nxt is None: continue
  disp=int(m.group(1),16)
  target=nxt+disp
  found.append((label,addr,nxt,disp,target,line))
for label,site,nxt,disp,target,line in found:
 print("DISPATCH_METHOD="+label)
 print("DISPATCH_INSTRUCTION="+line)
 print("NEXT_INSTRUCTION=0x"+format(nxt,"x"))
 print("RIP_DISPLACEMENT=0x"+format(disp,"x"))
 print("FUNCTION_TABLE_GLOBAL=0x"+format(target,"x"))
 exact=[n for a,t,n in nm if a==target]
 prior=[(a,n) for a,t,n in nm if a<=target]
 print("GLOBAL_EXACT_SYMBOLS="+(",".join(exact) if exact else "NONE"))
 if prior:
  a,n=max(prior)
  print("GLOBAL_NEAREST_SYMBOL="+n+" ADDRESS=0x"+format(a,"x")+" DELTA=0x"+format(target-a,"x"))
 else: print("GLOBAL_NEAREST_SYMBOL=UNRESOLVED")
loadlines=pathlib.Path(loadfile).read_text(errors="replace").splitlines()
segments=[];sections=[];i=0
while i<len(loadlines):
 if loadlines[i].startswith("Load command"):
  block=[loadlines[i]]; i+=1
  while i<len(loadlines) and not loadlines[i].startswith("Load command"): block.append(loadlines[i]); i+=1
  fields={}
  for x in block:
   m=re.match(r"\s*(segname|vmaddr|vmsize|fileoff|filesize)\s+(\S+)",x)
   if m: fields[m.group(1)]=m.group(2)
  if all(k in fields for k in ("segname","vmaddr","vmsize","fileoff","filesize")):
   segments.append((fields["segname"],int(fields["vmaddr"],0),int(fields["vmsize"],0),int(fields["fileoff"],0),int(fields["filesize"],0)))
  for j,x in enumerate(block):
   if x.strip()=="Section":
    d={}
    for y in block[j+1:j+12]:
     m=re.match(r"\s*(sectname|segname|addr|size|offset)\s+(\S+)",y)
     if m:d[m.group(1)]=m.group(2)
    if all(k in d for k in ("sectname","segname","addr","size","offset")):
     sections.append((d["segname"],d["sectname"],int(d["addr"],0),int(d["size"],0),int(d["offset"],0)))
  continue
 i+=1
raw=pathlib.Path(macho).read_bytes()
def readq(v):
 for seg,sect,a,z,o in sections:
  if a<=v and v+8<=a+z and o+v-a+8<=len(raw):
   pos=o+v-a; return struct.unpack("<Q",raw[pos:pos+8])[0],seg,sect,pos
 return None
for label,site,nxt,disp,target,line in found:
 item=readq(target)
 print("GLOBAL="+label+"_0x"+format(target,"x"))
 if item:
  q,seg,sect,pos=item
  print("GLOBAL_STORAGE_SECTION="+seg+","+sect+" FILE_OFFSET=0x"+format(pos,"x"))
  print("GLOBAL_STORAGE_RAW_QWORD=0x"+format(q,"x"))
  for off in (0x860,0x868):
   qitem=readq(q+off) if q and q<0x0000800000000000 else None
   if qitem:
    val,s2,se2,p2=qitem
    print("GLOBAL_TABLE_SLOT_0x"+format(off,"x")+"=0x"+format(val,"x")+" STORAGE="+s2+","+se2+" FILE_OFFSET=0x"+format(p2,"x"))
   else:
    print("GLOBAL_TABLE_SLOT_0x"+format(off,"x")+"=NOT_READABLE_AS_CANONICAL_VIRTUAL_ADDRESS")
 else: print("GLOBAL_STORAGE=NOT_FILE_BACKED")
print("STAGE131_RIP_GLOBAL_REFERENCE_COUNT="+str(len(found)))
PY
 echo
 echo "--- Confirm no driver/runtime operation took place ---"
 echo "STAGE131_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE131_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE131_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE131 =========="
} >"$REPORT"
echo "===== STAGE131 SUMMARY ====="
grep -aE '^(STAGE131_|===== METHOD|STAGE131_METHOD_|DISPATCH_METHOD=|FUNCTION_TABLE_GLOBAL=|GLOBAL_|GLOBAL_TABLE_SLOT_|ERROR:)' "$REPORT" | tail -160 || true
echo "STAGE131_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage131-apple-skywalk-enable-dispatch-"+stamp+".log"
payload={"message":"Stage131: publish read-only Apple Skywalk enable/disable dispatch audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE131_UPLOAD=PASS"); print("STAGE131_UPLOAD_SHA="+actual); print("STAGE131_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE131_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE131_UPLOAD_SHA="+existing); print("STAGE131_GITHUB_PATH="+dest); break
  print("STAGE131_UPLOAD_DESTINATION_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE131_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE131_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
