#!/bin/bash
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

find_driver_dir() {
    if [[ -n "${PROJECT_DIR:-}" ]]; then
        if [[ -f "${PROJECT_DIR}/Makefile" && -d "${PROJECT_DIR}/src/kext" ]]; then
            printf '%s\n' "$(cd "${PROJECT_DIR}" && pwd -P)"
            return 0
        fi
        if [[ -f "${PROJECT_DIR}/driver/RTL88WiFi/Makefile" ]]; then
            printf '%s\n' "$(cd "${PROJECT_DIR}/driver/RTL88WiFi" && pwd -P)"
            return 0
        fi
        fail "PROJECT_DIR is not the RTL88WiFi driver directory or project root: ${PROJECT_DIR}"
    fi

    if [[ -f "$PWD/Makefile" && -d "$PWD/src/kext" ]]; then
        pwd -P
        return 0
    fi
    if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
        (cd "$PWD/driver/RTL88WiFi" && pwd -P)
        return 0
    fi

    local base found
    for base in "$HOME/Downloads" "$PWD"; do
        [[ -d "$base" ]] || continue
        found="$(find "$base" -maxdepth 7 -type f -path '*/driver/RTL88WiFi/Makefile' -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            dirname "$found"
            return 0
        fi
    done
    return 1
}

DRIVER_DIR="$(find_driver_dir)" || fail "Cannot locate driver/RTL88WiFi/Makefile. Run from the project root or set PROJECT_DIR."
PROJECT_ROOT="$(cd "$DRIVER_DIR/../.." && pwd -P)"
MAKEFILE="$DRIVER_DIR/Makefile"
BASE_PLIST="$DRIVER_DIR/RTL88WiFi.kext/Contents/Info.plist"
NATIVE_KEXT="$DRIVER_DIR/RTL88WiFiNative.kext"
NATIVE_PLIST="$NATIVE_KEXT/Contents/Info.plist"

[[ -f "$MAKEFILE" ]] || fail "Makefile missing: $MAKEFILE"
[[ -f "$BASE_PLIST" ]] || fail "Existing legacy Info.plist missing: $BASE_PLIST"
[[ -d "$DRIVER_DIR/src/kext/wcl24h32" ]] || fail "Native WCL source directory missing."

OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
OS_BUILD="$(/usr/bin/sw_vers -buildVersion)"
ARCH="$(/usr/bin/uname -m)"
[[ "$OS_VERSION" == "15.8.1" ]] || fail "Expected macOS 15.8.1; found $OS_VERSION."
[[ "$OS_BUILD" == "24H32" ]] || fail "Expected build 24H32; found $OS_BUILD."
[[ "$ARCH" == "x86_64" ]] || fail "Expected x86_64; found $ARCH."

STAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT_ROOT/build/stage29b-native-target-setup-$STAMP"
mkdir -p "$STAGE_DIR"
LOG="$PROJECT_ROOT/output.log"
API_PATH="repos/shammu2bd/Realtek-WiFi-Native-macOS/contents/Development/output.log"

# Keep one canonical log: download the existing GitHub Development/output.log
# before appending this run, then push the updated file back automatically.
command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required for automatic Development/output.log sync."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run gh auth login once, then rerun."
REMOTE_LOG="$STAGE_DIR/output.log.github-before"
gh api "$API_PATH" --jq '.content' | \
    python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$REMOTE_LOG"
[[ -s "$REMOTE_LOG" ]] || fail "Could not download the canonical GitHub Development/output.log."
cp "$REMOTE_LOG" "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "RTL88WiFi Stage29b — separate native target definition"
echo "DATE: $(/bin/date '+%Y-%m-%d %H:%M:%S %z')"
echo "HOST: macOS $OS_VERSION / $OS_BUILD / $ARCH"
echo "DRIVER_DIR: $DRIVER_DIR"
echo "PROJECT_ROOT: $PROJECT_ROOT"
echo "STAGE_DIR: $STAGE_DIR"
echo "SCOPE: add independent Makefile target and native bundle metadata; dry-run only."
echo "LEGACY_TARGET_MODIFICATION: NO"
echo "SOURCE_FRONTEND_MODIFICATION: NO"
echo "BUILD: NOT RUN"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NOT RUN"

