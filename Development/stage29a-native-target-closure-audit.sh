#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
SRC="$DRIVER/src/kext"
OUT="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29a-native-target-closure-audit-$STAMP"
DRYRUN="$STAGE_DIR/make-native-boundary-dry-run.txt"
REPORT="$STAGE_DIR/native-target-closure-report.txt"
FINAL_RC=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ] || [ ! -d "$SRC" ]; then
    echo "ERROR: Stage26 project, Makefile or source tree missing: $PROJECT" >&2
    exit 2
fi

mkdir -p "$STAGE_DIR"

# Continue the single project output.log from the remote Development/output.log.
# No Desktop log is created or used.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then
            cp "$STAGE_DIR/output.log.github-before" "$OUT"
        fi
    fi
fi

{
    echo
    echo "RTL88WiFi Stage29a — native target and shared-object closure audit"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "DRIVER: $DRIVER"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "SCOPE: read-only Makefile dry-run, source-include and plist audit."
    echo "NO_SOURCE_MODIFICATIONS: YES"
    echo "BUILD: NOT RUN (make -n only)"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: NOT ENABLED"
} >> "$OUT"

# -n prints the commands without executing build recipes. -B forces make to
# show the complete dependency/compile plan rather than trusting old timestamps.
cd "$DRIVER"
set +e
make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
MAKE_RC=$?
set -e

if [ "$MAKE_RC" -ne 0 ]; then
    FINAL_RC=10
fi

python3 - "$DRIVER" "$SRC" "$DRYRUN" "$REPORT" "$MAKE_RC" <<'PY'
from pathlib import Path
import plistlib
import re
import shlex
import sys

driver, srcroot, dryrun, report = map(Path, sys.argv[1:5])
make_rc = int(sys.argv[5])
lines = dryrun.read_text(errors="replace").splitlines()
out = []

wcl_objects = [
    "RTW88WCLController.o",
    "RTW88WCLInfraInterface.o",
    "RTW88WCLPCIBackend.o",
    "RTW88WCLSkywalkQueues.o",
    "RTW88WCLSkywalkTxAdapter.o",
    "RTW88WCLSkywalkRxAdapter.o",
]
legacy_objects = [
    "RTL88WiFi.o",
    "RTL88WiFiInterface.o",
    "RTL88WiFiAWDL.o",
    "RTW88AWDLManager.o",
]
shared_candidates = [
    "RTW88IEEE80211.o",
    "RTW88HwOps.o",
    "RTW88WCLRadioBridge.o",
    "RTW88WCLWorkQueue.o",
]
source_candidates = [
    "RTW88IEEE80211.cpp",
    "RTW88HwOps.cpp",
    "RTW88WCLRadioBridge.cpp",
    "RTW88WCLWorkQueue.cpp",
]
legacy_markers = re.compile(
    r"IO80211FamilyLegacy|IO80211Controller|IO80211Interface|"
    r"IO80211InfraProtocol|apple80211_ioctl|apple80211Request|"
    r"RTL88WiFi\.hpp|RTL88WiFiInterface\.hpp"
)

out.append("=== 1. Makefile dry-run status ===")
out.append(f"MAKE_DRY_RUN_EXIT: {make_rc}")
out.append(f"DRY_RUN_LINES: {len(lines)}")
out.append("DRY_RUN_MODE: make -B -n -j1 rtl88wifi (recipes not executed)")
if make_rc != 0:
    out.append("MAKE_DRY_RUN_STATUS: FAIL")
else:
    out.append("MAKE_DRY_RUN_STATUS: PASS")

# Find the actual linker recipe that emits the active legacy kext executable.
link_records = []
for line in lines:
    if "-o" not in line or "RTL88WiFi.kext/Contents/MacOS/RTL88WiFi" not in line:
        continue
    try:
        tokens = shlex.split(line.strip())
    except ValueError:
        continue
    try:
        oi = tokens.index("-o")
        output_path = tokens[oi + 1]
    except (ValueError, IndexError):
        continue
    objects = [Path(t).name for t in tokens[oi + 2:] if t.endswith(".o")]
    link_records.append((output_path, objects, line.strip()))

