#!/bin/bash
set -u
set -o pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
API_PATH="repos/$REPO/contents/Development/output.log"
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"

fail() { echo "ERROR: $*" >&2; exit 2; }

find_project() {
    local candidate="${PROJECT_DIR:-}"
    local found=""

    if [[ -n "$candidate" ]]; then
        if [[ -f "$candidate/driver/RTL88WiFi/Makefile" ]]; then
            (cd "$candidate" && pwd -P); return 0
        fi
        if [[ -f "$candidate/Makefile" && -d "$candidate/src/kext" ]]; then
            (cd "$candidate/../.." && pwd -P); return 0
        fi
        echo "WARNING: Ignoring invalid PROJECT_DIR: $candidate" >&2
    fi

    if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$PWD" && pwd -P); return 0
    fi
    if [[ -f "$PWD/Makefile" && -d "$PWD/src/kext" ]]; then
        (cd "$PWD/../.." && pwd -P); return 0
    fi

    local expected="$HOME/Downloads/$PROJECT_NAME"
    if [[ -f "$expected/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$expected" && pwd -P); return 0
    fi

    if [[ -d "$HOME/Downloads" ]]; then
        found="$(find "$HOME/Downloads" -maxdepth 12 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$found" ]]; then
        (cd "$(dirname "$found")/../.." && pwd -P); return 0
    fi
    fail "Cannot find Stage26 project under ~/Downloads. Set PROJECT_DIR to the project root."
}

run_capture() {
    local name="$1"; shift
    if "$@" > "$STAGE_DIR/$name.txt" 2>&1; then
        echo "TOOL_STATUS $name: PASS"
        return 0
    else
        local rc=$?
        echo "TOOL_STATUS $name: WARN (exit $rc)"
        return "$rc"
    fi
}

PROJECT="$(find_project)" || exit 2
DRIVER="$PROJECT/driver/RTL88WiFi"
BUNDLE="$DRIVER/build/out/RTL88WiFiNative.kext"
INFO="$BUNDLE/Contents/Info.plist"
BIN="$BUNDLE/Contents/MacOS/RTL88WiFiNative"
LOG="$PROJECT/output.log"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage29d-native-mach-o-audit-$STAMP"
REMOTE_JSON="$STAGE_DIR/github-output-log-before.json"
BASE_LOG="$STAGE_DIR/output-log-before.txt"
PAYLOAD="$STAGE_DIR/github-output-log-payload.json"
RESPONSE="$STAGE_DIR/github-upload-response.json"

mkdir -p "$STAGE_DIR" || fail "Cannot create Stage29d audit directory."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."

# Restore the canonical Development log before appending; never start a new
# log or overwrite remote history from an older local copy.
gh api "$API_PATH" > "$REMOTE_JSON" || fail "Cannot read GitHub Development/output.log."
python3 - "$REMOTE_JSON" "$BASE_LOG" <<'PY'
import base64, json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
data = base64.b64decode(doc.get("content", ""), validate=False)
if len(data) < 500 or b"Stage29c-v5" not in data:
    raise SystemExit("Remote output.log is too small or lacks Stage29c-v5; refusing to append.")
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || fail "Could not validate the current remote log."
cp "$BASE_LOG" "$LOG" || fail "Could not initialize project output.log from GitHub."

[[ -f "$INFO" ]] || fail "Native bundle Info.plist missing: $INFO"
[[ -f "$BIN" ]] || fail "Native executable missing: $BIN"

OS_VERSION="$(sw_vers -productVersion)"
OS_BUILD="$(sw_vers -buildVersion)"
ARCH="$(uname -m)"
BINARY_SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
EXPECTED_SHA="$(python3 - "$LOG" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
matches = re.findall(r"(?m)^([0-9a-f]{64})\s+.*RTL88WiFiNative(?:\s|$)", text)
print(matches[-1] if matches else "")
PY
)"
[[ -n "$EXPECTED_SHA" ]] || fail "Stage29c-v5 binary SHA-256 is not recorded in the canonical log."
[[ "$BINARY_SHA" == "$EXPECTED_SHA" ]] || fail "Built binary SHA differs from Stage29c-v5 report; refusing to audit an unverified artifact."