for f in \
    src/kext/wcl24h32/RTW88WCLController.cpp \
    src/kext/wcl24h32/RTW88WCLController.hpp \
    src/kext/wcl24h32/RTW88WCLInfraInterface.cpp \
    src/kext/wcl24h32/RTW88WCLPCIBackend.cpp \
    src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp \
    src/kext/wcl24h32/RTW88WCLSkywalkTxAdapter.cpp \
    src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp \
    src/kext/RTW88IEEE80211.cpp \
    src/kext/RTW88IEEE80211.hpp \
    src/kext/RTW88HwOps.cpp \
    src/kext/RTW88WCLRadioBridge.cpp \
    src/kext/RTW88WCLRadioBridge.hpp \
    src/kext/RTW88WCLWorkQueue.cpp \
    src/kext/RTW88WCLWorkQueue.hpp
do
    [[ -f "$DRIVER_DIR/$f" ]] || fail "Required native target source is missing: $f"
done

grep -q 'WCL24H32_CONTROLLER_OBJ' "$MAKEFILE" || fail "WCL controller compile rule not found."
grep -q 'AIRPORT_KMOD_OBJ' "$MAKEFILE" || fail "Existing kmod metadata object variable not found."
grep -q 'AIRPORT_LDFLAGS' "$MAKEFILE" || fail "Existing kext linker flags not found."
[[ "$(grep -F -c '$(BUILD_DIR)/wcl24h32:' "$MAKEFILE" || true)" == "1" ]] || fail "Expected exactly one WCL build-directory rule insertion point."
if grep -Eq '(^|[[:space:]])rtl88wifi-native([[:space:]:]|$)' "$MAKEFILE"; then
    fail "rtl88wifi-native target already exists; refusing to patch twice."
fi
if [[ -e "$NATIVE_KEXT" ]]; then
    fail "Native bundle skeleton already exists: $NATIVE_KEXT. Review it before retrying."
fi

cp -p "$MAKEFILE" "$STAGE_DIR/Makefile.before-stage29b"
echo "MAKEFILE_BACKUP: $STAGE_DIR/Makefile.before-stage29b"

python3 - "$MAKEFILE" "$BASE_PLIST" "$NATIVE_PLIST" "$STAGE_DIR" <<'PY'
import os
import plistlib
import sys

makefile_path, base_plist_path, native_plist_path, stage_dir = sys.argv[1:5]

with open(makefile_path, "r", encoding="utf-8") as f:
    makefile = f.read()

required_make_tokens = [
    "DRIVER_OBJS", "CHIP_OBJS", "COMPAT_OBJS", "FIRMWARE_OBJS",
    "AIRPORT_KMOD_OBJ", "AIRPORT_LDFLAGS", "WCL24H32_CXXFLAGS",
    "WCL24H32_CONTROLLER_OBJ", "WCL24H32_INFRA_OBJ",
    "WCL24H32_PCI_BACKEND_OBJ", "WCL24H32_SKYWALK_QUEUES_OBJ",
    "WCL24H32_TX_ADAPTER_OBJ", "WCL24H32_RX_ADAPTER_OBJ",
]
missing = [x for x in required_make_tokens if x not in makefile]
if missing:
    raise SystemExit("Makefile preflight failed; missing tokens: " + ", ".join(missing))

with open(base_plist_path, "rb") as f:
    base = plistlib.load(f)

bundle_id = base.get("CFBundleIdentifier")
if not bundle_id or not isinstance(bundle_id, str):
    raise SystemExit("Legacy bundle plist has no valid CFBundleIdentifier.")
if base.get("CFBundleExecutable") != "RTL88WiFi":
    raise SystemExit("Unexpected legacy CFBundleExecutable; refusing to clone metadata.")
