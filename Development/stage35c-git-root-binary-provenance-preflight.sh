#!/bin/bash
# Stage 35C — Git-root discovery and native-binary provenance preflight.
# Read-only: does not build, install, load, or modify driver/OpenCore sources.
set -u
PROJECT_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
EXPECTED_REL="driver/RTL88WiFi/Makefile"
NATIVE_BIN_REL="driver/RTL88WiFi/build/out/RTL88WiFiNative.kext/Contents/MacOS/RTL88WiFiNative"
STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT="${HOME}/Downloads/RTL88WiFi-Stage35C-${STAMP}"
mkdir -p "$OUT" || exit 1
REPORT="$OUT/report.txt"
exec > >(tee "$REPORT") 2>&1
echo "STAGE35C_GIT_ROOT_AND_BINARY_PROVENANCE"
echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "host=$(hostname)"
echo "pwd=$PWD"
echo "home=$HOME"
echo

# Candidate paths: known project location, cwd ancestry, script ancestry,
# and bounded Downloads discovery. A candidate is accepted only if it has
# both the expected Makefile and Git metadata resolvable by git.
CANDIDATES=()
add_candidate() { [ -n "${1:-}" ] && CANDIDATES+=("$1"); }
add_ancestors() {
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    add_candidate "$p"
    p="$(dirname "$p")"
  done
}
add_candidate "$HOME/Downloads/$PROJECT_NAME"
add_ancestors "$PWD"
add_ancestors "$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"
if [ -d "$HOME/Downloads" ]; then
  while IFS= read -r d; do add_candidate "$d"; done < <(
    find "$HOME/Downloads" -maxdepth 5 \( -type d -name .git -o -type f -name .git \) -print 2>/dev/null |
    while IFS= read -r g; do dirname "$g"; done
  )
fi

ROOT=""
for c in "${CANDIDATES[@]}"; do
  [ -d "$c" ] || continue
  [ -f "$c/$EXPECTED_REL" ] || continue
  if git -C "$c" rev-parse --show-toplevel >/dev/null 2>&1; then
    ROOT="$(git -C "$c" rev-parse --show-toplevel 2>/dev/null)"
    break
  fi
done

if [ -z "$ROOT" ]; then
  echo "GIT_ROOT_STATUS=NOT_FOUND"
  echo "reason=No candidate containing $EXPECTED_REL had usable Git metadata."
  echo "next=Confirm the actual checkout path or clone the repository; do not initialize Git blindly."
  exit 2
fi

cd "$ROOT" || exit 2
ROOT_REAL="$(pwd -P)"
HEAD="$(git rev-parse HEAD 2>&1)"
BRANCH="$(git branch --show-current 2>&1)"
ORIGIN="$(git remote get-url origin 2>&1 || true)"
STATUS="$(git status --porcelain=v1 --untracked-files=all 2>&1)"
echo "GIT_ROOT_STATUS=FOUND"
echo "git_root=$ROOT_REAL"
echo "head=$HEAD"
echo "branch=$BRANCH"
echo "origin=$ORIGIN"
echo "working_tree_status_begin"
printf '%s\n' "$STATUS"
echo "working_tree_status_end"
if [ -z "$STATUS" ]; then echo "working_tree=CLEAN"; else echo "working_tree=DIRTY_OR_UNTRACKED"; fi
echo

