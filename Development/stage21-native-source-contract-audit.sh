#!/bin/bash
set -u

REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/output.log"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''

if [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(cd "$PROJECT_DIR" && pwd -P)"
elif [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$(pwd -P)"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi

if [[ -z "$PROJECT" ]]; then
  echo 'Cannot locate the Stage26 project. Run from its project root or set PROJECT_DIR.'
  exit 2
fi

DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext/wcl24h32"
MAKEFILE="$DRIVER/Makefile"
NATIVE="$DRIVER/build/out/RTL88WiFiNative.kext"
LEGACY="$DRIVER/RTL88WiFi.kext"
LOG="$PROJECT/output.log"
STAGE="$PROJECT/build/stage21-native-source-contract-audit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE" || exit 2

command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }

gh api "$API" > "$STAGE/remote-log.json" || exit 2
python3 - "$STAGE/remote-log.json" "$LOG" <<'PY'
import base64, json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
data = base64.b64decode(doc.get("content", ""))
text = data.decode("utf-8", errors="replace")
required = ["NATIVE_ACTUAL_BUILD: PASS", "STAGE29D_STATIC_AUDIT: PASS", "STAGE29G_PREFLIGHT: COMPLETE"]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit("Canonical output.log is missing prerequisites: " + ", ".join(missing))
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || { echo 'Canonical output.log validation failed.'; exit 2; }

if [[ ! -d "$SRC" ]]; then
  echo "Native WCL source directory not found: $SRC"
  exit 2
fi

python3 - "$PROJECT" "$DRIVER" "$SRC" "$MAKEFILE" "$NATIVE" "$LEGACY" "$STAGE" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, re, sys

project, driver, src, makefile, native, legacy, stage = map(Path, sys.argv[1:])
stage.mkdir(parents=True, exist_ok=True)
report = [
    "RTL88WiFi Stage21 — native source-to-ABI contract audit",
    "PURPOSE: read-only correlation of current Stage26 WCL sources with the saved 24H32 ABI findings",
    "SOURCE_TREE: " + str(src),
    "SOURCE_CHANGES: NONE",
    "BUILD: NOT RUN",
    "INSTALL: NOT RUN",
    "LOAD: NOT RUN",
    "OPENCORE_CHANGE: NONE",
    "QUEUE_REGISTRATION: NOT ENABLED BY THIS AUDIT",
    "RX_TX_CALLBACKS: NOT ENABLED BY THIS AUDIT",
    "RADIO_START: NOT RUN",
    "BSD_PUBLICATION: NOT RUN",
]

targets = re.compile(
    r"(Controller|InfraInterface|SkywalkQueues|SkywalkRxAdapter|SkywalkTxAdapter|PacketView|InterfaceABI|PoolOptions)",
    re.I
)
files = sorted(p for p in src.rglob("*") if p.is_file() and p.suffix in {".cpp", ".hpp"} and targets.search(p.name))
report.append("")
report.append("=== CURRENT WCL SOURCE INVENTORY ===")
report.append("RELEVANT_SOURCE_COUNT: " + str(len(files)))
for p in files:
    digest = hashlib.sha256(p.read_bytes()).hexdigest()
    report.append("SOURCE: {} | SHA256={}".format(p.relative_to(project), digest))

if not files:
    report.append("SOURCE_INVENTORY_STATUS: FAIL — no matching native WCL source files found")

def extract_context(path: Path, pattern: str, before: int = 2, after: int = 16):
    lines = path.read_text(errors="replace").splitlines()
    rx = re.compile(pattern)
    out = []
    for i, line in enumerate(lines):
        if rx.search(line):
            lo, hi = max(0, i-before), min(len(lines), i+after+1)
            out.append((lo+1, lines[lo:hi]))
    return out

report.append("")
report.append("=== CONTROLLER / INFRA START FENCES ===")
start_checks = [
    ("RTW88WCLController.cpp", r"RTW88WCLController::start\s*\("),
    ("RTW88WCLInfraInterface.cpp", r"RTW88WCLInfraInterface::start\s*\("),
]
for filename, pattern in start_checks:
    found = False
    for p in files:
        if p.name != filename:
            continue
        contexts = extract_context(p, pattern, before=3, after=70)
        if contexts:
            found = True
            for line_no, block in contexts[:2]:
                report.append("FUNCTION_CONTEXT: {}:{}-{}".format(p.relative_to(project), line_no, line_no+len(block)-1))
                report.extend("  {:04d}: {}".format(line_no+i, row) for i, row in enumerate(block))
                joined = "\n".join(block)
                report.append("  CONTAINS_RETURN_FALSE: " + ("YES" if re.search(r"\breturn\s+false\s*;", joined) else "NO"))
                report.append("  CONTAINS_GOTO_FAIL: " + ("YES" if re.search(r"\bgoto\s+fail\s*;", joined) else "NO"))
    report.append("FUNCTION_FOUND_{}: {}".format(filename, "YES" if found else "NO"))

report.append("")
report.append("=== REGISTRATION / QUEUE CALL-SITE INVENTORY ===")
call_rx = re.compile(
    r"(registerInfraEthernetInterface|registerEthernetInterface|registerNetworkInterface|"
    r"deregisterEthernetInterface|deregisterNetworkInterface|enqueuePackets|"
    r"requestEnqueue|requestDequeue|refillRxRing|completePackets|"
    r"activatePacketPath|quiescePacketPath|\.enable\s*\(|->enable\s*\()"
)
matches = []
for p in files:
    lines = p.read_text(errors="replace").splitlines()
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("*"):
            continue
        if call_rx.search(line):
            matches.append("{}:{}: {}".format(p.relative_to(project), i, stripped))
report.append("RELEVANT_CALLSITE_COUNT: " + str(len(matches)))
if matches:
    report.extend("CALLSITE: " + m for m in matches[:160])
    if len(matches) > 160:
        report.append("CALLSITE_OUTPUT_TRUNCATED: " + str(len(matches)-160))
else:
    report.append("No matching direct call-site lines found; inspect declarations and indirect callback registration separately.")

report.append("")
report.append("=== MAKEFILE NATIVE TARGET INVENTORY ===")
if makefile.is_file():
    mk = makefile.read_text(errors="replace").splitlines()
    idxs = [i for i, line in enumerate(mk) if re.search(r"rtl88wifi-native|RTL88WiFiNative|WCL24H32|AIRPORT_WCL", line, re.I)]
    report.append("MAKEFILE_MATCH_COUNT: " + str(len(idxs)))
    for i in idxs[:100]:
        report.append("MAKEFILE:{}: {}".format(i+1, mk[i].strip()))
else:
    report.append("MAKEFILE_STATUS: MISSING")

def load_plist(bundle: Path):
    info = bundle / "Contents" / "Info.plist"
    if not info.is_file():
        return None, info
    try:
        return plistlib.loads(info.read_bytes()), info
    except Exception as exc:
        return {"__parse_error__": str(exc)}, info

report.append("")
report.append("=== BUILT BUNDLE IDENTITY / FRAMEWORK DEPENDENCIES ===")
native_info, native_plist = load_plist(native)
legacy_info, legacy_plist = load_plist(legacy)
if native_info is None:
    report.append("NATIVE_BUNDLE_STATUS: MISSING at " + str(native))
else:
    report.append("NATIVE_PLIST: " + str(native_plist))
    report.append("NATIVE_BUNDLE_ID: " + str(native_info.get("CFBundleIdentifier", "<missing>")))
    report.append("NATIVE_EXECUTABLE: " + str(native_info.get("CFBundleExecutable", "<missing>")))
    libs = native_info.get("OSBundleLibraries", {})
    for key in sorted(libs):
        report.append("NATIVE_LIBRARY: {} = {}".format(key, libs[key]))
    report.append("NATIVE_HAS_IO80211FAMILY: " + ("YES" if "com.apple.iokit.IO80211Family" in libs else "NO"))
    report.append("NATIVE_HAS_IOSKYWALK: " + ("YES" if "com.apple.iokit.IOSkywalkFamily" in libs else "NO"))
    report.append("NATIVE_HAS_LEGACY_FAMILY: " + ("YES" if "com.apple.iokit.IO80211FamilyLegacy" in libs else "NO"))
if legacy_info is None:
    report.append("LEGACY_BUNDLE_STATUS: MISSING at " + str(legacy))
else:
    report.append("LEGACY_BUNDLE_ID: " + str(legacy_info.get("CFBundleIdentifier", "<missing>")))
if native_info and legacy_info:
    report.append("BUNDLE_ID_COLLISION: " + ("YES — test configuration must select exactly one" if native_info.get("CFBundleIdentifier") == legacy_info.get("CFBundleIdentifier") else "NO"))

binary = native / "Contents" / "MacOS" / (native_info or {}).get("CFBundleExecutable", "RTL88WiFiNative")
if binary.is_file():
    actual = hashlib.sha256(binary.read_bytes()).hexdigest()
    expected = "475d2ec90dad4f83aaafdf9ee17a9ffca8c7804951266cf7c41d02e58945cbc9"
    report.append("NATIVE_EXECUTABLE_SHA256: " + actual)
    report.append("STAGE29C_V5_BINARY_HASH_MATCH: " + ("PASS" if actual == expected else "MISMATCH — review source/build provenance"))
else:
    report.append("NATIVE_EXECUTABLE_STATUS: MISSING at " + str(binary))

report.extend([
    "",
    "=== AUDIT INTERPRETATION ===",
    "This audit is a source and packaging inventory, not a C++ semantic proof.",
    "Indirect callbacks, vtable calls, macro expansions and assembly semantics require manual correlation.",
    "Do not treat a call-site count or a plist dependency list as ABI or ownership validation.",
    "STAGE21_STATUS: REVIEW_REQUIRED — source-to-ABI manual review must continue.",
    "INSTALL: NOT RUN",
    "LOAD: NOT RUN",
    "OPENCORE_CHANGE: NONE",
    "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED",
])
(stage / "stage21-report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
print("\n".join(report))
PY
RC=$?

{
  echo
  echo '========== STAGE21 NATIVE SOURCE-TO-ABI CONTRACT AUDIT =========='
  echo "STAGE_DIR: $STAGE"
  cat "$STAGE/stage21-report.txt" 2>/dev/null || true
  echo "STAGE21_ANALYSIS_EXIT: $RC"
  echo 'SOURCE_CHANGES: NONE'
  echo 'BUILD: NOT RUN'
  echo 'INSTALL: NOT RUN'
  echo 'LOAD: NOT RUN'
  echo 'OPENCORE_CHANGE: NONE'
  echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'
} >> "$LOG"

SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$LOG" "$SHA" "$STAGE/payload.json" <<'PY'
import base64, json, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({
    "message": "Stage21 native source-to-ABI contract audit",
    "content": base64.b64encode(data).decode(),
    "sha": sys.argv[2]
}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT" && "$PUT" == "$READ" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }

echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
