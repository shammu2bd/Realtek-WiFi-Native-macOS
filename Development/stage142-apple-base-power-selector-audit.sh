#!/bin/bash
# Stage142: read-only audit of Apple base forwarding and IO80211 POWER selector handlers.
# Preserves all staged/unstaged source changes; writes only a temporary report outside the checkout.
# No build/sign/install/load/unload/hardware/OpenCore/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
for c in gh python3 shasum; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 3; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 4; }
BRANCH="$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
HEAD="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
STATUS_COUNT="$(git status --porcelain | wc -l | tr -d '[:space:]')"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"; [[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
REPORT="$(mktemp "$TMPROOT/stage142-report.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE142 APPLE BASE AND POWER SELECTOR SOURCE AUDIT =========="
 echo "STAGE142_BRANCH=$BRANCH"
 echo "STAGE142_HEAD=$HEAD"
 echo "STAGE142_WORKTREE_STATUS_ENTRIES=$STATUS_COUNT"
 echo "STAGE142_SCOPE=READ_ONLY_DRIVER_BASE_FORWARDING_AND_CONTROLLER_POWER_SELECTOR_REVIEW"
 echo "STAGE142_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE142_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 python3 - "$ROOT" <<'PY'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1])
rels=[
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp"]
src={}
for rel in rels:
 p=root/rel; data=p.read_bytes()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(rel,hashlib.sha256(data).hexdigest(),len(data)))
 src[rel]=data.decode(errors="replace")
def first_base(text,name):
 pat=r"\bclass\s+"+re.escape(name)+r"(?:\s+final)?\s*:\s*public\s+([A-Za-z_]\w*)"
 m=re.search(pat,text,re.S)
 return m.group(1) if m else None
h=src[rels[0]]; cpp=src[rels[1]]; abi=src[rels[2]]; ch=src[rels[3]]; cc=src[rels[4]]
for name,text in [
 ("RTW88WCLInfraInterface",h),
 ("IO80211InfraProtocol",abi),
 ("IO80211InfraInterface",abi),
 ("IO80211SkywalkInterface",abi),
 ("RTW88WCLController",ch)]:
 print("CLASS_DIRECT_BASE=%s:%s"%(name,first_base(text,name) or "NOT_RESOLVED"))
def class_region(text,name):
 m=re.search(r"\bclass\s+"+re.escape(name)+r"\b",text)
 if not m:return ""
 op=text.find("{",m.end())
 if op<0:return ""
 depth=0
 for i in range(op,len(text)):
  if text[i]=="{":depth+=1
  elif text[i]=="}":
   depth-=1
   if depth==0:return text[m.start():i+1]
 return text[m.start():]
rclass=class_region(h,"RTW88WCLInfraInterface")
for meth in ("enable","disable","setInterfaceEnable","interfaceAdvisoryEnable"):
 found=bool(re.search(r"\b"+meth+r"\s*\([^;{}]*\)\s*(?:override\s*)?;",rclass))
 print("DRIVER_DECLARES_%s=%s"%(meth.upper(),"YES" if found else "NO"))
def strip_comments_keep_length(s):
 out=list(s); i=0; state="normal"; quote=""
 while i<len(s):
  if state=="normal":
   if s.startswith("//",i):out[i]=out[i+1]=" ";i+=2;state="line";continue
   if s.startswith("/*",i):out[i]=out[i+1]=" ";i+=2;state="block";continue
   if s[i] in ("'",'"'):quote=s[i];state="string"
  elif state=="line":
   if s[i]=="\n":state="normal"
   else:out[i]=" "
  elif state=="block":
   if s.startswith("*/",i):out[i]=out[i+1]=" ";i+=2;state="normal";continue
   if s[i]!="\n":out[i]=" "
  elif state=="string":
   if s[i]=="\\":i+=2;continue
   if s[i]==quote:state="normal"
  i+=1
 return "".join(out)
def extract_body(text,qualified):
 masked=strip_comments_keep_length(text)
 pat=r"(?:IOReturn|SInt32)\s+"+re.escape(qualified)+r"\s*\([^)]*\)"
 m=re.search(pat,masked)
 if not m:return None
 op=masked.find("{",m.end())
 if op<0:return None
 depth=0
 for i in range(op,len(masked)):
  if masked[i]=="{":depth+=1
  elif masked[i]=="}":
   depth-=1
   if depth==0:return text[op+1:i]
 return None
