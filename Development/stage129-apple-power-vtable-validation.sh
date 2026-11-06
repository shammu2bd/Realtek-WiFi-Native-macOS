#!/bin/bash
# Stage129: read-only exact kernel-cache vtable pointer mapping and full symbolized call-site validation.
set -uo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
PIN="8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878"
INFRA="__ZN21IO80211InfraInterface18setInterfaceEnableEb"
SKYWALK="__ZN23IO80211SkywalkInterface18setInterfaceEnableEb"
KNOWN_CALLSITE="ffffff80022dc483"
KNOWN_TARGET="ffffff8002265a04"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -n "$ROOT" ]] || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT" || exit 2
BRANCH="$(git branch --show-current 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || BRANCH="DETACHED_OR_UNKNOWN"
STATUS="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
TARGET_OS="$(sw_vers -productVersion 2>/dev/null || true)"
BUILD="$(sw_vers -buildVersion 2>/dev/null || true)"
ARCH="$(uname -m)"
[[ "$TARGET_OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || {
 echo "ERROR: expected 15.8.1 24H32 x86_64; found $TARGET_OS $BUILD $ARCH"; exit 3; }
TC="/Applications/Xcode_16.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
NM="$TC/llvm-nm"; OTOOL="$(command -v otool 2>/dev/null || true)"
[[ -x "$NM" && -n "$OTOOL" && -x "$OTOOL" ]] || { echo "ERROR: required tools missing"; exit 4; }
KC="$(printenv STAGE129_KC_MACHO 2>/dev/null || true)"
if [[ -z "$KC" ]]; then KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"; fi
[[ -n "$KC" && -f "$KC" ]] || { echo "ERROR: pinned Stage120 Mach-O not found; set STAGE129_KC_MACHO"; exit 5; }
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
[[ "$KC_SHA" == "$PIN" ]] || { echo "ERROR: Mach-O SHA mismatch EXPECTED=$PIN ACTUAL=$KC_SHA"; exit 6; }
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp "$TMPROOT/stage129-report-XXXXXX")" || exit 7
NMF="$(mktemp "$TMPROOT/stage129-nm-XXXXXX")" || exit 7
LOADF="$(mktemp "$TMPROOT/stage129-load-XXXXXX")" || exit 7
DUMPF="$(mktemp "$TMPROOT/stage129-text-XXXXXX")" || exit 7
trap 'rm -f "$NMF" "$LOADF" "$DUMPF"' EXIT
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
"$NM" -n --defined-only "$KC" >"$NMF" 2>&1 || { echo "ERROR: llvm-nm failed"; exit 8; }
"$OTOOL" -l "$KC" >"$LOADF" 2>&1 || { echo "ERROR: otool -l failed"; exit 9; }
# -V requests symbolic operand resolution, unlike Stage128's non-symbolized -tv run.
if "$OTOOL" -arch x86_64 -tvV "$KC" >"$DUMPF" 2>&1; then DUMPRC=0; else DUMPRC=$?; fi
[[ "$DUMPRC" -eq 0 ]] || { echo "ERROR: full symbolized text disassembly failed RC=$DUMPRC"; sed -n '1,35p' "$DUMPF"; exit 10; }

{
 echo "========== STAGE129 APPLE POWER VTABLE POINTER / CALLSITE VALIDATION =========="
 echo "STAGE129_SOURCE_COMMIT=$SOURCE"
 echo "STAGE129_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE129_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE129_TARGET=$TARGET_OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE129_SCOPE=READ_ONLY_EXACT_VTABLE_POINTER_MAPPING_AND_FULL_SYMBOLIZED_CALLSITE_VALIDATION"
 echo "STAGE129_KC_MACHO_SHA256=$KC_SHA"
 echo "STAGE129_KC_MACHO_PATH=$KC"
 echo "STAGE129_OTOOL_FULL_TEXT_SYMBOLIC_EXIT_CODE=$DUMPRC"
 echo "STAGE129_KNOWN_STAGE126_CALLSITE=0x$KNOWN_CALLSITE"
 echo "STAGE129_KNOWN_STAGE126_DIRECT_TARGET=0x$KNOWN_TARGET"
 echo "STAGE129_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE129_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 echo "--- Derive __TEXT VM/file mapping and exact class vtable slot targets ---"
 python3 - "$NMF" "$LOADF" "$KC" <<'PY'
import pathlib,re,struct,sys
nmfile,loadfile,macho=sys.argv[1:]
wanted={"__ZTV23IO80211SkywalkInterface","__ZTV21IO80211InfraInterface"}
vts=[]; texts=[]
for line in pathlib.Path(nmfile).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)<3 or not re.fullmatch(r"[0-9a-fA-F]+",f[0]): continue
 a=int(f[0],16); typ=f[-2]; name=f[-1]
 if typ.upper()=="T": texts.append((a,name))
 if name in wanted: vts.append((a,typ,name))
