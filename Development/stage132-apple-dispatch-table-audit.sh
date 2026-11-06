#!/bin/bash
# Stage132: read-only decode of Apple kernel-cache dispatch table and callback slots.
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
if [[ ! -x "$NM" || -z "$OTOOL" || ! -x "$OTOOL" ]]; then echo "ERROR: required tools missing"; exit 4; fi
KC="$(printenv STAGE132_KC_MACHO 2>/dev/null || true)"
if [[ -z "$KC" ]]; then KC="$(find "$HOME/Developer" -type f -path '*/kc-cache/com.apple.iokit.IO80211Family.macho' -print -quit 2>/dev/null || true)"; fi
if [[ -z "$KC" || ! -f "$KC" ]]; then echo "ERROR: Stage120 IO80211Family Mach-O not found; set STAGE132_KC_MACHO"; exit 5; fi
KC_SHA="$(shasum -a 256 "$KC" | awk '{print $1}')"
if [[ "$KC_SHA" != "$PIN" ]]; then echo "ERROR: Mach-O SHA mismatch EXPECTED=$PIN ACTUAL=$KC_SHA"; exit 6; fi
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
if [[ -z "$TMPROOT" ]]; then TMPROOT="/tmp"; fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$(mktemp "$TMPROOT/stage132-report-XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
SOURCE="$(git rev-parse HEAD 2>/dev/null || printf UNKNOWN)"
{
 echo "========== STAGE132 APPLE KERNEL-CACHE DISPATCH TABLE AUDIT =========="
 echo "STAGE132_SOURCE_COMMIT=$SOURCE"
 echo "STAGE132_EXECUTION_BRANCH=$BRANCH"
 echo "STAGE132_WORKTREE_STATUS_ENTRIES=$STATUS"
 echo "STAGE132_TARGET=$OSVER BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE132_SCOPE=READ_ONLY_KERNEL_CACHE_POINTER_DECODE_AND_CALLBACK_TABLE_LOOKUP"
 echo "STAGE132_KC_MACHO_SHA256=$KC_SHA"
 echo "STAGE132_KC_MACHO_PATH=$KC"
 echo "STAGE132_DRIVER_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE132_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo
 python3 - "$KC" "$OTOOL" "$NM" "$(printenv STAGE132_SEARCH_ROOT 2>/dev/null || dirname "$(dirname "$KC")")" <<'PY'
import os, pathlib, re, struct, subprocess, sys
kc,otool,nm,search_root=sys.argv[1:]
PIN="8e95c4ec87ed99e3732354f32ad9eed45b7607e7bc7034f32ff7437e0c6ec878"
VTS={
 "__ZTV23IO80211SkywalkInterface":("__ZN23IO80211SkywalkInterface13getAssocStateEv",0x22d5ef8),
 "__ZTV21IO80211InfraInterface":("__ZN21IO80211InfraInterface13getAssocStateEv",0x22e6b50),
}
GOT_VADDR=0xffffff80023bc108
ENABLE=0xffffff8002265946
DISABLE=0xffffff800226595c
SLOT_ENABLE=0x860
SLOT_DISABLE=0x868

def run(args):
    return subprocess.run(args,capture_output=True,text=True,errors="replace")
def parse_load(path):
    p=run([otool,"-l",str(path)])
    if p.returncode: return [],[],p.stderr or p.stdout
    lines=p.stdout.splitlines()
    segs=[]; sections=[]; i=0
    while i<len(lines):
        if lines[i].startswith("Load command"):
            block=[lines[i]]; i+=1
            while i<len(lines) and not lines[i].startswith("Load command"):
                block.append(lines[i]); i+=1
            fields={}
            for x in block:
                m=re.match(r"\s*(segname|vmaddr|vmsize|fileoff|filesize)\s+(\S+)",x)
                if m: fields[m.group(1)]=m.group(2)
            if all(k in fields for k in ("segname","vmaddr","vmsize","fileoff","filesize")):
                segs.append((fields["segname"],int(fields["vmaddr"],0),int(fields["vmsize"],0),int(fields["fileoff"],0),int(fields["filesize"],0)))
            for j,x in enumerate(block):
                if x.strip()=="Section":
                    d={}
                    for y in block[j+1:j+12]:
                        m=re.match(r"\s*(sectname|segname|addr|size|offset)\s+(\S+)",y)
                        if m: d[m.group(1)]=m.group(2)
                    if all(k in d for k in ("sectname","segname","addr","size","offset")):
                        sections.append((d["segname"],d["sectname"],int(d["addr"],0),int(d["size"],0),int(d["offset"],0)))
            continue
        i+=1
    return segs,sections,None

def fileoff_for(vaddr,nbytes,segs,sections):
    for seg,sect,a,z,o in sections:
        if a<=vaddr and vaddr+nbytes<=a+z:
            pos=o+(vaddr-a)
            return pos,seg,sect
    for seg,a,z,o,fs in segs:
        if a<=vaddr and vaddr+nbytes<=a+fs:
            pos=o+(vaddr-a)
            return pos,seg,"<segment>"
    return None

def read_qword(path,off):
    data=pathlib.Path(path).read_bytes()
    if off<0 or off+8>len(data): return None
    return struct.unpack_from("<Q",data,off)[0]

def decode(raw,base0):
    target=raw & ((1<<30)-1)
    level=(raw>>30)&3
    diversity=(raw>>32)&0xffff
    addrdiv=(raw>>48)&1
    key=(raw>>49)&3
    nxt=(raw>>51)&0xfff
    auth=(raw>>63)&1
    resolved=(base0+target) if level==0 and base0 is not None else None
    return target,level,diversity,addrdiv,key,nxt,auth,resolved

segs,sections,err=parse_load(kc)
if err: print("STAGE132_CURRENT_IMAGE_LOAD_COMMANDS=FAILED"); print(err); raise SystemExit(0)
textseg=next((x for x in segs if x[0]=="__TEXT"),None)
if textseg is None: print("STAGE132_TEXT_SEGMENT=NOT_FOUND"); raise SystemExit(0)
_,textvm,textsize,textfile,textfilesize=textseg
base0=textvm-textfile
print("STAGE132_KERNEL_CACHE_BASE_POINTER0=0x"+format(base0,"x"))
print("STAGE132_BASE_POINTER_METHOD=__TEXT_vmaddr_minus_fileoff")
print("STAGE132_POINTER_FORMAT_SOURCE=DYLD_CHAINED_PTR_X86_64_KERNEL_CACHE_OR_64_KERNEL_CACHE")
print("STAGE132_POINTER_LAYOUT=target30_cacheLevel2_diversity16_addrDiv1_key2_next12_isAuth1")
rawfile=pathlib.Path(kc).read_bytes()
for vt,(expected_symbol,legacy_off) in VTS.items():
    addr=next((a for s,sec,a,z,o in sections if s=="__DATA" and sec=="__const" and False),None)
    vaddr={"__ZTV23IO80211SkywalkInterface":0xffffff80023d5190,
           "__ZTV21IO80211InfraInterface":0xffffff80023e5de8}[vt]
    slot=vaddr+0x10+0xd58
    m=fileoff_for(slot,8,segs,sections)
    if m is None:
        print("STAGE132_VTABLE="+vt+" SLOT_STORAGE=NOT_MAPPED"); continue
    off,sg,sc=m
    word=struct.unpack_from("<Q",rawfile,off)[0]
    dec=decode(word,base0)
    print("STAGE132_VTABLE="+vt)
    print("  SLOT_FILE_OFFSET=0x"+format(off,"x")+" SECTION="+sg+","+sc)
    print("  SLOT_RAW_QWORD=0x"+format(word,"x"))
    print("  SLOT_TARGET30=0x"+format(dec[0],"x")+" CACHE_LEVEL="+str(dec[1])+" AUTH="+str(dec[6]))
    print("  SLOT_RESOLVED=0x"+format(dec[7],"x") if dec[7] is not None else "  SLOT_RESOLVED=UNRESOLVED")
    print("  SLOT_EXPECTED_SYMBOL="+expected_symbol+" EXPECTED_ADDRESS=0x"+format(next(a for a,t,n in []),"x") if False else "  SLOT_EXPECTED_SYMBOL="+expected_symbol)
    if dec[7] is not None:
        nmout=run([nm,"-n","--defined-only",kc])
        match=any(len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]) and int(f[0],16)==dec[7] and f[-1]==expected_symbol for f in (x.split() for x in nmout.stdout.splitlines()))
        print("  SLOT_EXACT_SYMBOL_VALIDATION="+("PASS" if match else "NOT_MATCHED_IN_CHILD_NM"))

