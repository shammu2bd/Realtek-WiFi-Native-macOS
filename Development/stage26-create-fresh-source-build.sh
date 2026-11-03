#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"

# The old directory is used exactly once as the source snapshot. All future
# build and compile work moves to NEW_PROJECT; the old directory is not built.
SOURCE_PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
NEW_PROJECT="$HOME/Downloads/$NEW_NAME"
ARCHIVE="$HOME/Downloads/$NEW_NAME.zip"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$NEW_PROJECT/build/stage26-fresh-source-$STAMP"
OUT="$NEW_PROJECT/output.log"

if [ ! -d "$SOURCE_PROJECT" ]; then
    echo "ERROR: one-time source snapshot not found: $SOURCE_PROJECT" >&2
    exit 2
fi
if [ -e "$NEW_PROJECT" ] || [ -e "$ARCHIVE" ]; then
    echo "ERROR: new project or archive already exists; refusing to overwrite:" >&2
    echo "$NEW_PROJECT" >&2
    echo "$ARCHIVE" >&2
    exit 3
fi
if [ ! -f "$SOURCE_PROJECT/driver/RTL88WiFi/Makefile" ]; then
    echo "ERROR: source project Makefile missing" >&2
    exit 4
fi
if ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: rsync is required (normally available on macOS)" >&2
    exit 5
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "ERROR: zip utility is required (normally available on macOS)" >&2
    exit 5
fi

mkdir -p "$NEW_PROJECT"
rsync -a \
    --exclude='/.git/***' \
    --exclude='/build/***' \
    --exclude='/driver/RTL88WiFi/build/***' \
    --exclude='*.kext' \
    --exclude='*.dSYM' \
    --exclude='.DS_Store' \
    "$SOURCE_PROJECT/" "$NEW_PROJECT/"

if [ ! -f "$NEW_PROJECT/driver/RTL88WiFi/Makefile" ]; then
    echo "ERROR: copied project is incomplete; Makefile not found" >&2
    exit 6
fi

mkdir -p "$STAGE_DIR"

cat > "$NEW_PROJECT/BUILD_NAME.txt" <<EOF
BUILD_NAME=$NEW_NAME
TARGET=macOS Sequoia 15.8.1 (24H32), x86_64
SOURCE_LINEAGE=Stage14 packet/segment ABI source with locally verified Stage25 shutdown patch
STAGE26=cleanly rebased source tree with guarded start/stop cleanup callers
STATUS=experimental; queue registration disabled; do not install or load
KNOWN_GOOD_DRIVER=preserve the user's already-working older rtl88wifi.kext
EOF

# Carry Stage25 forward, then close its two remaining error-propagation gaps:
# start(fail) and stop() must not proceed with the superclass stop if native
# resource teardown could not complete.
python3 - "$NEW_PROJECT" "$SOURCE_PROJECT" "$STAGE_DIR" <<'PY'
from pathlib import Path
import difflib
import hashlib
import sys

project, source_project, stage_dir = map(Path, sys.argv[1:])
src_root = project / "driver/RTL88WiFi/src/kext/wcl24h32"
ctrl_path = src_root / "RTW88WCLController.cpp"
ctrlh_path = src_root / "RTW88WCLController.hpp"
pci_path = src_root / "RTW88WCLPCIBackend.cpp"
for p in (ctrl_path, ctrlh_path, pci_path):
    if not p.is_file():
        raise SystemExit("ERROR: expected WCL source missing: " + str(p))

ctrl = ctrl_path.read_text()
ctrlh = ctrlh_path.read_text()
pci = pci_path.read_text()
original = (ctrl, ctrlh, pci)

# Confirm this is the local source tree on which Stage25 was actually applied.
required = {
    "controller status-returning cleanup": "IOReturn RTW88WCLController::releaseNativeResources()",
    "controller cleanup status propagation": "return fenceStatus;",
    "controller quarantine on free": "quarantining controller and retaining workloop/resources",
    "PCI partial-enable rollback": "rollbackCommand & 0x0004U",
    "PCI backend free readback": "refusing to free DMA resources; backend quarantined",
}
for label, needle in required.items():
    target = pci if label.startswith("PCI") else ctrl
    if needle not in target:
        raise SystemExit("ERROR: Stage25 preflight failed: " + label)

fail_old = """fail:
    releaseNativeResources();
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
    return false;"""
fail_new = """fail:
    {
        const IOReturn cleanupStatus = releaseNativeResources();
        if (cleanupStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: start-failure cleanup incomplete (0x%08x); retaining native resources\\n",
                  cleanupStatus);
            return false;
        }
    }
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
    return false;"""

