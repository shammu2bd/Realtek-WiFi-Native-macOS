#!/usr/bin/env python3
"""Stage117: read-only EFI filesystem/ownership and boot-log observability audit.

Inspects only an already-mounted EFI volume, OpenCore config/binaries, and live
IORegistry/runtime state. It never mounts/writes EFI, changes config/NVRAM/SIP,
signs, builds, installs, loads/unloads, or performs a radio test.
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

BRANCH = "work/stage117-efi-volume-context"
BASE = "ab4ab2e4bf3367b6ddf228e6661573a0d167cead"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", DEFAULT_CONFIG))
NATIVE_NAME = "RTL88WiFiNative.kext"
NATIVE_EXEC = "RTL88WiFiNative"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage117-efi-volume-context.py")
ALLOWLIST = Path("Development/Allowlist/stage117-efi-volume-context.gitblob")

lines = []

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def block(name, value, max_lines=60, max_chars=520):
    emit("----- " + name + " -----")
    selected = (value or "").splitlines()
    if not selected:
        emit("(no output)")
    for line in selected[:max_lines]:
        emit(line[:max_chars] + (" ...[truncated]" if len(line) > max_chars else ""))
    if len(selected) > max_lines:
        emit("... " + str(len(selected) - max_lines) + " additional lines omitted")
    emit("----- END " + name + " -----")

def run(args, timeout=30):
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

def record(name, args, timeout=30, max_lines=50):
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
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip()).resolve()
    os.chdir(str(root))
    branch = subprocess.check_output(["git", "branch", "--show-current"], universal_newlines=True).strip()
    if branch != BRANCH:
        raise RuntimeError("wrong branch: " + branch)
    status = subprocess.check_output(["git", "status", "--porcelain"], universal_newlines=True)
    if status.strip():
        raise RuntimeError("working tree must be clean before audit:\n" + status)
    subprocess.check_call(["git", "cat-file", "-e", BASE + "^{commit}"])
    subprocess.check_call(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
    pin_lines = ALLOWLIST.read_text(encoding="utf-8").splitlines()
    pin = pin_lines[0].split()[0] if pin_lines and pin_lines[0].split() else ""
    actual_blob = subprocess.check_output(["git", "hash-object", str(SCRIPT)], universal_newlines=True).strip()
    if not pin or pin != actual_blob:
        raise RuntimeError("runner Git blob SHA does not match allowlist")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / ("stage117-efi-volume-context-" + stamp + ".log")

    version_rc, version = run(["sw_vers", "-productVersion"], 10)
    build_rc, build = run(["sw_vers", "-buildVersion"], 10)
    arch_rc, arch = run(["uname", "-m"], 10)
    target_ok = (version_rc, build_rc, arch_rc) == (0, 0, 0) and (version.strip(), build.strip(), arch.strip()) == ("15.8.1", "24H32", "x86_64")

    emit("========== STAGE117 EFI VOLUME / BOOT-LOG CONTEXT ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + version.strip() + " (" + build.strip() + ") " + arch.strip())
    emit("TARGET_MATCH_24H32=" + str(target_ok))
    emit("SCOPE=READ_ONLY_EXISTING_EFI_MOUNT_OWNERSHIP_FILESYSTEM_OPENCORE_DEBUG_IOREGISTRY")
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN")
    emit("MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")

    sip_rc, sip = record("SIP_STATUS", ["csrutil", "status"], 12, 8)
    emit("SIP_STATE=" + ("ENABLED" if re.search(r"status:\s*enabled|is enabled", sip, re.I) else "NOT_CONFIRMED"))

    cfg = {}
    cfg_root = None
    volume = None
    native_bundle = None
    native_sha_match = False
    native_count = 0
    native_enabled = 0
    config_state = "NOT_ASSESSED"
    debug_target = None
    apple_debug = None
    apple_panic = None

    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint = record("OPENCORE_CONFIG_PLUTIL", ["plutil", "-lint", str(CONFIG)], 12, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as stream:
                    cfg = plistlib.load(stream)
                cfg_root = CONFIG.parent.resolve()
                volume = CONFIG.parents[2] if len(CONFIG.parents) > 2 else None
                config_state = "PARSED"
                kernel = cfg.get("Kernel", {}) or {}
                rows = []
                for index, entry in enumerate(kernel.get("Add", []) or []):
                    bp = str(entry.get("BundlePath", ""))
                    basename = Path(bp).name
                    rel = Path(bp) if bp else Path(".")
                    candidates = [(cfg_root / rel).resolve()]
                    if len(rel.parts) == 1:
                        candidates.append((cfg_root / "Kexts" / rel).resolve())
                    bundle = next((p for p in candidates if p.is_dir() and inside(p, cfg_root)), None)
                    info = {}
                    if bundle:
                        try:
                            with (bundle / "Contents" / "Info.plist").open("rb") as stream:
                                info = plistlib.load(stream)
                        except Exception:
                            pass
                    is_native = basename == NATIVE_NAME or (
                        str(info.get("CFBundleExecutable", "")) == NATIVE_EXEC and
                        any(isinstance(p, dict) and p.get("IOClass") == "RTW88WCLController"
                            for p in (info.get("IOKitPersonalities", {}) or {}).values()))
                    if not is_native:
                        continue
                    exe_rel = str(entry.get("ExecutablePath", ""))
                    exe = (bundle / exe_rel).resolve() if bundle and exe_rel else None
                    ok = bool(exe and inside(exe, bundle) and exe.is_file())
                    row = {"index": index, "enabled": entry.get("Enabled") is True,
                           "bundle_path": bp, "arch": str(entry.get("Arch", "UNKNOWN")),
                           "bundle_id": str(info.get("CFBundleIdentifier", "")),
                           "executable_exists": ok, "sha256": sha256(exe) if ok else "MISSING"}
                    rows.append(row)
                    if bundle:
                        native_bundle = bundle
                native_count = len(rows)
                native_enabled = sum(1 for row in rows if row["enabled"])
                native_sha_match = bool(rows) and all(row["sha256"] == EXPECTED_NATIVE_SHA for row in rows)
                emit("OPENCORE_CONFIG_PATH=" + str(CONFIG))
                emit("NATIVE_KERNEL_ADD_ROWS=" + json.dumps(rows, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_COUNT=" + str(native_count))
                emit("NATIVE_KERNEL_ADD_ENABLED_COUNT=" + str(native_enabled))
                emit("NATIVE_EXECUTABLE_SHA_MATCH_STAGE113=" + str(native_sha_match))
                nvadd = cfg.get("NVRAM", {}).get("Add", {}) or {}
                nvdata = next((value for key, value in nvadd.items()
                               if str(key).upper() == "7C436110-AB2A-4BBB-A880-FE41995C9F82"), {})
                emit("CONFIGURED_BOOT_ARGS=" + str(nvdata.get("boot-args", ""))[:600])
                csr_value = nvdata.get("csr-active-config", b"")
                emit("CONFIGURED_CSR_ACTIVE_CONFIG_HEX=" + (csr_value.hex() if isinstance(csr_value, bytes) else str(csr_value)))
                security = cfg.get("Misc", {}).get("Security", {}) or {}
                debug = cfg.get("Misc", {}).get("Debug", {}) or {}
                debug_target = debug.get("Target", None)
                apple_debug = debug.get("AppleDebug", None)
                apple_panic = debug.get("ApplePanic", None)
                emit("SECURE_BOOT_MODEL=" + str(security.get("SecureBootModel", "UNKNOWN")))
                emit("OPENCORE_DEBUG_TARGET=" + str(debug_target))
                emit("OPENCORE_DEBUG_APPLE_DEBUG=" + str(apple_debug))
                emit("OPENCORE_DEBUG_APPLE_PANIC=" + str(apple_panic))
                emit("OPENCORE_DEBUG_LOGGING_DISABLED=" + str(debug_target == 0))
                emit("OPENCORE_CONFIG_RESULT=PARSED")
            except Exception as exc:
                config_state = "PARSE_ERROR"
                emit("OPENCORE_CONFIG_ERROR=" + repr(exc))
        else:
            config_state = "PLUTIL_FAIL"
    else:
        emit("OPENCORE_CONFIG_PATH=NOT_READABLE_CONFIGURED_EFI_NOT_MOUNTED")
    emit("OPENCORE_CONFIG_STATE=" + config_state)

    volume_mount_line = ""
    fs_personality = ""
    owners_setting = ""
    if volume and volume.exists():
        di_rc, di = record("EFI_DISKUTIL_INFO", ["diskutil", "info", str(volume)], 20, 55)
        for line in di.splitlines():
            if re.search(r"File System Personality|Type \(Bundle\)|Owners:|Device Node:|Volume Name:|Mounted:", line, re.I):
                emit("EFI_DISKUTIL_FIELD=" + line.strip())
            if re.search(r"File System Personality", line, re.I):
                fs_personality = line.split(":", 1)[-1].strip()
            if re.match(r"\s*Owners:", line, re.I):
                owners_setting = line.split(":", 1)[-1].strip()
        m_rc, mounts = run(["mount"], 12)
        mount_matches = [line for line in mounts.splitlines() if str(volume) in line]
        volume_mount_line = "\n".join(mount_matches)
        block("EFI_MOUNT_LINE", volume_mount_line, 5, 520)
        mount_options = ",".join(re.findall(r"\(([^)]*)\)", volume_mount_line))
        emit("EFI_MOUNT_OPTIONS=" + mount_options)
        noowners = bool(re.search(r"\bnoowners\b", mount_options, re.I)) or owners_setting.lower() == "disabled"
        emit("EFI_OWNERS_SETTING=" + (owners_setting or "NOT_REPORTED"))
        emit("EFI_MOUNT_HAS_NOOWNERS=" + str(bool(re.search(r"\bnoowners\b", mount_options, re.I))))
        emit("EFI_OWNERSHIP_DISABLED_OR_EMULATED=" + str(noowners))
        emit("EFI_FILESYSTEM_PERSONALITY=" + (fs_personality or "NOT_REPORTED"))
        if re.search(r"msdos|fat", fs_personality, re.I) and noowners:
            emit("EFI_OWNER_METADATA_INTERPRETATION=FAT_VOLUME_WITH_OWNERS_DISABLED; PATH_UID_GID_ARE_MOUNT_PRESENTATION_NOT_PERSISTED_PER_FILE_OWNER")
        else:
            emit("EFI_OWNER_METADATA_INTERPRETATION=REQUIRES_FILESYSTEM_SPECIFIC_REVIEW")
    else:
        emit("EFI_VOLUME_INFO=NOT_AVAILABLE_NO_MOUNT_ATTEMPTED")

    if volume and volume.exists():
        for path in (volume, volume / "EFI", cfg_root, cfg_root / "Kexts", native_bundle):
            if path and path.exists():
                try:
                    st = path.stat()
                    emit("EFI_MOUNT_STAT=" + json.dumps({"path": str(path), "uid": st.st_uid, "gid": st.st_gid,
                          "mode": oct(st.st_mode & 0o777), "is_dir": path.is_dir()}, sort_keys=True))
                except OSError as exc:
                    emit("EFI_MOUNT_STAT_ERROR=" + repr(exc))

    efi_binaries = []
    if volume:
        for path in (volume / "EFI" / "BOOT" / "BOOTx64.efi", cfg_root / "OpenCore.efi" if cfg_root else None,
                     cfg_root / "Drivers" / "OpenRuntime.efi" if cfg_root else None):
            if path and path.is_file():
                try:
                    row = {"path": str(path), "size": path.stat().st_size, "sha256": sha256(path)}
                    file_rc, file_out = run(["file", str(path)], 12)
                    row["file_type"] = file_out.strip()[:300]
                    efi_binaries.append(row)
                except OSError as exc:
                    efi_binaries.append({"path": str(path), "error": repr(exc)})
    emit("OPENCORE_EFI_BINARY_FINGERPRINTS=" + json.dumps(efi_binaries, sort_keys=True))

    native_diag_rc = 127
    native_diag = ""
    if native_bundle and native_bundle.exists():
        native_diag_rc, native_diag = record("EFI_NATIVE_KMUTIL_DIAGNOSTICS",
            ["kmutil", "print-diagnostics", "-p", str(native_bundle)], 50, 45)
        ownership_errors = len(re.findall(r"Invalid ownership", native_diag, re.I))
        bad_signature = bool(re.search(r"Authenticating extension failed:\s*Bad code signature", native_diag, re.I))
        deps_ok = bool(re.search(r"Dependencies:\s*OK", native_diag, re.I))
        emit("EFI_NATIVE_KMUTIL_INVALID_OWNERSHIP_COUNT=" + str(ownership_errors))
        emit("EFI_NATIVE_KMUTIL_BAD_CODE_SIGNATURE=" + str(bad_signature))
        emit("EFI_NATIVE_KMUTIL_DEPENDENCIES_OK=" + str(deps_ok))
    else:
        emit("EFI_NATIVE_KMUTIL_DIAGNOSTICS=NOT_RUN_NO_RESOLVED_BUNDLE")

    # Search the full IOService plane, then retain only the exact PCI-node neighborhood.
    pci_rc, pci_all = run(["ioreg", "-p", "IOService", "-l", "-w0"], 35)
    emit("IOREG_FULL_IO_SERVICE_QUERY_EXIT=" + str(pci_rc))
    pci_lines = pci_all.splitlines()
    hits = [i for i, line in enumerate(pci_lines) if re.search(r"pci10ec,c821(?:@[^ ]*)?\s+<class\s+IOPCIDevice", line, re.I)]
    if hits:
        snippets = []
        for index in hits[:3]:
            lo, hi = max(0, index - 2), min(len(pci_lines), index + 26)
            snippets.extend(pci_lines[lo:hi])
        pci_context = "\n".join(snippets)
    else:
        pci_context = ""
    block("RTL8821CE_EXACT_IOREGISTRY_NODE", pci_context, 90, 520)
    pci_node_match = bool(hits)
    emit("IOREG_RTL8821CE_EXACT_NODE_MATCH=" + str(pci_node_match))
    emit("IOREG_RTL8821CE_NODE_OCCURRENCES=" + str(len(hits)))
    emit("IOREG_RTL8821CE_VENDOR_ID_PROPERTY=" + str("vendor-id" in pci_context))
    emit("IOREG_RTL8821CE_DEVICE_ID_PROPERTY=" + str("device-id" in pci_context))

    loaded_rc, loaded = run(["kmutil", "showloaded"], 35)
    loaded_relevant = [line for line in loaded.splitlines()
                       if re.search(r"AMFIPass|Lilu|RTL88WiFi|RTW88|RtWlanU|IO80211Family|IOSkywalkFamily", line, re.I)]
    block("LOADED_RELEVANT_KEXTS", "\n".join(loaded_relevant), 35, 500)
    native_loaded = any("RTL88WiFiNative" in line or "RTW88WCL" in line for line in loaded_relevant)
    emit("NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))

    oc_logs = []
    if cfg_root and (cfg_root / "Logs").is_dir():
        candidates = sorted([path for path in (cfg_root / "Logs").iterdir()
                             if path.is_file() and path.suffix.lower() in (".txt", ".log")],
                            key=lambda path: path.stat().st_mtime, reverse=True)[:5]
        oc_logs = [str(path) for path in candidates]
    emit("OPENCORE_LOG_FILES_FOUND=" + str(len(oc_logs)))
    emit("OPENCORE_LOGGING_OBSERVABILITY=" + (
        "DISABLED_BY_TARGET_ZERO" if debug_target == 0 else
        "CONFIGURED_BUT_NO_LOG_FILES_FOUND" if debug_target is not None and not oc_logs else
        "LOG_FILES_PRESENT" if oc_logs else "UNKNOWN"))

    # Keep the diagnosis limited to what the current mounted filesystem and config prove.
    diagnosis = "INCONCLUSIVE"
    if config_state != "PARSED":
        diagnosis = "OPENCORE_CONFIG_UNAVAILABLE_OR_INVALID"
    elif native_count != 1 or native_enabled != 1:
        diagnosis = "NATIVE_KERNEL_ADD_ENTRY_MISSING_DISABLED_OR_DUPLICATED"
    elif not native_sha_match:
        diagnosis = "EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_BINARY"
    elif debug_target == 0 and len(oc_logs) == 0:
        diagnosis = "BOOT_INJECTION_CAUSE_UNOBSERVABLE_OPENCORE_FILE_LOGGING_DISABLED"
    elif native_loaded:
        diagnosis = "NATIVE_BUNDLE_LOADED_RUNTIME_ATTACH_REVIEW_REQUIRED"
    elif native_diag_rc == 0 and "Dependencies: OK" in native_diag and bad_signature:
        diagnosis = "EFI_COPY_AUTHENTICATION_FAILURE_CONFIRMED_BUT_BOOT_INJECTION_REJECTION_NOT_PROVEN"
    elif native_diag_rc == 0 and bad_signature:
        diagnosis = "EFI_COPY_AUTHENTICATION_FAILURE_REQUIRES_BOOT_LOG_CORRELATION"
    elif native_diag_rc == 0 and "Dependencies: OK" in native_diag:
        diagnosis = "EFI_BUNDLE_DEPENDENCIES_RESOLVE_CAUSE_OF_NO_LOAD_UNPROVEN"
    else:
        diagnosis = "READ_ONLY_EVIDENCE_INCOMPLETE"
    if re.search(r"msdos|fat", fs_personality, re.I) and owners_setting.lower() == "disabled":
        diagnosis += "_EFI_MOUNT_OWNERSHIP_IS_NOT_PERSISTED_FILE_OWNERSHIP"

    emit("STAGE117_PRIMARY_DIAGNOSIS=" + diagnosis)
    emit("STAGE117_EFI_FILESYSTEM_PERSONALITY=" + (fs_personality or "UNKNOWN"))
    emit("STAGE117_EFI_OWNERS_SETTING=" + (owners_setting or "UNKNOWN"))
    emit("STAGE117_EFI_OWNERSHIP_DISABLED_OR_EMULATED=" + str(
        bool(re.search(r"\bnoowners\b", volume_mount_line, re.I)) or owners_setting.lower() == "disabled"))
    emit("STAGE117_KMUTIL_DIAGNOSTICS_EXIT=" + str(native_diag_rc))
    emit("STAGE117_KMUTIL_BAD_CODE_SIGNATURE=" + str(bool(re.search(r"Authenticating extension failed:\s*Bad code signature", native_diag, re.I))))
    emit("STAGE117_KMUTIL_INVALID_OWNERSHIP_COUNT=" + str(len(re.findall(r"Invalid ownership", native_diag, re.I))))
    emit("STAGE117_RTL8821CE_EXACT_NODE_MATCH=" + str(pci_node_match))
    emit("STAGE117_NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))
    emit("STAGE117_OPENCORE_LOGGING_OBSERVABILITY=" + (
        "DISABLED_BY_TARGET_ZERO" if debug_target == 0 and len(oc_logs) == 0 else
        "LOG_FILES_PRESENT" if oc_logs else "NO_LOG_FILES"))
    emit("STAGE117_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW")
    emit("STAGE117_ACTIVATION=BLOCKED")
    emit("EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN HARDWARE_TEST=NOT_RUN PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE117 EFI VOLUME / BOOT-LOG CONTEXT ==========\n")
        stream.write("STAGE117_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW\n")
        stream.write("STAGE117_PRIMARY_DIAGNOSIS=" + diagnosis + "\n")
        stream.write("STAGE117_EFI_FILESYSTEM_PERSONALITY=" + (fs_personality or "UNKNOWN") + "\n")
        stream.write("STAGE117_EFI_OWNERS_SETTING=" + (owners_setting or "UNKNOWN") + "\n")
        stream.write("STAGE117_KMUTIL_DIAGNOSTICS_EXIT=" + str(native_diag_rc) + "\n")
        stream.write("STAGE117_KMUTIL_BAD_CODE_SIGNATURE=" + str(bool(re.search(r"Authenticating extension failed:\s*Bad code signature", native_diag, re.I))) + "\n")
        stream.write("STAGE117_KMUTIL_INVALID_OWNERSHIP_COUNT=" + str(len(re.findall(r"Invalid ownership", native_diag, re.I))) + "\n")
        stream.write("STAGE117_RTL8821CE_EXACT_NODE_MATCH=" + str(pci_node_match) + "\n")
        stream.write("STAGE117_OPENCORE_LOGGING_OBSERVABILITY=" + (
            "DISABLED_BY_TARGET_ZERO" if debug_target == 0 and len(oc_logs) == 0 else
            "LOG_FILES_PRESENT" if oc_logs else "NO_LOG_FILES") + "\n")
        stream.write("STAGE117_DETAIL_LOG=" + str(log_path) + "\n")
        stream.write("STAGE117_ACTIVATION=BLOCKED PR4_MERGE=BLOCKED\n")
    emit("STAGE117_DETAIL_LOG=" + str(log_path))
    emit("STAGE117_CANONICAL_LOG=" + str(OUTPUT_LOG))

if __name__ == "__main__":
    main()