out.append("\n=== 2. Active kext link boundary ===")
out.append(f"ACTIVE_KEXT_LINK_COMMAND_COUNT: {len(link_records)}")
if link_records:
    # Makefile should produce one active legacy executable in this target.
    output_path, linked_objects, link_line = link_records[-1]
    out.append(f"ACTIVE_KEXT_EXECUTABLE: {output_path}")
    out.append("ACTIVE_LINK_OBJECT_BASENAMES:")
    out.extend("  " + name for name in linked_objects)
    for name in legacy_objects:
        out.append(f"LEGACY_FRONTEND_OBJECT_{name}: {'LINKED' if name in linked_objects else 'NOT_LINKED'}")
    for name in wcl_objects:
        out.append(f"NATIVE_WCL_OBJECT_{name}: {'LINKED' if name in linked_objects else 'NOT_LINKED'}")
    for name in shared_candidates:
        out.append(f"SHARED_CORE_CANDIDATE_{name}: {'IN_ACTIVE_LINK' if name in linked_objects else 'NOT_IN_ACTIVE_LINK'}")
    native_excluded = not any(name in linked_objects for name in wcl_objects)
    legacy_present = "RTL88WiFi.o" in linked_objects and "RTL88WiFiInterface.o" in linked_objects
    out.append(f"LEGACY_TARGET_BOUNDARY_STATUS: {'CONFIRMED' if legacy_present and native_excluded else 'REVIEW_REQUIRED'}")
else:
    linked_objects = []
    out.append("ACTIVE_KEXT_LINK_STATUS: NOT_FOUND")
    out.append("LEGACY_TARGET_BOUNDARY_STATUS: UNKNOWN")

out.append("\n=== 3. Native WCL compile-only object plan ===")
for name in wcl_objects:
    source_stem = name[:-2] + ".cpp"
    compile_lines = [
        line for line in lines
        if source_stem in line and name in line and (" -c " in line or line.lstrip().startswith("c++ "))
    ]
    object_path = driver / "build" / "wcl24h32" / name
    out.append(f"{name}:")
    out.append(f"  SOURCE: {'PRESENT' if (srcroot / 'wcl24h32' / source_stem).is_file() else 'MISSING'}")
    out.append(f"  DRY_RUN_COMPILE_RULE: {'PRESENT' if compile_lines else 'NOT_FOUND'}")
    out.append(f"  EXISTING_OBJECT_FILE: {'PRESENT' if object_path.is_file() else 'ABSENT'}")
    out.append(f"  ACTIVE_LEGACY_LINK: {'YES' if name in linked_objects else 'NO'}")

out.append("\n=== 4. Shared Realtek/core candidate inventory ===")
for source, obj in zip(source_candidates, shared_candidates):
    source_path = srcroot / source
    obj_path = driver / "build" / "airport" / obj
    in_link = obj in linked_objects
    out.append(f"{source}:")
    out.append(f"  SOURCE: {'PRESENT' if source_path.is_file() else 'MISSING'}")
    out.append(f"  CURRENT_AIRPORT_OBJECT: {'PRESENT' if obj_path.is_file() else 'ABSENT'}")
    out.append(f"  CURRENT_LINK_INPUT: {'YES' if in_link else 'NO'}")

out.append("\n=== 5. Direct native/legacy include marker scan ===")
# Scan the four candidate translation units and their quoted local-header
# closure. This is a source triage check, not a complete compiler dependency proof.
for source in source_candidates:
    start = srcroot / source
    out.append(f"\n--- {source} ---")
    if not start.is_file():
        out.append("SOURCE_STATUS: MISSING")
        continue
    pending = [start]
    visited = set()
    findings = []
    while pending:
        p = pending.pop()
        try:
            p = p.resolve()
        except OSError:
            continue
        if p in visited or not p.is_file():
            continue
        visited.add(p)
        try:
            content = p.read_text(errors="replace")
        except OSError:
            continue
        for number, line in enumerate(content.splitlines(), 1):
            if legacy_markers.search(line):
                findings.append(f"{p.relative_to(srcroot.resolve())}:{number}: {line.strip()}")
            match = re.match(r'^\s*#\s*include\s*"([^"]+)"', line)
            if match:
                inc = match.group(1)
                candidates = [p.parent / inc, srcroot / inc]
                for candidate in candidates:
                    try:
                        resolved = candidate.resolve()
                        resolved.relative_to(srcroot.resolve())
                    except (OSError, ValueError):
                        continue
                    if resolved.is_file():
                        pending.append(resolved)
                        break
    out.append(f"LOCAL_INCLUDE_CLOSURE_FILES: {len(visited)}")
    out.append(f"LEGACY_ABI_MARKER_COUNT: {len(findings)}")
    if findings:
        out.extend("  " + item for item in findings[:80])
    else:
        out.append("LEGACY_ABI_MARKER_STATUS: NONE_FOUND_IN_SCANNED_LOCAL_CLOSURE")

out.append("\n=== 6. Existing kext bundle metadata ===")
plist_path = driver / "RTL88WiFi.kext" / "Contents" / "Info.plist"
if not plist_path.is_file():
    plist_path = driver / "build" / "out" / "RTL88WiFi.kext" / "Contents" / "Info.plist"