stop_old = """void RTW88WCLController::stop(IOService *provider)
{
    releaseNativeResources();
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
}"""
stop_new = """void RTW88WCLController::stop(IOService *provider)
{
    const IOReturn cleanupStatus = releaseNativeResources();
    if (cleanupStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: stop cleanup incomplete (0x%08x); deferring superclass stop and retaining resources\\n",
              cleanupStatus);
        return;
    }
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
}"""

if ctrl.count(fail_old) != 1:
    raise SystemExit("ERROR: start() fail-label shape mismatch; no source files changed")
if ctrl.count(stop_old) != 1:
    raise SystemExit("ERROR: stop() call-site shape mismatch; no source files changed")
ctrl = ctrl.replace(fail_old, fail_new, 1)
ctrl = ctrl.replace(stop_old, stop_new, 1)

# Verify all Stage25 changes and both additional caller checks before writing.
if ctrl.count("const IOReturn cleanupStatus = releaseNativeResources();") != 2:
    raise SystemExit("ERROR: expected guarded cleanup result in start(fail) and stop()")
if ctrl.count("start-failure cleanup incomplete") != 1:
    raise SystemExit("ERROR: start failure cleanup guard missing")
if ctrl.count("stop cleanup incomplete") != 1:
    raise SystemExit("ERROR: stop cleanup guard missing")
if "IOReturn releaseNativeResources();" not in ctrlh:
    raise SystemExit("ERROR: cleanup declaration is not status-returning")
if "return fenceStatus;" not in ctrl or "return closeStatus;" not in ctrl:
    raise SystemExit("ERROR: Stage25 status propagation changed")
if "rollbackCommand & 0x0004U" not in pci or "command & 0x0004U" not in pci[pci.find("void RTW88WCLPCIBackend::free()"):]:
    raise SystemExit("ERROR: Stage25 PCI rollback/free fence missing")

ctrl_path.write_text(ctrl)
(stage_dir / "RTW88WCLController.cpp.patch").write_text("".join(difflib.unified_diff(
    original[0].splitlines(True), ctrl.splitlines(True),
    fromfile="a/RTW88WCLController.cpp", tofile="b/RTW88WCLController.cpp"
)))
(stage_dir / "verification.txt").write_text(
    "PASS: new project copied from local Stage25-patched source snapshot\\n"
    "PASS: start(fail) checks releaseNativeResources() status before superclass stop\\n"
    "PASS: stop() checks releaseNativeResources() status before superclass stop\\n"
    "PASS: Stage25 PCI rollback, final-free bus-master readback and controller quarantine retained\\n"
    "LIMIT: no compile, install, load, queue registration or hardware test performed\\n"
)
(stage_dir / "source-sha256.txt").write_text(
    "RTW88WCLController.cpp " + hashlib.sha256(ctrl_path.read_bytes()).hexdigest() + "\\n" +
    "RTW88WCLController.hpp " + hashlib.sha256(ctrlh_path.read_bytes()).hexdigest() + "\\n" +
    "RTW88WCLPCIBackend.cpp " + hashlib.sha256(pci_path.read_bytes()).hexdigest() + "\\n"
)
print((stage_dir / "verification.txt").read_text())
PY

# Repoint historical stage runners inside this new copy to the new directory.
# The original source directory is not modified.
python3 - "$NEW_PROJECT" "$(basename "$SOURCE_PROJECT")" "$NEW_NAME" <<'PY'
from pathlib import Path
import sys
root, old_name, new_name = map(Path, sys.argv[1:])
count = 0
for p in root.rglob("*"):
    if not p.is_file() or p.suffix not in {".sh", ".md", ".txt", ".py"}:
        continue
    try:
        s = p.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    if str(old_name) in s:
        p.write_text(s.replace(str(old_name), str(new_name)))
        count += 1
print("HISTORICAL_RUNNER_PATH_FILES_UPDATED: " + str(count))
PY

# Build a deterministic manifest for source files; omit generated build products.
python3 - "$NEW_PROJECT" "$STAGE_DIR" <<'PY'
from pathlib import Path
import hashlib
import sys
root, stage = map(Path, sys.argv[1:])
manifest = []
for p in sorted(root.rglob("*")):
    if not p.is_file():
        continue
    rel = p.relative_to(root)
    if rel.parts[0] == "build" or "build" in rel.parts or p.suffix in {".kext", ".dSYM"}:
        continue
    if rel.as_posix() == "SOURCE_PACKAGE_MANIFEST.txt":
        continue
    digest = hashlib.sha256(p.read_bytes()).hexdigest()
    manifest.append(f"{digest}  {rel.as_posix()}")
(root / "SOURCE_PACKAGE_MANIFEST.txt").write_text("\n".join(manifest) + "\n")
print("SOURCE_FILES_IN_MANIFEST: " + str(len(manifest)))
PY