if "RTL88WiFi" not in (base.get("IOKitPersonalities") or {}):
    # Historical plist uses per-chip personality keys rather than a common key.
    if not any(
        isinstance(v, dict) and v.get("IOClass") == "RTL88WiFi"
        for v in (base.get("IOKitPersonalities") or {}).values()
    ):
        raise SystemExit("Cannot identify the known legacy PCI personalities in base plist.")

controller_header = os.path.join(os.path.dirname(base_plist_path), "..", "..", "src", "kext", "wcl24h32", "RTW88WCLController.hpp")
controller_header = os.path.abspath(controller_header)
with open(controller_header, "r", encoding="utf-8") as f:
    controller_header_text = f.read()
if "class RTW88WCLController" not in controller_header_text:
    raise SystemExit("Native controller class declaration did not match expected class name.")

def find_kext_bundle(bundle_identifier):
    roots = [
        "/System/Library/Extensions",
        "/System/Library/DriverExtensions",
        "/Library/Extensions",
    ]
    candidates = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for current, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if d not in {"Caches", "PlugIns", "Frameworks"}]
            if "Info.plist" not in files or not current.endswith(".kext/Contents"):
                continue
            path = os.path.join(current, "Info.plist")
            try:
                with open(path, "rb") as f:
                    info = plistlib.load(f)
            except Exception:
                continue
            if info.get("CFBundleIdentifier") == bundle_identifier:
                version = info.get("CFBundleVersion") or info.get("OSBundleCompatibleVersion")
                if version is not None:
                    candidates.append((path, str(version)))
        if candidates:
            # Prefer Apple’s sealed System volume when more than one copy exists.
            candidates.sort(key=lambda x: (0 if x[0].startswith("/System/Library/Extensions/") else 1, x[0]))
            return candidates[0]
    return None

required_ids = [
    "com.apple.iokit.IO80211Family",
    "com.apple.iokit.IOSkywalkFamily",
    "com.apple.iokit.IOPCIFamily",
]
resolved = {}
for identifier in required_ids:
    found = find_kext_bundle(identifier)
    if not found:
        raise SystemExit(
            "Cannot resolve installed Apple dependency " + identifier +
            " from this 24H32 system. No guessed version will be written."
        )
    resolved[identifier] = {"path": found[0], "version": found[1]}

libraries = dict(base.get("OSBundleLibraries") or {})
libraries.pop("com.apple.iokit.IO80211FamilyLegacy", None)
for identifier, item in resolved.items():
    libraries[identifier] = item["version"]

# Preserve IONetworkingFamily only when it is installed and resolvable.
networking_id = "com.apple.iokit.IONetworkingFamily"
if networking_id in libraries:
    found = find_kext_bundle(networking_id)
    if found:
        libraries[networking_id] = found[1]

if "com.apple.iokit.IO80211FamilyLegacy" in libraries:
    raise SystemExit("Legacy IO80211 dependency unexpectedly remains in native libraries.")
if "com.apple.iokit.IO80211Family" not in libraries:
    raise SystemExit("Native IO80211Family dependency was not written.")
if "com.apple.iokit.IOSkywalkFamily" not in libraries:
    raise SystemExit("Native IOSkywalkFamily dependency was not written.")

native = dict(base)
native["CFBundleIdentifier"] = bundle_id  # Same module ID; only one output is ever installed.
native["CFBundleExecutable"] = "RTL88WiFiNative"
native["CFBundleName"] = "RTL88WiFi Native"
native["LSMinimumSystemVersion"] = "15.0"
native["OSBundleLibraries"] = libraries
native["IOKitPersonalities"] = {
    "RTL88WiFiNative_8821CE": {
        "CFBundleIdentifier": bundle_id,
        "IOClass": "RTW88WCLController",
        "IOMatchCategory": "IODefaultMatchCategory",
        "IOProbeScore": 5000,
        "IOProviderClass": "IOPCIDevice",
        "IOPCIMatch": "0xC82110EC 0xB82110EC",
    }
}
native["OSBundleRequired"] = "Network-Root"