got=fileoff_for(GOT_VADDR,8,segs,sections)
if got is None:
    print("STAGE132_GOT_STORAGE=NOT_MAPPED")
    raise SystemExit(0)
got_off,got_seg,got_sec=got
got_raw=struct.unpack_from("<Q",rawfile,got_off)[0]
got_dec=decode(got_raw,base0)
print("STAGE132_GOT_POINTER_VADDR=0x"+format(GOT_VADDR,"x"))
print("STAGE132_GOT_FILE_OFFSET=0x"+format(got_off,"x")+" SECTION="+got_seg+","+got_sec)
print("STAGE132_GOT_RAW_QWORD=0x"+format(got_raw,"x"))
print("STAGE132_GOT_TARGET30=0x"+format(got_dec[0],"x"))
print("STAGE132_GOT_CACHE_LEVEL="+str(got_dec[1]))
print("STAGE132_GOT_DIVERSITY=0x"+format(got_dec[2],"x")+" ADDRDIV="+str(got_dec[3])+" KEY="+str(got_dec[4])+" NEXT="+str(got_dec[5])+" AUTH="+str(got_dec[6]))
if got_dec[7] is None:
    print("STAGE132_DISPATCH_TABLE_ADDRESS=UNRESOLVED_CACHE_LEVEL")
    raise SystemExit(0)
