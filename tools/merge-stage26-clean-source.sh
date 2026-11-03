#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/shammu2bd/Realtek-WIFI-Native-macOS.git"
ZIPNAME="RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source.zip"
SHA_EXPECTED="a381763935b7b8ada545eb4c1f6a4ad8e440a79097d3da57cb4673c08f7319db"
fail(){ echo "ERROR: $*" >&2; exit 1; }

for x in git unzip rsync python3 shasum; do command -v "$x" >/dev/null || fail "Missing $x"; done

ZIP=""
for x in "$HOME/Downloads/$ZIPNAME" "$HOME/Desktop/$ZIPNAME" "$HOME/Documents/$ZIPNAME"; do
  [[ -f "$x" ]] && ZIP="$x" && break
done
if [[ -z "$ZIP" ]]; then
  ZIP="$(find "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" -type f -iname '*stage26-clean-source*.zip' -print -quit 2>/dev/null || true)"
fi
[[ -n "$ZIP" && -f "$ZIP" ]] || fail "Cannot locate Stage26 source ZIP"
[[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" == "$SHA_EXPECTED" ]] || fail "Source ZIP checksum mismatch"
unzip -tq "$ZIP" >/dev/null

WORK="$(mktemp -d /tmp/rtl88wifi-stage26.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir "$WORK/unzip"
unzip -q "$ZIP" -d "$WORK/unzip"
SRC="$(find "$WORK/unzip" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -d "$SRC/driver/RTL88WiFi/src" ]] || fail "Unexpected source folder"

if command -v gh >/dev/null 2>&1; then gh auth setup-git >/dev/null 2>&1 || true; fi
git clone --branch main --single-branch "$REPO" "$WORK/repo"
cd "$WORK/repo"

rsync -a \
  --exclude='/README.md' --exclude='/CHANGELOG.md' --exclude='/output.log' \
  --exclude='__pycache__/' --exclude='*.pyc' --exclude='*.pyo' \
  --exclude='.DS_Store' --exclude='._*' "$SRC/" ./

SRC_DIR="$SRC" python3 <<'PY'
import os, re, hashlib, subprocess
from pathlib import Path
src = Path(os.environ["SRC_DIR"])
dst = Path.cwd()

raw = (src / "CHANGELOG.md").read_text(encoding="utf-8")
marker = "# Changelog"
pos = raw.find(marker)
if pos < 0: raise SystemExit("Main changelog heading missing")
preamble = raw[:pos].strip()
sections = [s.strip() for s in re.split(r"(?m)(?=^## )", raw[pos+len(marker):]) if s.strip()]
stages, releases, discontinued = [], {}, None
for s in sections:
    h = re.search(r"(?m)^## (.+)$", s)
    if not h: continue
    title = h.group(1)
    v = re.match(r"(?:RTL88WiFi )?([0-9]+\.[0-9]+\.[0-9]+)", title)
    if v: releases[v.group(1)] = s
    elif title.startswith("Discontinued"): discontinued = s
    else: stages.append(s)

for v in ("1.0.8","1.0.9","1.0.10","1.0.11"):
    p = src / ("CHANGELOG-" + v + ".md")
    lines = p.read_text(encoding="utf-8").strip().splitlines()
    if not lines or not lines[0].startswith("# RTL88WiFi " + v):
        raise SystemExit("Invalid " + p.name)
    lines[0] = "## " + lines[0][2:]
    for i in range(1,len(lines)):
        if lines[i].startswith("## "): lines[i] = "### " + lines[i][3:]
    releases[v] = "\n".join(lines).strip()

order = ["1.0.11","1.0.10","1.0.9","1.0.8","1.0.7","1.0.6","1.0.5","1.0.4","1.0.3","1.0.2","1.0.1","1.0.0"]
if set(releases) != set(order): raise SystemExit("Release history is incomplete")
if "Stage 12.1" not in preamble: raise SystemExit("Stage 12.1 missing")
out = ["# Changelog", preamble] + stages
for v in order:
    out.append(releases[v])
    if v == "1.0.1" and discontinued: out.append(discontinued)
merged = "\n\n".join(out).rstrip() + "\n"
found = re.findall(r"(?m)^## (?:RTL88WiFi )?([0-9]+\.[0-9]+\.[0-9]+)", merged)
if found != order: raise SystemExit("Changelog ordering check failed")
(dst / "CHANGELOG.md").write_text(merged, encoding="utf-8")
for v in ("1.0.8","1.0.9","1.0.10","1.0.11"):
    p = dst / ("CHANGELOG-" + v + ".md")
    if p.exists(): p.unlink()

readme = (src / "README.md").read_text(encoding="utf-8")
a = readme.find("> [!IMPORTANT]")
b = readme.find("> [!NOTE]", a)
if a < 0 or b < 0: raise SystemExit("README notice block missing")
notice = (
    "> [!IMPORTANT]\n"
    "> The original upstream legacy driver was marked discontinued after version 1.0.1.\n"
    "> This repository contains unofficial community source updates through 1.0.11 and\n"
    "> experimental native WCL porting work for macOS Sequoia 15.8.1 (24H32). Stage26\n"
    "> is source and ABI-audit work only, not a completed or hardware-validated native\n"
    "> WCL kext. Do not remove the legacy IO80211FamilyLegacy / IOSkywalkFamily\n"
    "> dependencies or the OpenCore Skywalk block when booting the existing legacy\n"
    "> kext. Keep a bootable EFI backup.\n\n"
)
readme = readme[:a] + notice + readme[b:]
readme = readme.replace(" and [CHANGELOG-1.0.11.md](CHANGELOG-1.0.11.md)", "")
readme = readme.replace("1.0.2–1.0.10", "1.0.2–1.0.11")
if "Sequoia 15.8.1: native WCL port in progress" not in readme:
    raise SystemExit("Stage26 README WCL note missing")
(dst / "README.md").write_text(readme, encoding="utf-8")

refs = 0
for p in dst.rglob("*"):
    if not p.is_file() or ".git" in p.parts or "__pycache__" in p.parts: continue
    if p.name == "output.log" or p.suffix in (".pyc",".pyo"): continue
    try: old = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError,OSError): continue
    new = old.replace("shammu2bd/BDIX-TV","shammu2bd/Realtek-WIFI-Native-macOS")
    if new != old: p.write_text(new,encoding="utf-8"); refs += 1
print("PASS: README and unified changelog")
print("PASS: Old repository references updated:", refs)

# Clean trailing whitespace from changed text files before manifest generation.
subprocess.run(["git","add","-A"],check=True)
names = subprocess.check_output(["git","diff","--cached","--name-only"],text=True).splitlines()
cleaned = 0
for name in names:
    p = dst / name
    if not p.is_file(): continue
    data = p.read_bytes()
    if b"\0" in data: continue
    try: data.decode("utf-8")
    except UnicodeDecodeError: continue
    new = re.sub(rb"[ \t]+(?=\r?$)",b"",data,flags=re.M)
    if new != data: p.write_bytes(new); cleaned += 1

manifest = []
for p in sorted(dst.rglob("*")):
    if not p.is_file() or ".git" in p.parts or "__pycache__" in p.parts: continue
    if p.name in ("SOURCE_PACKAGE_MANIFEST.txt","output.log",".DS_Store") or p.name.startswith("._"): continue
    if p.suffix in (".pyc",".pyo"): continue
    manifest.append(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.relative_to(dst).as_posix())
(dst / "SOURCE_PACKAGE_MANIFEST.txt").write_text("\n".join(manifest) + "\n",encoding="utf-8")
print("PASS: trailing whitespace normalized:", cleaned)
print("PASS: source manifest generated:", len(manifest))
PY

REQUIRED=(
tests/test-skywalk-packet-semantics-stage16.py tests/test-skywalk-queue-ownership-stage17.py
tests/test-stage18-ownership-review.py tests/test-wcl-abi-surface.py
tests/test-wcl-controller-lifecycle.py tests/test-wcl-generic-skywalk-segment-ref-stage14.py
tests/test-wcl-kcabi-reference-stage9.py tests/test-wcl-mbuf-tx-boundary.py
tests/test-wcl-packet-path-stage2.py tests/test-wcl-pci-backend-owner.py
tests/test-wcl-pcie-pool-ref-stage13.py tests/test-wcl-queue-pool-ref-stage12.py
tests/test-wcl-registration-abi-extractor-stage8.py tests/test-wcl-registration-abi-stage10.py
tests/test-wcl-registration-contract.py tests/test-wcl-registration-info-stage11.py
tests/test-wcl-rx-adapter-stage5.py tests/test-wcl-rx-packet-retention-stage7.py
tests/test-wcl-skywalk-queues.py tests/test-wcl-tx-adapter-stage4.py
tests/wcl-event-ring-test.cpp tests/wcl-request-decoder-test.cpp tests/wcl_mbuf_ring_test.cpp
tests/wcl_packet_span_test.cpp tests/wcl_registration_info_stage11_test.cpp
tests/wcl_rx_packet_address_test.cpp tests/wcl_tx_completion_slots_test.cpp
tools/apply-overlay-and-run.sh tools/audit-skywalk-packet-access-stage15.py
tools/audit-skywalk-packet-semantics-stage16.py tools/audit-skywalk-queue-ownership-stage17.py
tools/audit-skywalk-registration-24H32.py tools/build-stage18-ownership-review.py
tools/collect-sequoia-abi-24H32-stage12.sh tools/collect-sequoia-abi-24H32-stage13.sh
tools/collect-sequoia-abi-24H32-stage14.sh tools/collect-sequoia-abi-24H32-stage17.sh
tools/collect-sequoia-abi-24H32.sh tools/patch-kcabi-class-list-stage14.py
tools/patch-kcabi-class-list-stage17.py tools/prepare-kcabi-ref-24H32-stage12.py
tools/prepare-kcabi-ref-24H32-stage13.py tools/prepare-kcabi-ref-24H32-stage14.py
tools/prepare-kcabi-ref-24H32-stage17.py tools/prepare-kcabi-ref-24H32.py
tools/run-stage16.sh tools/run-stage17.sh tools/run-stage18.sh
)
for f in "${REQUIRED[@]}"; do [[ -f "$f" ]] || fail "Required file missing: $f"; done
[[ -f README.md && -f CHANGELOG.md && -f SOURCE_PACKAGE_MANIFEST.txt ]] || fail "README, changelog or manifest missing"
[[ ! -f output.log ]] || fail "Machine-specific output.log must not be committed"
for v in 1.0.8 1.0.9 1.0.10 1.0.11; do [[ ! -f "CHANGELOG-$v.md" ]] || fail "Duplicate changelog remains"; done

git add -A
git diff --cached --check || fail "Git whitespace check failed"
if git diff --cached --quiet; then echo "Repository already has the Stage26 source"; exit 0; fi

[[ -n "$(git config user.name || true)" ]] || git config user.name "RTL88WiFi Stage26 Merge"
[[ -n "$(git config user.email || true)" ]] || git config user.email "rtl88wifi-merge@users.noreply.github.com"
git diff --cached --stat
git commit -m "Merge Sequoia 15.8.1 Stage26 clean WCL source and documentation"

if ! git push origin main; then
  git fetch origin main
  git rebase origin/main || { git rebase --abort || true; fail "Rebase conflict; no force push made"; }
  git push origin main
fi

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git ls-remote origin refs/heads/main | awk 'NR==1 {print $1}')"
[[ -n "$REMOTE" && "$LOCAL" == "$REMOTE" ]] || fail "Remote commit verification failed"
echo
echo "STAGE26 MERGE SUCCESSFUL"
echo "Repository: $REPO"
echo "Branch: main"
echo "Commit: $LOCAL"
echo "README and changelog: verified"
echo "Stage16-18 tests and tools: verified"
echo "Remote verification: PASS"
