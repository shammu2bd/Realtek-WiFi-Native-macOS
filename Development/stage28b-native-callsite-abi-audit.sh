#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage28b-native-callsite-abi-audit-$STAMP"
REPORT="$STAGE_DIR/native-callsite-abi-report.txt"
FINAL_RC=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project or Makefile missing: $PROJECT" >&2
    exit 2
fi
mkdir -p "$STAGE_DIR"

# Preserve latest remote development log before appending.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then cp "$STAGE_DIR/output.log.github-before" "$OUT"; fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage28b — native/legacy call-site and class ABI boundary audit"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "SCOPE: source context and plist inspection only; no source modifications, build, install or load."
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
} >> "$OUT"

python3 - "$DRIVER" "$SRC" "$REPORT" <<'PY'
from pathlib import Path
import plistlib
import re
import sys

driver, srcroot, report = map(Path, sys.argv[1:])
out = []
files = [
    "wcl24h32/RTW88WCLController.hpp",
    "wcl24h32/RTW88WCLController.cpp",
    "wcl24h32/RTW88WCLInfraInterface.hpp",
    "wcl24h32/RTW88WCLInfraInterface.cpp",
    "wcl24h32/RTW88WCLPCIBackend.hpp",
    "wcl24h32/RTW88WCLPCIBackend.cpp",
    "wcl24h32/RTW88WCLSkywalkQueues.hpp",
    "wcl24h32/RTW88WCLSkywalkQueues.cpp",
    "wcl24h32/RTW88WCLSkywalkTxAdapter.hpp",
    "wcl24h32/RTW88WCLSkywalkTxAdapter.cpp",
    "wcl24h32/RTW88WCLSkywalkRxAdapter.hpp",
    "wcl24h32/RTW88WCLSkywalkRxAdapter.cpp",
    "RTW88IEEE80211.hpp",
    "RTW88IEEE80211.cpp",
    "RTW88WCLRadioBridge.hpp",
    "RTW88WCLRadioBridge.cpp",
    "RTW88WCLWorkQueue.hpp",
    "RTW88WCLWorkQueue.cpp",
    "RTW88HwOps.hpp",
    "RTW88HwOps.cpp",
]
targets = [
    "RTW88IEEE80211",
    "RTW88WCLRadioBridge",
    "RTW88WCLWorkQueue",
    "RTW88HwOps",
    "createAirport",
    "outputPacketWithCompletion",
    "IO80211Controller",
    "IO80211InfraInterface",
    "IOSkywalk",
    "IOPCI",
]
out.append("=== 1. Native and legacy source file inventory ===")
for rel in files:
    p = srcroot / rel
    out.append(f"{rel}: {'PRESENT' if p.is_file() else 'MISSING'}")

out.append("\n=== 2. Native/legacy cross-boundary call-site contexts ===")
hit_count = 0
for rel in files:
    p = srcroot / rel
    if not p.is_file():
        continue
    lines = p.read_text(errors="replace").splitlines()
    hits = [i for i, line in enumerate(lines) if any(t in line for t in targets)]
    if not hits:
        continue
    out.append(f"\n--- {rel} ---")
    merged = []
    for i in hits:
        start, end = max(0, i-5), min(len(lines), i+9)
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    for start, end in merged:
        out.append(f"CONTEXT_LINES {start+1}-{end}:")
        out.extend(f"{i+1}: {lines[i]}" for i in range(start, end))
        hit_count += 1
        if hit_count >= 160:
            out.append("[context cap reached]")
            break
    if hit_count >= 160:
        break

