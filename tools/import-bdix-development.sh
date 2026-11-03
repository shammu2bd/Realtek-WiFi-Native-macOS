#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REPO="shammu2bd/BDIX-TV"
SOURCE_BRANCH="main"
TARGET_REPO="shammu2bd/Realtek-WiFi-Native-macOS"
TARGET_BRANCH="main"
TARGET_URL="https://github.com/${TARGET_REPO}.git"

fail() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

for tool in curl git unzip python3 rsync shasum awk grep wc tr; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

if command -v gh >/dev/null 2>&1; then
  gh auth setup-git >/dev/null 2>&1 || true
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rtl88wifi-development-import.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

say "Pinning the current BDIX-TV main branch"
SOURCE_SHA="$(git ls-remote "https://github.com/${SOURCE_REPO}.git" "refs/heads/${SOURCE_BRANCH}" | awk 'NR==1 {print $1}')"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Could not resolve source repository main branch"

ZIP="$WORK/bdix-tv-source.zip"
ZIP_URL="https://codeload.github.com/${SOURCE_REPO}/zip/${SOURCE_SHA}"
say "Downloading the pinned repository ZIP"
curl --fail --location --retry 3 --retry-delay 2 --silent --show-error "$ZIP_URL" --output "$ZIP"
unzip -tq "$ZIP" >/dev/null || fail "Downloaded source ZIP failed its integrity test"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "SOURCE_COMMIT=$SOURCE_SHA"
echo "SOURCE_ZIP_SHA256=$ZIP_SHA"

say "Extracting only Development/ from the ZIP"
mkdir -p "$WORK/source"
python3 - "$ZIP" "$WORK/source" <<'PY'
import os, pathlib, sys, zipfile
archive = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as z:
    matches = []
    roots = set()
    for info in z.infolist():
        name = info.filename.rstrip("/")
        parts = pathlib.PurePosixPath(name).parts
        if len(parts) >= 2 and parts[1] == "Development":
            matches.append((info, parts))
            roots.add(parts[0])
    if len(roots) != 1 or not matches:
        raise SystemExit("Could not uniquely locate Development/ inside source ZIP")
    files = 0
    total = 0
    for info, parts in matches:
        rel = pathlib.PurePosixPath(*parts[1:])
        if rel.is_absolute() or any(p in ("", ".", "..") for p in rel.parts):
            raise SystemExit("Unsafe path in ZIP: " + info.filename)
        dest = (out / pathlib.Path(*rel.parts)).resolve()
        if dest != out and out not in dest.parents:
            raise SystemExit("ZIP path escaped extraction directory: " + info.filename)
        if info.is_dir():
            dest.mkdir(parents=True, exist_ok=True)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        data = z.read(info)
        dest.write_bytes(data)
        mode = (info.external_attr >> 16) & 0o777
        if mode:
            os.chmod(dest, mode)
        files += 1
        total += len(data)
    if files == 0:
        raise SystemExit("Development/ contained no files")
    print("EXTRACTED_FILES=" + str(files))
    print("EXTRACTED_BYTES=" + str(total))
PY

SRC="$WORK/source/Development"
[[ -f "$SRC/output.log" ]] || fail "Development/output.log missing from source snapshot"
[[ -f "$SRC/RTL88WiFi-STAGE-HISTORY.md" ]] || fail "Master Stage 1–88 history missing"
[[ -f "$SRC/RTL88WiFi-ROADMAP-STAGE89-101.md" ]] || fail "Stage89–101 roadmap missing"
grep -q "STAGE88_RUN:" "$SRC/output.log" || fail "Stage88 checkpoint not found in output.log"

say "Updating active scripts to publish future runs to the renamed repository"
python3 - "$SRC" "$SOURCE_REPO" "$TARGET_REPO" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
old, new = sys.argv[2], sys.argv[3]
allowed = {".sh", ".bash", ".zsh", ".py", ".command"}
changed = 0
occurrences = 0
for p in root.rglob("*"):
    if not p.is_file() or p.suffix.lower() not in allowed:
        continue
    try:
        text = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    n = text.count(old)
    if n:
        p.write_text(text.replace(old, new), encoding="utf-8")
        changed += 1
        occurrences += n
print("ACTIVE_SCRIPTS_UPDATED=" + str(changed))
print("REPOSITORY_REFERENCES_UPDATED=" + str(occurrences))
PY

say "Writing migration provenance and checksum manifest"
cat > "$SRC/README-REPOSITORY-MIGRATION.md" <<EOF2
# Development folder migration

- Source repository: https://github.com/${SOURCE_REPO}
- Source branch: ${SOURCE_BRANCH}
- Pinned source commit: ${SOURCE_SHA}
- Source ZIP SHA-256: ${ZIP_SHA}
- Destination repository: https://github.com/${TARGET_REPO}
- Destination branch: ${TARGET_BRANCH}
- Imported path: Development/

