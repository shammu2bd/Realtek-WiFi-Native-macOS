#!/bin/bash
# Stage141: read-only compare the local RTL88WiFi enable path against Apple 24H32 inheritance.
# Preserves all staged/unstaged changes. No local source or repository writes.
# No build/sign/install/load/unload/hardware/OpenCore/EFI/SIP/NVRAM/reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
for c in gh python3; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 3; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 4; }
WORKTREE_COUNT="$(git status --porcelain | wc -l | tr -d '[:space:]')"
BRANCH="$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
HEAD="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
TARGET="driver/RTL88WiFi/src/kext/wcl24h32"
for f in "$TARGET/RTW88WCLInfraInterface.hpp" "$TARGET/RTW88WCLInfraInterface.cpp" "$TARGET/RTW88WCL24H32InterfaceABI.hpp" "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/80211/IO80211SkywalkInterface.h" "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkEthernetInterface.h" "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkNetworkInterface.h"; do
 [[ -r "$ROOT/$f" ]] || { echo "ERROR: required source/header missing: $f"; exit 5; }
done
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"; [[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
REPORT="$(mktemp "$TMPROOT/stage141-report.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE141 RTL88WIFI POWER PATH SOURCE AUDIT =========="
 echo "STAGE141_BRANCH=$BRANCH"
 echo "STAGE141_HEAD=$HEAD"
 echo "STAGE141_WORKTREE_STATUS_ENTRIES=$WORKTREE_COUNT"
 echo "STAGE141_TARGET=LOCAL_CHECKOUT_WORKING_TREE_INCLUDING_STAGED_CHANGES"
 echo "STAGE141_SCOPE=READ_ONLY_INHERITANCE_ENABLE_DISABLE_AND_POWER_STATE_SOURCE_REVIEW"
 echo "STAGE141_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE141_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 python3 - "$ROOT" <<'PY'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1])
rels=[
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp",
"driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp",
"driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/80211/IO80211SkywalkInterface.h",
"driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkEthernetInterface.h",
"driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkNetworkInterface.h"]
sources={}
for rel in rels:
 p=root/rel; data=p.read_bytes()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(rel,hashlib.sha256(data).hexdigest(),len(data)))
 sources[rel]=data.decode(errors="replace")
def class_decl(src,name):
 m=re.search(r"\bclass\s+"+re.escape(name)+r"\s*:\s*public\s+([A-Za-z_]\w*)",src)
 return m.group(1) if m else None
chain=[
("RTW88WCLInfraInterface",sources[rels[0]]),
("IO80211InfraProtocol",sources[rels[2]]),
("IO80211InfraInterface",sources[rels[2]]),
("IO80211SkywalkInterface",sources[rels[3]]),
("IOSkywalkEthernetInterface",sources[rels[4]]),
("IOSkywalkNetworkInterface",sources[rels[5]])]
for cls,src in chain:
 print("CLASS_INHERITANCE=%s:%s"%(cls,class_decl(src,cls) or "NOT_FOUND"))
cpp=sources[rels[1]]
def method_body(src,signature):
 m=re.search(signature,src)
 if not m:return None
 op=src.find("{",m.end())
 if op<0:return None
 depth=0; quote=None; esc=False
 for i in range(op,len(src)):
  c=src[i]
  if quote:
   if esc:esc=False
   elif c=="\\":esc=True
   elif c==quote:quote=None
  else:
   if c in ("'",'"'):quote=c
   elif c=="{":depth+=1
   elif c=="}":
    depth-=1
    if depth==0:return src[op+1:i]
 return None
bodies={}
for label,pat in (
 ("ENABLE",r"IOReturn\s+RTW88WCLInfraInterface::enable\s*\([^)]*\)"),
 ("DISABLE",r"IOReturn\s+RTW88WCLInfraInterface::disable\s*\([^)]*\)")):
 body=method_body(cpp,pat)
 print("\nMETHOD="+label)
 if body is None:
  print("METHOD_STATUS=NOT_FOUND_OR_UNBALANCED");continue
 bodies[label]=body
 print("METHOD_BODY_BEGIN")
 for line in body.splitlines():
  if line.strip():print("SOURCE|"+line.rstrip())
 print("METHOD_BODY_END")
 checks=[
 ("CALLS_SUPER_ENABLE",r"\bsuper::enable\s*\("),
 ("CALLS_SUPER_DISABLE",r"\bsuper::disable\s*\("),
 ("CALLS_INFRA_ENABLE",r"\bIO80211InfraInterface::enable\s*\("),
 ("CALLS_INFRA_DISABLE",r"\bIO80211InfraInterface::disable\s*\("),
 ("CALLS_SKYWALK_ENABLE",r"\bIO80211SkywalkInterface::enable\s*\("),
 ("CALLS_SKYWALK_DISABLE",r"\bIO80211SkywalkInterface::disable\s*\("),
 ("CALLS_SET_INTERFACE_ENABLE",r"\bsetInterfaceEnable\s*\("),
 ("CALLS_IS_INTERFACE_ENABLED",r"\bisInterfaceEnabled\s*\("),
 ("CALLS_RADIO_POWER_ON",r"\b(?:_bridge\.)?powerOn\s*\("),
 ("CALLS_RADIO_POWER_OFF",r"\b(?:_bridge\.)?powerOff\s*\("),
 ("CALLS_PACKET_PATH_ACTIVATE",r"\bactivatePacketPath\s*\("),
 ("CALLS_PACKET_PATH_QUIESCE",r"\bquiescePacketPath\s*\(")]
 for key,pattern in checks:print(key+"="+("YES" if re.search(pattern,body) else "NO"))
 print("RETURNS_SUCCESS_TOKEN="+("YES" if "kIOReturnSuccess" in body else "NO"))
