#!/bin/bash
set -euo pipefail

REPO="shammu2bd/Realtek-WiFi-Native-macOS"
NEW_NAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
PROJECT="$HOME/Downloads/$NEW_NAME"
DRIVER="$PROJECT/driver/RTL88WiFi"
ARCHIVE="$HOME/Downloads/$NEW_NAME.zip"
OLD_SOURCE="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-stage14-generic-skywalk-segment-abi"
SOURCE_INFO="$OLD_SOURCE/driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist"
TARGET_INFO="$DRIVER/RTL88WiFi.kext/Contents/Info.plist"
STAMP="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="$PROJECT/build/stage27a-info-plist-repair-$STAMP"
OUT="$PROJECT/output.log"
DRYRUN="$STAGE_DIR/make-dry-run.txt"

if [ ! -f "$PROJECT/BUILD_NAME.txt" ] || [ ! -f "$DRIVER/Makefile" ]; then
    echo "ERROR: Stage26 project/Makefile missing: $PROJECT" >&2
    exit 2
fi
if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: zip and unzip utilities are required." >&2
    exit 3
fi
mkdir -p "$STAGE_DIR"

# Preserve the latest remote Development/output.log before appending.
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
    echo "RTL88WiFi Stage27a — restore source Info.plist omitted by Stage26 archive filter"
    echo "DATE: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "NEW_PROJECT: $PROJECT"
    echo "BUILD_NAME: $NEW_NAME"
    echo "STAGE_DIR: $STAGE_DIR"
    echo "STAGE27_USER_ERROR: make dry-run exit 2 — no rule to make target RTL88WiFi.kext/Contents/Info.plist"
    echo "ROOT_CAUSE: Stage26 rsync used a broad *.kext exclusion and omitted the source metadata bundle."
    echo "RECOVERY_SCOPE: copy only Info.plist into the new project; old source tree is read-only and is NOT a build directory."
} >> "$OUT"

if [ -f "$TARGET_INFO" ]; then
    echo "SOURCE_INFO_STATUS: already present in new project; will validate existing file" | tee "$STAGE_DIR/info-status.txt"
elif [ -f "$SOURCE_INFO" ]; then
    mkdir -p "$(dirname "$TARGET_INFO")"
    cp -p "$SOURCE_INFO" "$TARGET_INFO"
    echo "SOURCE_INFO_STATUS: copied read-only source metadata into new project" | tee "$STAGE_DIR/info-status.txt"
    echo "SOURCE_INFO_ORIGIN: $SOURCE_INFO" >> "$STAGE_DIR/info-status.txt"
else
    {
        echo "SOURCE_INFO_STATUS: FAILED"
        echo "EXPECTED_NEW_TREE: $TARGET_INFO"
        echo "READ_ONLY_SOURCE_REFERENCE: $SOURCE_INFO"
        echo "BUILD: NOT RUN"
    } | tee "$STAGE_DIR/info-status.txt"
    {
        echo "INFO_PLIST_REPAIR: FAILED — source Info.plist was not found."
        cat "$STAGE_DIR/info-status.txt"
        echo "OLD_SOURCE_TREE: NOT MODIFIED"
        echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
    } >> "$OUT"
    FINAL_RC=4
    goto_upload=1
fi

if [ "${goto_upload:-0}" -eq 0 ]; then
    if ! plutil -lint "$TARGET_INFO" > "$STAGE_DIR/plutil-lint.txt" 2>&1; then
        {
            echo "INFO_PLIST_REPAIR: FAILED — plist validation failed"
            cat "$STAGE_DIR/plutil-lint.txt"
            echo "BUILD: NOT RUN"
        } >> "$OUT"
        FINAL_RC=5
        goto_upload=1
    fi
fi

if [ "${goto_upload:-0}" -eq 0 ]; then
    INFO_SHA="$(shasum -a 256 "$TARGET_INFO" | awk '{print $1}')"
    echo "SOURCE_INFO_SHA256: $INFO_SHA" >> "$STAGE_DIR/info-status.txt"

    # Rebuild the manifest after adding the source metadata file.
    python3 - "$PROJECT" <<'PY'
