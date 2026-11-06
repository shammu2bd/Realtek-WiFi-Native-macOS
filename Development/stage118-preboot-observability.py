#!/usr/bin/env python3
"""Stage118: read-only preboot observability and OpenCore debug-profile proposal.

Inspects an already-mounted EFI and current runtime state. It does NOT edit config.plist,
mount/write EFI, alter SIP/NVRAM, reboot, sign, build, install, load/unload, or test radio.
The proposed values are printed for manual review only.
"""
from __future__ import print_function
import hashlib
import json
import os
import plistlib
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

BRANCH = "work/stage118-preboot-observability"
BASE = "b74c0f8b5539a3a3c17375e1c1cacbe124ae8e42"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", DEFAULT_CONFIG))
NATIVE_NAME = "RTL88WiFiNative.kext"
NATIVE_EXEC = "RTL88WiFiNative"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage118-preboot-observability.py")
ALLOWLIST = Path("Development/Allowlist/stage118-preboot-observability.gitblob")

# Conservative file-only OpenCore logging proposal:
# 0x01 = enable logging; 0x40 = write log to file. No on-screen logging or fast/unsafe bit.
PROPOSED_TARGET = 0x41
# DEBUG_ERROR | DEBUG_WARN | DEBUG_INFO
PROPOSED_DISPLAY_LEVEL = 0x80000042

lines = []

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def block(name, value, max_lines=55, max_chars=520):
    emit("----- " + name + " -----")
    selected = (value or "").splitlines()
    if not selected:
        emit("(no output)")
    for line in selected[:max_lines]:
        emit(line[:max_chars] + (" ...[truncated]" if len(line) > max_chars else ""))
    if len(selected) > max_lines:
        emit("... " + str(len(selected) - max_lines) + " additional lines omitted")
    emit("----- END " + name + " -----")

def run(args, timeout=25):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout or ""
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, out + "\nCOMMAND_TIMEOUT"
    except Exception as exc:
        return 127, "COMMAND_ERROR=" + repr(exc)

def record(name, args, timeout=25, max_lines=45):
    rc, output = run(args, timeout)
    emit(name + "_EXIT=" + str(rc))
    block(name, output, max_lines)
    return rc, output

def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def inside(path, root):
    try:
        return os.path.commonpath([str(path), str(root)]) == str(root)
    except Exception:
        return False

