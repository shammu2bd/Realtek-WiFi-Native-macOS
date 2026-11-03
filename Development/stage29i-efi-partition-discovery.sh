#!/bin/bash
set -u

REPO='shammu2bd/Realtek-WiFi-Native-macOS'
API="repos/$REPO/contents/Development/output.log"
NAME='RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source'
PROJECT=''

if [[ -f "$PWD/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$PWD"
elif [[ -f "$HOME/Downloads/$NAME/driver/RTL88WiFi/Makefile" ]]; then
  PROJECT="$HOME/Downloads/$NAME"
fi

if [[ -z "$PROJECT" ]]; then
  echo 'Cannot locate Stage26 project. Run from the project root or keep it in ~/Downloads.'
  exit 2
fi

LOG="$PROJECT/output.log"
STAGE="$PROJECT/build/stage29i-efi-partition-discovery-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STAGE" || exit 2

command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required.'; exit 2; }
gh auth status >/dev/null 2>&1 || { echo 'GitHub CLI authentication required.'; exit 2; }

gh api "$API" > "$STAGE/remote-log.json" || exit 2
python3 - "$STAGE/remote-log.json" "$LOG" <<'PY'
import base64, json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
data = base64.b64decode(doc.get("content", ""))
text = data.decode("utf-8", errors="replace")
required = ["STAGE29H: READ_ONLY_AUDIT_COMPLETE", "NATIVE_ACTUAL_BUILD: PASS"]
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit("Canonical log is missing prerequisite markers: " + ", ".join(missing))
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
[[ $? -eq 0 ]] || { echo 'Canonical output.log validation failed.'; exit 2; }

sw_vers > "$STAGE/sw_vers.txt" 2>&1
diskutil list > "$STAGE/diskutil-list.txt" 2>&1
DISK_LIST_RC=$?
diskutil list -plist > "$STAGE/diskutil-list.plist" 2> "$STAGE/diskutil-list-plist-error.txt"
DISK_PLIST_RC=$?
mount > "$STAGE/mounts.txt" 2>&1
diskutil info / > "$STAGE/root-volume-info.txt" 2>&1
ROOT_INFO_RC=$?
bless --getBoot > "$STAGE/bless-getboot.txt" 2>&1
BLESS_RC=$?

python3 - "$STAGE" <<'PY'
from pathlib import Path
import hashlib, plistlib, subprocess, sys

stage = Path(sys.argv[1])
report = [
    "RTL88WiFi Stage29i — read-only EFI system partition discovery",
    "PURPOSE: identify EFI partition candidates and inspect already-mounted OpenCore configs only",
    "MOUNT_ACTION: NONE",
    "WRITE_TO_EFI: NONE",
    "OPENCORE_CHANGE: NONE",
]
plist_path = stage / "diskutil-list.plist"
partitions = []
try:
    doc = plistlib.loads(plist_path.read_bytes())
    for disk in doc.get("AllDisksAndPartitions", []):
        for part in disk.get("Partitions", []):
            content = str(part.get("Content", "")).upper()
            ptype = str(part.get("PartitionType", "")).upper()
            if content == "EFI" or ptype == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B":
                dev = part.get("DeviceIdentifier")
                if dev:
                    partitions.append((disk.get("DeviceIdentifier", ""), dev, part))
except Exception as exc:
    report.append("DISKUTIL_PLIST_PARSE: FAILED: " + str(exc))

report.append("EFI_PARTITION_COUNT: {}".format(len(partitions)))
mounted_roots = set()
for parent, dev, part in partitions:
    report.append("")
    report.append("EFI_PARTITION: " + dev)
    report.append("  PARENT_DISK: " + str(parent))
    report.append("  SIZE: " + str(part.get("Size", "<unknown>")))
    try:
        raw = subprocess.check_output(["diskutil", "info", "-plist", dev], stderr=subprocess.STDOUT)
        info = plistlib.loads(raw)
        mountpoint = info.get("MountPoint") or ""
        report.append("  VOLUME_NAME: " + str(info.get("VolumeName", "<none>")))
        report.append("  FILESYSTEM: " + str(info.get("FilesystemType", info.get("FileSystemPersonality", "<unknown>"))))
        report.append("  MOUNT_POINT: " + (mountpoint if mountpoint else "<not mounted>"))
        report.append("  DEVICE_NODE: " + str(info.get("DeviceNode", "<unknown>")))
        if mountpoint:
            mounted_roots.add(mountpoint)
        else:
            report.append("  MANUAL_MOUNT_COMMAND: sudo diskutil mount " + dev)
    except Exception as exc:
        report.append("  DISKUTIL_INFO_ERROR: " + str(exc))

report.append("")
report.append("=== OPENCORE CONFIG SEARCH (MOUNTED VOLUMES ONLY) ===")
configs = set()
for root in mounted_roots:
    cfg = Path(root) / "EFI" / "OC" / "config.plist"
    if cfg.is_file():
        configs.add(cfg)
volumes = Path("/Volumes")
if volumes.is_dir():
    for cfg in volumes.glob("*/EFI/OC/config.plist"):
        if cfg.is_file():
            configs.add(cfg)
root_cfg = Path("/EFI/OC/config.plist")
if root_cfg.is_file():
    configs.add(root_cfg)

report.append("OPENCORE_CONFIG_COUNT: {}".format(len(configs)))
for cfg in sorted(configs, key=lambda p: str(p)):
    report.append("")
    report.append("OPENCORE_CONFIG: " + str(cfg))
    try:
        raw = cfg.read_bytes()
        data = plistlib.loads(raw)
        report.append("  CONFIG_SHA256: " + hashlib.sha256(raw).hexdigest())
        nvram_guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
        add = data.get("NVRAM", {}).get("Add", {}).get(nvram_guid, {})
        csr = add.get("csr-active-config", "<unset>")
        if isinstance(csr, bytes):
            csr = csr.hex()
        report.append("  NVRAM_ADD_CSR_ACTIVE_CONFIG: " + str(csr))
        bootargs = add.get("boot-args", "<unset>")
        report.append("  NVRAM_ADD_BOOT_ARGS: " + str(bootargs))
        sec = data.get("Misc", {}).get("Security", {})
        report.append("  SECURE_BOOT_MODEL: " + str(sec.get("SecureBootModel", "<unset>")))
        adds = data.get("Kernel", {}).get("Add", [])
        report.append("  KERNEL_ADD_COUNT: " + str(len(adds)))
        for entry in adds:
            bundle = str(entry.get("BundlePath", ""))
            comment = str(entry.get("Comment", ""))
            ident = bundle + " " + comment
            if any(key.lower() in ident.lower() for key in ["rtl88", "airport", "lilu", "amfipass"]):
                report.append("  KERNEL_ADD_RELEVANT: BundlePath={} | Enabled={} | Arch={} | Comment={}".format(
                    bundle, entry.get("Enabled", "<unset>"), entry.get("Arch", "<unset>"), comment))
        blocks = data.get("Kernel", {}).get("Block", [])
        for entry in blocks:
            ident = str(entry.get("Identifier", ""))
            if "IOSkywalk" in ident or "IO80211" in ident:
                report.append("  KERNEL_BLOCK_RELEVANT: Identifier={} | Enabled={} | Comment={}".format(
                    ident, entry.get("Enabled", "<unset>"), entry.get("Comment", "")))
    except Exception as exc:
        report.append("  CONFIG_PARSE_ERROR: " + str(exc))

if not configs:
    report.append("No EFI/OC/config.plist was readable on mounted volumes.")
    if partitions:
        report.append("NEXT_ACTION: mount the correct EFI partition using the exact MANUAL_MOUNT_COMMAND above, then rerun Stage29i.")
    else:
        report.append("NEXT_ACTION: review diskutil-list.txt; no EFI partition was identified by diskutil list -plist.")

report.append("")
report.append("=== SAFETY ===")
report.append("No EFI partition was mounted by this script.")
report.append("No OpenCore plist, NVRAM setting, SIP setting, filesystem ownership, kext, or boot entry was changed.")
report.append("The everyday EFI and currently loaded legacy driver remain untouched.")
report.append("STAGE29I: READ_ONLY_DISCOVERY_COMPLETE")
(stage / "stage29i-report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
print("\n".join(report))
PY
RC=$?

{
  echo
  echo '========== STAGE29I READ-ONLY EFI PARTITION DISCOVERY =========='
  echo "STAGE_DIR: $STAGE"
  echo "DISKUTIL_LIST_EXIT: $DISK_LIST_RC"
  echo "DISKUTIL_LIST_PLIST_EXIT: $DISK_PLIST_RC"
  echo "ROOT_VOLUME_INFO_EXIT: $ROOT_INFO_RC"
  echo "BLESS_GETBOOT_EXIT: $BLESS_RC"
  echo 'BLESS_GETBOOT_OUTPUT_BEGIN'
  cat "$STAGE/bless-getboot.txt" 2>/dev/null || true
  echo 'BLESS_GETBOOT_OUTPUT_END'
  echo 'ROOT_VOLUME_INFO_BEGIN'
  grep -E 'Device Identifier|Device Node|Part of Whole|Volume Name|Mount Point|APFS Physical Store|Disk / Partition UUID|Protocol' "$STAGE/root-volume-info.txt" 2>/dev/null || true
  echo 'ROOT_VOLUME_INFO_END'
  cat "$STAGE/stage29i-report.txt" 2>/dev/null || true
  echo 'DISKUTIL_LIST_BEGIN'
  cat "$STAGE/diskutil-list.txt" 2>/dev/null || true
  echo 'DISKUTIL_LIST_END'
  echo "STAGE29I_ANALYSIS_EXIT: $RC"
  echo 'MOUNT_ACTION: NONE'
  echo 'OPENCORE_CHANGE: NONE'
  echo 'INSTALL: NOT RUN'
  echo 'LOAD: NOT RUN'
  echo 'KNOWN_GOOD_LEGACY_KEXT: NOT TOUCHED'
} >> "$LOG"

SHA=$(gh api "$API" --jq '.sha') || exit 2
python3 - "$LOG" "$SHA" "$STAGE/payload.json" <<'PY'
import base64, json, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({
    "message": "Stage29i read-only EFI partition discovery",
    "content": base64.b64encode(data).decode(),
    "sha": sys.argv[2]
}))
PY
gh api --method PUT "$API" --input "$STAGE/payload.json" > "$STAGE/response.json" || exit 2
PUT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["content"]["sha"])' "$STAGE/response.json")
READ=$(gh api "$API" --jq '.sha') || exit 2
[[ -n "$PUT" && "$PUT" == "$READ" ]] || { echo 'GitHub read-back SHA mismatch'; exit 2; }

echo 'GITHUB_UPLOAD_STATUS: SUCCESS — verified Development/output.log'
exit "$RC"