echo "SOURCE_SNAPSHOT_BEGIN"
for f in \
  "driver/RTL88WiFi/Makefile" \
  "driver/RTL88WiFi/src/kext/RTW88HwOps.cpp" \
  "driver/RTL88WiFi/src/kext/RTW88PCIDevice.cpp" \
  "driver/RTL88WiFi/src/kext/RTW88WCLPCIBackend.cpp" \
  "driver/RTL88WiFi/src/kext/RTW88WCLController.cpp" \
  "driver/RTL88WiFi/src/kext/RTW88WCLSkywalkQueues.cpp"; do
  if [ -f "$f" ]; then
    WORK_HASH="$(shasum -a 256 "$f" | awk '{print $1}')"
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      HEAD_BLOB="$(git rev-parse "HEAD:$f" 2>/dev/null || true)"
      INDEX_BLOB="$(git rev-parse ":$f" 2>/dev/null || true)"
      if [ "$WORK_HASH" = "$(git hash-object "$f")" ] && [ "$HEAD_BLOB" = "$INDEX_BLOB" ]; then
        MATCH="INDEX_MATCHES_HEAD"
      else
        MATCH="WORKTREE_DIFFERS_FROM_HEAD_OR_INDEX"
      fi
    else
      HEAD_BLOB="UNTRACKED_OR_NOT_IN_HEAD"
      MATCH="NOT_TRACKED_IN_HEAD"
    fi
    printf 'file=%s sha256=%s head_blob=%s state=%s\n' "$f" "$WORK_HASH" "$HEAD_BLOB" "$MATCH"
  else
    printf 'file=%s status=MISSING\n' "$f"
  fi
done
echo "SOURCE_SNAPSHOT_END"
echo

BIN="$ROOT/$NATIVE_BIN_REL"
if [ -f "$BIN" ]; then
  echo "NATIVE_BINARY_STATUS=FOUND"
  echo "binary=$BIN"
  echo "binary_size=$(stat -f '%z' "$BIN" 2>/dev/null || wc -c < "$BIN" | tr -d ' ')"
  echo "binary_mtime=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$BIN" 2>/dev/null || true)"
  echo "binary_sha256=$(shasum -a 256 "$BIN" | awk '{print $1}')"
  if command -v dwarfdump >/dev/null 2>&1; then
    echo "binary_uuid_begin"; dwarfdump --uuid "$BIN" 2>&1; echo "binary_uuid_end"
  fi
  if command -v otool >/dev/null 2>&1; then
    echo "binary_build_load_commands_begin"
    otool -l "$BIN" 2>/dev/null | awk '/cmd LC_BUILD_VERSION|cmd LC_VERSION_MIN_MACOSX|cmdsize|platform |minos |sdk / {print}'
    echo "binary_build_load_commands_end"
  fi
  if command -v nm >/dev/null 2>&1; then
    echo "binary_dma_symbols_begin"
    nm -gU "$BIN" 2>/dev/null | grep -E '(^|[[:space:]])(_?dma_ops|_?rtw88_dma_ops)$' || true
    echo "binary_dma_symbols_end"
  fi
  echo "BINARY_SOURCE_PROVENANCE=UNPROVEN"
  echo "provenance_reason=Mach-O UUID/hash identify this artifact, but do not encode the Git commit or source-tree state."
else
  echo "NATIVE_BINARY_STATUS=NOT_FOUND"
  echo "expected_binary=$BIN"
fi
echo
echo "NATIVE_TARGET_DRY_RUN"
if grep -Eq '^[[:alnum:]_.-]*rtl88wifi-native[[:alnum:]_.-]*[[:space:]]*:' driver/RTL88WiFi/Makefile; then
  (cd driver/RTL88WiFi && make -n -f Makefile rtl88wifi-native) 2>&1
  echo "native_dry_run_exit=$?"
else
  echo "native_target_name=NOT_CONFIRMED"
  echo "makefile_target_candidates:"
  grep -nE '^[[:alnum:]_.-]+[[:space:]]*:' driver/RTL88WiFi/Makefile | grep -iE 'native|kext' || true
fi
echo
echo "STAGE35C_RESULT=GIT_ROOT_RESOLVED"
echo "BINARY_PROVENANCE_GATE=BLOCKED_UNTIL_BUILD_STAMP_OR_REPRODUCIBLE_REBUILD"
echo "report=$REPORT"
echo "report_sha256=$(shasum -a 256 "$REPORT" | awk '{print $1}')"
echo "No source, build, install, kext-load, or OpenCore changes were made."
