#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
NEW_PROJECT="$HOME/Downloads/$NEW_NAME"
ARCHIVE="$HOME/Downloads/$NEW_NAME.zip"
OUT="$NEW_PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$NEW_PROJECT/build/stage26-resume-$STAMP"

# RESUME ONLY: this operates solely on the already-created new project.
# It does not read, copy, build, or write anything in the previous Stage14 tree.
if [ ! -d "$NEW_PROJECT" ]; then
    echo "ERROR: the Stage26 new project directory was not created: $NEW_PROJECT" >&2
    exit 2
fi
if [ ! -f "$NEW_PROJECT/BUILD_NAME.txt" ] || [ ! -f "$NEW_PROJECT/driver/RTL88WiFi/Makefile" ]; then
    echo "ERROR: the partial new project is incomplete; refusing to guess or recopy." >&2
    exit 3
fi
if [ -e "$ARCHIVE" ]; then
    echo "ERROR: archive already exists; refusing to overwrite: $ARCHIVE" >&2
    exit 4
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "ERROR: zip utility not found." >&2
    exit 5
fi

mkdir -p "$STAGE_DIR"

# Start from the latest GitHub report when gh is authenticated, so the new
# project log does not roll back newer remote audit notes copied after Stage25.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh api "repos/$REPO/contents/Development/output.log" --jq '.content' 2>/dev/null | \
        python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
        > "$STAGE_DIR/output.log.github-before" 2>/dev/null; then
        if [ -s "$STAGE_DIR/output.log.github-before" ]; then
            cp "$STAGE_DIR/output.log.github-before" "$OUT"
        fi
    fi
fi

for f in RTW88WCLController.cpp RTW88WCLController.hpp RTW88WCLPCIBackend.cpp; do
    cp -p "$NEW_PROJECT/driver/RTL88WiFi/src/kext/wcl24h32/$f" "$STAGE_DIR/$f.before"
done
if [ -f "$OUT" ]; then cp -p "$OUT" "$STAGE_DIR/output.log.before"; fi

python3 - "$NEW_PROJECT" "$STAGE_DIR" <<'PY'
from pathlib import Path
import difflib
import hashlib
import sys

project, stage_dir = map(Path, sys.argv[1:])
src = project / "driver/RTL88WiFi/src/kext/wcl24h32"
ctrl_path = src / "RTW88WCLController.cpp"
ctrlh_path = src / "RTW88WCLController.hpp"
pci_path = src / "RTW88WCLPCIBackend.cpp"
for p in (ctrl_path, ctrlh_path, pci_path):
    if not p.is_file():
        raise SystemExit("ERROR: required new-tree source missing: " + str(p))

ctrl = ctrl_path.read_text()
ctrlh = ctrlh_path.read_text()
pci = pci_path.read_text()
ctrl_before, ctrlh_before, pci_before = ctrl, ctrlh, pci

# Prove that the failed first Stage26 attempt left the original Stage25 patch
# intact and that the free() cleanup guard is already present exactly once.
checks = {
    "status-returning controller cleanup": "IOReturn RTW88WCLController::releaseNativeResources()",
    "fence error propagation": "return fenceStatus;",
    "close error propagation": "return closeStatus;",
    "controller free quarantine marker": "quarantining controller and retaining workloop/resources",
    "PCI partial-enable rollback": "rollbackCommand & 0x0004U",
    "PCI backend free readback": "refusing to free DMA resources; backend quarantined",
}
for label, needle in checks.items():
    target = pci if label.startswith("PCI") else ctrl
    if needle not in target:
        raise SystemExit("ERROR: new-tree Stage25 preflight failed: " + label)
if "IOReturn releaseNativeResources();" not in ctrlh:
    raise SystemExit("ERROR: status-returning cleanup declaration missing")
existing_cleanup_guards = ctrl.count("const IOReturn cleanupStatus = releaseNativeResources();")
if existing_cleanup_guards != 1:
    raise SystemExit(
        "ERROR: expected only the existing Stage25 free() cleanup guard before resume; found "
        + str(existing_cleanup_guards) + "; no source files changed"
    )

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

# Correct count: free() already contains one guard from Stage25; this patch
# adds one in start(fail) and one in stop(), for a total of three.
if ctrl.count("const IOReturn cleanupStatus = releaseNativeResources();") != 3:
    raise SystemExit("ERROR: expected 3 cleanup guards (start, stop, free); no source files changed")
if ctrl.count("start-failure cleanup incomplete") != 1:
    raise SystemExit("ERROR: start cleanup guard missing")
if ctrl.count("stop cleanup incomplete") != 1:
    raise SystemExit("ERROR: stop cleanup guard missing")
if "super::stop(provider);" not in ctrl:
    raise SystemExit("ERROR: superclass stop calls disappeared unexpectedly")