out.append("\n=== 3. Class declarations and inheritance boundaries ===")
class_rx = re.compile(
    r"^\s*(?:class|struct)\s+(?:[A-Za-z_]\w*\s*:\s*)?[A-Za-z_]\w*(?:\s*:\s*[^{;]+)?\s*$"
)
for rel in files:
    p = srcroot / rel
    if not p.is_file() or not rel.endswith((".hpp", ".h")):
        continue
    lines = p.read_text(errors="replace").splitlines()
    hits = [i for i, line in enumerate(lines) if re.search(r"\bclass\s+(RTW88IEEE80211|RTW88WCLRadioBridge|RTW88WCLWorkQueue|RTW88HwOps|RTW88WCLController|RTW88WCLInfraInterface)\b", line)]
    for i in hits:
        start, end = max(0, i-2), min(len(lines), i+36)
        out.append(f"\n--- {rel}:{i+1} ---")
        out.extend(f"{j+1}: {lines[j]}" for j in range(start, end))

out.append("\n=== 4. Native target bundle metadata ===")
plist_paths = [
    driver / "RTL88WiFi.kext/Contents/Info.plist",
    driver / "build/out/RTL88WiFi.kext/Contents/Info.plist",
    driver / "rtw88.kext/Contents/Info.plist",
]
seen = set()
for p in plist_paths:
    if p in seen or not p.is_file():
        continue
    seen.add(p)
    out.append(f"\n--- {p.relative_to(driver)} ---")
    try:
        d = plistlib.loads(p.read_bytes())
        out.append("CFBundleIdentifier: " + str(d.get("CFBundleIdentifier", "(missing)")))
        out.append("CFBundleExecutable: " + str(d.get("CFBundleExecutable", "(missing)")))
        out.append("CFBundlePackageType: " + str(d.get("CFBundlePackageType", "(missing)")))
        out.append("OSBundleLibraries:")
        for k, v in sorted(d.get("OSBundleLibraries", {}).items()):
            out.append(f"  {k}: {v}")
        for key in ("IOKitPersonalities", "OSBundleRequired", "LSMinimumSystemVersion"):
            if key in d:
                out.append(f"{key}: {d[key]}")
    except Exception as e:
        out.append("PLIST_PARSE_ERROR: " + repr(e))

out.append("\n=== 5. Makefile native/legacy target separation ===")
mk = (driver / "Makefile").read_text(errors="replace").splitlines()
for a, b in ((325, 375), (384, 462)):
    out.append(f"\nMAKEFILE_LINES {a}-{min(b,len(mk))}:")
    out.extend(f"{i+1}: {mk[i]}" for i in range(a-1, min(b, len(mk))))

out.append("\n=== 6. Build object and link-boundary reminders ===")
out.append("The Stage28a symbol inventory found controller references satisfied by WCL PCI, Skywalk queue and RX adapter objects, plus airport/RTW88IEEE80211.o.")
out.append("The Stage28a inventory found InfraInterface references satisfied by airport/RTW88WCLRadioBridge.o and airport/RTW88WCLWorkQueue.o.")
out.append("The Stage28a inventory found PCI backend references satisfied by airport/RTW88HwOps.o and compat/rtw88_compat.o.")
out.append("The Stage28a inventory found TX adapter references satisfied by airport/RTW88IEEE80211.o.")
out.append("A no-obvious-symbol-collision result is not proof that two translation units share a compatible class/vtable ABI.")
out.append("The native target must not inherit legacy IO80211 class definitions by accident.")
out.append("LIMIT: this report is source-context evidence; it does not prove runtime ABI safety, complete framework symbol resolution, or functional packet I/O.")

report.write_text("\n".join(out) + "\n")
print(report.read_text())
PY

{
    echo
    echo "STAGE28B_NATIVE_CALLSITE_ABI_AUDIT:"
    cat "$REPORT"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
} >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    API_PATH="repos/$REPO/contents/Development/output.log"
    REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null || true)"
    B64="$(base64 < "$OUT" | tr -d '\n')"
    if [ -n "$REMOTE_SHA" ]; then
        gh api --method PUT "$API_PATH" \
            -f message="Stage28b native and legacy call-site ABI audit" \
            -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null
        echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote output.log SHA unavailable"
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local report retained"
fi

echo "REPORT: $REPORT"
echo "OUTPUT_LOG: $OUT"
exit "$FINAL_RC"
