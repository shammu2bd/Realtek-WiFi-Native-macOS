#!/bin/bash
# Read-only extension of the target-build ABI dump for queue/ownership methods.
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
command -v python3 >/dev/null 2>&1 || fail "Python 3 is required."
command -v git >/dev/null 2>&1 || fail "Git is required."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
STAGE14="$PROJECT_ROOT/build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz"
STAGE15="$PROJECT_ROOT/build/sequoia-abi-24H32-stage15/RTL88WiFi-Sequoia-24H32-stage15-packet-accessor-audit.tar.gz"
STAGE16="$PROJECT_ROOT/build/sequoia-abi-24H32-stage16/RTL88WiFi-Sequoia-24H32-stage16-packet-semantics-audit.tar.gz"
for input in "$STAGE14" "$STAGE15" "$STAGE16"; do
  [[ -r "$input" ]] || fail "Required prior-stage archive not found: $input"
done

KC_PATH="${KCABI_KC:-/System/Library/KernelCollections/BootKernelExtensions.kc}"
[[ -r "$KC_PATH" ]] || fail "Cannot read kernel collection: $KC_PATH"
KCABI_DIR="${KCABI_DIR:-$HOME/src/kcabi}"
if [[ ! -f "$KCABI_DIR/dump.py" ]]; then
  mkdir -p "$(dirname "$KCABI_DIR")"
  git clone --depth 1 https://github.com/watchthelight-labs/WTLKcAbi.git "$KCABI_DIR"
fi
[[ -f "$KCABI_DIR/dump.py" ]] || fail "kcabi dump.py not found in $KCABI_DIR"

LLVM_OBJDUMP_PATH="${LLVM_OBJDUMP:-}"
if [[ -z "$LLVM_OBJDUMP_PATH" ]]; then
  if command -v llvm-objdump >/dev/null 2>&1; then LLVM_OBJDUMP_PATH="$(command -v llvm-objdump)"
  elif [[ -x /opt/local/libexec/llvm-20/bin/llvm-objdump ]]; then LLVM_OBJDUMP_PATH=/opt/local/libexec/llvm-20/bin/llvm-objdump
  elif [[ -x /opt/local/bin/llvm-objdump-mp-20 ]]; then LLVM_OBJDUMP_PATH=/opt/local/bin/llvm-objdump-mp-20
  else fail "llvm-objdump not found; install MacPorts llvm-20 or set LLVM_OBJDUMP."; fi
fi
[[ -x "$LLVM_OBJDUMP_PATH" ]] || fail "LLVM_OBJDUMP is not executable: $LLVM_OBJDUMP_PATH"

OUT_DIR="${1:-$PROJECT_ROOT/build/sequoia-abi-24H32-stage17}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
[[ ! -e "$OUT_DIR/24H32" ]] || fail "Output already exists: $OUT_DIR/24H32 (choose a new output directory)."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtl88wifi-kcabi-stage17.XXXXXX")"
cleanup() {
  status=$?
  if [[ "$status" -eq 0 ]]; then rm -rf "$TMP_DIR"
  else printf '\nStage 17 collector failed; diagnostic data retained at:\n%s\n' "$TMP_DIR" >&2; fi
}
trap cleanup EXIT

printf 'Target: macOS %s (%s), %s\n' "$ACTUAL_VERSION" "$ACTUAL_BUILD" "$ACTUAL_ARCH"
printf 'Kernel collection: %s\n' "$KC_PATH"
printf 'Stage 14 input: %s\n' "$STAGE14"
printf 'Stage 15 input: %s\n' "$STAGE15"
printf 'Stage 16 input: %s\n' "$STAGE16"

REF_DIR="$TMP_DIR/ref-stage17"
python3 "$SCRIPT_DIR/prepare-kcabi-ref-24H32-stage17.py" --stage14-archive "$STAGE14" --out "$REF_DIR"

KCABI_COPY="$TMP_DIR/kcabi-stage17"
cp -R "$KCABI_DIR" "$KCABI_COPY"
python3 "$SCRIPT_DIR/patch-kcabi-class-list-stage17.py" "$KCABI_COPY/dump.py"
KCABI_COMMIT="$(git -C "$KCABI_COPY" rev-parse HEAD 2>/dev/null || printf 'unknown')"
printf 'WTLKcAbi checkout: %s (%s)\n' "$KCABI_DIR" "$KCABI_COMMIT"

mkdir -p "$TMP_DIR/dump-out"
printf '\nCollecting 24H32 packet, buffer, memory-segment, RX/TX queue and interface lifecycle bodies.\n'
(cd "$KCABI_COPY" && KCABI_KC="$KC_PATH" KCABI_CACHE="$TMP_DIR/kcabi-cache" \
  LLVM_OBJDUMP="$LLVM_OBJDUMP_PATH" python3 ./dump.py \
  --kc "$KC_PATH" --out "$OUT_DIR/24H32" \
  --ref "$REF_DIR/rtl88wifi-24H32-queue-ownership-stage17.asm.txt")
[[ -d "$OUT_DIR/24H32" ]] || fail "kcabi did not create Stage 17 24H32 dump."
cat > "$OUT_DIR/24H32/rtl88wifi-stage17-target.txt" <<EOF_TARGET
macOS product version: $ACTUAL_VERSION
macOS build: $ACTUAL_BUILD
architecture: $ACTUAL_ARCH
kernel collection: $KC_PATH
WTLKcAbi source commit: $KCABI_COMMIT
Stage 17: RX/TX queue lifecycle and packet ownership ABI evidence
Scope: method lists and exact target-build disassembly only; no driver queue registration or packet submission.
EOF_TARGET

set +e
python3 "$SCRIPT_DIR/audit-skywalk-queue-ownership-stage17.py" \
  --stage14-archive "$STAGE14" --stage15-archive "$STAGE15" --stage16-archive "$STAGE16" \
  --stage17-root "$OUT_DIR/24H32" --manifest "$REF_DIR/STAGE17-METHOD-MANIFEST.json" \
  --project-root "$PROJECT_ROOT" --out "$OUT_DIR/stage17-work"
AUDIT_STATUS=$?
set -e
cp "$REF_DIR/STAGE17-METHOD-MANIFEST.json" "$OUT_DIR/STAGE17-METHOD-MANIFEST.json"

ARCHIVE="$OUT_DIR/RTL88WiFi-Sequoia-24H32-stage17-rx-queue-ownership-kcabi.tar.gz"
(cd "$OUT_DIR" && /usr/bin/tar -czf "$ARCHIVE" 24H32 stage17-work STAGE17-METHOD-MANIFEST.json)
DIGEST="$(/usr/bin/shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$DIGEST" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"
printf 'Stage 17 archive: %s\n' "$ARCHIVE"
printf 'Stage 17 archive SHA-256: %s\n' "$DIGEST"
if [[ "$AUDIT_STATUS" -ne 0 ]]; then
  printf 'Stage 17 requires review. The diagnostic archive was still created for upload.\n' >&2
  exit "$AUDIT_STATUS"
fi
printf 'Stage 17 read-only queue/ownership evidence audit: PASS\n'
printf 'DATAPATH_ACTIVATION: BLOCKED pending manual ownership-contract review\n'