# The ZIP includes complete source, headers, Makefiles, scripts, bundled
# SDK ABI headers, documentation and manifest. Generated build output and
# kext bundles are intentionally omitted.
(
    cd "$HOME/Downloads"
    COPYFILE_DISABLE=1 zip -qr "$ARCHIVE" "$NEW_NAME" \
        -x "$NEW_NAME/build/*" \
           "$NEW_NAME/driver/RTL88WiFi/build/*" \
           "*.kext/*" "*.dSYM/*" "*/.DS_Store"
)

ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
ARCHIVE_SIZE="$(stat -f '%z' "$ARCHIVE" 2>/dev/null || wc -c < "$ARCHIVE" | tr -d ' ')"

{
    echo
    echo "RTL88WiFi Stage 26 — fresh source project and full source archive"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "HOST: $(sw_vers -productVersion 2>/dev/null || echo unknown) / $(sw_vers -buildVersion 2>/dev/null || echo unknown)"
    echo "ARCH: $(uname -m)"
    echo "SOURCE_SNAPSHOT_USED_ONCE: $SOURCE_PROJECT"
    echo "NEW_PROJECT: $NEW_PROJECT"
    echo "NEW_BUILD_NAME: $NEW_NAME"
    echo "STAGE_DIR: $STAGE_DIR"
    cat "$STAGE_DIR/verification.txt"
    echo "SOURCE_PACKAGE_MANIFEST: $NEW_PROJECT/SOURCE_PACKAGE_MANIFEST.txt"
    echo "SOURCE_FILES_IN_MANIFEST: $(wc -l < "$NEW_PROJECT/SOURCE_PACKAGE_MANIFEST.txt" | tr -d ' ')"
    echo "FULL_SOURCE_ARCHIVE: $ARCHIVE"
    echo "ARCHIVE_GITHUB_URL: https://github.com/$REPO/blob/main/Development/$(basename "$ARCHIVE")"
    echo "ARCHIVE_SIZE_BYTES: $ARCHIVE_SIZE"
    echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
    echo "ARCHIVE_FORMAT: ZIP"
    echo "GENERATED_BUILD_OUTPUT: EXCLUDED"
    echo "INSTALLED_WORKING_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    echo "OLD_STAGE14_DIRECTORY: SOURCE SNAPSHOT ONLY; DO NOT USE FOR FURTHER BUILDS"
    echo "BUILD: NOT RUN IN THIS STAGE"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_NEW_TREE_COMPILE_AND_REMAINING_ABI_DEPENDENCY_REVIEW"
} >> "$OUT"

upload_github_file() {
    local local_file="$1"
    local repo_path="$2"
    local message="$3"
    local api_path="repos/$REPO/contents/$repo_path"
    local current_sha json_file
    current_sha="$(gh api "$api_path" --jq '.sha' 2>/dev/null || true)"
    json_file="$STAGE_DIR/github-upload.json"
    python3 - "$local_file" "$message" "$current_sha" "$json_file" <<'PY'
import base64, json, pathlib, sys
local_file, message, sha, output = sys.argv[1:]
payload = {
    "message": message,
    "content": base64.b64encode(pathlib.Path(local_file).read_bytes()).decode("ascii")
}
if sha:
    payload["sha"] = sha
pathlib.Path(output).write_text(json.dumps(payload))
PY
    gh api --method PUT "$api_path" --input "$json_file" >/dev/null
}

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if upload_github_file "$ARCHIVE" "Development/$(basename "$ARCHIVE")" "Publish fresh Stage 26 full source archive"; then
        echo "ARCHIVE_GITHUB_UPLOAD: SUCCESS"
        echo "ARCHIVE_GITHUB_URL: https://github.com/$REPO/blob/main/Development/$(basename "$ARCHIVE")"
    else
        echo "ARCHIVE_GITHUB_UPLOAD: FAILED — archive remains at $ARCHIVE"
    fi
    if upload_github_file "$OUT" "Development/output.log" "Stage 26 fresh source project and archive"; then
        echo "OUTPUT_LOG_GITHUB_UPLOAD: SUCCESS — https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "OUTPUT_LOG_GITHUB_UPLOAD: FAILED — local report remains at $OUT"
    fi
else
    echo "GITHUB_UPLOAD: GH_CLI_NOT_AUTHENTICATED — archive and output.log remain local."
fi

echo "NEW_PROJECT: $NEW_PROJECT"
echo "FULL_SOURCE_ARCHIVE: $ARCHIVE"
echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
echo "NEXT_BUILD_ROOT: $NEW_PROJECT/driver/RTL88WiFi"
echo "REPORT: $OUT"