# Read-only capture. Nothing is rebuilt, modified, installed, or loaded.
run_capture binary-file file "$BIN" || true
run_capture binary-arch lipo -archs "$BIN" || true
run_capture macho-header otool -hv "$BIN" || true
run_capture linked-libraries otool -L "$BIN" || true
run_capture load-commands otool -l "$BIN" || true
run_capture all-symbols nm -a "$BIN" || true
run_capture external-symbols nm -g "$BIN" || true
run_capture undefined-symbols nm -u "$BIN" || true
run_capture strings strings -a "$BIN" || true
run_capture plist-lint plutil -lint "$INFO" || true
run_capture plist-dump plutil -p "$INFO" || true

if command -v kextlibs >/dev/null 2>&1; then
    run_capture kextlibs-undefined kextlibs -undef-symbols "$BUNDLE" || true
else
    echo "INFO: kextlibs is not available on this host."
fi

python3 - "$STAGE_DIR" "$INFO" "$BIN" "$BINARY_SHA" "$EXPECTED_SHA" "$OS_VERSION" "$OS_BUILD" "$ARCH" <<'PY'
from pathlib import Path
import plistlib, re, sys

stage, info_path, binary, binary_sha, expected_sha, os_version, os_build, arch = sys.argv[1:]
stage = Path(stage)
def read(name):
    p = stage / (name + ".txt")
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""

all_symbols = read("all-symbols")
global_symbols = read("external-symbols")
undefined = read("undefined-symbols")
header = read("macho-header")
file_info = read("binary-file")
arch_info = read("binary-arch")
kextlibs = read("kextlibs-undefined")

required_native = [
    "RTW88WCLController",
    "RTW88WCLInfraInterface",
    "RTW88WCLPCIBackend",
    "RTW88WCLSkywalkQueues",
    "RTW88WCLSkywalkTxAdapter",
    "RTW88WCLSkywalkRxAdapter",
]
legacy_frontend = [
    "RTL88WiFiInterface",
    "RTL88WiFiAWDL",
    "RTW88AWDLManager",
]
native_counts = {name: all_symbols.count(name) for name in required_native}
legacy_counts = {name: all_symbols.count(name) for name in legacy_frontend}
missing_native = [name for name, count in native_counts.items() if count == 0]
present_legacy = [name for name, count in legacy_counts.items() if count > 0]

try:
    info = plistlib.loads(Path(info_path).read_bytes())
except Exception as exc:
    info = {}
    plist_error = str(exc)
else:
    plist_error = ""

libraries = info.get("OSBundleLibraries", {})
personalities = info.get("IOKitPersonalities", {})
classes = []
matches = []
for pname, personality in personalities.items():
    if isinstance(personality, dict):
        classes.append(str(personality.get("IOClass", "")))
        matches.append(str(personality.get("IOPCIMatch", "")))

required_libraries = ["com.apple.iokit.IO80211Family", "com.apple.iokit.IOSkywalkFamily", "com.apple.iokit.IOPCIFamily"]
missing_libraries = [name for name in required_libraries if name not in libraries]
legacy_dependency = "com.apple.iokit.IO80211FamilyLegacy" in libraries
native_controller_match = "RTW88WCLController" in classes
pci_match_ok = any(("0xC82110EC" in m and "0xB82110EC" in m) for m in matches)

undefined_lines = [line for line in undefined.splitlines() if line.strip()]
defined_meta = [line for line in all_symbols.splitlines() if "MetaClass" in line or "gMetaClass" in line]
defined_vtables = [line for line in all_symbols.splitlines() if "_ZTV" in line or "vtable" in line.lower()]
native_symbol_lines = [line for line in all_symbols.splitlines() if any(name in line for name in required_native)]
legacy_symbol_lines = [line for line in all_symbols.splitlines() if any(name in line for name in legacy_frontend)]

macho_ok = ("KEXTBUNDLE" in header and "MH_MAGIC_64" in header and "x86_64" in file_info.lower() or
            "Mach-O 64-bit kext bundle x86_64" in file_info)
arch_ok = "x86_64" in arch_info
identity_ok = (info.get("CFBundleExecutable") == "RTL88WiFiNative" and
               info.get("CFBundleIdentifier") == "io.github.x1ren41l.RTL88WiFi")
deps_ok = not missing_libraries and not legacy_dependency
native_classes_ok = not missing_native
legacy_absent = not present_legacy
overall = all([macho_ok, arch_ok, identity_ok, deps_ok, native_classes_ok, legacy_absent,
               native_controller_match, pci_match_ok, binary_sha == expected_sha])