from pathlib import Path
import hashlib, sys
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
print("SOURCE_FILES_IN_MANIFEST:", len(manifest))
PY

    # Repackage the source with only generated build output excluded. Do NOT
    # exclude *.kext globally: RTL88WiFi.kext/Contents/Info.plist is source input.
    TMP_ARCHIVE="$ARCHIVE.stage27a.tmp.zip"
    rm -f "$TMP_ARCHIVE"
    (
        cd "$HOME/Downloads"
        COPYFILE_DISABLE=1 zip -qr "$TMP_ARCHIVE" "$NEW_NAME" \
            -x "$NEW_NAME/build/*" "$NEW_NAME/driver/RTL88WiFi/build/*" \
               "*.dSYM/*" "*/.DS_Store"
    )
    unzip -t "$TMP_ARCHIVE" > "$STAGE_DIR/zip-test.txt"
    mv "$TMP_ARCHIVE" "$ARCHIVE"
    ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    ARCHIVE_SIZE="$(stat -f '%z' "$ARCHIVE" 2>/dev/null || wc -c < "$ARCHIVE" | tr -d ' ')"
    if ! unzip -l "$ARCHIVE" | grep -Fq "$NEW_NAME/driver/RTL88WiFi/RTL88WiFi.kext/Contents/Info.plist"; then
        echo "ERROR: repackaged ZIP still lacks source Info.plist" >&2
        exit 6
    fi

    # Re-run only the make dry-run now that the missing prerequisite is present.
    cd "$DRIVER"
    set +e
    make -B -n -j1 rtl88wifi > "$DRYRUN" 2>&1
    DRY_RC=$?
    set -e
    if [ "$DRY_RC" -eq 0 ]; then
        for source in RTW88WCLController.cpp RTW88WCLPCIBackend.cpp RTW88WCLSkywalkQueues.cpp; do
            if ! grep -Fq "$source" "$DRYRUN"; then
                echo "DRY_RUN_STATUS: FAIL — Makefile output omitted $source" > "$STAGE_DIR/dryrun-status.txt"
                DRY_RC=7
                break
            fi
        done
    fi
    if [ "$DRY_RC" -eq 0 ]; then
        echo "DRY_RUN_STATUS: PASS — make -B -n rtl88wifi includes controller, PCI backend and Skywalk queues" > "$STAGE_DIR/dryrun-status.txt"
    else
        echo "DRY_RUN_STATUS: FAIL — make dry-run exit $DRY_RC" > "$STAGE_DIR/dryrun-status.txt"
    fi

    {
        echo
        echo "INFO_PLIST_REPAIR: PASS"
        cat "$STAGE_DIR/info-status.txt"
        echo "SOURCE_MANIFEST_FILES: $(wc -l < "$PROJECT/SOURCE_PACKAGE_MANIFEST.txt" | tr -d ' ')"
        echo "FULL_SOURCE_ZIP: $ARCHIVE"
        echo "ARCHIVE_SIZE_BYTES: $ARCHIVE_SIZE"
        echo "ARCHIVE_SHA256: $ARCHIVE_SHA"
        cat "$STAGE_DIR/zip-test.txt"
        cat "$STAGE_DIR/dryrun-status.txt"
        if [ "$DRY_RC" -ne 0 ]; then
            echo "MAKE_DRY_RUN_LAST_80_LINES:"
            tail -80 "$DRYRUN"
        fi
        echo "BUILD: NOT RUN BY STAGE27a"
        echo "INSTALL: NOT RUN"
        echo "LOAD: NOT RUN"
        echo "OLD_SOURCE_TREE: READ-ONLY METADATA REFERENCE ONLY; NO BUILD THERE"
        echo "KNOWN_GOOD_OLD_RTL88WIFI_KEXT: NOT TOUCHED"
        echo "QUEUE_REGISTRATION: STILL DISABLED"
    } >> "$OUT"
    FINAL_RC="$DRY_RC"
fi

upload_file() {
    local local_file="$1" repo_path="$2" message="$3"
    local api_path="repos/$REPO/contents/$repo_path" sha payload
    sha="$(gh api "$api_path" --jq '.sha' 2>/dev/null || true)"
    payload="$STAGE_DIR/upload.json"
    python3 - "$local_file" "$message" "$sha" "$payload" <<'PY'
import base64, json, pathlib, sys
file, message, sha, dest = sys.argv[1:]
obj={"message":message,"content":base64.b64encode(pathlib.Path(file).read_bytes()).decode("ascii")}
if sha: obj["sha"]=sha
pathlib.Path(dest).write_text(json.dumps(obj))
PY
    gh api --method PUT "$api_path" --input "$payload" >/dev/null
}
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if [ -f "$ARCHIVE" ]; then
        upload_file "$ARCHIVE" "Development/$(basename "$ARCHIVE")" "Stage27a restore source Info.plist and refresh full source ZIP"
    fi
    upload_file "$OUT" "Development/output.log" "Stage27a source Info.plist recovery and Makefile dry-run"
    echo "GITHUB_UPLOAD_STATUS: SUCCESS — Development archive and output.log updated"
else
    echo "GITHUB_UPLOAD_STATUS: GH_CLI_NOT_AUTHENTICATED — local outputs ready"
fi

echo "NEW_PROJECT: $PROJECT"
echo "INFO_PLIST: $TARGET_INFO"
echo "ARCHIVE: $ARCHIVE"
echo "REPORT: $OUT"
exit "$FINAL_RC"