table=got_dec[7]
print("STAGE132_DISPATCH_TABLE_ADDRESS=0x"+format(table,"x"))
print("STAGE132_ENABLE_TABLE_SLOT_VADDR=0x"+format(table+SLOT_ENABLE,"x"))
print("STAGE132_DISABLE_TABLE_SLOT_VADDR=0x"+format(table+SLOT_DISABLE,"x"))

# Find a Mach-O image in the extracted kernel-cache run that maps the resolved table.
candidates=[]
roots=[search_root]
seen=set()
for root in roots:
    if not os.path.isdir(root): continue
    root_depth=root.rstrip(os.sep).count(os.sep)
    for cur,dirs,files in os.walk(root):
        depth=cur.count(os.sep)-root_depth
        if depth>=5: dirs[:]=[]
        for name in files:
            p=os.path.join(cur,name)
            if p in seen: continue
            seen.add(p)
            try:
                st=os.stat(p)
                if st.st_size<4096 or st.st_size>2_000_000_000: continue
                with open(p,"rb") as f: magic=f.read(4)
            except OSError: continue
            if magic in (b"\xcf\xfa\xed\xfe",b"\xfe\xed\xfa\xcf",b"\xce\xfa\xed\xfe",b"\xfe\xed\xfa\xce",
                         b"\xca\xfe\xba\xbe",b"\xbe\xba\xfe\xca",b"\xca\xfe\xba\xbf",b"\xbf\xba\xfe\xca") or p.endswith(".macho"):
                candidates.append(p)
                if len(candidates)>=1500: break
        if len(candidates)>=1500: break
    if len(candidates)>=1500: break
print("STAGE132_SEARCH_ROOT="+search_root)
print("STAGE132_MACHO_CANDIDATE_COUNT="+str(len(candidates)))
matches=[]
for p in candidates:
    sg,sc,e=parse_load(p)
    if e: continue
    span=table+SLOT_DISABLE+8
    hit=[]
    for seg,a,z,o,fs in sg:
        if a<=table and span<=a+fs:
            hit.append((seg,a,z,o,fs))
    if hit:
        matches.append((p,sg,sc,hit))
