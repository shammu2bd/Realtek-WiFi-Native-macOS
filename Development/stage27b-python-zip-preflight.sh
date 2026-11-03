#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
ARCHIVE="$HOME/Downloads/$NEW_NAME.zip"
DRIVER="$PROJECT/driver/RTL88WiFi"
TARGET_INFO="$DRIVER/RTL88WiFi.kext/Contents/Info.plist"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27b-python-zip-preflight-$STAMP"
OUT="$PROJECT/output.log"
DRYRUN="$STAGE_DIR/make-dry-run.txt"
STATUS="$STAGE_DIR/status.txt"
FINAL_RC=0
ARCHIVE_VERIFIED=0

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project/Makefile missing: $PROJECT" >&2
    exit 2
fi
mkdir -p "$STAGE_DIR"

# Preserve the current remote development log when GitHub CLI access is available.
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
    echo "RTL88WiFi Stage27b — rebuild source ZIP with Python and validate exact archive member"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "PROJECT: $PROJECT"
    echo "BUILD_NAME: $NEW_NAME"
    echo "PURPOSE: replace fragile archive-list text matching with exact ZIP member inspection"
    echo "BUILD: NOT RUN"
    echo "INSTALL: NOT RUN"
    echo "LOAD: NOT RUN"
} >> "$OUT"

if [ ! -f "$TARGET_INFO" ]; then
    echo "ERROR: restored source Info.plist is missing: $TARGET_INFO" | tee "$STATUS" >&2
    FINAL_RC=3
elif ! plutil -lint "$TARGET_INFO" > "$STAGE_DIR/plutil-lint.txt" 2>&1; then
    {
        echo "ERROR: source Info.plist failed plutil validation"
        cat "$STAGE_DIR/plutil-lint.txt"
    } | tee "$STATUS" >&2
    FINAL_RC=4
else
    INFO_SHA="$(shasum -a 256 "$TARGET_INFO" | awk '{print $1}')"

    # Regenerate the source manifest; keep source .kext bundles and plist files.
    python3 - "$PROJECT" <<'PY' > "$STAGE_DIR/manifest-status.txt"
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1])
manifest = []
for p in sorted(root.rglob("*")):
    if not p.is_file():
        continue
    rel = p.relative_to(root)
    if "build" in rel.parts or any(part.endswith(".dSYM") for part in rel.parts):
        continue
    if ".DS_Store" in rel.parts or rel.as_posix() == "SOURCE_PACKAGE_MANIFEST.txt":
        continue
    manifest.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {rel.as_posix()}")
(root / "SOURCE_PACKAGE_MANIFEST.txt").write_text("\n".join(manifest) + "\n")
print("SOURCE_FILES_IN_MANIFEST:", len(manifest))
print("INFO_PLIST_IN_MANIFEST:", any(line.endswith("  driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist") for line in manifest))
PY

    # Use Python zipfile and verify the exact member name.
    TMP_ARCHIVE="$ARCHIVE.stage27b.tmp.zip"
    rm -f "$TMP_ARCHIVE"
    set +e
    python3 - "$PROJECT" "$TMP_ARCHIVE" "$NEW_NAME" <<'PY' > "$STAGE_DIR/zip-create-verify.txt" 2>&1
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import sys
root = Path(sys.argv[1])
dest = Path(sys.argv[2])
top = sys.argv[3]
expected = f"{top}/driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist"
count = 0
with ZipFile(dest, "w", compression=ZIP_DEFLATED, compresslevel=6) as z:
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if "build" in rel.parts or any(part.endswith(".dSYM") for part in rel.parts):
            continue
        if ".DS_Store" in rel.parts:
            continue
        if p.is_file():
            z.write(p, f"{top}/{rel.as_posix()}")
            count += 1
with ZipFile(dest, "r") as z:
    bad = z.testzip()
    names = set(z.namelist())
    if bad:
        raise SystemExit(f"ZIP_TEST_FAILED: corrupt member {bad}")
    if expected not in names:
        matches = sorted(n for n in names if n.endswith("/RTL88WiFi.kext/Contents/Info.plist") or n.endswith("/Contents/Info.plist"))
        print("EXPECTED_MEMBER_MISSING:", expected)
        print("OTHER_INFO_PLIST_MEMBERS:", matches)
        raise SystemExit(10)
    print("ZIP_TEST: PASS")
    print("EXACT_INFO_PLIST_MEMBER: PASS", expected)
    print("REGULAR_FILES_ADDED:", count)
    print("ARCHIVE_MEMBER_COUNT:", len(names))