The complete tracked Development directory was extracted from the pinned source
repository archive and merged into this repository. This includes the stage
history, output.log, audit reports, run folders, scripts, documentation and
source archives present at the pinned commit.

Active shell, Python and command scripts were updated so their repository
references point to the destination repository. Historical logs and reports
were left unchanged to preserve their original evidence and provenance.

This import does not modify the driver source outside Development/, build a
kext, install or load a driver, or change OpenCore.
EOF2

python3 - "$SRC" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = root / "TRANSFER-MANIFEST.sha256"
rows = []
for p in sorted(root.rglob("*")):
    if not p.is_file() or p == manifest:
        continue
    rel = p.relative_to(root).as_posix()
    rows.append(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + rel)
manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")
print("TRANSFER_MANIFEST_ENTRIES=" + str(len(rows)))
PY

say "Cloning the destination repository"
git clone --branch "$TARGET_BRANCH" --single-branch "$TARGET_URL" "$WORK/destination"
DEST="$WORK/destination"
mkdir -p "$DEST/Development"

say "Merging Development/ into the destination repository"
rsync -a "$SRC/" "$DEST/Development/"

say "Verifying the imported history and Stage88 checkpoint"
[[ -f "$DEST/Development/output.log" ]] || fail "Destination output.log missing"
[[ -f "$DEST/Development/RTL88WiFi-STAGE-HISTORY.md" ]] || fail "Destination master history missing"
[[ -f "$DEST/Development/RTL88WiFi-ROADMAP-STAGE89-101.md" ]] || fail "Destination roadmap missing"
[[ -f "$DEST/Development/TRANSFER-MANIFEST.sha256" ]] || fail "Destination transfer manifest missing"
grep -q "STAGE88_RUN:" "$DEST/Development/output.log" || fail "Destination output.log has no Stage88 checkpoint"
cmp "$SRC/TRANSFER-MANIFEST.sha256" "$DEST/Development/TRANSFER-MANIFEST.sha256" >/dev/null || fail "Transfer manifest copy mismatch"

OLD_REFS="$(grep -RIl --include='*.sh' --include='*.bash' --include='*.zsh' --include='*.py' --include='*.command' "$SOURCE_REPO" "$DEST/Development" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$OLD_REFS" == "0" ]] || fail "Some active scripts still reference the old repository name"

git -C "$DEST" add -A -- Development
say "Reviewing the staged transfer"
git -C "$DEST" -c core.pager=cat diff --cached --stat

if git -C "$DEST" diff --cached --quiet; then
  say "Development is already synchronized; no new commit is needed"
else
  if [[ -z "$(git -C "$DEST" config user.name || true)" ]]; then
    git -C "$DEST" config user.name "RTL88WiFi Development Import"
  fi
  if [[ -z "$(git -C "$DEST" config user.email || true)" ]]; then
    git -C "$DEST" config user.email "rtl88wifi-import@users.noreply.github.com"
  fi
  git -C "$DEST" -c core.pager=cat commit -m "Import complete BDIX-TV Development history through Stage88"
fi

say "Pushing to the renamed repository"
if ! git -C "$DEST" push origin "$TARGET_BRANCH"; then
  git -C "$DEST" fetch origin "$TARGET_BRANCH"
  git -C "$DEST" rebase "origin/$TARGET_BRANCH" || {
    git -C "$DEST" rebase --abort || true
    fail "Rebase conflict; no force push was attempted"
  }
  git -C "$DEST" push origin "$TARGET_BRANCH"
fi

LOCAL_SHA="$(git -C "$DEST" rev-parse HEAD)"
REMOTE_SHA="$(git ls-remote "$TARGET_URL" "refs/heads/${TARGET_BRANCH}" | awk 'NR==1 {print $1}')"
[[ -n "$REMOTE_SHA" && "$LOCAL_SHA" == "$REMOTE_SHA" ]] || fail "Remote commit verification failed"

echo
echo "DEVELOPMENT IMPORT SUCCESSFUL"
echo "SOURCE_REPOSITORY=https://github.com/${SOURCE_REPO}"
echo "SOURCE_COMMIT=${SOURCE_SHA}"
echo "DESTINATION_REPOSITORY=https://github.com/${TARGET_REPO}"
echo "BRANCH=${TARGET_BRANCH}"
echo "COMMIT=${LOCAL_SHA}"
echo "STAGE_HISTORY=1_TO_88_TRANSFERRED"
echo "ROADMAP=STAGE89_TO_101_TRANSFERRED"
echo "ACTIVE_SCRIPT_REPOSITORY_REFERENCES=UPDATED"
echo "TRANSFER_MANIFEST=GENERATED"
echo "REMOTE_VERIFICATION=PASS"
