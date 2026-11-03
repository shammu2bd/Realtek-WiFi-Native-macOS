#!/bin/bash
# Two-pass, read-only ABI evidence collector for Sequoia 15.8.1 (24H32).
# Pass one obtains method lists. Pass two disassembles every method in the
# queue/pool lifetime classes plus all previously targeted registration APIs.
set -euo pipefail

EXPECTED_VERSION="15.8.1"
EXPECTED_BUILD="24H32"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Run on macOS Sequoia 15.8.1, not Linux."
ACTUAL_VERSION="$(/usr/bin/sw_vers -productVersion)"
ACTUAL_BUILD="$(/usr/bin/sw_vers -buildVersion)"
ACTUAL_ARCH="$(/usr/bin/uname -m)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || fail "Expected macOS $EXPECTED_VERSION; found $ACTUAL_VERSION."
[[ "$ACTUAL_BUILD" == "$EXPECTED_BUILD" ]] || fail "Expected build $EXPECTED_BUILD; found $ACTUAL_BUILD."
[[ "$ACTUAL_ARCH" == "x86_64" ]] || fail "Expected x86_64; found $ACTUAL_ARCH."

command -v git >/dev/null 2>&1 || fail "Git is required."
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
        fail "llvm-objdump not found; install MacPorts llvm-20 or set LLVM_OBJDUMP."
    fi
fi
[[ -x "$LLVM_OBJDUMP_PATH" ]] || fail "LLVM_OBJDUMP is not executable: $LLVM_OBJDUMP_PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUT_DIR="${1:-$PROJECT_ROOT/build/sequoia-abi-24H32-stage12}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
[[ ! -e "$OUT_DIR/24H32" ]] || fail "Output already exists: $OUT_DIR/24H32 (choose a new directory)."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtl88wifi-kcabi-stage12.XXXXXX")"
cleanup() {
    status=$?
    if [[ "$status" -eq 0 ]]; then
        rm -rf "$TMP_DIR"
    else
        printf '\nStage 12 failed; diagnostic pass data retained at:\n%s\n' "$TMP_DIR" >&2
        printf 'Inspect the four *.methods.txt files and INDEX.txt in pass1/24H32.\n' >&2
    fi
}
trap cleanup EXIT

printf 'Target: macOS %s (%s), %s\n' "$ACTUAL_VERSION" "$ACTUAL_BUILD" "$ACTUAL_ARCH"
printf 'Kernel collection: %s\n' "$KC_PATH"
printf 'kcabi: %s\n' "$KCABI_DIR"
printf 'llvm-objdump: %s\n' "$LLVM_OBJDUMP_PATH"

# Keep the exact Stage 8-10 targets as the seed; Stage 12 adds all method
# symbols from four queue/pool classes after the baseline dump exposes them.
SEED_REF="$TMP_DIR/ref-seed"
SEED_ARGS=(--out "$SEED_REF")
if [[ -n "${KCABI_REF:-}" ]]; then
    SEED_ARGS+=(--reference "$KCABI_REF")
fi
python3 "$SCRIPT_DIR/prepare-kcabi-ref-24H32.py" "${SEED_ARGS[@]}"

mkdir -p "$TMP_DIR/pass1" "$TMP_DIR/pass2"
printf '\nPass 1/2: collect 24H32 method lists and baseline registration bodies.\n'
(
    cd "$KCABI_DIR"
    KCABI_KC="$KC_PATH" KCABI_CACHE="$TMP_DIR/cache-pass1" LLVM_OBJDUMP="$LLVM_OBJDUMP_PATH" \
        python3 ./dump.py --out "$TMP_DIR/pass1/24H32" --ref "$SEED_REF"
)
[[ -d "$TMP_DIR/pass1/24H32" ]] || fail "kcabi pass 1 did not create 24H32 output."

printf '\nExpand exact class methods for queue/pool lifecycle review.\n'
EXPANDED_REF="$TMP_DIR/ref-stage12"
python3 "$SCRIPT_DIR/prepare-kcabi-ref-24H32-stage12.py" \
    --methods-root "$TMP_DIR/pass1/24H32" --out "$EXPANDED_REF" --reference "$SEED_REF"

printf '\nPass 2/2: disassemble selected queue/pool class methods.\n'
(
    cd "$KCABI_DIR"
    KCABI_KC="$KC_PATH" KCABI_CACHE="$TMP_DIR/cache-pass2" LLVM_OBJDUMP="$LLVM_OBJDUMP_PATH" \
        python3 ./dump.py --out "$TMP_DIR/pass2/24H32" --ref "$EXPANDED_REF"
)
[[ -d "$TMP_DIR/pass2/24H32" ]] || fail "kcabi pass 2 did not create 24H32 output."
cat > "$TMP_DIR/pass2/24H32/rtl88wifi-target.txt" <<EOF_TARGET
macOS product version: $ACTUAL_VERSION
macOS build: $ACTUAL_BUILD
architecture: $ACTUAL_ARCH
kernel collection: $KC_PATH
Stage 12: two-pass queue/pool lifecycle ABI evidence
EOF_TARGET

mv "$TMP_DIR/pass2/24H32" "$OUT_DIR/24H32"
ARCHIVE="$OUT_DIR/RTL88WiFi-Sequoia-24H32-stage12-queue-pool-kcabi.tar.gz"
(
    cd "$OUT_DIR"
    /usr/bin/tar -czf "$ARCHIVE" 24H32
)
/usr/bin/shasum -a 256 "$ARCHIVE"
printf '\nCreated Stage 12 ABI archive:\n%s\n' "$ARCHIVE"
printf 'Upload this archive only if requested; upload the project-root output.log for review.\n'
