#!/bin/bash
# Stage147: establish the driver's most-derived postMessage override and forwarding chain.
# READ ONLY. No checkout/source/index changes, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in gh python3 shasum; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
REPORT="$(mktemp "$TMPROOT/stage147-report.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE147 DRIVER POSTMESSAGE OVERRIDE AUDIT =========="
 echo "STAGE147_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE147_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE147_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE147_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE147_SCOPE=READ_ONLY_MOST_DERIVED_OVERRIDE_AND_CONTROLLER_FORWARDING"
 echo "STAGE147_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE147_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 python3 - "$ROOT" <<'PY'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1])
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
specs=[
 ("RTW88WCLInfraInterface.hpp",[
  (r"\bclass\s+RTW88WCLInfraInterface\b",30),
  (r"\bpostMessage\s*\(",12),
  (r"\bRTW88WCLController\b",8)
 ]),
 ("RTW88WCLInfraInterface.cpp",[
  (r"RTW88WCLInfraInterface::postMessage\s*\(",70),
  (r"_controller\s*->\s*postMessage\s*\(",10),
 ]),
 ("RTW88WCL24H32ABI.hpp",[
  (r"\bclass\s+IO80211Controller\b",12),
  (r"\bpostMessage\s*\(",10),
  (r"\bgetPOWER\s*\(",8),
  (r"\bsetPOWER\s*\(",8)
 ]),
 ("RTW88WCL24H32InterfaceABI.hpp",[
  (r"\bclass\s+IO80211InfraProtocol\b",18),
  (r"\bclass\s+IO80211InfraInterface\b",18),
  (r"\bpostMessage\s*\(",8)
 ]),
 ("RTW88WCLController.hpp",[
  (r"\bclass\s+RTW88WCLController\b",24),
  (r"\bpostMessage\s*\(",10),
  (r"\bgetPOWER\s*\(",8),
  (r"\bsetPOWER\s*\(",8)
 ]),
 ("RTW88WCLController.cpp",[
  (r"RTW88WCLController::postMessage\s*\(",70),
  (r"RTW88WCLController::getPOWER\s*\(",20),
  (r"RTW88WCLController::setPOWER\s*\(",20)
 ])
]
def emit_range(lines,start,end,label):
 print("SOURCE_CONTEXT_BEGIN="+label)
 for i in range(start,max(start,min(end,len(lines)))):
  print("%05d %s"%(i+1,lines[i]))
 print("SOURCE_CONTEXT_END="+label)
for filename,patterns in specs:
 p=base/filename
 if not p.exists():
  print("SOURCE_FILE=%s STATUS=NOT_FOUND"%(p.relative_to(root)));continue
 data=p.read_bytes()
 lines=data.decode("utf-8","replace").splitlines()
 print("\\nSOURCE_FILE=%s SHA256=%s BYTES=%d"%(p.relative_to(root),hashlib.sha256(data).hexdigest(),len(data)))
 ranges=[]
 for pattern,radius in patterns:
  matches=[i for i,line in enumerate(lines) if re.search(pattern,line)]
  print("SOURCE_PATTERN file=%s regex=%s MATCH_COUNT=%d"%(filename,pattern,len(matches)))
  for i in matches[:6]:
   ranges.append((max(0,i- min(8,radius//3)),min(len(lines),i+radius),pattern,i))
 # Merge overlapping ranges, preserving all matching declarations/definitions.
 ranges.sort()
 merged=[]
 for a,b,pat,i in ranges:
  if merged and a<=merged[-1][1]:
   merged[-1][1]=max(merged[-1][1],b)
   merged[-1][2].append((pat,i))
  else: merged.append([a,b,[(pat,i)]])
 for n,(a,b,matches) in enumerate(merged,1):
  tags=";".join("%s@%d"%(x,i+1) for x,i in matches)
  emit_range(lines,a,b,"%s#%d[%s]"%(filename,n,tags))
print("\\n--- Static conclusion checks ---")
infra_h=(base/"RTW88WCLInfraInterface.hpp").read_text(errors="replace") if (base/"RTW88WCLInfraInterface.hpp").exists() else ""
infra_cpp=(base/"RTW88WCLInfraInterface.cpp").read_text(errors="replace") if (base/"RTW88WCLInfraInterface.cpp").exists() else ""
controller_h=(base/"RTW88WCLController.hpp").read_text(errors="replace") if (base/"RTW88WCLController.hpp").exists() else ""
controller_cpp=(base/"RTW88WCLController.cpp").read_text(errors="replace") if (base/"RTW88WCLController.cpp").exists() else ""
print("DRIVER_INFRA_POSTMESSAGE_DECLARED=%s"%("YES" if re.search(r"\bpostMessage\s*\(",infra_h) else "NO"))
print("DRIVER_INFRA_POSTMESSAGE_DEFINED=%s"%("YES" if re.search(r"RTW88WCLInfraInterface::postMessage\s*\(",infra_cpp) else "NO"))
print("DRIVER_INFRA_POSTMESSAGE_FORWARDS_CONTROLLER=%s"%("YES" if re.search(r"_controller\s*->\s*postMessage\s*\(",infra_cpp) else "NO"))
print("DRIVER_CONTROLLER_POSTMESSAGE_DECLARED=%s"%("YES" if re.search(r"\bpostMessage\s*\(",controller_h) else "NO"))
print("DRIVER_CONTROLLER_POSTMESSAGE_DEFINED=%s"%("YES" if re.search(r"RTW88WCLController::postMessage\s*\(",controller_cpp) else "NO"))
print("DRIVER_CONTROLLER_POWER_GET_DEFINED=%s"%("YES" if re.search(r"RTW88WCLController::getPOWER\s*\(",controller_cpp) else "NO"))
print("DRIVER_CONTROLLER_POWER_SET_DEFINED=%s"%("YES" if re.search(r"RTW88WCLController::setPOWER\s*\(",controller_cpp) else "NO"))
print("STAGE147_INTERPRETATION=SOURCE_DECLARATION_AND_FORWARDING_ONLY; NO_COMPILED_VTABLE_OR_RUNTIME_PROOF")
PY
 echo "STAGE147_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE147_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE147 =========="
} >"$REPORT"
echo "===== STAGE147 SUMMARY ====="
grep -aE '^(STAGE147_|SOURCE_FILE=|SOURCE_PATTERN |DRIVER_INFRA_POSTMESSAGE|DRIVER_CONTROLLER_POSTMESSAGE|DRIVER_CONTROLLER_POWER_|STAGE147_INTERPRETATION=)' "$REPORT" | head -180 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage147-driver-postmessage-override-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage147: publish read-only driver postMessage override audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE147_UPLOAD_SHA="+actual);print("STAGE147_GITHUB_PATH="+dest);print("STAGE147_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE147_UPLOAD_SHA="+existing);print("STAGE147_GITHUB_PATH="+dest);print("STAGE147_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE147_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE147_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3: time.sleep(attempt*3)
else:
 print("STAGE147_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
