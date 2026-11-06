#!/usr/bin/env python3
"""Stage114: read-only OpenCore native-kext injection/load diagnostics.

Only inspects an already-mounted EFI and the current running system. It never
mounts/writes EFI, edits NVRAM/SIP, signs, builds, installs, loads or unloads.
It writes timestamped evidence files to Development/ and publishes those files.
"""
from __future__ import print_function
import hashlib
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

BRANCH = "work/stage114-opencore-load-diagnostics"
BASE = "86e2dbae408395a42b6cbc41876b8009f76d64bd"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", DEFAULT_CONFIG))
NATIVE_NAME = "RTL88WiFiNative.kext"
NATIVE_ID = "io.github.x1ren41l.rtl88wifi"
NATIVE_EXEC = "RTL88WiFiNative"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage114-opencore-load-diagnostics.py")
ALLOWLIST = Path("Development/Allowlist/stage114-opencore-load-diagnostics.gitblob")

lines = []
counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
findings = {}

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def mark(kind, message):
    counts[kind] += 1
    emit(kind + ": " + message)

def block(title, value, max_lines=70, max_chars=520):
    emit("----- " + title + " -----")
    value = value or ""
    selected = value.splitlines()
    if not selected:
        emit("(no output)")
    else:
        for line in selected[:max_lines]:
            emit(line[:max_chars] + (" ...[truncated]" if len(line) > max_chars else ""))
        if len(selected) > max_lines:
            emit("... " + str(len(selected) - max_lines) + " additional lines omitted")
    emit("----- END " + title + " -----")

def run(args, timeout=35):
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

def record_command(label, args, timeout=35, max_lines=70):
    rc, out = run(args, timeout)
    emit(label + "_EXIT=" + str(rc))
    block(label, out, max_lines)
    return rc, out

def within(path, root):
    try:
        return os.path.commonpath([str(path), str(root)]) == str(root)
    except Exception:
        return False

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_kmutil_xml(output):
    marker = output.find("<plist")
    if marker < 0:
        raise ValueError("no XML plist found in kmutil output")
    start = output.rfind("<?xml", 0, marker)
    if start < 0:
        start = marker
    data = plistlib.loads(output[start:].encode("utf-8"))
    libs = data.get("OSBundleLibraries") if isinstance(data, dict) else None
    if not isinstance(libs, dict):
        raise ValueError("kmutil XML has no OSBundleLibraries dictionary")
    return {str(k): str(v) for k, v in libs.items()}

