#!/bin/bash
# Stage154: inspect the exact native controller subclass for IO80211WorkQueue overrides.
# READ ONLY. No source/index/branch/worktree edits, build, signing, install, load/unload, hardware, OC/EFI/SIP/NVRAM, or reboot.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE153_PATH="Development/Logs/stage153-postoffice-delivery-20261106T213227Z.log"
STAGE153_SHA="e06c60ad5bb1e0fd8377fd8c51c338419e6b6b2d"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"
[[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in gh python3 shasum; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage154-work.XXXXXX")"
REPORT="$(mktemp "$TMPROOT/stage154-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE153_PATH?ref=main" > "$WORK/stage153.json"
python3 - "$WORK/stage153.json" "$STAGE153_SHA" <<'PY'
import json,pathlib,sys
obj=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE154_STAGE153_REPORT_SHA="+str(obj.get("sha")))
if obj.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage153 report blob SHA mismatch")
print("STAGE153_REPORT_INTEGRITY=PASS")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE154 NATIVE CONTROLLER WORKQUEUE OVERRIDE AUDIT =========="
 echo "STAGE154_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE154_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE154_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE154_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE154_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE154_STAGE153_REPORT_SHA=$STAGE153_SHA"
 echo "STAGE154_SCOPE=READ_ONLY_VERIFY_RTW88WCLCONTROLLER_CREATEWORKQUEUE_GETWORKQUEUE_OVERRIDE_AND_WORKQUEUE_OWNERSHIP"
 echo "STAGE154_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE154_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 python3 - "$ROOT" <<'PY'
import hashlib,pathlib,re,sys
root=pathlib.Path(sys.argv[1])
base=root/"driver/RTL88WiFi/src/kext/wcl24h32"
files=["RTW88WCLController.hpp","RTW88WCLController.cpp","RTW88WCL24H32ABI.hpp"]
loaded={}
for name in files:
 p=base/name
 if not p.is_file():
  print("SOURCE_FILE_MISSING="+str(p))
  continue
 data=p.read_bytes()
 loaded[name]=data.decode("utf-8","replace").splitlines()
 print("SOURCE_FILE=%s SHA256=%s BYTES=%d"%(name,hashlib.sha256(data).hexdigest(),len(data)))
# Identify the exact subclass declaration and capture its method declarations.
hpp=loaded.get("RTW88WCLController.hpp",[])
cpp=loaded.get("RTW88WCLController.cpp",[])
abi=loaded.get("RTW88WCL24H32ABI.hpp",[])
class_start=next((i for i,x in enumerate(hpp) if re.search(r"class\s+RTW88WCLController\b",x)),None)
class_lines=[]
if class_start is not None:
 depth=0; entered=False
 for i in range(class_start,len(hpp)):
  line=hpp[i]
  depth += line.count("{")-line.count("}")
  if "{" in line: entered=True
  class_lines.append((i+1,line))
  if entered and depth==0: break
 print("NATIVE_CLASS_DECLARATION_LINE=%d"%(class_start+1))
 for no,line in class_lines:
  if no==class_start+1 or re.search(r"createWorkQueue|getWorkQueue|createWorkLoop|getWorkLoop|IO80211WorkQueue|IOWorkLoop|class RTW88WCLController",line):
   print("NATIVE_CLASS_MATCH=%s:%d:%s"%(files[0],no,line.strip()))
else: print("NATIVE_CLASS_DECLARATION=NOT_FOUND")
methods=("createWorkQueue","getWorkQueue","createWorkLoop","getWorkLoop")
for method in methods:
 decl=[(i+1,x.strip()) for i,x in enumerate(hpp) if re.search(r"\b"+method+r"\s*\(",x)]
 defs=[(i+1,x.strip()) for i,x in enumerate(cpp) if re.search(r"\bRTW88WCLController::"+method+r"\s*\(",x)]
 print("METHOD_DECLARATION_COUNT %s=%d"%(method,len(decl)))
 for no,line in decl: print("METHOD_DECLARATION %s:%d:%s"%(files[0],no,line))
 print("METHOD_DEFINITION_COUNT %s=%d"%(method,len(defs)))
 for no,line in defs: print("METHOD_DEFINITION %s:%d:%s"%(files[1],no,line))
# Include ABI declarations for these four methods and the workqueue type.
for no,line in enumerate(abi,1):
 if re.search(r"createWorkQueue|getWorkQueue|createWorkLoop|getWorkLoop|IO80211WorkQueue",line):
  print("ABI_METHOD_OR_TYPE %s:%d:%s"%(files[2],no,line.strip()))
# Search all native WCL source files for workqueue creation/ownership and controller method calls.
all_paths=sorted(p for p in base.rglob("*") if p.is_file() and p.suffix in (".h",".hpp",".cpp",".cc",".c"))
matches=[]
for p in all_paths:
 try: lines=p.read_text(errors="replace").splitlines()
 except Exception: continue
 for no,line in enumerate(lines,1):
  if re.search(r"IO80211WorkQueue|createWorkQueue|getWorkQueue|RTW88WCLController::createWork|RTW88WCLController::getWork",line):
   matches.append((p.relative_to(root).as_posix(),no,line.strip()))
print("NATIVE_WORKQUEUE_SOURCE_MATCH_COUNT=%d"%len(matches))
for p,no,line in matches[:180]:
 print("NATIVE_WORKQUEUE_MATCH %s:%d:%s"%(p,no,line))
# Explicitly compare the unrelated IONetworkController workloop hooks with IO80211WorkQueue hooks.
loop_defs=[(i+1,x.strip()) for i,x in enumerate(cpp) if re.search(r"RTW88WCLController::(createWorkLoop|getWorkLoop)\s*\(",x)]
queue_defs=[(i+1,x.strip()) for i,x in enumerate(cpp) if re.search(r"RTW88WCLController::(createWorkQueue|getWorkQueue)\s*\(",x)]
queue_decl=[(i+1,x.strip()) for i,x in enumerate(hpp) if re.search(r"\b(createWorkQueue|getWorkQueue)\s*\(",x)]
if class_start is not None and not queue_defs and not queue_decl:
 print("STAGE154_SOURCE_RESULT=CONTROLLER_SUBCLASS_HAS_NO_WORKQUEUE_OVERRIDE_OR_DECLARATION")
 print("STAGE154_INHERITANCE_RESULT=INHERITS_IO80211CONTROLLER_WORKQUEUE_IMPLEMENTATIONS")
elif queue_defs or queue_decl:
 print("STAGE154_SOURCE_RESULT=WORKQUEUE_OVERRIDE_OR_DECLARATION_PRESENT_REVIEW_SIGNATURE_AND_IMPLEMENTATION")
else:
 print("STAGE154_SOURCE_RESULT=INCOMPLETE_SOURCE_EVIDENCE")
if loop_defs:
 print("STAGE154_WORKLOOP_HOOKS_PRESENT=YES")
else: print("STAGE154_WORKLOOP_HOOKS_PRESENT=NO")
if not queue_defs and loop_defs:
 print("STAGE154_DISTINCTION=IOWorkLoop_HOOKS_DO_NOT_IMPLEMENT_IO80211WorkQueue_HOOKS")
print("STAGE154_INTERPRETATION=SOURCE_DECLARATION_AND_DEFINITION_AUDIT_ONLY; NO_BUILD_OR_RUNTIME_PROOF")
PY
 echo "STAGE154_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE154_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE154 =========="
} >"$REPORT"
echo "===== STAGE154 SUMMARY ====="
grep -aE '^(STAGE154_|STAGE153_REPORT_INTEGRITY=|SOURCE_FILE=|NATIVE_CLASS_|METHOD_DECLARATION_COUNT|METHOD_DECLARATION |METHOD_DEFINITION_COUNT|METHOD_DEFINITION |ABI_METHOD_OR_TYPE |NATIVE_WORKQUEUE_SOURCE_MATCH_COUNT=|NATIVE_WORKQUEUE_MATCH |STAGE154_SOURCE_RESULT=|STAGE154_INHERITANCE_RESULT=|STAGE154_WORKLOOP_HOOKS_PRESENT=|STAGE154_DISTINCTION=|STAGE154_INTERPRETATION=)' "$REPORT" | head -260 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes()
dest="Development/Logs/stage154-controller-workqueue-audit-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage154: publish read-only native controller workqueue override audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
last=""
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try: actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception: actual=None
  if actual==expected:
   print("STAGE154_UPLOAD_SHA="+actual);print("STAGE154_GITHUB_PATH="+dest);print("STAGE154_UPLOAD=PASS");break
  last="GitHub blob SHA mismatch: "+str(actual)
 else:last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try: existing=json.loads(chk.stdout).get("sha")
  except Exception: existing=None
  if existing==expected:
   print("STAGE154_UPLOAD_SHA="+existing);print("STAGE154_GITHUB_PATH="+dest);print("STAGE154_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  print("STAGE154_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 print("STAGE154_UPLOAD_ATTEMPT_%d=FAILED"%attempt)
 if attempt<3:time.sleep(attempt*3)
else:
 print("STAGE154_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