print("STAGE132_TABLE_STORAGE_IMAGE_MATCH_COUNT="+str(len(matches)))
slot_targets=[]
for p,sg,sc,hit in matches:
    print("STAGE132_TABLE_OWNER_IMAGE="+p)
    for seg,a,z,o,fs in hit:
        off=o+(table-a)
        qenable=read_qword(p,off+SLOT_ENABLE)
        qdisable=read_qword(p,off+SLOT_DISABLE)
        print("  TABLE_SEGMENT="+seg+" VMADDR=0x"+format(a,"x")+" FILEOFF=0x"+format(o,"x"))
        print("  ENABLE_SLOT_FILE_OFFSET=0x"+format(off+SLOT_ENABLE,"x")+" RAW=0x"+format(qenable,"x"))
        print("  DISABLE_SLOT_FILE_OFFSET=0x"+format(off+SLOT_DISABLE,"x")+" RAW=0x"+format(qdisable,"x"))
        for label,q in (("ENABLE",qenable),("DISABLE",qdisable)):
            d=decode(q,base0)
            resolved=d[7]
            print("  "+label+"_SLOT_TARGET30=0x"+format(d[0],"x")+" CACHE_LEVEL="+str(d[1])+" AUTH="+str(d[6]))
            if resolved is None:
                print("  "+label+"_CALLBACK_ADDRESS=UNRESOLVED_CACHE_LEVEL")
                continue
            print("  "+label+"_CALLBACK_ADDRESS=0x"+format(resolved,"x"))
            slot_targets.append((label,resolved))
        nmo=run([nm,"-n","--defined-only",p])
        textsyms=[]
        for line in nmo.stdout.splitlines():
            f=line.split()
            if len(f)>=3 and re.fullmatch(r"[0-9a-fA-F]+",f[0]):
                try: textsyms.append((int(f[0],16),f[-2],f[-1]))
                except ValueError: pass
        for label,target in slot_targets[-2:]:
            ex=[n for a,t,n in textsyms if a==target]
            prior=[(a,n) for a,t,n in textsyms if t.upper()=="T" and a<=target]
            print("  "+label+"_EXACT_SYMBOL="+(",".join(ex) if ex else "NONE_IN_OWNER_IMAGE"))
            if prior:
                a,n=max(prior)
                print("  "+label+"_NEAREST_OWNER_TEXT_SYMBOL="+n+" ADDRESS=0x"+format(a,"x")+" DELTA=0x"+format(target-a,"x"))

if not matches:
    print("STAGE132_TABLE_OWNER_IMAGE=NOT_FOUND_IN_SEARCH_ROOT")
    print("STAGE132_NEXT_REQUIREMENT=LOCATE_PARENT_KERNEL_COLLECTION_OR_FULL_KC_IMAGE")
print("STAGE132_POINTER_DECODING=KERNEL_CACHE_TARGET_PLUS_BASE_POINTER0_WHEN_CACHE_LEVEL_0")
print("STAGE132_DRIVER_SOURCE_MODIFIED=NO")
PY
 echo
 echo "STAGE132_DRIVER_SOURCE_MODIFIED=NO"
 echo "STAGE132_BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE132_HARDWARE_ACTIVATION=NOT_RUN OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN"
 echo "========== END STAGE132 =========="
} >"$REPORT"
echo "===== STAGE132 SUMMARY ====="
grep -aE '^(STAGE132_|  (SLOT_|GOT_|TABLE_|ENABLE_|DISABLE_|LOW|DECODED|TARGET))' "$REPORT" | tail -200 || true
echo "STAGE132_LOCAL_REPORT=$REPORT"
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]); stamp,repo=sys.argv[2:]
data=report.read_bytes(); dest="Development/Logs/stage132-apple-dispatch-table-"+stamp+".log"
payload={"message":"Stage132: publish read-only Apple kernel-cache dispatch table audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
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
   print("STAGE132_UPLOAD=PASS"); print("STAGE132_UPLOAD_SHA="+actual); print("STAGE132_GITHUB_PATH="+dest); break
  last="GitHub SHA mismatch "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE132_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT"); print("STAGE132_UPLOAD_SHA="+existing); print("STAGE132_GITHUB_PATH="+dest); break
  print("STAGE132_UPLOAD_CONFLICT="+str(existing)); raise SystemExit(8)
 print("STAGE132_UPLOAD_ATTEMPT_"+str(attempt)+"=FAILED")
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE132_UPLOAD=FAILED"); print(last); raise SystemExit(9)
PY