out = []
out.append("RTL88WiFi Stage29d — native Mach-O symbol, meta-class and dependency audit")
out.append("STAGE_SCOPE: READ-ONLY INSPECTION OF THE EXACT STAGE29C-V5 BINARY")
out.append("HOST: macOS {} / {} / {}".format(os_version, os_build, arch))
out.append("BINARY: {}".format(binary))
out.append("BINARY_SHA256: {}".format(binary_sha))
out.append("STAGE29C_V5_SHA256: {}".format(expected_sha))
out.append("BINARY_IDENTITY_MATCH: {}".format("PASS" if binary_sha == expected_sha else "FAIL"))
out.append("")
out.append("=== MACH-O ===")
out.append("MACHO_KEXTBUNDLE_64: {}".format("PASS" if macho_ok else "FAIL"))
out.append("X86_64_ARCHITECTURE: {}".format("PASS" if arch_ok else "FAIL"))
out.append("HEADER_FLAGS: {}".format(" | ".join(x.strip() for x in header.splitlines() if "MH_MAGIC" in x or "filetype" in x)))
out.append("")
out.append("=== BUNDLE METADATA ===")
out.append("PLIST_PARSE: {}".format("FAIL " + plist_error if plist_error else "PASS"))
out.append("CFBundleExecutable: {}".format(info.get("CFBundleExecutable", "<missing>")))
out.append("CFBundleIdentifier: {}".format(info.get("CFBundleIdentifier", "<missing>")))
out.append("BUNDLE_IDENTITY: {}".format("PASS" if identity_ok else "FAIL"))
out.append("IOKitPersonalities_IOClass: {}".format(", ".join(classes)))
out.append("IOKitPersonalities_IOPCIMatch: {}".format(" ; ".join(matches)))
out.append("NATIVE_CONTROLLER_PERSONALITY: {}".format("PASS" if native_controller_match else "FAIL"))
out.append("RTL8821CE_PCI_MATCH: {}".format("PASS" if pci_match_ok else "FAIL"))
out.append("OSBundleLibraries:")
for name in sorted(libraries):
    out.append("  {} = {}".format(name, libraries[name]))
out.append("MISSING_REQUIRED_NATIVE_LIBRARIES: {}".format(", ".join(missing_libraries) if missing_libraries else "NONE"))
out.append("IO80211FamilyLegacy_DEPENDENCY: {}".format("PRESENT — BLOCK" if legacy_dependency else "ABSENT — PASS"))
out.append("NATIVE_DEPENDENCY_SET: {}".format("PASS" if deps_ok else "FAIL"))
out.append("")
out.append("=== C++ CLASS / VTABLE SYMBOL INVENTORY ===")
for name, count in native_counts.items():
    out.append("NATIVE_CLASS_SYMBOL {}: {}".format(name, count))
out.append("NATIVE_CLASS_SYMBOLS: {}".format("PASS" if native_classes_ok else "FAIL"))
for name, count in legacy_counts.items():
    out.append("LEGACY_FRONTEND_SYMBOL {}: {}".format(name, count))
out.append("LEGACY_FRONTEND_SYMBOLS: {}".format("ABSENT — PASS" if legacy_absent else "PRESENT — BLOCK"))
out.append("META_CLASS_SYMBOL_LINES: {}".format(len(defined_meta)))
for line in defined_meta[:80]:
    out.append("  " + line)
out.append("VTABLE_SYMBOL_LINES: {}".format(len(defined_vtables)))
for line in defined_vtables[:100]:
    out.append("  " + line)
out.append("NATIVE_CLASS_SYMBOL_LINES:")
for line in native_symbol_lines[:180]:
    out.append("  " + line)
if legacy_symbol_lines:
    out.append("LEGACY_FRONTEND_SYMBOL_LINES:")
    for line in legacy_symbol_lines[:100]:
        out.append("  " + line)
out.append("")
out.append("=== UNDEFINED SYMBOL INVENTORY ===")
out.append("NM_UNDEFINED_SYMBOL_LINE_COUNT: {}".format(len(undefined_lines)))
for line in undefined_lines[:600]:
    out.append("  " + line)
if len(undefined_lines) > 600:
    out.append("  ... truncated in output.log; full list is in " + str(stage / "undefined-symbols.txt"))
out.append("KEXTLIBS_AUDIT:")
if kextlibs:
    out.extend("  " + line for line in kextlibs.splitlines()[:250])