def main():
    root = Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip()).resolve()
    os.chdir(str(root))
    branch = subprocess.check_output(
        ["git", "branch", "--show-current"], universal_newlines=True).strip()
    if branch != BRANCH:
        raise RuntimeError("wrong branch: " + branch)
    status = subprocess.check_output(
        ["git", "status", "--porcelain"], universal_newlines=True)
    if status.strip():
        raise RuntimeError("working tree must be clean before audit:\n" + status)
    subprocess.check_call(["git", "cat-file", "-e", BASE + "^{commit}"])
    subprocess.check_call(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
    pin_lines = ALLOWLIST.read_text(encoding="utf-8").splitlines()
    pin = pin_lines[0].split()[0] if pin_lines and pin_lines[0].split() else ""
    actual_blob = subprocess.check_output(
        ["git", "hash-object", str(SCRIPT)], universal_newlines=True).strip()
    if not pin or pin != actual_blob:
        raise RuntimeError("runner Git blob SHA does not match allowlist")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / ("stage118-preboot-observability-" + stamp + ".log")
    version_rc, version = run(["sw_vers", "-productVersion"], 10)
    build_rc, build = run(["sw_vers", "-buildVersion"], 10)
    arch_rc, arch = run(["uname", "-m"], 10)
    target_ok = (version_rc, build_rc, arch_rc) == (0, 0, 0) and (
        version.strip(), build.strip(), arch.strip()) == ("15.8.1", "24H32", "x86_64")

    emit("========== STAGE118 PREBOOT OBSERVABILITY PROFILE ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(
        ["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + version.strip() + " (" + build.strip() + ") " + arch.strip())
    emit("TARGET_MATCH_24H32=" + str(target_ok))
    emit("SCOPE=READ_ONLY_EFI_CONFIG_DEBUG_PROFILE_IOREGISTRY_RUNTIME")
    emit("CONFIG_WRITE=NONE EFI_WRITE=NONE MOUNT=NOT_RUN SIP_CHANGE=NONE NVRAM_CHANGE=NONE")
    emit("SIGNING=NOT_RUN BUILD=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN REBOOT=NOT_RUN HARDWARE_TEST=NOT_RUN")
    emit("PROPOSAL_ONLY=TRUE")

    sip_rc, sip = record("SIP_STATUS", ["csrutil", "status"], 12, 8)
    emit("SIP_STATE=" + ("ENABLED" if re.search(r"status:\s*enabled|is enabled", sip, re.I) else "NOT_CONFIRMED"))

    cfg_root = None
    volume = None
    native_rows = []
    config_state = "NOT_ASSESSED"
    current_debug = {}
    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint = record("OPENCORE_CONFIG_PLUTIL", ["plutil", "-lint", str(CONFIG)], 12, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as stream:
                    cfg = plistlib.load(stream)
                cfg_root = CONFIG.parent.resolve()
                volume = CONFIG.parents[2] if len(CONFIG.parents) > 2 else None
                kernel = cfg.get("Kernel", {}) or {}
                for index, entry in enumerate(kernel.get("Add", []) or []):
                    bp = str(entry.get("BundlePath", ""))
                    rel = Path(bp) if bp else Path(".")
                    choices = [(cfg_root / rel).resolve()]
                    if len(rel.parts) == 1:
                        choices.append((cfg_root / "Kexts" / rel).resolve())
                    bundle = next((p for p in choices if p.is_dir() and inside(p, cfg_root)), None)
                    info = {}
                    if bundle:
                        try:
                            with (bundle / "Contents" / "Info.plist").open("rb") as stream:
                                info = plistlib.load(stream)
                        except Exception:
                            pass
                    is_native = Path(bp).name == NATIVE_NAME or (
                        str(info.get("CFBundleExecutable", "")) == NATIVE_EXEC and
                        any(isinstance(person, dict) and person.get("IOClass") == "RTW88WCLController"
                            for person in (info.get("IOKitPersonalities", {}) or {}).values()))
                    if not is_native:
                        continue
                    exe_rel = str(entry.get("ExecutablePath", ""))
                    exe = (bundle / exe_rel).resolve() if bundle and exe_rel else None
                    exe_ok = bool(exe and inside(exe, bundle) and exe.is_file())
                    native_rows.append({
                        "index": index, "enabled": entry.get("Enabled") is True,
                        "bundle_path": bp, "bundle_id": str(info.get("CFBundleIdentifier", "")),
                        "executable_exists": exe_ok,
                        "sha256": sha256(exe) if exe_ok else "MISSING"
                    })

                debug = cfg.get("Misc", {}).get("Debug", {}) or {}
                current_debug = {
                    "Target": debug.get("Target", "UNKNOWN"),
                    "DisplayLevel": debug.get("DisplayLevel", "UNKNOWN"),
                    "AppleDebug": debug.get("AppleDebug", "UNKNOWN"),
                    "ApplePanic": debug.get("ApplePanic", "UNKNOWN"),
                    "DisableWatchDog": debug.get("DisableWatchDog", "UNKNOWN"),
                    "SysReport": debug.get("SysReport", "UNKNOWN")
                }
                emit("OPENCORE_CONFIG_PATH=" + str(CONFIG))
                emit("OPENCORE_CONFIG_STATE=PARSED")
                emit("NATIVE_KERNEL_ADD_ROWS=" + json.dumps(native_rows, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_COUNT=" + str(len(native_rows)))
                emit("NATIVE_KERNEL_ADD_ENABLED_COUNT=" + str(sum(1 for row in native_rows if row["enabled"])))
                emit("NATIVE_EXECUTABLE_SHA_MATCH_STAGE113=" + str(bool(native_rows) and all(
                    row["sha256"] == EXPECTED_NATIVE_SHA for row in native_rows)))
                emit("CURRENT_OPENCORE_DEBUG=" + json.dumps(current_debug, sort_keys=True))
                target_now = current_debug["Target"]
                display_now = current_debug["DisplayLevel"]
                emit("CURRENT_TARGET_HEX=" + (hex(target_now) if isinstance(target_now, int) else "UNKNOWN"))
                emit("CURRENT_DISPLAY_LEVEL_HEX=" + (hex(display_now) if isinstance(display_now, int) else "UNKNOWN"))
                emit("PROPOSED_TARGET_DECIMAL=" + str(PROPOSED_TARGET))
                emit("PROPOSED_TARGET_HEX=" + hex(PROPOSED_TARGET))
                emit("PROPOSED_TARGET_BITS=ENABLE_LOGGING|FILE_LOGGING")
                emit("PROPOSED_DISPLAY_LEVEL_DECIMAL=" + str(PROPOSED_DISPLAY_LEVEL))
                emit("PROPOSED_DISPLAY_LEVEL_HEX=" + hex(PROPOSED_DISPLAY_LEVEL))
                emit("PROPOSED_DISPLAY_LEVEL_BITS=DEBUG_ERROR|DEBUG_WARN|DEBUG_INFO")
                emit("PROPOSAL_DIFF_TARGET=" + str(target_now != PROPOSED_TARGET))
                emit("PROPOSAL_DIFF_DISPLAY_LEVEL=" + str(display_now != PROPOSED_DISPLAY_LEVEL))
                emit("PROPOSAL_DIFF_APPLE_DEBUG=" + str(current_debug["AppleDebug"] is not True))
                emit("PROPOSAL_DIFF_APPLE_PANIC=" + str(current_debug["ApplePanic"] is not True))
                emit("OPENCORE_DEBUG_PROFILE_PROPOSAL=TARGET_65_DISPLAYLEVEL_2147483714")
                emit("OPENCORE_CONFIG_WRITE_PERFORMED=False")
                config_state = "PARSED"
            except Exception as exc:
                config_state = "PARSE_ERROR"
                emit("OPENCORE_CONFIG_ERROR=" + repr(exc))
        else:
            config_state = "PLUTIL_FAIL"
    else:
        emit("OPENCORE_CONFIG_READABILITY=NOT_READABLE_NO_MOUNT_ATTEMPTED")
    emit("OPENCORE_CONFIG_RESULT=" + config_state)

    if volume and volume.exists():
        di_rc, di = record("EFI_DISKUTIL_INFO", ["diskutil", "info", str(volume)], 18, 40)
        fs = next((line.split(":", 1)[1].strip() for line in di.splitlines()
                   if "File System Personality" in line), "UNKNOWN")
        mount_rc, mount_output = run(["mount"], 12)
        mount_line = "\n".join(line for line in mount_output.splitlines() if str(volume) in line)
        block("EFI_MOUNT_LINE", mount_line, 4, 500)
        emit("EFI_FILESYSTEM_PERSONALITY=" + fs)
        emit("EFI_MOUNT_NOOWNERS=" + str(bool(re.search(r"\bnoowners\b", mount_line, re.I))))
        emit("EFI_OWNER_WARNINGS_FROM_STAGE116_INTERPRETATION=FAT32_NOOWNERS_MOUNT_EMULATION_NOT_PER_FILE_OWNER_PROOF")

    if cfg_root:
        debug_dir = cfg_root / "Logs"
        log_files = sorted([path for path in debug_dir.iterdir()
                            if path.is_file() and path.suffix.lower() in (".txt", ".log")],
                           key=lambda path: path.stat().st_mtime, reverse=True)[:8] if debug_dir.is_dir() else []
        emit("OPENCORE_LOG_DIRECTORY=" + str(debug_dir))
        emit("OPENCORE_LOG_FILES_FOUND=" + str(len(log_files)))
        for path in log_files:
            try:
                st = path.stat()
                emit("OPENCORE_LOG_FILE=" + json.dumps({
                    "path": str(path), "bytes": st.st_size,
                    "mtime": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat()
                }, sort_keys=True))
            except OSError as exc:
                emit("OPENCORE_LOG_STAT_ERROR=" + repr(exc))
        for path in (cfg_root / "OpenCore.efi", cfg_root / "Drivers" / "OpenRuntime.efi",
                     volume / "EFI" / "BOOT" / "BOOTx64.efi" if volume else None):
            if path and path.is_file():
                file_rc, file_text = run(["file", str(path)], 10)
                emit("OPENCORE_BINARY_FINGERPRINT=" + json.dumps({
                    "path": str(path), "sha256": sha256(path),
                    "size": path.stat().st_size, "file": file_text.strip()[:280]
                }, sort_keys=True))

    # Query class instances directly; do not infer device identity from an unrelated
    # occurrence of a string in the root IORegistry tree.
    pci_rc, pci_output = run(["ioreg", "-p", "IOService", "-r", "-c", "IOPCIDevice", "-l", "-w0"], 28)
    emit("IOREG_IOPCIDEVICE_CLASS_QUERY_EXIT=" + str(pci_rc))
    pci_lines = pci_output.splitlines()
    pci_hits = [idx for idx, line in enumerate(pci_lines)
                if re.search(r"pci10ec,c821|vendor-id.*ec100000|device-id.*21c80000", line, re.I)]
    pci_context = []
    for idx in pci_hits[:4]:
        pci_context.extend(pci_lines[max(0, idx-3):min(len(pci_lines), idx+8)])
    block("RTL8821CE_IOPCIDEVICE_MATCH_CONTEXT", "\n".join(pci_context), 50, 520)
    pci_match = bool(pci_hits)
    emit("IOREG_RTL8821CE_MATCH_IN_IOPCIDEVICE_INSTANCES=" + str(pci_match))
    emit("IOREG_IOPCIDEVICE_INSTANCE_COUNT=" + str(sum(1 for line in pci_lines if "<class IOPCIDevice" in line)))

    class_states = {}
    for cls in ("RTW88WCLController", "RTW88WCLInfraInterface"):
        rc, output = run(["ioreg", "-p", "IOService", "-r", "-c", cls, "-l", "-w0"], 18)
        found = bool(rc == 0 and re.search(r"<class\s+" + re.escape(cls) + r"(?:[,>])", output))
        class_states[cls] = "MATCH" if found else ("NO_MATCH" if rc == 0 else "UNKNOWN")
        emit("IOREG_" + cls + "_EXIT=" + str(rc))
        block("IOREG_" + cls, output, 14, 460)
        emit("IOREG_" + cls + "_STATE=" + class_states[cls])

    loaded_rc, loaded = run(["kmutil", "showloaded"], 30)
    relevant = [line for line in loaded.splitlines()
                if re.search(r"AMFIPass|Lilu|RTL88WiFi|RTW88|RtWlanU|IO80211Family|IOSkywalkFamily", line, re.I)]
    block("LOADED_RELEVANT_KEXTS", "\n".join(relevant), 35, 500)
    native_loaded = any("RTL88WiFiNative" in line or "RTW88WCL" in line for line in relevant)
    usb_backup_loaded = any("RtWlanU" in line for line in relevant)
    emit("NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))
    emit("USB_BACKUP_RTWLANU_PRESENT=" + str(usb_backup_loaded))

    # The runner only proposes settings; a subsequent user-approved EFI/config change
    # and reboot would be required to obtain a new preboot log.
    diagnosis = "OPENCORE_DEBUG_LOGGING_DISABLED_AND_NATIVE_LOAD_CAUSE_UNOBSERVABLE"
    if config_state != "PARSED":
        diagnosis = "OPENCORE_CONFIG_UNAVAILABLE_OR_INVALID"
    elif not native_rows or sum(1 for row in native_rows if row["enabled"]) != 1:
        diagnosis = "NATIVE_OPENCORE_ENTRY_MISSING_DISABLED_OR_DUPLICATED"
    elif not all(row["sha256"] == EXPECTED_NATIVE_SHA for row in native_rows):
        diagnosis = "EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_VALIDATED_BINARY"
    elif current_debug.get("Target") == 0:
        diagnosis = "OPENCORE_TARGET_ZERO_PREVENTS_BOOT_LOG_CAPTURE_REVIEW_DEBUG_PROFILE"
    elif len(log_files) == 0:
        diagnosis = "OPENCORE_LOG_TARGET_ENABLED_BUT_NO_LOG_FILES_FOUND"
    elif native_loaded:
        diagnosis = "NATIVE_BUNDLE_LOADED_RUNTIME_ATTACH_REVIEW_REQUIRED"
    emit("STAGE118_PRIMARY_DIAGNOSIS=" + diagnosis)
    emit("STAGE118_SIGNATURE_POLICY_REFERENCE=AirportRTW_RELEASE_BUILD_USES_CODE_SIGNING_ALLOWED_NO")
    emit("STAGE118_PROPOSED_TARGET_DECIMAL=" + str(PROPOSED_TARGET))
    emit("STAGE118_PROPOSED_DISPLAY_LEVEL_DECIMAL=" + str(PROPOSED_DISPLAY_LEVEL))
    emit("STAGE118_RTL8821CE_PCI_MATCH=" + str(pci_match))
    emit("STAGE118_NATIVE_CONTROLLER_IOREGISTRY=" + class_states.get("RTW88WCLController", "UNKNOWN"))
    emit("STAGE118_NATIVE_INTERFACE_IOREGISTRY=" + class_states.get("RTW88WCLInfraInterface", "UNKNOWN"))
    emit("STAGE118_NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))
    emit("STAGE118_USB_BACKUP_PRESERVED=" + str(usb_backup_loaded))
    emit("STAGE118_OPENCORE_LOG_FILES=" + str(len(log_files)))
    emit("STAGE118_RESULT=EVIDENCE_CAPTURED_PROPOSAL_ONLY")
    emit("STAGE118_CONFIG_CHANGE=NONE EFI_WRITE=NONE REBOOT=NOT_RUN")
    emit("STAGE118_ACTIVATION=BLOCKED PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE118 PREBOOT OBSERVABILITY PROFILE ==========\n")
        stream.write("STAGE118_RESULT=EVIDENCE_CAPTURED_PROPOSAL_ONLY\n")
        stream.write("STAGE118_PRIMARY_DIAGNOSIS=" + diagnosis + "\n")
        stream.write("STAGE118_PROPOSED_TARGET_DECIMAL=" + str(PROPOSED_TARGET) + "\n")
        stream.write("STAGE118_PROPOSED_DISPLAY_LEVEL_DECIMAL=" + str(PROPOSED_DISPLAY_LEVEL) + "\n")
        stream.write("STAGE118_RTL8821CE_PCI_MATCH=" + str(pci_match) + "\n")
        stream.write("STAGE118_NATIVE_CONTROLLER_IOREGISTRY=" + class_states.get("RTW88WCLController", "UNKNOWN") + "\n")
        stream.write("STAGE118_NATIVE_INTERFACE_IOREGISTRY=" + class_states.get("RTW88WCLInfraInterface", "UNKNOWN") + "\n")
        stream.write("STAGE118_NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded) + "\n")
        stream.write("STAGE118_USB_BACKUP_PRESERVED=" + str(usb_backup_loaded) + "\n")
        stream.write("STAGE118_DETAIL_LOG=" + str(log_path) + "\n")
        stream.write("STAGE118_CONFIG_CHANGE=NONE EFI_WRITE=NONE REBOOT=NOT_RUN PR4_MERGE=BLOCKED\n")
    emit("STAGE118_DETAIL_LOG=" + str(log_path))
    emit("STAGE118_CANONICAL_LOG=" + str(OUTPUT_LOG))

if __name__ == "__main__":
    main()
