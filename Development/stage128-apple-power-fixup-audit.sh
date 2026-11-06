#!/bin/bash
# Stage128: read-only full-text setter caller and kernel-cache vtable fixup audit.
set -uo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PIN="8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878"
INFRA="__ZN21IO80211InfraInterface18setInterfaceEnableEb"
SKYWALK="__ZN23IO80211SkywalkInterface18setInterfaceEnableEb"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$ROOT" ]] || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT" || exit 2
BRANCH="$(git branch --show-current 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || BRANCH="DETACHED_OR_UNKNOWN"
STATUS="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
TARGET="$(sw_vers -productVersion 2>/dev/null || true)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || true)"
ARCH="$(uname -m)"
[[ "$TARGET" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
 echo "ERROR: expected 15.8.1 24H32 x86_64; found $TARGET $BUILD $ARCH"; exit 3; }
TC="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
NM="$TC/llvm-nm"; OTOOL="$(command -v otool 2>/dev/null || true)"
[[ -x "$NM" && -n "$OTOOL" && -x "$OTOOL" ]] || { echo "ERROR: required tools missing"; exit 4; }
KC="$(printenv STAGE128_KC_MACHO 2>/dev/null || true)"
if [[ -z "$KC" ]]; then KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"; fi
[[ -n "$KC" && -f "$KC" ]] || { echo "ERROR: pinned Stage120 Mach-O not found; set STAGE128_KC_MACHO"; exit 5; }
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
[[ "$KC_SHA" == "$PIN" ]] || { echo "ERROR: Mach-O SHA mismatch"; echo "EXPECTED=$PIN ACTUAL=$KC_SHA"; exit 6; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="$(printenv TMPDIR 2>/dev/null || printf /tmp)"
REPORT="$(mktemp "$TMPROOT/stage128-report-XXXXXX")" || exit 7
NMF="$(mktemp "$TMPROOT/stage128-nm-XXXXXX")" || exit 7
LOADF="$(mktemp "$TMPROOT/stage128-load-XXXXXX")" || exit 7
DUMPF="$(mktemp "$TMPROOT/stage128-text-XXXXXX")" || exit 7
FIXF="$(mktemp "$TMPROOT/stage128-fix-XXXXXX")" || exit 7
RELOCF="$(mktemp "$TMPROOT/stage128-reloc-XXXXXX")" || exit 7
trap 'rm -f "$NMF" "$LOADF" "$DUMPF" "$FIXF" "$RELOCF"' EXIT
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
"$NM" -n --defined-only "$KC" >"$NMF" 2>&1 || { echo "ERROR: llvm-nm failed"; exit 8; }
"$OTOOL" -l "$KC" >"$LOADF" 2>&1 || { echo "ERROR: otool -l failed"; exit 9; }
if "$OTOOL" -arch x86_64 -tv "$KC" >"$DUMPF" 2>&1; then DUMPRC=0; else DUMPRC=$?; fi
[[ "$DUMPRC" -eq 0 ]] || { echo "ERROR: full text disassembly failed RC=$DUMPRC"; sed -n '1,30p' "$DUMPF"; exit 10; }
DYLD_INFO="$(command -v dyld_info 2>/dev/null || true)"
if [[ -n "$DYLD_INFO" && -x "$DYLD_INFO" ]]; then
 if "$DYLD_INFO" -fixups -arch x86_64 "$KC" >"$FIXF" 2>&1; then FIXRC=0; else FIXRC=$?; fi
else
 FIXRC="NOT_AVAILABLE"; echo "dyld_info unavailable on PATH" >"$FIXF"
fi
if "$OTOOL" -r -v "$KC" >"$RELOCF" 2>&1; then RELRC=0; else RELRC=$?; fi

{
 echo "========== STAGE128 APPLE POWER CALLSITE / VTABLE FIXUP AUDIT =========="
 echo "STAGE128_SOURCE_COMMIT=$SOURCE"
 echo "STAGE128_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE128_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE128_TARGET=$TARGET BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE128_SCOPE=READ_ONLY_FULL_TEXT_CALLSITE_AND_KERNELCACHE_VTABLE_FIXUP_AUDIT"
 echo "STAGE128_KC_MACHO_SHA256=$KC_SHA"
 echo "STAGE128_KC_MACHO_PATH=$KC"
 echo "STAGE128_FULL_TEXT_OTOOL_EXIT_CODE=$DUMPRC"
 echo "STAGE128_DYLD_INFO_PATH=$DYLD_INFO"
 echo "STAGE128_DYLD_INFO_FIXUPS_EXIT_CODE=$FIXRC"
 echo "STAGE128_OTOOL_RELOCATIONS_EXIT_CODE=$RELRC"
 echo "STAGE128_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE128_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 echo "--- Direct setter callers across full Apple text ---"
 python3 - "$DUMPF" "$NMF" "$INFRA" "$SKYWALK" <<'PY'
import pathlib,re,sys
dump,nmpath,infra,sky=sys.argv[1:]
nm={}
for line in pathlib.Path(nmpath).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]): nm[f[-1]]=int(f[0],16)
hits={infra:[],sky:[]}; current="UNKNOWN_FUNCTION"
for line in pathlib.Path(dump).read_text(errors="replace").splitlines():
 s=line.strip()
 if s.endswith(":") and not re.match(r"^(?:0x)?[0-9a-fA-F]{8,}:?$",s): current=s[:-1]
 m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):\s*(.*)$",line)
 if not m: continue
 address=int(m.group(1),16); asm=m.group(2)
 if not re.search(r"\bcallq?\b",asm): continue
 am=re.search(r"\bcallq?\s+(?:0x)?([0-9a-fA-F]{8,})",asm)
 target=int(am.group(1),16) if am else None
 for name in hits:
  if name in asm or (target is not None and target==nm.get(name)): hits[name].append((current,address,line.strip()))