else:
    out.append("  NOT AVAILABLE OR NO OUTPUT")
out.append("")
out.append("=== STAGE29D RESULT ===")
checks = {
    "MACHO_KEXTBUNDLE_64": macho_ok,
    "X86_64_ARCHITECTURE": arch_ok,
    "BUNDLE_IDENTITY": identity_ok,
    "NATIVE_CONTROLLER_PERSONALITY": native_controller_match,
    "RTL8821CE_PCI_MATCH": pci_match_ok,
    "NATIVE_DEPENDENCIES": deps_ok,
    "NATIVE_CLASS_SYMBOLS": native_classes_ok,
    "LEGACY_FRONTEND_SYMBOLS_ABSENT": legacy_absent,
    "STAGE29C_BINARY_HASH_MATCH": binary_sha == expected_sha,
}
for name, ok in checks.items():
    out.append("{}: {}".format(name, "PASS" if ok else "FAIL"))
out.append("STAGE29D_STATIC_AUDIT: {}".format("PASS" if overall else "REVIEW_REQUIRED"))
out.append("NOTE: Symbol presence is a static inventory, not proof of runtime ABI correctness or driver operation.")
out.append("INSTALL: NOT RUN")
out.append("LOAD: NOT RUN")
out.append("OPENCORE_CHANGE: NONE")
out.append("QUEUE_REGISTRATION: NOT ENABLED")
out.append("KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED")
out.append("SOURCE_FILES_MODIFIED: NONE")
(stage / "stage29d-report.txt").write_text("\n".join(out) + "\n", encoding="utf-8")
print("\n".join(out))
raise SystemExit(0 if overall else 1)
PY
PY_RC=$?

{
    echo
    echo "========== STAGE29D RAW TOOL INVENTORY =========="
    echo "STAGE_DIR: $STAGE_DIR"
    for item in binary-file binary-arch macho-header linked-libraries load-commands; do
        echo "--- $item ---"
        cat "$STAGE_DIR/$item.txt" 2>/dev/null || true
    done
    echo
    echo "========== STAGE29D SYMBOL / ABI AUDIT REPORT =========="
    cat "$STAGE_DIR/stage29d-report.txt" 2>/dev/null || echo "ERROR: Stage29d Python analysis did not produce a report (exit $PY_RC)."
    echo
    echo "STAGE29D_PYTHON_ANALYSIS_EXIT: $PY_RC"
    echo "BUILD: NOT RUN"
    echo "SOURCE_FILES_MODIFIED: NONE"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
    echo "OPENCORE_CHANGE: NONE"
    echo "QUEUE_REGISTRATION: NOT ENABLED"
    echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
} >> "$LOG" 2>&1

# Use file-backed JSON upload. Never pass log base64 on the command line.
REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "Cannot obtain current GitHub output.log SHA."
python3 - "$LOG" "$REMOTE_SHA" "$PAYLOAD" <<'PY'
import base64, json, pathlib, sys
log_path, sha, payload_path = sys.argv[1:4]
data = pathlib.Path(log_path).read_bytes()
if len(data) < 500:
    raise SystemExit("Refusing to upload empty output.log.")
payload = {
    "message": "Stage29d read-only native Mach-O symbol and ABI audit",
    "content": base64.b64encode(data).decode("ascii"),
    "sha": sha,
}
pathlib.Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
print("LOG_BYTES_TO_UPLOAD: {}".format(len(data)))
PY
PREP_RC=$?
[[ "$PREP_RC" -eq 0 ]] || fail "Could not create GitHub upload payload."

gh api --method PUT "$API_PATH" --input "$PAYLOAD" > "$RESPONSE" || fail "GitHub upload failed."
PUT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"]["sha"])' "$RESPONSE")"
COMMIT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"]["sha"])' "$RESPONSE")"
READ_SHA="$(gh api "$API_PATH" --jq '.sha')" || fail "GitHub read-back failed."
[[ -n "$PUT_SHA" && "$PUT_SHA" == "$READ_SHA" ]] || fail "GitHub output.log read-back SHA mismatch."

echo "GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log"
echo "GITHUB_COMMIT: $COMMIT_SHA"
echo "GITHUB_BLOB_SHA: $READ_SHA"
echo "STAGE29D_ANALYSIS_EXIT: $PY_RC"

[[ "$PY_RC" -eq 0 ]] || exit "$PY_RC"