def main():
    root = Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip()).resolve()
    os.chdir(str(root))
    current_branch = subprocess.check_output(
        ["git", "branch", "--show-current"], universal_newlines=True).strip()
    if current_branch != BRANCH:
        raise RuntimeError("wrong branch: " + current_branch)
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
    log_path = LOG_DIR / ("stage114-opencore-load-diagnostics-" + stamp + ".log")

    version_rc, version = run(["sw_vers", "-productVersion"])
    build_rc, build = run(["sw_vers", "-buildVersion"])
    arch_rc, arch = run(["uname", "-m"])
    emit("========== STAGE114 OPENCORE NATIVE-KEXT LOAD DIAGNOSTICS ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + version.strip() + " (" + build.strip() + ") " + arch.strip())
    emit("SCOPE=READ_ONLY_EXISTING_EFI_SIGNATURE_OWNERSHIP_BOOT_LOGS_KMUTIL_IOREGISTRY")
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN")
    emit("MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    mark("PASS", "Stage114 runner is SHA-pinned and Stage113 validation commit is an ancestor")
    if (version_rc, build_rc, arch_rc) == (0, 0, 0) and (version.strip(), build.strip(), arch.strip()) == ("15.8.1", "24H32", "x86_64"):
        mark("PASS", "host matches Sequoia 15.8.1 build 24H32 x86_64")
    else:
        mark("WARN", "host version/build/architecture differs from the validated target")

    # Booted state: configured NVRAM values and live values are deliberately separate.
    sip_rc, sip = record_command("SIP_STATUS", ["csrutil", "status"], 15, 8)
    emit("SIP_STATE=" + ("ENABLED" if re.search(r"status:\s*enabled|is enabled", sip, re.I) else "NOT_CONFIRMED"))
    boot_rc, boot = record_command("LIVE_BOOT_ARGS", ["sysctl", "-n", "kern.bootargs"], 15, 8)
    emit("LIVE_BOOT_ARGS=" + boot.strip()[:700].replace("\n", " "))
    nv_rc, nv = run(["nvram", "-p"], 15)
    emit("NVRAM_READ_EXIT=" + str(nv_rc))
    nv_matches = [x for x in nv.splitlines() if re.search(r"opencore|boot-args|csr-active-config", x, re.I)]
    block("LIVE_NVRAM_RELEVANT_KEYS", "\n".join(nv_matches), 20, 400)

    native_entries = []
    same_id_entries = []
    native_bundle = None
    info = {}
    cfg = {}
    cfg_root = None
    volume = None
    config_state = "NOT_ASSESSED"
    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint = record_command("OPENCORE_CONFIG_PLUTIL", ["plutil", "-lint", str(CONFIG)], 15, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as f:
                    cfg = plistlib.load(f)
                cfg_root = CONFIG.parent.resolve()
                volume = CONFIG.parents[2] if len(CONFIG.parents) > 2 else CONFIG.parent
                config_state = "PARSED"
                emit("OPENCORE_CONFIG_PATH=" + str(CONFIG))
                emit("OPENCORE_OC_ROOT=" + str(cfg_root))
                emit("OPENCORE_VOLUME_PATH=" + str(volume))
                kernel = cfg.get("Kernel", {}) or {}
                add = kernel.get("Add", []) or []
                for index, entry in enumerate(add):
                    bp = str(entry.get("BundlePath", ""))
                    if not bp:
                        continue
                    rel = Path(bp)
                    choices = [(cfg_root / rel).resolve()]
                    if len(rel.parts) == 1:
                        choices.append((cfg_root / "Kexts" / rel).resolve())
                    bundle = next((p for p in choices if p.is_dir() and within(p, cfg_root)), None)
                    plist = {}
                    if bundle:
                        ip = bundle / "Contents" / "Info.plist"
                        try:
                            with ip.open("rb") as f:
                                plist = plistlib.load(f)
                        except Exception:
                            plist = {}
                    bid = str(plist.get("CFBundleIdentifier", ""))
                    native = Path(bp).name == NATIVE_NAME or (
                        str(plist.get("CFBundleExecutable", "")) == NATIVE_EXEC and
                        any(isinstance(x, dict) and x.get("IOClass") == "RTW88WCLController"
                            for x in (plist.get("IOKitPersonalities", {}) or {}).values()))
                    if bid.lower() == NATIVE_ID:
                        same_id_entries.append({"index": index, "bundle_path": bp,
                                                "enabled": entry.get("Enabled") is True,
                                                "native_path": native})
                    if not native:
                        continue
                    exe_rel = str(entry.get("ExecutablePath", ""))
                    plist_rel = str(entry.get("PlistPath", ""))
                    if bundle and exe_rel:
                        exe = (bundle / exe_rel).resolve()
                    else:
                        exe = None
                    exe_inside = bool(bundle and exe and within(exe, bundle))
                    exe_exists = bool(exe_inside and exe.is_file())
                    row = {
                        "index": index,
                        "enabled": entry.get("Enabled") is True,
                        "arch": str(entry.get("Arch", "UNKNOWN")),
                        "min_kernel": str(entry.get("MinKernel", "")),
                        "max_kernel": str(entry.get("MaxKernel", "")),
                        "bundle_path": bp,
                        "resolved_bundle": str(bundle) if bundle else "UNRESOLVED",
                        "bundle_id": bid,
                        "plist_executable": str(plist.get("CFBundleExecutable", "")),
                        "entry_executable_path": exe_rel,
                        "entry_plist_path": plist_rel,
                        "executable_exists": exe_exists,
                        "sha256": digest(exe) if exe_exists else "MISSING",
                    }
                    native_entries.append(row)
                    if bundle:
                        native_bundle = bundle
                        info = plist
                    emit("NATIVE_KERNEL_ADD_ENTRY=" + json.dumps(row, sort_keys=True))
                emit("SAME_BUNDLE_ID_KERNEL_ADD_ENTRIES=" + json.dumps(same_id_entries, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_COUNT=" + str(len(native_entries)))
                emit("NATIVE_KERNEL_ADD_ENABLED_COUNT=" + str(sum(1 for x in native_entries if x["enabled"])))
                emit("NATIVE_EFI_SHA_MATCH_STAGE113=" + str(bool(native_entries) and all(x["sha256"] == EXPECTED_NATIVE_SHA for x in native_entries)))
                block_entries = kernel.get("Block", []) or []
                blocked = [str(x.get("BundleIdentifier", "")) for x in block_entries
                           if x.get("Enabled") is True and str(x.get("BundleIdentifier", "")).lower()
                           in ("com.apple.iokit.ioskywalkfamily", "com.apple.iokit.io80211familylegacy")]
                emit("RELEVANT_ENABLED_KERNEL_BLOCK_ENTRIES=" + (",".join(blocked) if blocked else "NONE"))
                nvadd = cfg.get("NVRAM", {}).get("Add", {}) or {}
                nvdata = next((v for k, v in nvadd.items()
                               if str(k).upper() == "7C436110-AB2A-4BBB-A880-FE41995C9F82"), {})
                boot_cfg = nvdata.get("boot-args", "")
                if isinstance(boot_cfg, bytes):
                    boot_cfg = boot_cfg.decode("utf-8", "replace")
                csr_cfg = nvdata.get("csr-active-config", "UNKNOWN")
                if isinstance(csr_cfg, bytes):
                    csr_cfg = csr_cfg.hex()
                emit("CONFIGURED_BOOT_ARGS=" + str(boot_cfg)[:700])
                emit("CONFIGURED_CSR_ACTIVE_CONFIG=" + str(csr_cfg))
                sec = cfg.get("Misc", {}).get("Security", {}) or {}
                debug = cfg.get("Misc", {}).get("Debug", {}) or {}
                emit("SECURE_BOOT_MODEL=" + str(sec.get("SecureBootModel", "UNKNOWN")))
                emit("VAULT=" + str(sec.get("Vault", "UNKNOWN")))
                emit("OPENCORE_DEBUG_TARGET=" + str(debug.get("Target", "UNKNOWN")))
                emit("OPENCORE_DEBUG_DISPLAY_LEVEL=" + str(debug.get("DisplayLevel", "UNKNOWN")))
                emit("OPENCORE_DEBUG_APPLE_DEBUG=" + str(debug.get("AppleDebug", "UNKNOWN")))
                quirks = kernel.get("Quirks", {}) or {}
                for key in ("DisableLinkeditJettison", "KernelCache", "Force"):
                    if key in quirks:
                        emit("KERNEL_QUIRK_" + key + "=" + str(quirks[key]))
                mark("PASS", "already-mounted OpenCore config parsed without modification")
            except Exception as exc:
                config_state = "PARSE_ERROR"
                mark("FAIL", "OpenCore config inspection failed: " + repr(exc))
        else:
            config_state = "PLUTIL_FAIL"
            mark("FAIL", "OpenCore config failed plutil validation")
    else:
        mark("WARN", "configured EFI path is not already mounted/readable; no mount attempted")
    emit("OPENCORE_CONFIG_RESULT=" + config_state)

    if native_bundle:
        expected_files = [
            native_bundle,
            native_bundle / "Contents",
            native_bundle / "Contents" / "Info.plist",
            native_bundle / "Contents" / "MacOS",
            native_bundle / "Contents" / "MacOS" / NATIVE_EXEC,
        ]
        for path in expected_files:
            try:
                st = path.stat()
                emit("EFI_PATH_STAT=" + json.dumps({
                    "path": str(path), "uid": st.st_uid, "gid": st.st_gid,
                    "mode": oct(st.st_mode & 0o777), "is_dir": path.is_dir(),
                    "size": st.st_size if path.is_file() else None
                }, sort_keys=True))
            except OSError as exc:
                emit("EFI_PATH_STAT_ERROR=" + str(path) + " " + repr(exc))
        ls_rc, ls_out = record_command("EFI_BUNDLE_ACL_METADATA",
            ["ls", "-led@", str(native_bundle), str(native_bundle / "Contents"),
             str(native_bundle / "Contents" / "Info.plist"),
             str(native_bundle / "Contents" / "MacOS" / NATIVE_EXEC)], 15, 22)
    else:
        mark("WARN", "native bundle path could not be resolved from Kernel -> Add")

    if volume and volume.exists():
        di_rc, di = record_command("EFI_VOLUME_INFO", ["diskutil", "info", str(volume)], 20, 35)
        m_rc, m_out = run(["mount"], 15)
        mount_lines = [x for x in m_out.splitlines() if str(volume) in x]
        block("EFI_VOLUME_MOUNT_LINE", "\n".join(mount_lines), 5, 500)

    signature_state = "NOT_ASSESSED"
    diagnostics = ""
    if native_bundle:
        csd_rc, csd = record_command("CODESIGN_DETAILS", ["codesign", "-dv", "--verbose=4", str(native_bundle)], 20, 35)
        csv_rc, csv = record_command("CODESIGN_VERIFY", ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(native_bundle)], 25, 35)
        signature_state = "VERIFY_PASS" if csv_rc == 0 else "VERIFY_FAIL"
        emit("NATIVE_CODESIGN_VERIFY_STATE=" + signature_state)
        kd_rc, diagnostics = record_command("KMUTIL_PRINT_DIAGNOSTICS", ["kmutil", "print-diagnostics", str(native_bundle)], 45, 90)
        diag_low = diagnostics.lower()
        emit("KMUTIL_DIAGNOSTICS_BAD_SIGNATURE=" + str("bad code signature" in diag_low or "authentication failed" in diag_low))
        emit("KMUTIL_DIAGNOSTICS_INVALID_OWNER=" + str("invalid ownership" in diag_low))
        kl_rc, kl = run(["kmutil", "libraries", "--bundle-path", str(native_bundle), "--xml"], 45)
        emit("KMUTIL_LIBRARIES_EXIT=" + str(kl_rc))
        if kl_rc == 0:
            try:
                libs = parse_kmutil_xml(kl)
                emit("EXECUTABLE_DERIVED_DEPENDENCIES=" + json.dumps(libs, sort_keys=True))
                plist_libs = info.get("OSBundleLibraries", {}) or {}
                emit("PLIST_DEPENDENCIES_MATCH_KMUTIL=" + str({str(k): str(v) for k, v in plist_libs.items()} == libs))
            except Exception as exc:
                emit("KMUTIL_LIBRARIES_PARSE=ERROR " + repr(exc))
        else:
            block("KMUTIL_LIBRARIES_OUTPUT", kl, 30, 500)

    loaded_rc, loaded = run(["kmutil", "showloaded", "--show", "all", "--bundle-identifier", NATIVE_ID], 40)
    emit("KMUTIL_NATIVE_BUNDLE_QUERY_EXIT=" + str(loaded_rc))
    block("KMUTIL_NATIVE_BUNDLE_QUERY", loaded, 30, 500)
    general_rc, general = run(["kmutil", "showloaded"], 40)
    relevant_loaded = [x for x in general.splitlines()
                       if re.search(r"AMFIPass|Lilu|RTL88WiFi|RTW88|IOSkywalkFamily|IO80211Family", x, re.I)]
    emit("KMUTIL_SHOWLOADED_EXIT=" + str(general_rc))
    block("LOADED_KEXT_RELEVANT_LINES", "\n".join(relevant_loaded), 45, 500)

    ioreg_results = {}
    for cls in ("RTW88WCLController", "RTW88WCLInfraInterface"):
        rc, out = run(["ioreg", "-p", "IOService", "-r", "-c", cls, "-l", "-w0"], 25)
        found = bool(rc == 0 and re.search(r"<class\s+" + re.escape(cls) + r"(?:[,>])", out))
        state = "MATCH" if found else ("NO_MATCH" if rc == 0 else "UNKNOWN")
        ioreg_results[cls] = state
        emit("IOREG_" + cls + "_EXIT=" + str(rc))
        block("IOREG_" + cls, out, 18, 480)
        emit("IOREG_" + cls + "_STATE=" + state)
    pci_rc, pci = run(["ioreg", "-p", "IOService", "-n", "pci10ec,c821", "-l", "-w0"], 25)
    pci_found = pci_rc == 0 and "pci10ec,c821" in pci.lower()
    emit("IOREG_RTL8821CE_PCI_EXIT=" + str(pci_rc))
    block("IOREG_RTL8821CE_PCI", pci, 20, 480)
    emit("IOREG_RTL8821CE_PCI_PRESENT=" + str(pci_found))

    predicate = ('process == "amfid" OR process == "syspolicyd" OR '
                 'eventMessage CONTAINS[c] "RTL88WiFi" OR '
                 'eventMessage CONTAINS[c] "RTW88WCL" OR '
                 'eventMessage CONTAINS[c] "bad code signature" OR '
                 'eventMessage CONTAINS[c] "authentication failed"')
    log_rc, logs = run(["log", "show", "--last", "6h", "--style", "compact",
                        "--predicate", predicate], 60)
    emit("UNIFIED_LOG_QUERY_EXIT=" + str(log_rc))
    if log_rc == 0:
        selected = [x for x in logs.splitlines()
                    if re.search(r"amfid|syspolicyd|RTL88WiFi|RTW88WCL|bad code signature|authentication failed", x, re.I)]
        block("RECENT_AMFI_KEXT_LOG_MATCHES", "\n".join(selected), 120, 560)
        emit("RECENT_RELEVANT_LOG_LINE_COUNT=" + str(len(selected)))
    else:
        block("RECENT_AMFI_KEXT_LOG_ERROR", logs, 12, 400)

    # OpenCore debug logs are read only, and only under the already-mounted EFI OC/Logs folder.
    oc_log_dir = (cfg_root / "Logs") if cfg_root else None
    oc_logs = []
    if oc_log_dir and oc_log_dir.is_dir():
        try:
            candidates = sorted(
                [p for p in oc_log_dir.iterdir() if p.is_file() and p.suffix.lower() in (".txt", ".log")],
                key=lambda p: p.stat().st_mtime, reverse=True
            )[:3]
            for path in candidates:
                oc_logs.append(path)
                try:
                    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
                    emit("OPENCORE_LOG_FILE=" + str(path))
                    block("OPENCORE_LOG_TAIL_" + path.name, "\n".join(content[-65:]), 65, 500)
                except OSError as exc:
                    emit("OPENCORE_LOG_READ_ERROR=" + repr(exc))
        except OSError as exc:
            emit("OPENCORE_LOG_ENUMERATION_ERROR=" + repr(exc))
    emit("OPENCORE_DEBUG_LOG_FILES_FOUND=" + str(len(oc_logs)))

    # High-level diagnosis keeps observations distinct from causal proof.
    native_count = len(native_entries)
    native_enabled = sum(1 for x in native_entries if x["enabled"])
    hash_match = bool(native_entries) and all(x["sha256"] == EXPECTED_NATIVE_SHA for x in native_entries)
    code_sig_bad = signature_state == "VERIFY_FAIL" or "bad code signature" in diagnostics.lower()
    invalid_owner = "invalid ownership" in diagnostics.lower()
    controller = ioreg_results.get("RTW88WCLController", "UNKNOWN")
    interface = ioreg_results.get("RTW88WCLInfraInterface", "UNKNOWN")
    if config_state != "PARSED":
        diagnosis = "EFI_CONFIG_NOT_AVAILABLE_OR_INVALID"
    elif native_count != 1 or native_enabled != 1:
        diagnosis = "OPENCORE_NATIVE_KERNEL_ADD_ENTRY_MISSING_DISABLED_OR_DUPLICATED"
    elif not hash_match:
        diagnosis = "EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_VALIDATED_BINARY"
    elif loaded_rc == 0 and not loaded.strip() and code_sig_bad:
        diagnosis = "NATIVE_NOT_LOADED_WITH_CODE_SIGNATURE_FAILURE_EVIDENCE"
    elif loaded_rc == 0 and not loaded.strip():
        diagnosis = "NATIVE_NOT_PRESENT_IN_LOADED_KEXT_QUERY; CAUSE_NOT_YET_PROVEN"
    elif controller == "NO_MATCH":
        diagnosis = "BUNDLE_QUERY_AND_IOREGISTRY_DISAGREE_OR_PERSONALITY_DID_NOT_ATTACH"
    elif controller == "MATCH" and interface != "MATCH":
        diagnosis = "CONTROLLER_PRESENT_INTERFACE_NOT_REGISTERED"
    elif controller == "MATCH" and interface == "MATCH":
        diagnosis = "NATIVE_CLASSES_PRESENT; NETWORK_FUNCTIONALITY_NOT_TESTED"
    else:
        diagnosis = "INCONCLUSIVE_READ_ONLY_OBSERVATIONS"
    emit("STAGE114_PRIMARY_DIAGNOSIS=" + diagnosis)
    emit("STAGE114_CODE_SIGNATURE_FAILURE_EVIDENCE=" + str(code_sig_bad))
    emit("STAGE114_INVALID_OWNERSHIP_DIAGNOSTIC=" + str(invalid_owner))
    emit("STAGE114_PCI_DEVICE_PRESENT=" + str(pci_found))
    emit("STAGE114_NATIVE_CONTROLLER_IOREGISTRY=" + controller)
    emit("STAGE114_NATIVE_INTERFACE_IOREGISTRY=" + interface)
    emit("STAGE114_OPENCORE_LOG_FILES=" + str(len(oc_logs)))
    emit("STAGE114_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW")
    emit("STAGE114_ACTIVATION=BLOCKED")
    emit("SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as f:
        f.write("\n========== STAGE114 OPENCORE NATIVE-KEXT LOAD DIAGNOSTICS ==========\n")
        f.write("STAGE114_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW\n")
        f.write("STAGE114_PRIMARY_DIAGNOSIS=" + diagnosis + "\n")
        f.write("STAGE114_CODE_SIGNATURE_FAILURE_EVIDENCE=" + str(code_sig_bad) + "\n")
        f.write("STAGE114_INVALID_OWNERSHIP_DIAGNOSTIC=" + str(invalid_owner) + "\n")
        f.write("STAGE114_NATIVE_EFI_COUNT=" + str(native_count) + "\n")
        f.write("STAGE114_NATIVE_EFI_ENABLED_COUNT=" + str(native_enabled) + "\n")
        f.write("STAGE114_NATIVE_EFI_HASH_MATCH_STAGE113=" + str(hash_match) + "\n")
        f.write("STAGE114_PCI_DEVICE_PRESENT=" + str(pci_found) + "\n")
        f.write("STAGE114_NATIVE_CONTROLLER_IOREGISTRY=" + controller + "\n")
        f.write("STAGE114_NATIVE_INTERFACE_IOREGISTRY=" + interface + "\n")
        f.write("STAGE114_OPENCORE_LOG_FILES=" + str(len(oc_logs)) + "\n")
        f.write("STAGE114_DETAIL_LOG=" + str(log_path) + "\n")
        f.write("SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN\n")
        f.write("STAGE114_ACTIVATION=BLOCKED PR4_MERGE=BLOCKED\n")
        f.write("===============================================================\n")

    subprocess.check_call(["git", "add", str(log_path), str(OUTPUT_LOG)])
    subprocess.check_call(["git", "diff", "--cached", "--check"])
    subprocess.check_call(["git", "commit", "-m", "Stage114: record OpenCore native kext load diagnostics"])
    subprocess.check_call(["git", "push", "origin", BRANCH])
    emit("STAGE114_PUBLICATION=PUSHED")
    emit("STAGE114_COMMIT=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("STAGE114_DETAIL_LOG=" + str(log_path))
    emit("STAGE114_SUMMARY=COMPLETE")

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print("STAGE114_ABORTED_COMMAND=" + repr(exc), file=sys.stderr)
        sys.exit(exc.returncode if exc.returncode else 1)
    except Exception as exc:
        print("STAGE114_ABORTED=" + repr(exc), file=sys.stderr)
        sys.exit(2)