for name,label in ((infra,"INFRA_SETTER"),(sky,"SKYWALK_SETTER")):
 print("STAGE128_"+label+"_DIRECT_CALL_COUNT="+str(len(hits[name])))
 for fn,address,line in hits[name][:100]:
  print("CALLER="+fn+" CALLSITE=0x"+format(address,"x")); print("  "+line)
 if not hits[name]: print("STAGE128_"+label+"_DIRECT_CALLS=NONE_FOUND_IN_FULL_TEXT")
PY
 echo
 echo "--- Exact vtable symbols (MetaClass entries excluded) ---"
 grep -E ' __ZTV(23IO80211SkywalkInterface|21IO80211InfraInterface)$' "$NMF" || true
 echo
 echo "--- Relevant load commands ---"
 grep -E 'cmd LC_(DYLD_CHAINED_FIXUPS|DYLD_INFO|DYLD_INFO_ONLY|SEGMENT_64|FILESET_ENTRY)|segname __TEXT|segname __TEXT_EXEC|vmaddr |vmsize |fileoff |filesize ' "$LOADF" | sed -n '1,140p' || true
 echo
 echo "--- Vtable slot pointer and candidate normalization ---"
 python3 - "$NMF" "$LOADF" "$KC" <<'PY'
import pathlib,re,struct,sys
nmfile,loadfile,macho=sys.argv[1:]
want={"__ZTV23IO80211SkywalkInterface","__ZTV21IO80211InfraInterface"}
vt=[]; ts=[]
for line in pathlib.Path(nmfile).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)<3 or not re.fullmatch(r"[0-9a-fA-F]+",f[0]): continue
 a=int(f[0],16); typ=f[-2]; name=f[-1]
 if typ.upper()=="T": ts.append((a,name))
 if name in want: vt.append((a,typ,name))
ll=pathlib.Path(loadfile).read_text(errors="replace").splitlines()
sections=[]; segments=[]; i=0
while i<len(ll):
 if ll[i].startswith("Load command"):
  block=[ll[i]]; i+=1
  while i<len(ll) and not ll[i].startswith("Load command"): block.append(ll[i]); i+=1
  fields={}
  for x in block:
   m=re.match(r"\s*(segname|vmaddr|vmsize|fileoff|filesize)\s+(\S+)",x)
   if m: fields[m.group(1)]=m.group(2)
  if all(k in fields for k in ("segname","vmaddr","vmsize")):
   segments.append((fields["segname"],int(fields["vmaddr"],0),int(fields["vmsize"],0)))
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
bases=[a for n,a,z in segments if n=="__TEXT"]
base=min(bases) if bases else None
def readq(v):
 for seg,sect,a,z,o in sections:
  if a<=v and v+8<=a+z and o+v-a+8<=len(raw):
   pos=o+v-a
   return struct.unpack("<Q",raw[pos:pos+8])[0],seg,sect,pos
 return None
