#!/bin/bash
# Read-only ABI dump helper for RTL88WiFi's Sequoia 15.8.1 (24H32) WCL port.
set -euo pipefail

EXPECTED_VERSION="15.8.1"
EXPECTED_BUILD="24H32"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Run this script on your macOS Sequoia Hackintosh, not Linux."
ACTUAL_VERSION="$(/usr/bin/sw_vers -productVersion)"
ACTUAL_BUILD="$(/usr/bin/sw_vers -buildVersion)"
ACTUAL_ARCH="$(/usr/bin/uname -m)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || fail "Expected macOS $EXPECTED_VERSION; found $ACTUAL_VERSION."
[[ "$ACTUAL_BUILD" == "$EXPECTED_BUILD" ]] || fail "Expected build $EXPECTED_BUILD; found $ACTUAL_BUILD."
[[ "$ACTUAL_ARCH" == "x86_64" ]] || fail "Expected an Intel x86_64 kernel; found $ACTUAL_ARCH."

command -v git >/dev/null 2>&1 || fail "Git is required. Install Xcode Command Line Tools first."
command -v python3 >/dev/null 2>&1 || fail "Python 3.9+ is required."
python3 - <<'PY' || exit 1
import sys
if sys.version_info < (3, 9):
    raise SystemExit("ERROR: Python 3.9 or newer is required; found " + sys.version.split()[0])
PY

KC_PATH="${KCABI_KC:-/System/Library/KernelCollections/BootKernelExtensions.kc}"
[[ -r "$KC_PATH" ]] || fail "Cannot read kernel collection: $KC_PATH"

KCABI_DIR="${KCABI_DIR:-$HOME/src/kcabi}"
if [[ ! -f "$KCABI_DIR/dump.py" ]]; then
    command -v git >/dev/null 2>&1 || fail "Cannot clone kcabi because git is unavailable."
    mkdir -p "$(dirname "$KCABI_DIR")"
    git clone --depth 1 https://github.com/watchthelight-labs/kcabi.git "$KCABI_DIR"
fi
[[ -f "$KCABI_DIR/dump.py" ]] || fail "kcabi/dump.py was not found in $KCABI_DIR"

LLVM_OBJDUMP_PATH="${LLVM_OBJDUMP:-}"
if [[ -z "$LLVM_OBJDUMP_PATH" ]]; then
    if command -v llvm-objdump >/dev/null 2>&1; then
        LLVM_OBJDUMP_PATH="$(command -v llvm-objdump)"
    elif [[ -x /opt/local/libexec/llvm-20/bin/llvm-objdump ]]; then
        LLVM_OBJDUMP_PATH=/opt/local/libexec/llvm-20/bin/llvm-objdump
    elif [[ -x /opt/local/bin/llvm-objdump-mp-20 ]]; then
        LLVM_OBJDUMP_PATH=/opt/local/bin/llvm-objdump-mp-20
    else
        fail "llvm-objdump not found. Install MacPorts llvm-20 or set LLVM_OBJDUMP=/path/to/llvm-objdump."
    fi
fi
[[ -x "$LLVM_OBJDUMP_PATH" ]] || fail "LLVM_OBJDUMP is not executable: $LLVM_OBJDUMP_PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OUT_DIR="${1:-$PWD/build/sequoia-abi-24H32}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
[[ ! -e "$OUT_DIR/24H32" ]] || fail "Output already exists: $OUT_DIR/24H32 (move it aside first; the script will not overwrite it)."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtl88wifi-kcabi.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

printf 'Target: macOS %s (%s), %s\n' "$ACTUAL_VERSION" "$ACTUAL_BUILD" "$ACTUAL_ARCH"
printf 'Kernel collection: %s\n' "$KC_PATH"
printf 'kcabi: %s\n' "$KCABI_DIR"
printf 'llvm-objdump: %s\n' "$LLVM_OBJDUMP_PATH"

REF_ARGS=(--out "$TMP_DIR/ref")
if [[ -n "${KCABI_REF:-}" ]]; then
    REF_ARGS+=(--reference "$KCABI_REF")
fi
python3 "$SCRIPT_DIR/prepare-kcabi-ref-24H32.py" "${REF_ARGS[@]}"

(
    cd "$KCABI_DIR"
    KCABI_KC="$KC_PATH" \
    KCABI_CACHE="$TMP_DIR/cache" \
    LLVM_OBJDUMP="$LLVM_OBJDUMP_PATH" \
        python3 ./dump.py --out "$TMP_DIR/24H32" --ref "$TMP_DIR/ref"
)

[[ -d "$TMP_DIR/24H32" ]] || fail "kcabi did not create its expected 24H32 dump directory."
cat > "$TMP_DIR/24H32/rtl88wifi-target.txt" <<EOF_TARGET
macOS product version: $ACTUAL_VERSION
macOS build: $ACTUAL_BUILD
architecture: $ACTUAL_ARCH
kernel collection: $KC_PATH
EOF_TARGET

mv "$TMP_DIR/24H32" "$OUT_DIR/24H32"
ARCHIVE="$OUT_DIR/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz"
(
    cd "$OUT_DIR"
    /usr/bin/tar -czf "$ARCHIVE" 24H32
)
/usr/bin/shasum -a 256 "$ARCHIVE"
printf '\nCreated ABI archive:\n%s\n' "$ARCHIVE"
printf 'Please upload that archive together with the RTL88WiFi source workbench.\n'
