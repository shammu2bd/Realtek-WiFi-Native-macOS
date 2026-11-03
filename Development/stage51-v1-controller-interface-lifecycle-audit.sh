#!/bin/bash
# Stage 51 — controller / infrastructure-interface ownership and lifecycle audit.
# VERSION_MARKER: STAGE51_V1_20261102
# READ ONLY: no source edits, build, signing, install/load, SIP/NVRAM, or OpenCore changes.
set -Eeuo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
VERSION="STAGE51_V1_20261102"
SOURCE_ROOT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
SRC="$SOURCE_ROOT/driver/RTL88WiFi"
RUN="run-$(date -u '+%Y%m%d-%H%M%S')-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
OUT="$SOURCE_ROOT/run log/stage51/$RUN"
mkdir -p "$OUT"
UPLOAD_ERROR="$OUT/upload-error.txt"
trap 'rc=$?; trap - ERR; echo "STAGE51_ERROR=exit:$rc line:$LINENO" >&2; [[ ! -f "$UPLOAD_ERROR" ]] || tail -50 "$UPLOAD_ERROR" >&2; exit "$rc"' ERR
fail(){ echo "ERROR: $*" >&2; exit 2; }

for t in curl gh python3 shasum split grep awk sw_vers uname wc; do
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
import hashlib,pathlib,re,sys

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

srcdir=src/"src"
source_files=[]
for p in sorted(srcdir.rglob("*")):
    if p.is_file() and p.suffix.lower() in (".cpp",".hpp",".h",".c"):
        if any(x in ("build","DerivedData",".git") for x in p.parts): continue
        source_files.append(p)
raw={}; masked={}
for p in source_files:
    try: raw[p]=p.read_text(errors="replace"); masked[p]=mask_cpp(raw[p])
    except Exception: continue

# Extract every qualified, out-of-line method definition for these two classes.
classes=("RTW88WCLInfraInterface","RTW88WCLController")
methods=[]
for p in source_files:
    code=masked.get(p,"")
    text=raw.get(p,"")
    for cls in classes:
        rx=re.compile(r"\b"+cls+r"\s*::\s*([A-Za-z_]\w*)\s*\(")
        for m in rx.finditer(code):
            op=code.find("(",m.start())
            depth=0; close=None
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
            line=code.count("\n",0,m.start())+1
            body_line=code.count("\n",0,brace)+1
            methods.append({
                "class":cls,"name":m.group(1),"path":p,"signature_line":line,
                "body_line":body_line,"body":code[brace:end],"raw":text
            })

bodyout=[
 "STAGE51_EXACT_CONTROLLER_INTERFACE_METHODS",
 "EXTRACTION=qualified out-of-line definitions; comments and string/character literals masked for brace matching",
 "METHOD_COUNT="+str(len(methods))
]
for item in methods:
    rawlines=item["raw"].splitlines()
    body_end=item["body_line"]+item["body"].count("\n")
    bodyout += ["\n===== %s::%s | %s:%d..%d ====="%(
        item["class"],item["name"],item["path"].relative_to(src),
        item["signature_line"],body_end)]
    for n in range(item["body_line"],min(body_end,len(rawlines))+1):
        bodyout.append("%5d %s"%(n,rawlines[n-1]))
(out/"method-bodies.txt").write_text("\n".join(bodyout)+"\n")

# List all code-only references to interface/controller ownership and lifecycle APIs,
# including references outside the two implementation translation units.
tokens=[
 "RTW88WCLInfraInterface","RTW88WCLController","attachRadio","detachRadio",
 "bindRadioBackend","bindRadio","setPrimarySkywalkInterface","getPrimarySkywalkInterface",
 "createSkywalkInterface","registerInfraEthernetInterface","prepareRegistrationInfo",
 "clearRegistrationInfo","RTW88WCLInfraInterfaceStage","RTW88WCLControllerStage",
 "new RTW88WCLInfraInterface","new RTW88WCLController"
]
occ=["STAGE51_CODE_REFERENCE_INDEX","COMMENTS_AND_QUOTED_LITERALS=EXCLUDED"]
for token in tokens:
    rx=re.compile(re.escape(token))
    hits=[]
    for p,code in masked.items():
        lines=code.splitlines(); rawlines=raw[p].splitlines()
        for m in rx.finditer(code):
            n=code.count("\n",0,m.start())+1
            rawline=rawlines[n-1].strip() if n<=len(rawlines) else ""
            hits.append((str(p.relative_to(src)),n,rawline[:500]))
    occ.append("\nTOKEN=%s CODE_OCCURRENCES=%d"%(token,len(hits)))
    for path,line,value in hits[:150]:
        occ.append("%s:%d: %s"%(path,line,value))
    if len(hits)>150: occ.append("TRUNCATED=%d"%(len(hits)-150))
(out/"reference-index.txt").write_text("\n".join(occ)+"\n")

# Body-level reachability matrix. A positive means the exact token appears in
# that method body; it does not imply runtime execution or ABI correctness.
def body_for(cls,name):
    return [m for m in methods if m["class"]==cls and m["name"]==name]