PY
    ZIP_RC=$?
    set -e

    if [ "$ZIP_RC" -eq 0 ]; then
        ARCHIVE_VERIFIED=1
        mv "$TMP_ARCHIVE" "$ARCHIVE"
        ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
        ARCHIVE_SIZE="$(stat -f '%z' "$ARCHIVE" 2>/dev/null || wc -c < "$ARCHIVE" | tr -d ' ')"

        cd "$DRIVER"
        set +e
        make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
        DRY_RC=$?
        set -e
        if [ "$DRY_RC" -eq 0 ]; then
            for source in RTW88WCLController.cpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
                if ! grep -Fq "$source" "$DRYRUN"; then
                    echo "DRY_RUN_STATUS: FAIL — Makefile output omitted $source" > "$STAGE_DIR/dryrun-status.txt"
                    DRY_RC=11
                    break
                fi
            done
        fi
        if [ "$DRY_RC" -eq 0 ]; then
            echo "DRY_RUN_STATUS: PASS — controller, PCI backend and Skywalk queues included" > "$STAGE_DIR/dryrun-status.txt"
        else
            echo "DRY_RUN_STATUS: FAIL — make dry-run exit $DRY_RC" > "$STAGE_DIR/dryrun-status.txt"
        fi

        {
            echo "STAGE27B_PACKAGE_STATUS: PASS"
            cat "$STAGE_DIR/manifest-status.txt"
            echo "SOURCE_INFO_PLIST_SHA256: $INFO_SHA"
            cat "$STAGE_DIR/plutil-lint.txt"
            cat "$STAGE_DIR/zip-create-verify.txt"
            echo "FULL_SOURCE_ZIP: $ARCHIVE"
            echo "ARCHIVE_SIZE_BYTES: $ARCHIVE_SIZE"
            echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
            cat "$STAGE_DIR/dryrun-status.txt"
            if [ "$DRY_RC" -ne 0 ]; then
                echo "MAKE_DRY_RUN_LAST_80_LINES:"
                tail -80 "$DRYRUN"
            fi
        } | tee "$STATUS"

        {
            echo
            echo "STAGE27B_PACKAGE_STATUS: PASS"
            cat "$STATUS"
            echo "BUILD: NOT RUN"
            echo "INSTALL: NOT RUN"
            echo "LOAD: NOT RUN"
            echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
            echo "OLD_STAGE14_TREE: READ-ONLY SOURCE METADATA REFERENCE ONLY"
            echo "QUEUE_REGISTRATION: STILL DISABLED"
            echo "NEXT: run Stage27 compile-only runner only when DRY_RUN_STATUS is PASS"
        } >> "$OUT"
        FINAL_RC="$DRY_RC"
    else
        {
            echo "STAGE27B_PACKAGE_STATUS: FAILED — Python ZIP creation/verification exit $ZIP_RC"
            cat "$STAGE_DIR/manifest-status.txt"
            echo "SOURCE_INFO_PLIST_SHA256: $INFO_SHA"
            cat "$STAGE_DIR/zip-create-verify.txt"
            echo "BUILD: NOT RUN"
        } | tee "$STATUS" >&2
        {
            echo
            cat "$STATUS"
            echo "INSTALL: NOT RUN"
            echo "LOAD: NOT RUN"
            echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
        } >> "$OUT"
        FINAL_RC=5
    fi
fi

if [ "$FINAL_RC" -eq 3 ] || [ "$FINAL_RC" -eq 4 ]; then
    {
        echo
        echo "STAGE27B_PACKAGE_STATUS: FAILED"
        cat "$STATUS"
        echo "BUILD: NOT RUN"
        echo "INSTALL: NOT RUN"
        echo "LOAD: NOT RUN"
    } >> "$OUT"
fi

upload_file() {
    local local_file="$1" repo_path="$2" message="$3"
    local api_path="repos/$REPO/contents/$repo_path" sha payload
    sha="$(gh api "$api_path" --jq '.sha' 2>/dev/null || true)"
    payload="$STAGE_DIR/upload-$(basename "$local_file").json"
    python3 - "$local_file" "$message" "$sha" "$payload" <<'PY'
import base64, json, pathlib, sys
file, message, sha, dest = sys.argv[1:]
obj={"message":message,"content":base64.b64encode(pathlib.Path(file).read_bytes()).decode("ascii")}
if sha:
    obj["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(obj))
PY
    gh api --method PUT "$api_path" --input "$payload" >/dev/null
}

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if [ "$ARCHIVE_VERIFIED" -eq 1 ] && [ -f "$ARCHIVE" ]; then
        upload_file "$ARCHIVE" "Development/$(basename "$ARCHIVE")" "Stage27b repack source ZIP and verify Info.plist"
    fi
    upload_file "$OUT" "Development/output.log" "Stage27b Python ZIP packaging and Makefile dry-run result"
    echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development/output.log updated"
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local report retained"
fi

echo "PROJECT: $PROJECT"
echo "ARCHIVE: $ARCHIVE"
echo "STATUS: $STATUS"
echo "REPORT: $OUT"
exit "$FINAL_RC"