lines=pathlib.Path(loadfile).read_text(errors="replace").splitlines()
segments=[]; sections=[]; i=0
while i<len(lines):
 if lines[i].startswith("Load command"):
  block=[lines[i]]; i+=1
  while i<len(lines) and not lines[i].startswith("Load command"): block.append(lines[i]); i+=1
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
textseg=next((s for s in segments if s[0]=="__TEXT"),None)
if textseg is None: print("STAGE129_TEXT_SEGMENT=NOT_FOUND"); raise SystemExit(0)
_,text_vm,text_vmsize,text_file,text_filesize=textseg
print("STAGE129_TEXT_VMADDR=0x"+format(text_vm,"x"))
print("STAGE129_TEXT_FILEOFF=0x"+format(text_file,"x"))
print("STAGE129_TEXT_VMSIZE=0x"+format(text_vmsize,"x"))
print("STAGE129_TEXT_FILESIZE=0x"+format(text_filesize,"x"))
raw=pathlib.Path(macho).read_bytes()
def getq(addr):
 for seg,sect,a,z,o in sections:
  if a<=addr and addr+8<=a+z and o+addr-a+8<=len(raw):
   pos=o+addr-a; return struct.unpack("<Q",raw[pos:pos+8])[0],seg,sect,pos
 return None
def find_symbol(addr):
 exact=[n for a,n in texts if a==addr]
 prior=[(a,n) for a,n in texts if a<=addr]
 nearest=max(prior) if prior else None
 return exact,nearest
for vaddr,typ,name in sorted(vts):
 slot=vaddr+0x10+0xD58
 print("VTABLE="+name+" TYPE="+typ+" SYMBOL_ADDRESS=0x"+format(vaddr,"x"))
 print("  ADDRESS_POINT=0x"+format(vaddr+0x10,"x")+" SLOT_VIRTUAL_ADDRESS=0x"+format(slot,"x"))
 q=getq(slot)
 if q is None: print("  SLOT_STATUS=UNREADABLE"); continue
 word,seg,sect,pos=q
 print("  SLOT_SECTION="+seg+","+sect+" FILE_OFFSET=0x"+format(pos,"x"))
 print("  SLOT_RAW_QWORD=0x"+format(word,"x"))
 # The low 30 bits of the kernel-cache pointer are treated as a Mach-O file offset
 # only as a testable hypothesis; require mapping into __TEXT and an exact T symbol.
 encoded=word & 0x3fffffff
 print("  LOW30_ENCODED_VALUE=0x"+format(encoded,"x"))
 delta=encoded-text_file
 print("  FILEOFF_DELTA_FROM_TEXT=0x"+format(delta,"x"))
 if delta<0 or delta>=text_filesize:
  print("  TEXT_FILEOFF_MAPPING=OUTSIDE_TEXT_FILE_RANGE"); continue
 target=text_vm+delta
 print("  DECODED_TARGET_CANDIDATE=0x"+format(target,"x"))
 print("  TARGET_IN_TEXT_VM_RANGE="+("YES" if text_vm<=target<text_vm+text_vmsize else "NO"))
 exact,near=find_symbol(target)
 if exact:
  print("  TARGET_EXACT_TEXT_SYMBOLS="+",".join(exact))
  print("  TARGET_MAPPING_VALIDATION=EXACT_TEXT_SYMBOL_MATCH")
 else:
  print("  TARGET_EXACT_TEXT_SYMBOLS=NONE")
  if near:
   a,n=near; print("  TARGET_NEAREST_TEXT_SYMBOL="+n+" ADDRESS=0x"+format(a,"x")+" DELTA=0x"+format(target-a,"x"))
  print("  TARGET_MAPPING_VALIDATION=NOT_EXACT")