# Verify method-level guard placement, not merely the presence of the strings.
def method_body(text, sig):
    pos = text.find(sig)
    if pos < 0:
        raise SystemExit("ERROR: method not found: " + sig)
    opening = text.find("{", pos)
    depth = 0
    state = "normal"
    i = opening
    while i < len(text):
        ch = text[i]
        nxt = text[i+1] if i+1 < len(text) else ""
        if state == "normal":
            if ch == "/" and nxt == "/": state = "line"; i += 2; continue
            if ch == "/" and nxt == "*": state = "block"; i += 2; continue
            if ch == '"': state = "string"; i += 1; continue
            if ch == "'": state = "char"; i += 1; continue
            if ch == "{": depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0: return text[opening:i+1]
        elif state == "line":
            if ch == "\n": state = "normal"
        elif state == "block":
            if ch == "*" and nxt == "/": state = "normal"; i += 2; continue
        elif state in ("string", "char"):
            if ch == chr(92): i += 2; continue
            if (state == "string" and ch == '"') or (state == "char" and ch == "'"): state = "normal"
        i += 1
    raise SystemExit("ERROR: unmatched braces while checking " + sig)

start_body = method_body(ctrl, "bool RTW88WCLController::start(")
stop_body = method_body(ctrl, "void RTW88WCLController::stop(")
free_body = method_body(ctrl, "void RTW88WCLController::free()")
if "const IOReturn cleanupStatus = releaseNativeResources();" not in start_body or "start-failure cleanup incomplete" not in start_body:
    raise SystemExit("ERROR: start fail path status guard not inside start()")
if "const IOReturn cleanupStatus = releaseNativeResources();" not in stop_body or "stop cleanup incomplete" not in stop_body:
    raise SystemExit("ERROR: stop status guard not inside stop()")
if "const IOReturn cleanupStatus = releaseNativeResources();" not in free_body or "quarantining controller" not in free_body:
    raise SystemExit("ERROR: free() Stage25 guard not preserved")

# Save diff and patched source only after every guard has passed.
patch = "".join(difflib.unified_diff(
    ctrl_before.splitlines(True), ctrl.splitlines(True),
    fromfile="a/RTW88WCLController.cpp", tofile="b/RTW88WCLController.cpp"
))
(stage_dir / "RTW88WCLController.cpp.patch").write_text(patch)
ctrl_path.write_text(ctrl)

(stage_dir / "verification.txt").write_text(
    "PASS: Stage25 source preflight passed in the new project tree\\n"
    "PASS: start(fail) propagates releaseNativeResources() failure by retaining native resources\\n"
    "PASS: stop() defers superclass stop when cleanup fails\\n"
    "PASS: free() Stage25 quarantine guard retained\\n"
    "PASS: exact cleanup guard count is 3 (start, stop, free)\\n"
    "PASS: PCI rollback, bus-master readback and cleanup status propagation retained\\n"
    "LIMIT: compile, install, load, queue registration and hardware test not performed\\n"
)
(stage_dir / "source-sha256.txt").write_text(
    "RTW88WCLController.cpp " + hashlib.sha256(ctrl_path.read_bytes()).hexdigest() + "\\n" +
    "RTW88WCLController.hpp " + hashlib.sha256(ctrlh_path.read_bytes()).hexdigest() + "\\n" +
    "RTW88WCLPCIBackend.cpp " + hashlib.sha256(pci_path.read_bytes()).hexdigest() + "\\n"
)
print((stage_dir / "verification.txt").read_text())
PY

# Retarget historical shell runners inside the NEW project only.
python3 - "$NEW_PROJECT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
old = "RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
new = root.name
changed = 0
for p in root.rglob("*"):
    if not p.is_file() or p.suffix not in {".sh", ".md", ".txt", ".py"}:
        continue
    try:
        data = p.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    if old in data:
        p.write_text(data.replace(old, new))
        changed += 1
print("HISTORICAL_PATHS_RETARGETED_IN_NEW_TREE: " + str(changed))
PY

cat > "$NEW_PROJECT/BUILD_NAME.txt" <<EOF
BUILD_NAME=$NEW_NAME
TARGET=macOS Sequoia 15.8.1 (24H32), x86_64
STAGE26=source tree prepared; start/stop cleanup callers guarded
SOURCE_BASE=Stage25-patched local source snapshot
STATUS=experimental; queue registration disabled; do not install or load
KNOWN_GOOD_DRIVER=preserve the user's already-working older rtl88wifi.kext
EOF

# Create source manifest, excluding all generated build-stage files.
python3 - "$NEW_PROJECT" <<'PY'
from pathlib import Path
import hashlib
import sys
root = Path(sys.argv[1])
manifest = []
for p in sorted(root.rglob("*")):
    if not p.is_file():
        continue
    rel = p.relative_to(root)
    if "build" in rel.parts or p.suffix in {".kext", ".dSYM"}:
        continue
    if rel.as_posix() == "SOURCE_PACKAGE_MANIFEST.txt":
        continue
    manifest.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {rel.as_posix()}")
