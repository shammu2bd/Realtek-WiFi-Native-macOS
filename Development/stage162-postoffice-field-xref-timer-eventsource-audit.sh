#!/bin/bash
# Stage162: full xref and event-source ownership audit for IO80211 PostOffice/workqueue.
# READ ONLY. Preserve existing staged/unstaged worktree; never clean/reset/stash/switch.
# No source edits, builds, signing, install/load/unload, hardware activation, or OC/security changes.
set -euo pipefail
REPO="shammu2bd/Realtek-WiFi-Native-macOS"
BOOTKC="/System/Library/KernelCollections/BootKernelExtensions.kc"
EXPECTED_BOOTKC="cd013c14a7f21dbb8181fb06c44e079de8646b6a674abe21f6e47f42e8979af3"
STAGE161_PATH="Development/Logs/stage161-controller-postoffice-timer-workqueue-lifetime-20261106T215127Z.log"
STAGE161_SHA="cc528f8f4a0ae16134e1ef893856ae3b54abfcdb"
READER_COMMIT="cea28a5297633118177cee6a75e86d8bc57f1960"
READER_SHA="5d31e8a73e5cb175851e7407529456f223683589"
TMPROOT="$(printenv TMPDIR 2>/dev/null || true)"; [[ -n "$TMPROOT" ]] || TMPROOT="/tmp"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: run inside existing project checkout"; exit 2; }
cd "$ROOT"
OS="$(sw_vers -productVersion)"; BUILD="$(sw_vers -buildVersion)"; ARCH="$(uname -m)"
[[ "$OS" == "15.8.1" && "$BUILD" == "24H32" && "$ARCH" == "x86_64" ]] || { echo "ERROR: target mismatch $OS $BUILD $ARCH"; exit 3; }
for c in curl gh python3 shasum otool nm; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing $c"; exit 4; }; done
gh auth status >/dev/null 2>&1 || { echo "ERROR: GitHub CLI authentication required"; exit 5; }
[[ -r "$BOOTKC" ]] || { echo "ERROR: BootKC unavailable"; exit 6; }
BOOT_SHA="$(shasum -a 256 "$BOOTKC" | awk '{print $1}')"
[[ "$BOOT_SHA" == "$EXPECTED_BOOTKC" ]] || { echo "ERROR: BootKC SHA mismatch $BOOT_SHA"; exit 7; }
WORK="$(mktemp -d "$TMPROOT/stage162-work.XXXXXX")"; REPORT="$(mktemp "$TMPROOT/stage162-report.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$REPORT"' EXIT
gh api "repos/$REPO/contents/$STAGE161_PATH?ref=main" > "$WORK/stage161.json"
python3 - "$WORK/stage161.json" "$STAGE161_SHA" <<'PY'
import json,pathlib,sys
o=json.loads(pathlib.Path(sys.argv[1]).read_text())
print("STAGE162_STAGE161_REPORT_SHA="+str(o.get("sha")))
if o.get("sha")!=sys.argv[2]: raise SystemExit("STOP: Stage161 report blob SHA mismatch")
print("STAGE161_REPORT_INTEGRITY=PASS")
PY
curl -fsSLo "$WORK/kcfile.py" "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/$READER_COMMIT/kcfile.py"
python3 - "$WORK/kcfile.py" "$READER_SHA" <<'PY'
import hashlib,pathlib,sys
d=pathlib.Path(sys.argv[1]).read_bytes()
s=hashlib.sha1(b"blob "+str(len(d)).encode()+b"\0"+d).hexdigest()
print("STAGE162_READER_BLOB_SHA="+s)
if s!=sys.argv[2]: raise SystemExit("Pinned KC reader SHA mismatch")
PY
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
{
 echo "========== STAGE162 POSTOFFICE FIELD XREF AND TIMER EVENT-SOURCE AUDIT =========="
 echo "STAGE162_BRANCH=$(git branch --show-current 2>/dev/null || echo UNKNOWN)"
 echo "STAGE162_HEAD=$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
 echo "STAGE162_WORKTREE_STATUS_ENTRIES=$(git status --porcelain | wc -l | tr -d '[:space:]')"
 echo "STAGE162_TARGET=$OS BUILD=$BUILD ARCH=$ARCH"
 echo "STAGE162_BOOTKC_SHA256=$BOOT_SHA"
 echo "STAGE162_STAGE161_REPORT_SHA=$STAGE161_SHA"
 echo "STAGE162_SCOPE=READ_ONLY_POSTOFFICE_CONTROLLER_EXPANSION_XREFS_AND_TIMER_EVENT_SOURCE_QUEUE_OWNERSHIP"
 echo "STAGE162_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE162_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 STAGE162_WORK="$WORK" python3 - "$BOOTKC" "$(command -v otool)" "$(command -v nm)" <<'PY'
import os,re,subprocess,sys
sys.path.insert(0,os.environ["STAGE162_WORK"])
from kcfile import KC
kc=KC(sys.argv[1]); otool=sys.argv[2]; nm=sys.argv[3]
owners=["com.apple.iokit.IO80211Family","com.apple.kernel"]
images={}
for owner in owners:
 path=os.path.join(os.environ["STAGE162_WORK"],owner.replace(".","_")+".macho")
 try:
  kc.carve(owner,path);images[owner]=path
  print("FILESSET_CARVE=PASS OWNER="+owner)
 except Exception as e: print("FILESSET_CARVE=UNAVAILABLE OWNER=%s ERROR=%s"%(owner,str(e)[:240]))
io="com.apple.iokit.IO80211Family"
def own(a):
 try:return kc.owner(a) or "UNATTRIBUTED"
 except Exception:return "UNKNOWN"
def disasm(name,tag,owner,limit=0x3000):
 a=kc.find(name)
 print("\nTARGET_SYMBOL TAG=%s NAME=%s ADDRESS=%s OWNER=%s"%(tag,name,("0x%x"%a) if a else "NOT_FOUND",own(a) if a else "UNKNOWN"))
 if not a or owner not in images:return
 end=kc.next_sym(a) or a+limit
 if end<=a or end>a+limit:end=a+limit
 p=subprocess.run([otool,"-arch","x86_64","-tvV","-p",name,images[owner]],capture_output=True,text=True)
 if p.returncode: print("DISASSEMBLY_FAILED TAG=%s ERROR=%s"%(tag,p.stderr.strip()[:200]));return
 rows=[]
 for line in p.stdout.splitlines():
  m=re.match(r"^\s*(?:0x)?([0-9a-fA-F]{8,}):?\s+(.*)$",line)
  if m and a<=int(m.group(1),16)<end: rows.append(line.strip())
 if not rows: print("METHOD_NOT_VERIFIED TAG=%s"%tag);return
 print("METHOD_TAG=%s SYMBOL=%s ADDRESS=0x%x INSTRUCTIONS=%d"%(tag,name,a,len(rows)))
 for line in rows: print(line)
# Full IO80211Family text scan for every instruction that accesses the controller expansion's PostOffice field.
# Only matching lines and surrounding function context are retained to keep the report small.
if io in images:
 p=subprocess.run([otool,"-arch","x86_64","-tvV",images[io]],capture_output=True,text=True)
 print("\nCONTROLLER_EXPANSION_FULL_TEXT_SCAN_RETURN_CODE=%d"%p.returncode)
 if p.returncode==0:
  lines=p.stdout.splitlines(); hits=[]
  for i,line in enumerate(lines):
   if re.search(r"(?i)(?:0x)?b08(?:\(|,|\s)",line):
    hits.append(i)
  print("CONTROLLER_EXPANSION_B08_XREF_COUNT=%d"%len(hits))
  emitted=set()
  for h in hits:
   lo=max(0,h-8);hi=min(len(lines),h+7)
   if any(x in emitted for x in range(lo,hi)):continue
   for x in range(lo,hi): print("B08_XREF_CONTEXT "+lines[x]);emitted.add(x)
  for field in ("b10","b00","af8","b18"):
   q=[i for i,line in enumerate(lines) if re.search(r"(?i)(?:0x)?"+field+r"(?:\(|,|\s)",line)]
   print("CONTROLLER_EXPANSION_NEARBY_FIELD_%s_XREF_COUNT=%d"%(field.upper(),len(q)))
 else: print("CONTROLLER_EXPANSION_FULL_TEXT_SCAN_ERROR="+p.stderr.strip()[:500])
# Workqueue and timer-source vtable/method inventory.
for cls in ("IO80211WorkQueue","IO80211TimerSource","IO80211PostOffice"):
 try:
  methods=kc.methods(cls);print("\nCLASS_METHOD_COUNT NAME=%s COUNT=%d"%(cls,len(methods)))
  for a,n in methods:
   if any(k.lower() in n.lower() for k in ("init","free","addEventSource","removeEventSource","workQueue","allocWithParams","start","cancel","enableAllInterrupts","disableAllInterrupts")):
    print("CLASS_RELEVANT_SYMBOL CLASS=%s ADDRESS=0x%x OWNER=%s NAME=%s"%(cls,a,own(a),n))
 except Exception as e:print("CLASS_METHOD_SCAN_FAILED NAME=%s ERROR=%s"%(cls,str(e)[:200]))
# Timer source passes queue into a workqueue/event-source operation; decode available named target APIs.
for n,tag in (
 ("__ZN18IO80211TimerSource4initE26IO80211TimerSourcePriorityP8OSObjectP16IO80211WorkQueuePFvS2_PS_E","TIMER_SOURCE_INIT"),
 ("__ZN18IO80211TimerSource4freeEv","TIMER_SOURCE_FREE"),
 ("__ZN17IO80211PostOffice14initWithParamsEP16IO80211WorkQueue","POSTOFFICE_INIT"),
 ("__ZN17IO80211PostOffice4freeEv","POSTOFFICE_FREE"),
 ("__ZN17IO80211Controller4stopEP9IOService","CONTROLLER_STOP"),
 ("__ZN17IO80211Controller4freeEv","CONTROLLER_FREE"),
): disasm(n,tag,io,0x9000)
# IOWorkLoop/IOEventSource implementations establish whether queue/event source retains each other.
for n,tag in (
 ("__ZN9IOWorkLoop14addEventSourceEP12IOEventSource","WORKLOOP_ADD_EVENT_SOURCE"),
 ("__ZN9IOWorkLoop17removeEventSourceEP12IOEventSource","WORKLOOP_REMOVE_EVENT_SOURCE"),
 ("__ZN13IOEventSource11setWorkLoopEP10IOWorkLoop","EVENT_SOURCE_SET_WORKLOOP"),
 ("__ZN13IOEventSource4freeEv","EVENT_SOURCE_FREE"),
):
 owner=own(kc.find(n)) if kc.find(n) else "UNKNOWN"
 disasm(n,tag,owner,0x5000)
print("\nSTAGE162_INTERPRETATION=DO_NOT_INFER_POSTOFFICE_OWNER_OR_QUEUE_RETENTION_FROM_FIELD_STORAGE; REQUIRE_COMPLETE_XREF_AND_EVENT_SOURCE_LIFETIME_CHAIN")
PY
 echo "STAGE162_SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN"
 echo "STAGE162_HARDWARE=NOT_RUN OPENCORE=UNCHANGED EFI=UNCHANGED SIP=UNCHANGED NVRAM=UNCHANGED REBOOT=NOT_RUN"
 echo "========== END STAGE162 =========="
} >"$REPORT"
echo "===== STAGE162 SUMMARY ====="
grep -aE '^(STAGE162_|STAGE161_REPORT_INTEGRITY=|FILESSET_CARVE=|CONTROLLER_EXPANSION_|CLASS_METHOD_COUNT |CLASS_RELEVANT_SYMBOL |TARGET_SYMBOL |METHOD_TAG=|METHOD_NOT_VERIFIED |DISASSEMBLY_FAILED |STAGE162_INTERPRETATION=)' "$REPORT" | head -700 || true
python3 - "$REPORT" "$STAMP" "$REPO" <<'PY'
import base64,hashlib,json,pathlib,subprocess,sys,tempfile,time
report=pathlib.Path(sys.argv[1]);stamp,repo=sys.argv[2:]
data=report.read_bytes();dest="Development/Logs/stage162-postoffice-field-xref-timer-eventsource-"+stamp+".log"
expected=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
payload={"message":"Stage162: publish read-only PostOffice field xref and timer event-source audit","branch":"main","content":base64.b64encode(data).decode("ascii")}
for attempt in range(1,4):
 with tempfile.NamedTemporaryFile(mode="w",suffix=".json") as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run(["gh","api","--method","PUT","repos/"+repo+"/contents/"+dest,"--input",f.name],capture_output=True,text=True)
 if r.returncode==0:
  try:actual=json.loads(r.stdout).get("content",{}).get("sha")
  except Exception:actual=None
  if actual==expected:
   print("STAGE162_UPLOAD_SHA="+actual);print("STAGE162_GITHUB_PATH="+dest);print("STAGE162_UPLOAD=PASS");break
 last=r.stderr.strip() or r.stdout.strip()
 chk=subprocess.run(["gh","api","repos/"+repo+"/contents/"+dest+"?ref=main"],capture_output=True,text=True)
 if chk.returncode==0:
  try:existing=json.loads(chk.stdout).get("sha")
  except Exception:existing=None
  if existing==expected:
   print("STAGE162_UPLOAD_SHA="+existing);print("STAGE162_GITHUB_PATH="+dest);print("STAGE162_UPLOAD=PASS_RECOVERED_AFTER_TIMEOUT");break
  if existing: print("STAGE162_UPLOAD_CONFLICT="+str(existing));raise SystemExit(8)
 if attempt<3:time.sleep(attempt*3)
else: print("STAGE162_UPLOAD=FAILED");print(last);raise SystemExit(9)
PY