os.makedirs(os.path.dirname(native_plist_path), exist_ok=True)
with open(native_plist_path, "wb") as f:
    plistlib.dump(native, f, fmt=plistlib.FMT_XML, sort_keys=True)

native_block = r"""
# Stage29b: independent native Sequoia 24H32 target.
# This target has a separate bundle/output path and never links legacy Wi-Fi
# frontend objects. It shares only the ABI-neutral RTW88 hardware/core objects.
NATIVE_KEXT_SKEL := $(PROJ_ROOT)/RTL88WiFiNative.kext
NATIVE_OUT_KEXT := $(OUT_DIR)/RTL88WiFiNative.kext
NATIVE_OUT_BIN := $(NATIVE_OUT_KEXT)/Contents/MacOS/RTL88WiFiNative
NATIVE_CORE_OBJ_DIR := $(BUILD_DIR)/native
NATIVE_CORE_SRCS := $(KEXT_SRC)/RTW88IEEE80211.cpp $(KEXT_SRC)/RTW88HwOps.cpp $(KEXT_SRC)/RTW88WCLRadioBridge.cpp $(KEXT_SRC)/RTW88WCLWorkQueue.cpp
NATIVE_CORE_HEADERS := $(wildcard $(KEXT_SRC)/*.hpp) $(wildcard $(KEXT_SRC)/wcl24h32/*.hpp)
NATIVE_CORE_OBJS := $(addprefix $(NATIVE_CORE_OBJ_DIR)/,RTW88IEEE80211.o RTW88HwOps.o RTW88WCLRadioBridge.o RTW88WCLWorkQueue.o)
NATIVE_ALL_OBJS := $(DRIVER_OBJS) $(CHIP_OBJS) $(COMPAT_OBJS) $(FIRMWARE_OBJS) $(AIRPORT_KMOD_OBJ) $(NATIVE_CORE_OBJS) $(WCL24H32_CONTROLLER_OBJ) $(WCL24H32_INFRA_OBJ) $(WCL24H32_PCI_BACKEND_OBJ) $(WCL24H32_SKYWALK_QUEUES_OBJ) $(WCL24H32_TX_ADAPTER_OBJ) $(WCL24H32_RX_ADAPTER_OBJ)
NATIVE_LDFLAGS := $(AIRPORT_LDFLAGS)

.PHONY: rtl88wifi-native
rtl88wifi-native: $(NATIVE_OUT_BIN)

$(NATIVE_CORE_OBJ_DIR):
	mkdir -p $@

$(NATIVE_CORE_OBJ_DIR)/%.o: $(KEXT_SRC)/%.cpp $(NATIVE_CORE_HEADERS) | $(NATIVE_CORE_OBJ_DIR)
	@echo "  NATIVE CXX  $< (24H32 isolated core object)"
	$(CXX) $(WCL24H32_CXXFLAGS) -c $< -o $@

$(NATIVE_OUT_KEXT)/Contents/MacOS:
	mkdir -p $@

$(NATIVE_OUT_BIN): $(NATIVE_ALL_OBJS) $(NATIVE_KEXT_SKEL)/Contents/Info.plist | $(NATIVE_OUT_KEXT)/Contents/MacOS
	@echo "  NATIVE LD   $(notdir $@)"
	$(LD) $(NATIVE_LDFLAGS) -o $@ $(NATIVE_ALL_OBJS)
	@echo "  NATIVE SYNC $(NATIVE_OUT_KEXT)"
	rsync -a --exclude='MacOS' $(NATIVE_KEXT_SKEL)/ $(NATIVE_OUT_KEXT)/
	@echo "  NATIVE OK   $(NATIVE_OUT_KEXT)"
"""

marker = "$(BUILD_DIR)/wcl24h32:"
if makefile.count(marker) != 1:
    raise SystemExit("Expected exactly one Makefile insertion marker for WCL build directory.")
