#!/bin/bash
# Stage 52 — IOKit personality, class-registration and provider-contract audit.
# VERSION_MARKER: STAGE52_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE52_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage52/$RUN"
mkdir -p "$OUT"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE52_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -50 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum grep awk sw_vers uname wc; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"
done
[[ -f "$SRC/Makefile" ]] || fail "Stage26 source tree not found: $SRC"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated"
OSVER="$(sw_vers -productVersion)"
BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
[[ "$OSVER" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || fail "expected macOS 15.8.1/24H32/x86_64; got $OSVER/$BUILD/$ARCH"

EXPECTED_CPP="2a6da4ac698635e2bfe904a23004536478d60cad99718ec3d7186e9be68cfc9b"
EXPECTED_ABI="63a6a038ef7513312c686199b00e8cf45a16d251c7792ab03d2f5986f9fd84fb"
EXPECTED_HPP="9b1181fd35990cebc128228503bc671a60a680815a698c79121ac9bdcf23cfc4"

python3 - "$SRC" "$OUT" "$EXPECTED_CPP" "$EXPECTED_ABI" "$EXPECTED_HPP" <<'PY'
import hashlib,pathlib,re,sys,plistlib

src,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
expected=dict(zip([
 "src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
 "src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
 "src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"
],sys.argv[3:6]))
fp=[]
for rel,want in expected.items():
    p=src/rel
    got=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "MISSING"
    fp += ["FILE="+rel,"EXPECTED_SHA256="+want,"ACTUAL_SHA256="+got,
           "RESULT="+("MATCH" if got==want else "MISMATCH")]
continuity=all(x=="RESULT=MATCH" for x in fp if x.startswith("RESULT="))
(out/"source-fingerprint.txt").write_text(
    "\n".join(fp)+"\nSTAGE43_SOURCE_CONTINUITY="+("PASS" if continuity else "REVIEW_REQUIRED")+"\n"
)
if not continuity:
    raise SystemExit("Stage43 source fingerprint mismatch; stop and review")

def mask_cpp(text):
    chars=list(text); i=0; state="code"
    while i<len(chars):
        c=chars[i]; n=chars[i+1] if i+1<len(chars) else ""
        if state=="code":
            if c=="/" and n=="/":
                chars[i]=chars[i+1]=" "; i+=2; state="line"; continue
            if c=="/" and n=="*":
                chars[i]=chars[i+1]=" "; i+=2; state="block"; continue
            if c=='"': chars[i]=" "; i+=1; state="string"; continue
            if c=="'": chars[i]=" "; i+=1; state="char"; continue
            i+=1; continue
        if state=="line":
            if c=="\n": state="code"
            else: chars[i]=" "
            i+=1; continue
        if state=="block":
            if c=="*" and n=="/":
                chars[i]=chars[i+1]=" "; i+=2; state="code"; continue
            if c!="\n": chars[i]=" "
            i+=1; continue
        if state in ("string","char"):
            end='"' if state=="string" else "'"
            if c=="\\":
                chars[i]=" "
                if i+1<len(chars):
                    if chars[i+1]!="\n": chars[i+1]=" "
                    i+=2
                else: i+=1
                continue
            if c==end: chars[i]=" "; i+=1; state="code"; continue
            if c!="\n": chars[i]=" "
            i+=1
    return "".join(chars)

source_files=[]
for p in sorted((src/"src").rglob("*")):
    if p.is_file() and p.suffix.lower() in (".cpp",".hpp",".h",".c"):
        if any(x in ("build","DerivedData",".git") for x in p.parts): continue
        source_files.append(p)
raw={}; masked={}
for p in source_files:
    try: raw[p]=p.read_text(errors="replace"); masked[p]=mask_cpp(raw[p])
    except Exception: continue

# Extract out-of-line definitions for the lifecycle handoff methods that matter.
specs=[
 ("infra_init_noarg","RTW88WCLInfraInterface","init",0),
 ("infra_init_provider","RTW88WCLInfraInterface","init",1),
 ("infra_attach_radio","RTW88WCLInfraInterface","attachRadio",0),
 ("infra_get_controller","RTW88WCLInfraInterface","getController",0),
 ("infra_start","RTW88WCLInfraInterface","start",0),
 ("infra_stop","RTW88WCLInfraInterface","stop",0),
 ("controller_init","RTW88WCLController","init",0),
 ("controller_start","RTW88WCLController","start",0),
 ("controller_free","RTW88WCLController","free",0)
]
methods={}
def extract_method(cls,name,occurrence=0):
    rx=re.compile(r"\b"+re.escape(cls)+r"\s*::\s*"+re.escape(name)+r"\s*\(")
    hits=[]
    for p in source_files:
        code=masked.get(p,""); text=raw.get(p,"")
        for m in rx.finditer(code):
            op=code.find("(",m.start()); depth=0; close=None
            for i in range(op,len(code)):
                if code[i]=="(": depth+=1
                elif code[i]==")":
                    depth-=1
                    if depth==0: close=i; break
            if close is None: continue
            j=close+1; brace=None
            while j<len(code):
                if code[j]=="{": brace=j; break
                if code[j]==";": break
                j+=1
            if brace is None: continue
            depth=0; end=None
            for i in range(brace,len(code)):
                if code[i]=="{": depth+=1
                elif code[i]=="}":
                    depth-=1
                    if depth==0: end=i+1; break
            if end is None: continue
            hits.append((p,code.count("\n",0,m.start())+1,
                         code.count("\n",0,brace)+1,code[brace:end],text))
    if occurrence>=len(hits): return None
    return hits[occurrence]

method_out=[
 "STAGE52_PROVIDER_HANDOFF_METHOD_BODIES",
 "EXTRACTION=qualified out-of-line method definitions; comments and literals masked for brace matching"
]
for label,cls,name,occ in specs:
    item=extract_method(cls,name,occ)
    if not item:
        methods[label]=None
        method_out.append("\n===== %s | %s::%s | NOT_EXTRACTED ====="%(label,cls,name))
        continue
    p,sigline,bodyline,body,text=item
    methods[label]=body
    lines=text.splitlines()
    endline=bodyline+body.count("\n")
    method_out.append("\n===== %s | %s::%s | %s:%d..%d ====="%(
        label,cls,name,p.relative_to(src),sigline,endline))
    for n in range(bodyline,min(endline,len(lines))+1):
        method_out.append("%5d %s"%(n,lines[n-1]))
(out/"method-bodies.txt").write_text("\n".join(method_out)+"\n")

# Capture class inheritance and meta-class registration declarations from headers/source.
class_lines=[
 "STAGE52_CLASS_DECLARATION_AND_METACLASS_INDEX",
 "COMMENTS_AND_QUOTED_LITERALS=EXCLUDED"
]
needles=re.compile(
 r"OSDeclare(Default)?Structors|OSDefineMetaClassAndStructors|OSMetaClass|"
 r"class\s+RTW88WCL(InfraInterface|Controller)|"
 r"IO80211InfraProtocol|IO80211InfraInterface|IO80211SkywalkInterface|IO80211Controller",
 re.I
)
for p in source_files:
    lines=raw[p].splitlines(); code=masked[p].splitlines()
    hits=[i for i,line in enumerate(code) if needles.search(line)]
    if not hits: continue
    class_lines.append("\nFILE="+str(p.relative_to(src)))
    chosen=set()
    for i in hits:
        for n in range(max(0,i-2),min(len(lines),i+3)):
            if n not in chosen:
                class_lines.append("%5d %s"%(n+1,lines[n])); chosen.add(n)
(out/"class-and-metaclass-index.txt").write_text("\n".join(class_lines)+"\n")

# Whole-source code-only occurrences: distinguish definitions, declarations and
# references by retaining exact path/line. Occurrence inventory is not a call graph.
tokens=[
 "RTW88WCLInfraInterface","RTW88WCLController","IO80211InfraProtocol",
 "IO80211InfraInterface","IO80211SkywalkInterface","IO80211Controller",
 "OSDefineMetaClassAndStructors","OSDeclareDefaultStructors",
 "getPrimarySkywalkInterface","setPrimarySkywalkInterface",
 "createSkywalkInterface","createInterface","registerService",
 "attachRadio","detachRadio","prepareRegistrationInfo",
 "initRegistrationInfo","registerInfraEthernetInterface",
 "getController"
]
index=["STAGE52_SOURCE_REFERENCE_INDEX","COMMENTS_AND_QUOTED_LITERALS=EXCLUDED"]
for token in tokens:
    rx=re.compile(re.escape(token))
    hits=[]
    for p,code in masked.items():
        codelines=code.splitlines(); rawlines=raw[p].splitlines()
        for m in rx.finditer(code):
            n=code.count("\n",0,m.start())+1
            value=rawlines[n-1].strip() if n<=len(rawlines) else ""
            hits.append((str(p.relative_to(src)),n,value[:500]))
    index.append("\nTOKEN=%s CODE_OCCURRENCES=%d"%(token,len(hits)))
    for path,line,value in hits[:160]:
        index.append("%s:%d: %s"%(path,line,value))
    if len(hits)>160: index.append("TRUNCATED=%d"%(len(hits)-160))
(out/"reference-index.txt").write_text("\n".join(index)+"\n")

# Parse every Info.plist under the kext tree and report the relevant personalities.
plist_files=sorted(p for p in src.rglob("Info.plist")
                   if p.is_file() and "run log" not in p.parts and ".git" not in p.parts)
plist_report=[
 "STAGE52_IOKIT_PERSONALITY_REPORT",
 "INFO_PLIST_FILES_FOUND=%d"%len(plist_files)
]
parsed=[]
for p in plist_files:
    rawbytes=p.read_bytes()
    plist_report += ["\n===== FILE=%s ====="%p.relative_to(src),
                     "BYTES=%d"%len(rawbytes),
                     "SHA256="+hashlib.sha256(rawbytes).hexdigest()]
    try:
        obj=plistlib.loads(rawbytes)
        plist_report.append("PLIST_PARSE=PASS")
    except Exception as e:
        plist_report.append("PLIST_PARSE=FAIL:"+str(e))
        continue
    bundle=obj.get("CFBundleIdentifier","")
    executable=obj.get("CFBundleExecutable","")
    plist_report += ["CFBundleIdentifier="+str(bundle),
                     "CFBundleExecutable="+str(executable)]
    personalities=obj.get("IOKitPersonalities",{})
    plist_report.append("IOKIT_PERSONALITY_COUNT="+str(len(personalities) if isinstance(personalities,dict) else "NOT_A_DICT"))
    if isinstance(personalities,dict):
        for pname,personality in personalities.items():
            plist_report.append("\nPERSONALITY_NAME="+str(pname))
            if not isinstance(personality,dict):
                plist_report.append("PERSONALITY_VALUE_TYPE="+type(personality).__name__)
                continue
            for key in ("IOClass","IOProviderClass","IOMatchCategory","IONameMatch",
                        "IOProbeScore","IOResourceMatch","IOPropertyMatch",
                        "CFBundleIdentifier","IOUserClientClass","IOPersonalityPublisher"):
                if key in personality:
                    plist_report.append("%s=%s"%(key,repr(personality[key])[:1200]))
            parsed.append((str(p.relative_to(src)),str(pname),personality.get("IOClass"),
                           personality.get("IOProviderClass"),personality.get("IOMatchCategory")))
(out/"personality-report.txt").write_text("\n".join(plist_report)+"\n")

# Textual metadata refs outside Info.plist too.
text_meta=[]
for p in sorted(src.rglob("*")):
    if not p.is_file() or p.stat().st_size>2_000_000: continue
    if "run log" in p.parts or ".git" in p.parts: continue
    if p.name=="Info.plist": continue
    if p.suffix.lower() not in (".plist",".xml",".json",".txt",".md"): continue
    try: lines=p.read_text(errors="replace").splitlines()
    except Exception: continue
    for n,line in enumerate(lines,1):
        if any(x in line for x in ("RTW88WCLInfraInterface","RTW88WCLController","IO80211InfraProtocol")):
            text_meta.append("%s:%d: %s"%(p.relative_to(src),n,line.strip()[:500]))
(out/"metadata-reference.txt").write_text(
 "STAGE52_NONPLIST_METADATA_REFERENCES\n"+
 ("\n".join(text_meta)+"\n" if text_meta else "NO_MATCHING_TEXT_REFERENCES\n")
)

# Direct-body lifecycle edges.
def has(label,pattern):
    body=methods.get(label)
    return bool(body and re.search(pattern,body,re.I))
checks=[
 ("infra provider-init calls IO80211SkywalkInterface::init(provider,address)",
  has("infra_init_provider",r"IO80211SkywalkInterface\s*::\s*init\s*\(")),
 ("infra provider-init casts provider to RTW88WCLController",
  has("infra_init_provider",r"OSDynamicCast\s*\(\s*RTW88WCLController\s*,\s*provider\s*\)")),
 ("infra attachRadio obtains provider controller workloop",
  has("infra_attach_radio",r"_controller\s*->\s*getWorkLoop\s*\(")),
 ("infra attachRadio attaches radio and work queue to bridge",
  has("infra_attach_radio",r"_bridge\s*\.\s*attach\s*\(")),
 ("infra getController returns stored provider controller",
  has("infra_get_controller",r"return\s+_controller\s*;")),
 ("infra start returns false",
  has("infra_start",r"return\s+false\s*;")),
 ("controller start creates infra-interface object",
  has("controller_start",r"new\s+RTW88WCLInfraInterface|OSMakeUnique\s*<\s*RTW88WCLInfraInterface")),
 ("controller start sets primary Skywalk interface",
  has("controller_start",r"setPrimarySkywalkInterface|setPrimaryInterface")),
 ("controller start prepares or starts infra protocol",
  has("controller_start",r"prepareRegistrationInfo|RTW88WCLInfraInterface")),
 ("controller free retains resources on cleanup failure",
  has("controller_free",r"cleanupStatus[\s\S]{0,500}return\s*;")),
]
matrix=[
 "STAGE52_PROVIDER_AND_PERSONALITY_MATRIX",
 "PRESENT means a direct token/reference appears in the extracted method body or parsed plist entry.",
 "A missing source edge does not prove the Apple framework has no internal factory path."
]
for label,value in checks:
    matrix.append("%s: %s"%(label,"PRESENT" if value else "ABSENT"))
if parsed:
    for file,pname,io_class,provider,category in parsed:
        matrix.append("PLIST_PERSONALITY: file=%s name=%s IOClass=%r IOProviderClass=%r IOMatchCategory=%r"%(
            file,pname,io_class,provider,category))
else:
    matrix.append("PLIST_PERSONALITIES=NONE_PARSED")
matrix.append("METHODS_EXTRACTED=%d"%sum(v is not None for v in methods.values()))
matrix.append("METHODS_REQUESTED=%d"%len(specs))
(out/"provider-contract-matrix.txt").write_text("\n".join(matrix)+"\n")

summary=[
 "STAGE52_IOKIT_PERSONALITY_PROVIDER_CONTRACT_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "SOURCE_FILES_SCANNED=%d"%len(source_files),
 "METHOD_BODIES_EXTRACTED=%d"%sum(v is not None for v in methods.values()),
 "METHOD_BODIES_REQUESTED=%d"%len(specs),
 "INFO_PLIST_FILES_FOUND=%d"%len(plist_files),
 "PARSED_PERSONALITY_ENTRIES=%d"%len(parsed),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 52 IOKIT PERSONALITY / PROVIDER CONTRACT AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage51 run-20261102-125002-c08308fb6081"
 echo "SCOPE=IOKit Info.plist personality keys; RTW88 class/metaclass declarations; IO80211 protocol inheritance; provider init and controller linkage; interface factory/publication references"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "INSTALL=NOT_RUN"
 echo "LOAD=NOT_RUN"
 echo "OPENCORE_CHANGE=NONE"
 echo
 cat "$OUT/source-fingerprint.txt"
 echo
 cat "$OUT/audit-summary.txt"
 echo
 cat "$OUT/provider-contract-matrix.txt"
 echo
 echo "METHOD_BODIES=$OUT/method-bodies.txt"
 echo "CLASS_METACLASS_INDEX=$OUT/class-and-metaclass-index.txt"
 echo "SOURCE_REFERENCE_INDEX=$OUT/reference-index.txt"
 echo "PERSONALITY_REPORT=$OUT/personality-report.txt"
 echo "METADATA_REFERENCE=$OUT/metadata-reference.txt"
 echo
 echo "SOURCE_TREE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "CODESIGN=NOT_RUN"
 echo "KEXT_INSTALL=NOT_RUN"
 echo "KEXT_LOAD=NOT_RUN"
 echo "OPENCORE_MODIFIED=NO"
 echo "SIP_NVRAM_MODIFIED=NO"
 echo "HARDWARE_TEST=NOT_RUN"
 echo "SYSTEM_FILES_MODIFIED=NO"
 echo "========== END STAGE 52 =========="
} > "$OUT/report.txt"

github_sha() {
 gh api "repos/$REPO/contents/$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha",""))' 2>/dev/null || true
}
blob_sha() {
 python3 - "$1" <<'PY2'
import hashlib,pathlib,sys
b=pathlib.Path(sys.argv[1]).read_bytes()
print(hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest())
PY2
}
PAYLOAD_INDEX=0
upload_one() {
 local file="$1" path="$2" allow="$3"
 local expected old payload response put got
 expected="$(blob_sha "$file")"
 old="$(github_sha "$path")"
 if [[ "$allow" == 1 ]]; then
   [[ "$old" =~ ^[0-9a-f]{40}$ ]] || { echo "UPDATE_TARGET_SHA_NOT_FOUND=$path" >> "$UPLOAD_ERROR"; return 1; }
 elif [[ -n "$old" ]]; then
   if [[ "$old" == "$expected" ]]; then
     echo "IDENTICAL_EXISTING=$path SHA=$old" >> "$OUT/upload-verification.txt"; return 0
   fi
   echo "REFUSE_OVERWRITE_DIFFERENT_FILE=$path REMOTE=$old LOCAL=$expected" >> "$UPLOAD_ERROR"
   return 1
 fi
 PAYLOAD_INDEX=$((PAYLOAD_INDEX+1))
 payload="$OUT/payload-$PAYLOAD_INDEX.json"
 response="$OUT/response-$PAYLOAD_INDEX.json"
 python3 - "$file" "$old" "$payload" <<'PY2'
import base64,json,pathlib,sys
f,sha,dst=sys.argv[1:]
obj={"message":"Add Stage52 read-only IOKit provider/personality audit evidence",
     "content":base64.b64encode(pathlib.Path(f).read_bytes()).decode()}
if sha: obj["sha"]=sha
pathlib.Path(dst).write_text(json.dumps(obj),encoding="utf-8")
PY2
 gh api --method PUT "repos/$REPO/contents/$path" --input "$payload" > "$response"
 put="$(python3 - "$response" <<'PY2'
import json,sys
print(json.load(open(sys.argv[1]))["content"]["sha"])
PY2
)"
 got="$(github_sha "$path")"
 [[ "$put" == "$got" && "$got" == "$expected" ]] || {
   echo "READBACK_SHA_MISMATCH=$path PUT=$put GOT=$got EXPECTED=$expected" >> "$UPLOAD_ERROR"; return 1;
 }
 echo "VERIFIED=$path SHA=$got" >> "$OUT/upload-verification.txt"
}