def body_has(cls,name,pattern):
    candidates=body_for(cls,name)
    return any(re.search(pattern,m["body"],re.I) for m in candidates)

checks=[
 ("controller start -> constructs native infra interface",
  body_has("RTW88WCLController","start",r"new\s+RTW88WCLInfraInterface|OSMakeUnique\s*<\s*RTW88WCLInfraInterface")),
 ("controller start -> calls infra attachRadio",
  body_has("RTW88WCLController","start",r"attachRadio\s*\(")),
 ("controller start -> installs primary Skywalk interface",
  body_has("RTW88WCLController","start",r"setPrimarySkywalkInterface|setSkywalkInterface|setPrimaryInterface")),
 ("controller start -> prepares/starts infra interface",
  body_has("RTW88WCLController","start",r"prepareRegistrationInfo|->\s*start\s*\(|\.start\s*\(")),
 ("infra start -> controller binding or PCI backend startup",
  body_has("RTW88WCLInfraInterface","start",r"attachRadio|bindRadio|RTW88WCLController|powerOn")),
 ("infra init -> superclass IO80211 Skywalk init",
  body_has("RTW88WCLInfraInterface","init",r"IO80211SkywalkInterface::init")),
 ("infra free/stop -> detachRadio",
  any(body_has("RTW88WCLInfraInterface",n,r"detachRadio\s*\(") for n in ("free","stop"))),
 ("controller start -> creates queue owner",
  body_has("RTW88WCLController","start",r"new\s+RTW88WCLSkywalkQueues")),
 ("controller start -> creates RX adapter",
  body_has("RTW88WCLController","start",r"new\s+RTW88WCLSkywalkRxAdapter")),
 ("controller stop -> releaseNativeResources",
  body_has("RTW88WCLController","stop",r"releaseNativeResources\s*\(")),
 ("interface registration-preparation routine is invoked from lifecycle",
  any(re.search(r"prepareRegistrationInfo\s*\(",m["body"]) for m in methods)),
]
matrix=[
 "STAGE51_CONTROLLER_INTERFACE_LIFECYCLE_MATRIX",
 "PRESENT means a target token/reference appears inside the specified exact method body.",
 "ABSENT means no such direct body edge was found in the scanned source. It is not proof that no indirect path exists."
]
for label,result in checks:
    matrix.append("%s: %s"%(label,"PRESENT" if result else "ABSENT"))
matrix.append("INFRA_INTERFACE_METHODS="+",".join(sorted({m["name"] for m in methods if m["class"]=="RTW88WCLInfraInterface"})))
matrix.append("CONTROLLER_METHODS="+",".join(sorted({m["name"] for m in methods if m["class"]=="RTW88WCLController"})))
(out/"lifecycle-matrix.txt").write_text("\n".join(matrix)+"\n")

# Capture metadata/personality text references where the files are textual.
meta=[]
for p in sorted(src.rglob("*")):
    if not p.is_file() or p.stat().st_size>2_000_000: continue
    if "run log" in p.parts or ".git" in p.parts: continue
    if p.suffix.lower() not in (".plist",".xml",".json",".txt",".md",".plist.in"): continue
    try: txt=p.read_text(errors="replace")
    except Exception: continue
    lines=txt.splitlines()
    hits=[(i+1,line.strip()) for i,line in enumerate(lines)
          if "RTW88WCLInfraInterface" in line or "RTW88WCLController" in line]
    if hits:
        meta.append("\nFILE="+str(p.relative_to(src)))
        meta.extend("%d: %s"%(n,v[:500]) for n,v in hits[:100])
(out/"personality-reference.txt").write_text(
    "STAGE51_PERSONALITY_AND_METADATA_REFERENCE_SCAN\n"+
    ("NO_MATCHING_TEXT_REFERENCE_FOUND\n" if not meta else "\n".join(meta)+"\n")
)

summary=[
 "STAGE51_CONTROLLER_INTERFACE_LIFECYCLE_AUDIT",
 "TARGET=macOS 15.8.1 / 24H32 / x86_64",
 "SOURCE_FILES_SCANNED=%d"%len(source_files),
 "CLASS_METHOD_BODIES_EXTRACTED=%d"%len(methods),
 "INFRA_INTERFACE_METHOD_COUNT=%d"%sum(m["class"]=="RTW88WCLInfraInterface" for m in methods),
 "CONTROLLER_METHOD_COUNT=%d"%sum(m["class"]=="RTW88WCLController" for m in methods),
 "SOURCE_MODIFIED=NO","BUILD=NOT_RUN","CODESIGN=NOT_RUN",
 "KEXT_INSTALL=NOT_RUN","KEXT_LOAD=NOT_RUN",
 "OPENCORE_MODIFIED=NO","SIP_NVRAM_MODIFIED=NO","HARDWARE_TEST=NOT_RUN"
]
(out/"audit-summary.txt").write_text("\n".join(summary)+"\n")
PY