if "rtl88wifi-native" in makefile:
    raise SystemExit("Native target text already exists in Makefile; refusing duplicate insertion.")

makefile = makefile.replace(marker, native_block + "\n" + marker, 1)
tmp_makefile = makefile_path + ".stage29b.tmp"
with open(tmp_makefile, "w", encoding="utf-8") as f:
    f.write(makefile)
os.replace(tmp_makefile, makefile_path)

print("NATIVE_PLIST: " + native_plist_path)
print("NATIVE_CFBundleIdentifier: " + bundle_id)
print("NATIVE_CFBundleExecutable: RTL88WiFiNative")
for identifier in required_ids:
    item = resolved[identifier]
    print("NATIVE_DEPENDENCY: {} {} ({})".format(identifier, item["version"], item["path"]))
print("NATIVE_IO80211FamilyLegacy: ABSENT")
print("NATIVE_PERSONALITY: IOClass=RTW88WCLController; PCI=0xC82110EC 0xB82110EC")
print("MAKEFILE_PATCH: ADDED rtl88wifi-native; original rtl88wifi recipe not rewritten")
PY

NATIVE_BIN="$DRIVER_DIR/build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"
NATIVE_DRYRUN="$STAGE_DIR/native-target-dry-run.txt"
LEGACY_DRYRUN="$STAGE_DIR/legacy-target-dry-run.txt"

echo
echo "========== NATIVE TARGET DRY-RUN =========="
set +e
(cd "$DRIVER_DIR" && make -B -n -j1 rtl88wifi-native) >"$NATIVE_DRYRUN" 2>&1
NATIVE_RC=$?
set -e
echo "NATIVE_MAKE_DRY_RUN_EXIT: $NATIVE_RC"
echo "NATIVE_MAKE_DRY_RUN_LINES: $(wc -l < "$NATIVE_DRYRUN" | tr -d ' ')"
if [[ "$NATIVE_RC" -ne 0 ]]; then
    tail -n 80 "$NATIVE_DRYRUN"
    fail "Native target dry-run failed. Makefile and native plist are backed up/isolated; see report above."
fi

LINK_LINE="$(grep -F "$NATIVE_BIN" "$NATIVE_DRYRUN" | grep -F -- ' -o ' | tail -n 1 || true)"
[[ -n "$LINK_LINE" ]] || {
    tail -n 80 "$NATIVE_DRYRUN"
    fail "Could not find the native link command in the dry-run."
}
echo "NATIVE_LINK_COMMAND: $LINK_LINE"

for obj in \
    RTW88WCLController.o RTW88WCLInfraInterface.o RTW88WCLPCIBackend.o \
    RTW88WCLSkywalkQueues.o RTW88WCLSkywalkTxAdapter.o RTW88WCLSkywalkRxAdapter.o \
    RTW88IEEE80211.o RTW88HwOps.o RTW88WCLRadioBridge.o RTW88WCLWorkQueue.o
do
    [[ "$LINK_LINE" == *"$obj"* ]] || fail "Native link line is missing required object: $obj"
done

for obj in RTL88WiFi.o RTL88WiFiInterface.o RTL88WiFiAWDL.o RTW88AWDLManager.o
do
    [[ "$LINK_LINE" != *"$obj"* ]] || fail "Legacy frontend object leaked into native link: $obj"
done
echo "NATIVE_LINK_OBJECT_CLOSURE: PASS"
echo "LEGACY_FRONTEND_OBJECTS_IN_NATIVE_LINK: NONE"

echo
echo "========== LEGACY TARGET PRESERVATION DRY-RUN =========="
set +e
(cd "$DRIVER_DIR" && make -B -n -j1 rtl88wifi) >"$LEGACY_DRYRUN" 2>&1
LEGACY_RC=$?
set -e
echo "LEGACY_MAKE_DRY_RUN_EXIT: $LEGACY_RC"
if [[ "$LEGACY_RC" -ne 0 ]]; then
    tail -n 80 "$LEGACY_DRYRUN"
    fail "Existing legacy rtl88wifi dry-run no longer passes."