print("STAGE129_VTABLE_SYMBOL_COUNT="+str(len(vts)))
PY
 echo
 echo "--- Full-image direct call-site search (symbol or numeric target) ---"
 python3 - "$DUMPF" "$NMF" "$INFRA" "$SKYWALK" "$KNOWN_CALLSITE" "$KNOWN_TARGET" <<'PY'
import pathlib,re,sys
dump,nmpath,infra,sky,known_callsite,known_target=sys.argv[1:]
nm={}
for line in pathlib.Path(nmpath).read_text(errors="replace").splitlines():
 f=line.split()
 if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]): nm[f[-1]]=int(f[0],16)
targets={infra:"INFRA",sky:"SKYWALK"}
hits={k:[] for k in targets}; current="UNKNOWN_FUNCTION"
known=False
for line in pathlib.Path(dump).read_text(errors="replace").splitlines():
 s=line.strip()
 if s.endswith(":") and not re.match(r"^(?:0x)?[0-9a-fA-F]{8,}:?$",s): current=s[:-1]
 m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):\s*(.*)$",line)
 if not m: continue
 site=int(m.group(1),16); asm=m.group(2)
 if site==int(known_callsite,16) and (sky in asm or re.search(r"(?:0x)?"+known_target,asm,re.I)):
  known=True; print("STAGE129_KNOWN_STAGE126_CALLSITE=FOUND"); print("KNOWN_CALLER="+current); print("  "+line.strip())
 if not re.search(r"\bcall(?:q|l)?\b",asm): continue
 am=re.search(r"\bcall(?:q|l)?\s+\*?(?:0x)?([0-9a-fA-F]{8,})",asm)
 numeric=int(am.group(1),16) if am else None
 for name,label in targets.items():
  if name in asm or (numeric is not None and numeric==nm.get(name)):
   hits[name].append((current,site,line.strip()))
print("STAGE129_KNOWN_STAGE126_CALLSITE_STATUS="+("PASS" if known else "NOT_FOUND"))
for name,label in targets.items():
 print("STAGE129_"+label+"_DIRECT_CALL_COUNT="+str(len(hits[name])))
 for fn,site,line in hits[name][:120]:
  print("CALLER="+fn+" CALLSITE=0x"+format(site,"x")); print("  "+line)
 if not hits[name]: print("STAGE129_"+label+"_DIRECT_CALLS=NONE_FOUND_IN_FULL_SYMBOLIZED_TEXT")
PY
 echo
 echo "--- Exact setter symbol references in the disassembly ---"
 grep -nF "$INFRA" "$DUMPF" | head -30 || true
 grep -nF "$SKYWALK" "$DUMPF" | head -30 || true
 echo
 echo "STAGE129_VTABLE_SLOT_BYTE_OFFSET=0xD58"
 echo "STAGE129_VTABLE_SLOT_INDEX=427"
 echo "STAGE129_POINTER_HYPOTHESIS=LOW30_VALUE_AS_MACHO_FILE_OFFSET_REBASED_THROUGH_TEXT_SEGMENT"
 echo "STAGE129_POWER_CALL_GRAPH=REVIEW_REQUIRED"
 echo "STAGE129_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE129_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE129_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE129 =========="
} >"$REPORT"

echo "===== STAGE129 SUMMARY ====="
grep -aE '^(STAGE129_|VTABLE=|  (ADDRESS|SLOT|LOW30|FILEOFF|DECODED|TARGET_|KNOWN_|CALLER=))' "$REPORT" | tail -180 || true
echo "STAGE129_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage129-apple-power-vtable-validation-"+stamp+".log"
payload={"message":"Stage129: publish read-only Apple 24H32 vtable pointer and full call-site validation","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE129_UPLOAD=PASS"); print("STAGE129_UPLOAD_SHA="+actual); print("STAGE129_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else: last=r.stderr.strip() or r.stdout.strip()
 check=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if check.returncode==0:
  try: existing=json.loads(check.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE129_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE129_UPLOAD_SHA="+existing); print("STAGE129_GITHUB_PATH="+dest); break
  print("STAGE129_UPLOAD_DESTINATION_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE129_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE129_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