def print_method(label,body):
 print("\nMETHOD="+label)
 if body is None:
  print("METHOD_STATUS=NOT_FOUND_OR_UNBALANCED");return
 print("METHOD_STATUS=FOUND")
 for line in body.splitlines():
  if line.strip():print("SOURCE|"+line.rstrip())
 patterns=[
 ("CALLS_APPLE_INFRA_ENABLE",r"\bIO80211InfraInterface::enable\s*\(|\bsuper::enable\s*\("),
 ("CALLS_APPLE_INFRA_DISABLE",r"\bIO80211InfraInterface::disable\s*\(|\bsuper::disable\s*\("),
 ("CALLS_SKYWALK_SETTER",r"\b(?:IO80211SkywalkInterface::)?setInterfaceEnable\s*\("),
 ("CALLS_SKYWALK_ADVISORY",r"\binterfaceAdvisoryEnable\s*\("),
 ("CALLS_RADIO_POWER_ON",r"\bpowerOn\s*\("),
 ("CALLS_RADIO_POWER_OFF",r"\bpowerOff\s*\("),
 ("CALLS_PACKET_PATH_ACTIVATE",r"\bactivatePacketPath\s*\("),
 ("CALLS_PACKET_PATH_QUIESCE",r"\bquiescePacketPath\s*\(")]
 for key,pat in patterns:print(key+"="+("YES" if re.search(pat,body) else "NO"))
print_method("RTW88WCLInfraInterface::enable",extract_body(cpp,"RTW88WCLInfraInterface::enable"))
print_method("RTW88WCLInfraInterface::disable",extract_body(cpp,"RTW88WCLInfraInterface::disable"))
print_method("RTW88WCLController::getPOWER",extract_body(cc,"RTW88WCLController::getPOWER"))
print_method("RTW88WCLController::setPOWER",extract_body(cc,"RTW88WCLController::setPOWER"))
print("\n--- Selector and inheritance declarations ---")
for name,text in (("RTW88WCLInfraInterface",h),("IO80211InfraInterface",abi),("IO80211InfraProtocol",abi),("RTW88WCLController",ch)):
 region=class_region(text,name)
 for selector in ("getPOWER","setPOWER"):
  if selector in region:print("CLASS_SELECTOR_REFERENCE=%s:%s=YES"%(name,selector))
print("STAGE142_DRIVER_ENABLE_FORWARDING="+("YES" if re.search(r"IO80211InfraInterface::enable\s*\(|super::enable\s*\(",extract_body(cpp,"RTW88WCLInfraInterface::enable") or "") else "NO"))
print("STAGE142_DRIVER_DISABLE_FORWARDING="+("YES" if re.search(r"IO80211InfraInterface::disable\s*\(|super::disable\s*\(",extract_body(cpp,"RTW88WCLInfraInterface::disable") or "") else "NO"))
print("STAGE142_CONTROLLER_GETPOWER_NOTREADY="+("YES" if "kIOReturnNotReady" in (extract_body(cc,"RTW88WCLController::getPOWER") or "") else "NO"))
print("STAGE142_CONTROLLER_SETPOWER_NOTREADY="+("YES" if "kIOReturnNotReady" in (extract_body(cc,"RTW88WCLController::setPOWER") or "") else "NO"))
print("STAGE142_INTERPRETATION=SOURCE_ONLY; NO_RUNTIME_POWER_OR_MENU_CLAIM")
PY
 echo "STAGE142_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE142_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE142 =========="
} >"$REPORT"
echo "===== STAGE142 SUMMARY ====="
grep -aE '^(STAGE142_|SOURCE_FILE=|CLASS_DIRECT_BASE=|DRIVER_DECLARES_|METHOD=|METHOD_STATUS=|CALLS_|CLASS_SELECTOR_REFERENCE=|SOURCE\||STAGE142_DRIVER_|STAGE142_CONTROLLER_)' "$REPORT" | head -220 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage142-apple-base-power-selector-audit-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage142: publish read-only Apple base and POWER selector audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE142_UPLOAD_SHA="+actual);print("STAGE142_GITHUB_PATH="+dest);print("STAGE142_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE142_UPLOAD_SHA="+existing);print("STAGE142_GITHUB_PATH="+dest);print("STAGE142_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE142_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE142_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE142_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