MAN="$OUT/manifest.txt"
{
 echo "STAGE=52"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only IOKit personality, metaclass and provider-contract audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage51 run-20261102-125002-c08308fb6081"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage52/$RUN/$base"
 root="Development/Logs/stage52-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/provider-contract-matrix.txt "$OUT"/method-bodies.txt "$OUT"/class-and-metaclass-index.txt "$OUT"/reference-index.txt "$OUT"/personality-report.txt "$OUT"/metadata-reference.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
# Freeze manifest after all artifact paths have been recorded.
upload_one "$MAN" "Development/Logs/stage52/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage52-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 52 IOKIT PERSONALITY / PROVIDER CONTRACT AUDIT ==========\n"
 "STAGE52_RUN: %s\n"%run+
 "STAGE52_VERSION: %s\n"%version+
 "STAGE52_SCOPE: IOKit personality keys, class/metaclass declarations, IO80211 provider init, controller linkage and interface publication references\n"+
 "STAGE52_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — provider/personality audit only; no registration implementation or hardware-test authorization\n"+
 "STAGE52_LOGS: Development/Logs/stage52/%s/ and unique files directly under Development/Logs/\n"%run+
 "====================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE52_VERSION=$VERSION"
echo "STAGE52_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE52_RUN=$RUN"
echo "STAGE52_LOCAL_OUTPUT=$OUT"
echo "STAGE52_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage52/$RUN"
echo "STAGE52_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE52_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE52_SOURCE_MODIFIED=NO"
echo "STAGE52_BUILD=NOT_RUN"
echo "STAGE52_INSTALL=NOT_RUN"
echo "STAGE52_LOAD=NOT_RUN"
echo "STAGE52_OPENCORE_CHANGE=NONE"