print("\n--- Power and enable references in driver source ---")
found=0
for p in sorted((root/"driver/RTL88WiFi/src/kext").rglob("*")):
 if not p.is_file() or p.suffix.lower() not in (".h",".hpp",".cpp",".cc",".mm"):continue
 try:lines=p.read_text(errors="replace").splitlines()
 except OSError:continue
 for i,line in enumerate(lines):
  if re.search(r"\b(getPOWER|setPOWER|isInterfaceEnabled|setInterfaceEnable|interfaceAdvisoryEnable|IO80211InfraInterface::enable|IO80211SkywalkInterface::enable)\b",line):
   print("SOURCE_REFERENCE=%s:%d:%s"%(p.relative_to(root),i+1,line.strip()))
   found+=1
   if found>=100:print("SOURCE_REFERENCE_LIMIT=100");break
 if found>=100:break
print("STAGE141_POWER_REFERENCE_COUNT=%d"%found)
eb=bodies.get("ENABLE","");db=bodies.get("DISABLE","")
def has(body,pat):return bool(re.search(pat,body))
print("\n--- Source-level path assessment ---")
checks=[
("ENABLE_BASE_FORWARDING",has(eb,r"\b(?:super|IO80211InfraInterface|IO80211SkywalkInterface)::enable\s*\(")),
("DISABLE_BASE_FORWARDING",has(db,r"\b(?:super|IO80211InfraInterface|IO80211SkywalkInterface)::disable\s*\(")),
("ENABLE_APPLE_POWER_FLAG_PATH",has(eb,r"\b(?:setInterfaceEnable|IO80211InfraInterface::enable|IO80211SkywalkInterface::enable)\s*\(")),
("DISABLE_APPLE_POWER_FLAG_PATH",has(db,r"\b(?:setInterfaceEnable|IO80211InfraInterface::disable|IO80211SkywalkInterface::disable)\s*\(")),
("ENABLE_RADIO_HARDWARE_PATH",has(eb,r"\bpowerOn\s*\(")),
("DISABLE_RADIO_HARDWARE_PATH",has(db,r"\bpowerOff\s*\(")),
("ENABLE_PACKET_PATH_PATH",has(eb,r"\bactivatePacketPath\s*\(")),
("DISABLE_PACKET_PATH_PATH",has(db,r"\bquiescePacketPath\s*\("))]
for key,val in checks:print(key+"="+("YES" if val else "NO"))
print("STAGE141_INTERPRETATION=STATIC_SOURCE_ONLY_NO_RUNTIME_OR_HARDWARE_CONCLUSION")
PY
 echo "STAGE141_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE141_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE141 =========="
} >"$REPORT"
echo "===== STAGE141 SUMMARY ====="
grep -aE '^(STAGE141_|SOURCE_FILE=|CLASS_INHERITANCE=|METHOD=|METHOD_STATUS=|CALLS_|RETURNS_SUCCESS_TOKEN=|SOURCE_REFERENCE=|STAGE141_POWER_REFERENCE_COUNT=|ENABLE_BASE_FORWARDING=|DISABLE_BASE_FORWARDING=|ENABLE_APPLE_POWER_FLAG_PATH=|DISABLE_APPLE_POWER_FLAG_PATH=|ENABLE_RADIO_HARDWARE_PATH=|DISABLE_RADIO_HARDWARE_PATH=|ENABLE_PACKET_PATH_PATH=|DISABLE_PACKET_PATH_PATH=)' "$REPORT" || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage141-driver-power-path-source-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage141: publish read-only driver power path source audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE141_UPLOAD_SHA="+actual);print("STAGE141_GITHUB_PATH="+dest);print("STAGE141_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE141_UPLOAD_SHA="+existing);print("STAGE141_GITHUB_PATH="+dest);print("STAGE141_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE141_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE141_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE141_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