{
 echo "========== STAGE 51 CONTROLLER / INTERFACE OWNERSHIP AND LIFECYCLE AUDIT =========="
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "SOURCE_ROOT=$SOURCE_ROOT"
 echo "PREDECESSOR=Stage50 V2 run-20261102-124442-a9b4b83d7295"
 echo "SCOPE=exact RTW88WCLController and RTW88WCLInfraInterface method bodies; object construction; radio attach/detach; primary-interface publication references; start/stop/free ordering; personality references"
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
 cat "$OUT/lifecycle-matrix.txt"
 echo
 echo "METHOD_BODIES=$OUT/method-bodies.txt"
 echo "REFERENCE_INDEX=$OUT/reference-index.txt"
 echo "PERSONALITY_REFERENCE=$OUT/personality-reference.txt"
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
 echo "========== END STAGE 51 =========="
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
obj={"message":"Add Stage51 read-only controller/interface lifecycle audit evidence",
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
 echo "STAGE=51"
 echo "VERSION=$VERSION"
 echo "RUN=$RUN"
 echo "PURPOSE=read-only controller/interface ownership and lifecycle audit"
 echo "TARGET=$OSVER/$BUILD/$ARCH"
 echo "PREDECESSOR=Stage50 V2 run-20261102-124442-a9b4b83d7295"
 echo "SOURCE_MODIFIED=NO"
 echo "BUILD=NOT_RUN"
 echo "ACTIVATION_GATE=BLOCKED"
 echo "LOCAL_OUTPUT=$OUT"
} > "$MAN"

upload_artifact() {
 local file="$1" base group root
 base="$(basename "$file")"
 group="Development/Logs/stage51/$RUN/$base"
 root="Development/Logs/stage51-$RUN-$base"
 upload_one "$file" "$group" 0
 upload_one "$file" "$root" 0
 echo "GROUPED=$group | ROOT=$root | SHA256=$(shasum -a 256 "$file" | awk '{print $1}')" >> "$MAN"
}
for f in "$OUT"/report.txt "$OUT"/audit-summary.txt "$OUT"/source-fingerprint.txt "$OUT"/lifecycle-matrix.txt "$OUT"/method-bodies.txt "$OUT"/reference-index.txt "$OUT"/personality-reference.txt; do
 [[ -f "$f" ]] || fail "missing audit artifact: $f"
 bytes="$(wc -c < "$f" | tr -d ' ')"
 if (( bytes <= 225280 )); then
   upload_artifact "$f"
 else
   split -b 220k "$f" "$f.part-"
   for part in "$f".part-*; do upload_artifact "$part"; done
 fi
done
# Upload manifest after all artifact paths have been appended.
upload_one "$MAN" "Development/Logs/stage51/$RUN/manifest.txt" 0
upload_one "$MAN" "Development/Logs/stage51-$RUN-manifest.txt" 0

gh api "repos/$REPO/contents/Development/output.log" > "$OUT/remote-output-log.json"
python3 - "$OUT/remote-output-log.json" "$OUT/output.log" "$RUN" "$VERSION" <<'PY'
import base64,json,pathlib,sys
remote,dst,run,version=sys.argv[1:]
obj=json.load(open(remote))
old=base64.b64decode(obj["content"])
entry=(
 "\n========== STAGE 51 CONTROLLER / INTERFACE OWNERSHIP AND LIFECYCLE AUDIT ==========\n"
 "STAGE51_RUN: %s\n"%run+
 "STAGE51_VERSION: %s\n"%version+
 "STAGE51_SCOPE: exact controller/interface method bodies, object creation, radio attachment, primary interface publication references and start/stop/free ordering\n"+
 "STAGE51_SOURCE_MODIFIED: NO | BUILD: NOT_RUN | INSTALL: NOT_RUN | LOAD: NOT_RUN | OPENCORE_CHANGE: NONE\n"+
 "ACTIVATION_GATE: BLOCKED — lifecycle inspection only; it does not implement registration, connect callbacks or authorize hardware testing\n"+
 "STAGE51_LOGS: Development/Logs/stage51/%s/ and unique files directly under Development/Logs/\n"%run+
 "====================================================================\n"
).encode()
pathlib.Path(dst).write_bytes(old.rstrip()+entry)
PY
upload_one "$OUT/output.log" "Development/output.log" 1

echo
echo "STAGE51_VERSION=$VERSION"
echo "STAGE51_STATUS=UPLOADED_AND_READBACK_VERIFIED"
echo "STAGE51_RUN=$RUN"
echo "STAGE51_LOCAL_OUTPUT=$OUT"
echo "STAGE51_GITHUB_GROUPED=https://github.com/$REPO/tree/main/Development/Logs/stage51/$RUN"
echo "STAGE51_GITHUB_ROOT_LOGS=https://github.com/$REPO/tree/main/Development/Logs"
echo "STAGE51_GITHUB_OUTPUT_LOG=https://github.com/$REPO/blob/main/Development/output.log"
echo "STAGE51_SOURCE_MODIFIED=NO"
echo "STAGE51_BUILD=NOT_RUN"
echo "STAGE51_INSTALL=NOT_RUN"
echo "STAGE51_LOAD=NOT_RUN"
echo "STAGE51_OPENCORE_CHANGE=NONE"