(root / "SOURCE_PACKAGE_MANIFEST.txt").write_text("\n".join(manifest) + "\n")
print("SOURCE_FILES_IN_MANIFEST: " + str(len(manifest)))
PY

{
    echo
    echo "STAGE26 INITIAL RUN — SAFE PREFLIGHT ABORT"
    echo "The initial Stage26 generator copied the source into the new project and created BUILD_NAME.txt, then aborted before any C++ write because it expected two cleanupStatus declarations."
    echo "Correct expected count: three (the existing Stage25 free() guard plus the new start(fail) and stop() guards)."
    echo "The failed attempt did not write C++ sources, create the manifest, create the ZIP, or run a build."
    echo "The resume runner below acts only on the new project directory and does not use the old Stage14 path."
    echo
    echo "RTL88WiFi Stage26 — resumed fresh source preparation"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "NEW_PROJECT: $NEW_PROJECT"
    echo "BUILD_NAME: $NEW_NAME"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    cat "$STAGE_DIR/verification.txt"
    echo "SOURCE_PACKAGE_MANIFEST: $NEW_PROJECT/SOURCE_PACKAGE_MANIFEST.txt"
    echo "SOURCE_FILES_IN_MANIFEST: $(wc -l < "$NEW_PROJECT/SOURCE_PACKAGE_MANIFEST.txt" | tr -d ' ')"
    echo "OLD_STAGE14_DIRECTORY: NOT USED BY THIS RESUME RUNNER"
    echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
} >> "$OUT"

# Archive the project source, docs, scripts and manifest. Exclude generated
# build folders, .kext bundles, dSYM and the archive itself.
(
    cd "$HOME/Downloads"
    COPYFILE_DISABLE=1 zip -qr "$ARCHIVE" "$NEW_NAME" \
        -x "$NEW_NAME/build/*" "$NEW_NAME/driver/RTL88WiFi/build/*" \
           "*.kext/*" "*.dSYM/*" "*/.DS_Store"
)

ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
ARCHIVE_SIZE="$(stat -f '%z' "$ARCHIVE" 2>/dev/null || wc -c < "$ARCHIVE" | tr -d ' ')"
{
    echo "FULL_SOURCE_ZIP: $ARCHIVE"
    echo "ARCHIVE_SIZE_BYTES: $ARCHIVE_SIZE"
    echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
    echo "ARCHIVE_FORMAT: ZIP"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "QUEUE_REGISTRATION: STILL DISABLED"
    echo "DATAPATH_ACTIVATION: BLOCKED_PENDING_NEW_TREE_COMPILE_AND_ABI_DEPENDENCY_REVIEW"
} >> "$OUT"

upload_file() {
    local local_file="$1" repo_path="$2" message="$3"
    local api_path="repos/$REPO/contents/$repo_path"
    local sha json_file
    sha="$(gh api "$api_path" --jq '.sha' 2>/dev/null || true)"
    json_file="$STAGE_DIR/upload-payload.json"
    python3 - "$local_file" "$message" "$sha" "$json_file" <<'PY'
import base64, json, pathlib, sys
local_file, message, sha, out = sys.argv[1:]
payload = {"message": message, "content": base64.b64encode(pathlib.Path(local_file).read_bytes()).decode("ascii")}
if sha:
    payload["sha"] = sha
pathlib.Path(out).write_text(json.dumps(payload))
PY
    gh api --method PUT "$api_path" --input "$json_file" >/dev/null
}

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if upload_file "$ARCHIVE" "Development/$(basename "$ARCHIVE")" "Publish Stage 26 fresh full source ZIP"; then
        echo "ARCHIVE_GITHUB_UPLOAD: SUCCESS"
        echo "ARCHIVE_GITHUB_URL: https://github.com/$REPO/blob/main/Development/$(basename "$ARCHIVE")"
    else
        echo "ARCHIVE_GITHUB_UPLOAD: FAILED — local ZIP preserved at $ARCHIVE"
    fi
    if upload_file "$OUT" "Development/output.log" "Stage 26 fresh source project ZIP prepared"; then
        echo "OUTPUT_LOG_GITHUB_UPLOAD: SUCCESS"
        echo "OUTPUT_LOG_GITHUB_URL: https://github.com/$REPO/blob/main/Development/output.log"
    else
        echo "OUTPUT_LOG_GITHUB_UPLOAD: FAILED — local output.log preserved"
    fi
else
    echo "GITHUB_UPLOAD: GH_CLI_NOT_AUTHENTICATED — ZIP and log remain local."
fi

echo "NEW_PROJECT: $NEW_PROJECT"
echo "FULL_SOURCE_ZIP: $ARCHIVE"
echo "ARCHIVE_SIZE_BYTES: $ARCHIVE_SIZE"
echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
echo "NEXT_BUILD_ROOT: $NEW_PROJECT/driver/RTL88WiFi"
echo "REPORT: $OUT"