if plist_path.is_file():
    out.append(f"PLIST_PATH: {plist_path}")
    try:
        plist = plistlib.loads(plist_path.read_bytes())
        out.append(f"CFBundleIdentifier: {plist.get('CFBundleIdentifier', '(missing)')}")
        out.append(f"CFBundleExecutable: {plist.get('CFBundleExecutable', '(missing)')}")
        libraries = plist.get("OSBundleLibraries", {})
        out.append("OSBundleLibraries:")
        for key, value in sorted(libraries.items()):
            out.append(f"  {key}: {value}")
        legacy_dep = "com.apple.iokit.IO80211FamilyLegacy" in libraries
        out.append(f"LEGACY_FRAMEWORK_DEPENDENCY: {'PRESENT' if legacy_dep else 'ABSENT'}")
        personalities = plist.get("IOKitPersonalities", {})
        classes = sorted({
            str(value.get("IOClass"))
            for value in personalities.values()
            if isinstance(value, dict) and value.get("IOClass") is not None
        })
        out.append("PERSONALITY_IOCLASSES: " + (", ".join(classes) if classes else "(none)"))
        out.append(f"NATIVE_CONTROLLER_PERSONALITY: {'PRESENT' if 'RTW88WCLController' in classes else 'ABSENT'}")
    except Exception as exc:
        out.append("PLIST_PARSE_STATUS: FAIL")
        out.append("PLIST_PARSE_ERROR: " + repr(exc))
else:
    out.append("PLIST_STATUS: NOT_FOUND")

out.append("\n=== 7. Native bundle/target presence ===")
makefile = (driver / "Makefile").read_text(errors="replace")
native_target_lines = [
    line.strip() for line in makefile.splitlines()
    if re.match(r"^[A-Za-z0-9_.%-]*(?:native|wcl)[A-Za-z0-9_.%-]*\s*:", line, re.I)
]
out.append(f"NATIVE_OR_WCL_MAKE_TARGET_LINES: {len(native_target_lines)}")
for line in native_target_lines[:80]:
    out.append("  " + line)
native_plists = sorted(driver.glob("**/*WCL*.kext/Contents/Info.plist"))
out.append(f"NATIVE_WCL_KEXT_INFO_PLISTS: {len(native_plists)}")
for path in native_plists[:40]:
    out.append("  " + str(path.relative_to(driver)))

out.append("\n=== 8. Stage29a decision ===")
out.append("The active rtl88wifi target is the legacy bundle target unless the dry-run link evidence above proves otherwise.")
out.append("The native WCL controller/infra/queue/TX/RX objects must remain out of that legacy link.")
out.append("Common Realtek/core objects are only candidates for a future native target; this scan does not certify their complete ABI or runtime safety.")
out.append("A native target needs its own controller personality and Info.plist without IO80211FamilyLegacy, while retaining Apple's native IO80211Family and IOSkywalkFamily dependencies as verified for 24H32.")
out.append("No registration, BSD publication, packet delivery, radio start, install, load, or OpenCore change is authorized by this audit.")
out.append("READINESS_FOR_NATIVE_KEXT_TEST: NOT_READY")
out.append("NEXT_GATE: define and separately dry-run a native 24H32 link target; do not replace the known-good legacy kext yet.")

report.write_text("\n".join(out) + "\n")
print(report.read_text())
PY

{
    echo
    echo "STAGE29A_NATIVE_TARGET_CLOSURE_AUDIT:"
    cat "$REPORT"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "BUILD: NOT RUN (dry-run only)"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "QUEUE_REGISTRATION: NOT ENABLED"
} >> "$OUT"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    API_PATH="repos/$REPO/contents/Development/output.log"
    REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha' 2>/dev/null || true)"
    if [ -n "$REMOTE_SHA" ]; then
        B64="$(base64 < "$OUT" | tr -d '\n')"
        if gh api --method PUT "$API_PATH" \
            -f message="Stage29a native target and shared object closure audit" \
            -f content="$B64" -f sha="$REMOTE_SHA" >/dev/null; then
            echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
        else
            echo "GITHUB_UPLOAD_STATUS: FAILED — gh api update failed"
            FINAL_RC=20
        fi
    else
        echo "GITHUB_UPLOAD_STATUS: FAILED — remote Development/output.log SHA unavailable"
        FINAL_RC=21
    fi
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local project output.log retained"
fi

echo "REPORT: $REPORT"
echo "OUTPUT_LOG: $OUT"
exit "$FINAL_RC"