for a,typ,name in sorted(vt):
 slot=a+0x10+0xD58
 print("VTABLE="+name+" TYPE="+typ+" ADDRESS=0x"+format(a,"x"))
 print("  ADDRESS_POINT=0x"+format(a+0x10,"x")+" SLOT_ADDRESS=0x"+format(slot,"x"))
 item=readq(slot)
 if item is None: print("  SLOT_STATUS=UNREADABLE"); continue
 w,seg,sect,pos=item
 print("  SLOT_SECTION="+seg+","+sect+" FILE_OFFSET=0x"+format(pos,"x"))
 print("  RAW_QWORD=0x"+format(w,"x"))
 for label,off in (("LOW30",w&0x3fffffff),("LOW32",w&0xffffffff),("LOW48",w&0xffffffffffff)):
  print("  "+label+"_OFFSET=0x"+format(off,"x"))
  if base is None: print("  "+label+"_STATUS=TEXT_BASE_UNKNOWN"); continue
  cand=base+off
  intext=any(n in ("__TEXT","__TEXT_EXEC") and x<=cand<x+z for n,x,z in segments)
  print("  "+label+"_REBASED=0x"+format(cand,"x")+" IN_TEXT="+("YES" if intext else "NO"))
  prior=[(x,n) for x,n in ts if x<=cand]
  if prior:
   x,n=max(prior); delta=cand-x
   print("  "+label+"_NEAREST_SYMBOL="+n+" ADDRESS=0x"+format(x,"x")+" DELTA=0x"+format(delta,"x"))
  else: print("  "+label+"_NEAREST_SYMBOL=UNRESOLVED")
 print("  DECODE_STATUS=CANDIDATE_ONLY_FIXUP_FORMAT_NOT_ASSUMED")
print("STAGE128_TEXT_BASE="+("0x"+format(base,"x") if base is not None else "UNKNOWN"))
print("STAGE128_EXACT_VTABLE_COUNT="+str(len(vt)))
PY
 echo
 echo "--- dyld_info fixup excerpts ---"
 grep -Ei 'chained|fixup|__const|0x0*23d5|0x0*23e6|0x0*21658|0x0*21dc' "$FIXF" | sed -n '1,100p' || true
 echo
 echo "--- relocation excerpts ---"
 grep -Ei '0x0*23d5|0x0*23e6|0x0*21658|0x0*21dc|relocat|scattered' "$RELOCF" | sed -n '1,100p' || true
 echo
 echo "STAGE128_VTABLE_SLOT_BYTE_OFFSET=0xD58"
 echo "STAGE128_VTABLE_SLOT_INDEX=427"
 echo "STAGE128_POINTER_DECODE_POLICY=RAW_AND_CANDIDATE_MASKS_ONLY"
 echo "STAGE128_POWER_CALL_GRAPH=REVIEW_REQUIRED"
 echo "STAGE128_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE128_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE128_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE128 =========="
} >"$REPORT"

echo "===== STAGE128 SUMMARY ====="
grep -aE '^(STAGE128_|VTABLE=|  (ADDRESS|SLOT|RAW|LOW[0-9]+_|CALLER=|  callq))' "$REPORT" | tail -180 || true
echo "STAGE128_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage128-apple-power-fixups-"+stamp+".log"
payload={"message":"Stage128: publish read-only Apple 24H32 full-text call-site and vtable fixup audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE128_UPLOAD=PASS"); print("STAGE128_UPLOAD_SHA="+actual); print("STAGE128_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if check.returncode==0:
  try: existing=json.loads(check.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE128_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE128_UPLOAD_SHA="+existing); print("STAGE128_GITHUB_PATH="+dest); break
  print("STAGE128_UPLOAD_DESTINATION_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE128_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE128_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