fi
LEGACY_LINK_LINE="$(grep -F 'Contents/MacOS/RTL88WiFi' "$LEGACY_DRYRUN" | grep -F -- ' -o ' | tail -n 1 || true)"
[[ -n "$LEGACY_LINK_LINE" ]] || fail "Could not find existing legacy link command."
for obj in RTL88WiFi.o RTL88WiFiInterface.o RTL88WiFiAWDL.o RTW88AWDLManager.o
do
    [[ "$LEGACY_LINK_LINE" == *"$obj"* ]] || fail "Existing legacy link lost expected object: $obj"
done
for obj in RTW88WCLController.o RTW88WCLInfraInterface.o RTW88WCLPCIBackend.o RTW88WCLSkywalkQueues.o RTW88WCLSkywalkTxAdapter.o RTW88WCLSkywalkRxAdapter.o
do
    [[ "$LEGACY_LINK_LINE" != *"$obj"* ]] || fail "Native WCL object leaked into existing legacy link: $obj"
done
echo "LEGACY_LINK_OBJECT_BOUNDARY: PASS"
echo "NATIVE_WCL_OBJECTS_IN_LEGACY_LINK: NONE"

echo
echo "========== STAGE29B RESULT =========="
echo "SEPARATE_NATIVE_TARGET: ADDED"
echo "NATIVE_TARGET: rtl88wifi-native"
echo "NATIVE_OUTPUT: $DRIVER_DIR/build/out/RTL88WiFiNative.kext"
echo "NATIVE_BUNDLE_IDENTIFIER: same as existing RTL88WiFi (mutually exclusive install only)"
echo "NATIVE_BUNDLE_EXECUTABLE: RTL88WiFiNative"
echo "NATIVE_IOCLASS: RTW88WCLController"
echo "NATIVE_IO80211FamilyLegacy_DEPENDENCY: ABSENT"
echo "NATIVE_APPLE_IO80211Family_DEPENDENCY: PRESENT"
echo "NATIVE_APPLE_IOSkywalkFamily_DEPENDENCY: PRESENT"
echo "LEGACY_TARGET: PRESERVED"
echo "LEGACY_TARGET_DRY_RUN: PASS"
echo "NATIVE_TARGET_DRY_RUN: PASS"
echo "ACTUAL_BUILD: NOT RUN"
echo "INSTALL: NOT RUN"
echo "LOAD: NOT RUN"
echo "OPENCORE_CHANGE: NONE"
echo "KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED"
echo "MAKEFILE_BACKUP: $STAGE_DIR/Makefile.before-stage29b"
echo "DRY_RUN_FILES: $NATIVE_DRYRUN ; $LEGACY_DRYRUN"
echo "LOG_FILE: $LOG"
echo
echo "NEXT_GATE: review this output.log. If both dry-runs pass, the next stage is an actual native link build only; it will still not install or load the kext."

# Push the canonical log to GitHub Development/ automatically; no manual upload.
REMOTE_SHA="$(gh api "$API_PATH" --jq '.sha')"
PAYLOAD="$STAGE_DIR/github-output-log.json"
python3 - "$LOG" "$REMOTE_SHA" "$PAYLOAD" <<'PY'
import base64, json, pathlib, sys
log_path, sha, payload_path = sys.argv[1:4]
data = {
    "message": "Stage29b separate native target definition and dry-run audit",
    "content": base64.b64encode(pathlib.Path(log_path).read_bytes()).decode("ascii"),
    "sha": sha,
}
pathlib.Path(payload_path).write_text(json.dumps(data), encoding="utf-8")
PY
UPLOAD_RESPONSE="$(gh api --method PUT "$API_PATH" --input "$PAYLOAD")"
UPLOAD_COMMIT="$(printf '%s' "$UPLOAD_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["sha"])')"
echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated (commit $UPLOAD_COMMIT)"
