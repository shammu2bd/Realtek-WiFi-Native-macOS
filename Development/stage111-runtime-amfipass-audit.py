#!/usr/bin/env python3
"""Stage111: read-only AMFIPass, OpenCore EFI and live macOS runtime audit."""
from __future__ import print_function
import hashlib
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BRANCH = "work/stage91-tx-submission-callback-v1"
BASE = "df4b52378a60e9e2ea78654ffd05eaae4588382e"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
NATIVE_ID = "io.github.x1ren41l.rtl88wifi"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", "/Volumes/EFI/EFI/OC/config.plist"))
NVRAM_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
ALLOWLIST = Path("Development/Allowlist/stage111-runtime-amfipass-audit.gitblob")
SCRIPT = Path("Development/stage111-runtime-amfipass-audit.py")
lines = []
counts = {"PASS": 0, "WARN": 0, "FAIL": 0}

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def mark(kind, message):
    counts[kind] += 1
    emit(kind + ": " + message)

def run_cmd(args, timeout=30):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, p.stdout or ""
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, str(out) + "\nCOMMAND_TIMEOUT"
    except Exception as e:
        return 127, "COMMAND_ERROR=" + repr(e)

def need_tool(name):
    from shutil import which
    return which(name) is not None

def filtered_tokens(value):
    try:
        tokens = shlex.split(value)
    except Exception:
        tokens = value.split()
    return [t for t in tokens if t.lower().startswith("amfi") or
            t.lower() == "-amfipassbeta" or t.lower().startswith("ipc_control_port_options")]

def emit_block(title, value, max_lines=60, max_chars=420):
    emit("----- " + title + " -----")
    if not value.strip():
        emit("(no matching output)")
    else:
        all_lines = value.splitlines()
        for line in all_lines[:max_lines]:
            if len(line) > max_chars:
                line = line[:max_chars] + " ... [line truncated]"
            emit(line)
        if len(all_lines) > max_lines:
            emit("... output truncated for report")
    emit("----- END " + title + " -----")

def is_within(path, root):
    try:
        return os.path.commonpath([str(path), str(root)]) == str(root)
    except Exception:
        return False

def plist_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value) if value is not None else ""

def main():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip())
    os.chdir(str(root))
    current_branch = subprocess.check_output(["git", "branch", "--show-current"], universal_newlines=True).strip()
    if current_branch != BRANCH:
        raise RuntimeError("wrong branch: " + current_branch)
    status = subprocess.check_output(["git", "status", "--porcelain"], universal_newlines=True)
    if status.strip():
        raise RuntimeError("working tree is not clean:\n" + status)
    subprocess.check_call(["git", "cat-file", "-e", BASE + "^{commit}"])
    subprocess.check_call(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
    pin_lines = ALLOWLIST.read_text(encoding="utf-8").splitlines()
    pin = pin_lines[0].split()[0] if pin_lines and pin_lines[0].split() else ""
    actual_blob = subprocess.check_output(["git", "hash-object", str(SCRIPT)], universal_newlines=True).strip()
    if not pin or pin != actual_blob:
        raise RuntimeError("runner blob hash does not match allowlist")

    required = ["sw_vers", "uname", "plutil", "python3", "git", "shasum", "kmutil",
                "ioreg", "sysctl", "csrutil"]
    missing = [x for x in required if not need_tool(x)]
    if missing:
        raise RuntimeError("required read-only tools unavailable: " + ", ".join(missing))

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / ("stage111-runtime-amfipass-audit-" + stamp + ".log")
    os_version = subprocess.check_output(["sw_vers", "-productVersion"], universal_newlines=True).strip()
    build = subprocess.check_output(["sw_vers", "-buildVersion"], universal_newlines=True).strip()
    arch = subprocess.check_output(["uname", "-m"], universal_newlines=True).strip()

    emit("========== STAGE111 AMFIPASS / LIVE RUNTIME AUDIT ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("STAGE110_BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + os_version + " (" + build + ") " + arch)
    emit("SCOPE=READ_ONLY_AMFIPASS_OPENCORE_LIVE_KEXT_IOREGISTRY_WIFI_DIAGNOSTICS")
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_PERFORMED_BY_RUNNER MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    mark("PASS", "Stage111 runner is SHA-pinned and Stage110 audit commit is an ancestor")
    if (os_version, build, arch) == ("15.8.1", "24H32", "x86_64"):
        mark("PASS", "host matches macOS Sequoia 15.8.1 build 24H32 x86_64")
    else:
        mark("FAIL", "host target mismatch; audit observations may not match Stage108")

    sip_rc, sip_text = run_cmd(["csrutil", "status"])
    emit("CSRUTIL_EXIT=" + str(sip_rc))
    emit_block("SIP STATUS", sip_text, 10)
    sip = "ENABLED" if re.search(r"status:\s*enabled|is enabled", sip_text, re.I) else "NOT_CONFIRMED"
    emit("STAGE111_SIP_STATE=" + sip)

    # Inspect an already-mounted EFI only. No mount attempt is made.
    efi_state = "NOT_ASSESSED"
    amfi_rows = []
    lilu_rows = []
    native_rows = []
    other_realtek_rows = []
    boot_args_cfg = ""
    csr_config = "UNKNOWN"
    secure_boot = "UNKNOWN"
    vault = "UNKNOWN"
    efi_hash_match = "UNKNOWN"
    amfipass_order = "UNKNOWN"
    amfipass_count = "UNKNOWN"
    amfipass_enabled = "UNKNOWN"
    lilu_count = "UNKNOWN"
    lilu_enabled = "UNKNOWN"
    native_count = "UNKNOWN"
    native_enabled = "UNKNOWN"
    realtek_collision_count = "UNKNOWN"
    efi_config_ok = False

    emit("STAGE111_EFI_CONFIG_PATH=" + str(CONFIG))
    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint_out = run_cmd(["plutil", "-lint", str(CONFIG)])
        emit("EFI_PLUTIL_EXIT=" + str(lint_rc))
        emit_block("EFI CONFIG PLIST CHECK", lint_out, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as f:
                    cfg = plistlib.load(f)
                oc_root = CONFIG.parent.resolve()
                add = cfg.get("Kernel", {}).get("Add", []) or []
                for index, entry in enumerate(add):
                    bundle_path = str(entry.get("BundlePath", ""))
                    executable = str(entry.get("ExecutablePath", ""))
                    lowered = bundle_path.lower()
                    candidates = []
                    if bundle_path:
                        candidates.append((oc_root / bundle_path).resolve())
                        if len(Path(bundle_path).parts) == 1:
                            candidates.append((oc_root / "Kexts" / bundle_path).resolve())
                    bundle = next((p for p in candidates if p.is_dir() and is_within(p, oc_root)), None)
                    info = {}
                    if bundle is not None:
                        info_path = bundle / "Contents" / "Info.plist"
                        if info_path.is_file():
                            try:
                                with info_path.open("rb") as f:
                                    info = plistlib.load(f)
                            except Exception:
                                info = {}
                    bundle_id = str(info.get("CFBundleIdentifier", ""))
                    label = (lowered + " " + bundle_id.lower())
                    is_amfi = "amfipass" in label
                    is_lilu = "lilu" in label
                    is_native = ("rtl88wifinative" in lowered or bundle_id.lower() == NATIVE_ID)
                    is_realtek_other = ("rtl88wifi" in label or "airportrtw" in label) and not is_native
                    if not (is_amfi or is_lilu or is_native or is_realtek_other):
                        continue
                    enabled = entry.get("Enabled") is True
                    version = str(info.get("CFBundleShortVersionString", info.get("CFBundleVersion", "UNKNOWN")))
                    exe_path = (bundle / executable).resolve() if bundle is not None and executable else None
                    exe_inside = bool(exe_path and bundle and is_within(exe_path, bundle))
                    exe_exists = bool(exe_inside and exe_path.is_file())
                    digest = hashlib.sha256(exe_path.read_bytes()).hexdigest() if exe_exists else "MISSING"
                    archs = "UNKNOWN"
                    if exe_exists and need_tool("lipo"):
                        lipo_rc, lipo_out = run_cmd(["lipo", "-archs", str(exe_path)], 15)
                        if lipo_rc == 0:
                            archs = lipo_out.strip().replace("\n", ",")
                    row = {"index": index, "enabled": enabled, "bundle_path": bundle_path,
                           "bundle_id": bundle_id, "version": version, "executable_exists": exe_exists,
                           "sha256": digest, "archs": archs}
                    emit("EFI_KEXT_ENTRY=" + json.dumps(row, sort_keys=True))
                    if is_amfi:
                        amfi_rows.append(row)
                    if is_lilu:
                        lilu_rows.append(row)
                    if is_native:
                        native_rows.append(row)
                    if is_realtek_other:
                        other_realtek_rows.append(row)

                nvram_add = cfg.get("NVRAM", {}).get("Add", {}) or {}
                nvram = next((v for k, v in nvram_add.items() if str(k).upper() == NVRAM_GUID), {})
                boot_args_cfg = plist_text(nvram.get("boot-args", ""))
                csr_value = nvram.get("csr-active-config", "UNKNOWN")
                csr_config = csr_value.hex() if isinstance(csr_value, bytes) else str(csr_value)
                security = cfg.get("Misc", {}).get("Security", {}) or {}
                secure_boot = str(security.get("SecureBootModel", "UNKNOWN"))
                vault = str(security.get("Vault", "UNKNOWN"))
                cfg_tokens = filtered_tokens(boot_args_cfg)
                emit("EFI_AMFI_RELEVANT_BOOT_ARGS=" + (" ".join(cfg_tokens) if cfg_tokens else "NONE"))
                emit("EFI_CSR_ACTIVE_CONFIG=" + csr_config)
                emit("EFI_SECURE_BOOT_MODEL=" + secure_boot)
                emit("EFI_VAULT=" + vault)

                amfipass_count = str(len(amfi_rows))
                amfipass_enabled = str(sum(1 for x in amfi_rows if x["enabled"]))
                lilu_count = str(len(lilu_rows))
                lilu_enabled = str(sum(1 for x in lilu_rows if x["enabled"]))
                native_count = str(len(native_rows))
                native_enabled = str(sum(1 for x in native_rows if x["enabled"]))
                realtek_collision_count = str(len(other_realtek_rows))
                if native_rows:
                    efi_hash_match = str(all(x["sha256"] == EXPECTED_NATIVE_SHA for x in native_rows))
                enabled_amfi_rows = [x for x in amfi_rows if x["enabled"]]
                enabled_lilu_rows = [x for x in lilu_rows if x["enabled"]]
                if enabled_amfi_rows and enabled_lilu_rows:
                    amfipass_order = "ENABLED_LILU_BEFORE_ENABLED_AMFIPASS" if min(x["index"] for x in enabled_lilu_rows) < min(x["index"] for x in enabled_amfi_rows) else "ENABLED_LILU_NOT_BEFORE_ENABLED_AMFIPASS"
                elif enabled_amfi_rows:
                    amfipass_order = "ENABLED_AMFIPASS_WITHOUT_ENABLED_LILU"
                elif amfi_rows:
                    amfipass_order = "AMFIPASS_DISABLED"
                elif lilu_rows:
                    amfipass_order = "AMFIPASS_ENTRY_MISSING"
                if len(amfi_rows) == 0:
                    mark("WARN", "AMFIPass is not listed in OpenCore Kernel -> Add")
                elif sum(1 for x in amfi_rows if x["enabled"]) == 0:
                    mark("WARN", "AMFIPass entry exists but is disabled")
                else:
                    mark("PASS", "AMFIPass entry exists and is enabled")
                if amfipass_order == "ENABLED_LILU_BEFORE_ENABLED_AMFIPASS":
                    mark("PASS", "enabled Lilu entry is listed before enabled AMFIPass entry")
                elif amfi_rows:
                    mark("WARN", "enabled Lilu/AMFIPass presence or load order needs review")
                if native_count == "1" and native_enabled == "1":
                    mark("PASS", "exactly one enabled native EFI entry")
                else:
                    mark("WARN", "native EFI entry is absent, disabled or duplicated")
                if efi_hash_match == "True":
                    mark("PASS", "EFI native executable SHA-256 matches Stage108")
                elif native_rows:
                    mark("WARN", "EFI native executable does not match Stage108")
                if realtek_collision_count == "0":
                    mark("PASS", "no additional RTL88WiFi/AirportRTW Kernel->Add entry found")
                else:
                    mark("WARN", "other Realtek Wi-Fi frontend entry/entries are also listed")
                efi_state = "PARSED"
                efi_config_ok = True
            except Exception as e:
                mark("FAIL", "EFI plist parse/inspection failed: " + repr(e))
        else:
            mark("FAIL", "EFI config plist failed plutil validation")
    else:
        mark("WARN", "USB EFI config is not mounted/readable; no mount attempted")

    emit("STAGE111_EFI_CONFIG_RESULT=" + efi_state)
    emit("STAGE111_AMFIPASS_EFI_COUNT=" + str(amfipass_count))
    emit("STAGE111_AMFIPASS_EFI_ENABLED_COUNT=" + str(amfipass_enabled))
    emit("STAGE111_LILU_EFI_COUNT=" + str(lilu_count))
    emit("STAGE111_LILU_EFI_ENABLED_COUNT=" + str(lilu_enabled))
    emit("STAGE111_LILU_AMFIPASS_ORDER=" + str(amfipass_order))
    emit("STAGE111_NATIVE_EFI_COUNT=" + str(native_count))
    emit("STAGE111_NATIVE_EFI_ENABLED_COUNT=" + str(native_enabled))
    emit("STAGE111_NATIVE_EFI_HASH_MATCH=" + str(efi_hash_match))
    emit("STAGE111_OTHER_REALTEK_EFI_ENTRY_COUNT=" + str(realtek_collision_count))

    # The NVRAM plist is configured state; kern.bootargs is live boot state.
    boot_rc, boot_text = run_cmd(["sysctl", "-n", "kern.bootargs"])
    emit("LIVE_BOOTARGS_SYSCTL_EXIT=" + str(boot_rc))
    live_boot_args = boot_text.strip()
    live_tokens = filtered_tokens(live_boot_args)
    emit("LIVE_AMFI_RELEVANT_BOOT_ARGS=" + (" ".join(live_tokens) if live_tokens else "NONE"))
    live_amfi_override = any(t.lower().startswith("amfi_get_out_of_my_way=") or
                             t.lower() in ("amfi=0x80", "amfi=0x1", "amfi=1") for t in live_tokens)
    emit("LIVE_AMFI_OVERRIDE_TOKEN_PRESENT=" + str(live_amfi_override))
    emit("LIVE_AMFIPASS_BETA_FLAG_PRESENT=" + str("-amfipassbeta" in [x.lower() for x in live_tokens]))
    if boot_rc == 0:
        mark("PASS", "live kern.bootargs read without modifying NVRAM")
        if live_amfi_override:
            mark("WARN", "live boot arguments contain an explicit AMFI override token")
    else:
        mark("WARN", "live kern.bootargs could not be read")

    # Loaded-kext inventory is informational; no load/unload operation is performed.
    km_rc, km_text = run_cmd(["kmutil", "showloaded"], 40)
    emit("KMUTIL_SHOWLOADED_EXIT=" + str(km_rc))
    km_lines = [x for x in km_text.splitlines() if re.search(r"AMFIPass|RTL88WiFi|AirportRTW|Lilu|RTW88", x, re.I)]
    emit_block("LOADED KEXT MATCHES", "\n".join(km_lines), 80)
    km_low = km_text.lower()
    runtime_amfipass = "FOUND" if "amfipass" in km_low else ("NOT_FOUND" if km_rc == 0 else "UNKNOWN")
    runtime_lilu = "FOUND" if "lilu" in km_low else ("NOT_FOUND" if km_rc == 0 else "UNKNOWN")
    runtime_native_bundle = "AMBIGUOUS_SHARED_BUNDLE_ID" if NATIVE_ID in km_low else ("NOT_FOUND" if km_rc == 0 else "UNKNOWN")
    runtime_realtek = "FOUND" if ("rtl88wifi" in km_low or "airportrtw" in km_low or "rtw88" in km_low) else ("NOT_FOUND" if km_rc == 0 else "UNKNOWN")
    emit("STAGE111_AMFIPASS_RUNTIME_LOADED=" + runtime_amfipass)
    emit("STAGE111_LILU_RUNTIME_LOADED=" + runtime_lilu)
    emit("STAGE111_NATIVE_BUNDLE_ID_RUNTIME_LOADED=" + runtime_native_bundle)
    emit("STAGE111_ANY_REALTEK_DRIVER_RUNTIME_LOADED=" + runtime_realtek)
    if runtime_amfipass == "FOUND":
        mark("PASS", "AMFIPass appears in the live loaded-kext inventory")
    elif runtime_amfipass == "NOT_FOUND":
        mark("WARN", "AMFIPass does not appear in the live loaded-kext inventory")
    else:
        mark("WARN", "loaded-kext inventory could not be interpreted")

    # Query exact IORegistry classes. A shared bundle ID is never treated as native proof.
    def query_ioreg_class(class_name, label):
        rc, output = run_cmd(
            ["ioreg", "-p", "IOService", "-r", "-c", class_name, "-l", "-w0"], 25)
        matched = bool(rc == 0 and re.search(
            r"<class\s+" + re.escape(class_name) + r"(?:[,>])", output))
        state = "MATCH" if matched else ("NO_MATCH" if rc == 0 else "UNKNOWN")
        emit("IOREG_" + label + "_EXIT=" + str(rc))
        emit_block(label + " CLASS QUERY", output, 24, 420)
        emit("STAGE111_" + label + "_CLASS_MATCH=" + state)
        return state, rc

    native_controller_state, native_controller_rc = query_ioreg_class(
        "RTW88WCLController", "NATIVE_CONTROLLER_IOREGISTRY")
    native_interface_state, native_interface_rc = query_ioreg_class(
        "RTW88WCLInfraInterface", "NATIVE_INFRA_INTERFACE_IOREGISTRY")
    legacy_controller_state, legacy_controller_rc = query_ioreg_class(
        "RTL88WiFi", "LEGACY_CONTROLLER_IOREGISTRY")
    legacy_interface_state, legacy_interface_rc = query_ioreg_class(
        "RTL88WiFiInterface", "LEGACY_INTERFACE_IOREGISTRY")

    pci_rc, pci_text = run_cmd(
        ["ioreg", "-p", "IOService", "-n", "pci10ec,c821", "-l", "-w0"], 25)
    pci_lines = [line for line in pci_text.splitlines()
                 if "pci10ec,c821" in line.lower() or
                 re.search(r"<class\s+IOPCIDevice", line)]
    emit("IOREG_RTL8821CE_PCI_NODE_EXIT=" + str(pci_rc))
    emit_block("RTL8821CE PCI NODE", "\n".join(pci_lines), 16, 420)
    realtek_pci_state = "YES" if pci_rc == 0 and any(
        "pci10ec,c821" in line.lower() for line in pci_lines) else (
        "NO_MATCH" if pci_rc == 0 else "UNKNOWN")

    native_states = [native_controller_state, native_interface_state]
    if native_states == ["MATCH", "MATCH"]:
        native_ioreg_state = "BOTH_NATIVE_CLASSES_MATCH"
    elif native_states == ["MATCH", "NO_MATCH"]:
        native_ioreg_state = "CONTROLLER_ONLY"
    elif native_states == ["NO_MATCH", "MATCH"]:
        native_ioreg_state = "INFRA_INTERFACE_ONLY"
    elif native_states == ["NO_MATCH", "NO_MATCH"]:
        native_ioreg_state = "NO_NATIVE_CLASS_MATCH"
    else:
        native_ioreg_state = "UNKNOWN"

    legacy_states = [legacy_controller_state, legacy_interface_state]
    if "MATCH" in legacy_states:
        legacy_ioreg_state = "LEGACY_CLASS_MATCH"
    elif legacy_states == ["NO_MATCH", "NO_MATCH"]:
        legacy_ioreg_state = "NO_LEGACY_CLASS_MATCH"
    else:
        legacy_ioreg_state = "UNKNOWN"

    emit("STAGE111_NATIVE_CONTROLLER_IOREGISTRY_CLASS=" + native_controller_state)
    emit("STAGE111_NATIVE_INFRA_INTERFACE_IOREGISTRY_CLASS=" + native_interface_state)
    emit("STAGE111_NATIVE_IOREGISTRY_SERVICE_MATCH=" + native_ioreg_state)
    emit("STAGE111_LEGACY_CONTROLLER_IOREGISTRY_CLASS=" + legacy_controller_state)
    emit("STAGE111_LEGACY_INTERFACE_IOREGISTRY_CLASS=" + legacy_interface_state)
    emit("STAGE111_LEGACY_IOREGISTRY_FRONTEND_STATE=" + legacy_ioreg_state)
    emit("STAGE111_REALTEK_PCI_IOREGISTRY_HINT=" + realtek_pci_state)

    io_rc = 0 if all(rc == 0 for rc in [
        native_controller_rc, native_interface_rc,
        legacy_controller_rc, legacy_interface_rc, pci_rc]) else 1
    if io_rc == 0:
        mark("PASS", "targeted IORegistry class queries completed without altering device state")
    else:
        mark("WARN", "one or more targeted IORegistry class queries failed or timed out")

    # Wi-Fi inventory is supplementary; a generic Wi-Fi interface is not proof of RTL8821CE attachment.
    sp_rc, sp_text = run_cmd(["system_profiler", "SPAirPortDataType", "-detailLevel", "mini"], 45) if need_tool("system_profiler") else (127, "")
    emit("SYSTEM_PROFILER_AIRPORT_EXIT=" + str(sp_rc))
    sp_lines = [x for x in sp_text.splitlines() if re.search(r"Wi-Fi|Card Type|Firmware Version|Interface|Supported PHY Modes|Status:", x, re.I)]
    emit_block("AIRPORT SYSTEM PROFILER SUMMARY", "\n".join(sp_lines), 50)
    emit("STAGE111_AIRPORT_SYSTEM_PROFILER=" + ("AVAILABLE" if sp_rc == 0 else "UNAVAILABLE"))
    if sp_rc == 0:
        mark("PASS", "AirPort system_profiler query completed")
    else:
        mark("WARN", "AirPort system_profiler query unavailable")

    # Recent diagnostic messages may explain AMFI, kext policy or attachment failures.
    log_predicate = 'eventMessage CONTAINS[c] "AMFIPass" OR eventMessage CONTAINS[c] "RTL88WiFi" OR eventMessage CONTAINS[c] "RTL8821" OR eventMessage CONTAINS[c] "RTW88"'
    log_rc, log_text = run_cmd(["log", "show", "--last", "6h", "--style", "compact", "--predicate", log_predicate], 45) if need_tool("log") else (127, "")
    emit("UNIFIED_LOG_QUERY_EXIT=" + str(log_rc))
    relevant_logs = [x for x in log_text.splitlines() if re.search(r"AMFIPass|RTL88WiFi|RTL8821|RTW88", x, re.I)]
    emit_block("RECENT AMFI / REALTEK LOG MATCHES", "\n".join(relevant_logs), 80)
    emit("STAGE111_RECENT_LOG_MATCH_COUNT=" + str(len(relevant_logs)))
    if log_rc == 0:
        mark("PASS", "recent unified-log query completed")
    else:
        mark("WARN", "recent unified-log query unavailable or timed out")

    # Compact network inventory; interface presence alone is not driver proof.
    if need_tool("networksetup"):
        net_rc, net_text = run_cmd(["networksetup", "-listallhardwareports"], 15)
        net_lines = [x for x in net_text.splitlines() if re.search(r"Hardware Port:|Device:|Wi-Fi|WLAN|Ethernet", x, re.I)]
        emit("NETWORK_HARDWARE_PORTS_EXIT=" + str(net_rc))
        emit_block("NETWORK HARDWARE PORTS", "\n".join(net_lines), 40)
    else:
        emit("NETWORK_HARDWARE_PORTS_EXIT=127")

    # Summary deliberately separates "configured" from "actually loaded" and "hardware attached".
    amfi_config = "PRESENT_ENABLED" if any(x["enabled"] for x in amfi_rows) else ("PRESENT_DISABLED" if amfi_rows else "MISSING")
    order_summary = amfipass_order
    activation = "UNPROVEN_NATIVE_FRONTEND_RUNTIME; AUDIT_DOES_NOT_LOAD_OR_ACTIVATE_KEXTS"
    result = "AUDIT_COMPLETE" if efi_state == "PARSED" and counts["FAIL"] == 0 else "REVIEW_REQUIRED"
    emit("========== STAGE111 SUMMARY ==========")
    emit("STAGE111_PASS_COUNT=" + str(counts["PASS"]))
    emit("STAGE111_FAIL_COUNT=" + str(counts["FAIL"]))
    emit("STAGE111_WARN_COUNT=" + str(counts["WARN"]))
    emit("STAGE111_RESULT=" + result)
    emit("STAGE111_AMFIPASS_EFI_STATE=" + amfi_config)
    emit("STAGE111_LILU_AMFIPASS_ORDER=" + str(order_summary))
    emit("STAGE111_AMFIPASS_RUNTIME_LOADED=" + runtime_amfipass)
    emit("STAGE111_LILU_RUNTIME_LOADED=" + runtime_lilu)
    emit("STAGE111_NATIVE_BUNDLE_ID_RUNTIME_LOADED=" + runtime_native_bundle)
    emit("STAGE111_ANY_REALTEK_DRIVER_RUNTIME_LOADED=" + runtime_realtek)
    emit("STAGE111_NATIVE_CONTROLLER_IOREGISTRY_CLASS=" + native_controller_state)
    emit("STAGE111_NATIVE_INFRA_INTERFACE_IOREGISTRY_CLASS=" + native_interface_state)
    emit("STAGE111_NATIVE_IOREGISTRY_SERVICE_MATCH=" + native_ioreg_state)
    emit("STAGE111_LEGACY_CONTROLLER_IOREGISTRY_CLASS=" + legacy_controller_state)
    emit("STAGE111_LEGACY_INTERFACE_IOREGISTRY_CLASS=" + legacy_interface_state)
    emit("STAGE111_LEGACY_IOREGISTRY_FRONTEND_STATE=" + legacy_ioreg_state)
    emit("STAGE111_REALTEK_PCI_IOREGISTRY_HINT=" + realtek_pci_state)
    emit("STAGE111_LIVE_AMFI_OVERRIDE_TOKEN_PRESENT=" + str(live_amfi_override))
    emit("STAGE111_LIVE_AMFIPASS_BETA_FLAG_PRESENT=" + str("-amfipassbeta" in [x.lower() for x in live_tokens]))
    emit("STAGE111_SIP_STATE=" + sip)
    emit("STAGE111_DETAIL_LOG=" + str(log_path))
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_PERFORMED_BY_RUNNER MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("STAGE111_NATIVE_ACTIVATION=" + activation)
    emit("STAGE111_PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as f:
        f.write("\n========== STAGE111 AMFIPASS / LIVE RUNTIME AUDIT ==========\n")
        f.write("STAGE111_RESULT=" + result + "\n")
        f.write("STAGE111_PASS_COUNT=" + str(counts["PASS"]) + "\n")
        f.write("STAGE111_FAIL_COUNT=" + str(counts["FAIL"]) + "\n")
        f.write("STAGE111_WARN_COUNT=" + str(counts["WARN"]) + "\n")
        f.write("STAGE111_AMFIPASS_EFI_STATE=" + amfi_config + "\n")
        f.write("STAGE111_LILU_EFI_COUNT=" + str(lilu_count) + "\n")
        f.write("STAGE111_LILU_EFI_ENABLED_COUNT=" + str(lilu_enabled) + "\n")
        f.write("STAGE111_LILU_AMFIPASS_ORDER=" + str(order_summary) + "\n")
        f.write("STAGE111_AMFIPASS_RUNTIME_LOADED=" + runtime_amfipass + "\n")
        f.write("STAGE111_LILU_RUNTIME_LOADED=" + runtime_lilu + "\n")
        f.write("STAGE111_NATIVE_BUNDLE_ID_RUNTIME_LOADED=" + runtime_native_bundle + "\n")
        f.write("STAGE111_ANY_REALTEK_DRIVER_RUNTIME_LOADED=" + runtime_realtek + "\n")
        f.write("STAGE111_NATIVE_CONTROLLER_IOREGISTRY_CLASS=" + native_controller_state + "\n")
        f.write("STAGE111_NATIVE_INFRA_INTERFACE_IOREGISTRY_CLASS=" + native_interface_state + "\n")
        f.write("STAGE111_NATIVE_IOREGISTRY_SERVICE_MATCH=" + native_ioreg_state + "\n")
        f.write("STAGE111_LEGACY_CONTROLLER_IOREGISTRY_CLASS=" + legacy_controller_state + "\n")
        f.write("STAGE111_LEGACY_INTERFACE_IOREGISTRY_CLASS=" + legacy_interface_state + "\n")
        f.write("STAGE111_LEGACY_IOREGISTRY_FRONTEND_STATE=" + legacy_ioreg_state + "\n")
        f.write("STAGE111_REALTEK_PCI_IOREGISTRY_HINT=" + realtek_pci_state + "\n")
        f.write("STAGE111_LIVE_AMFI_OVERRIDE_TOKEN_PRESENT=" + str(live_amfi_override) + "\n")
        f.write("STAGE111_SIP_STATE=" + sip + "\n")
        f.write("STAGE111_DETAIL_LOG=" + str(log_path) + "\n")
        f.write("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_PERFORMED_BY_RUNNER MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN\n")
        f.write("STAGE111_NATIVE_ACTIVATION=" + activation + "\n")
        f.write("STAGE111_PR4_MERGE=BLOCKED\n")
        f.write("============================================================\n")

    # Only the generated audit records are committed; source, EFI and system state remain untouched.
    subprocess.check_call(["python3", "-c",
        "from pathlib import Path; import sys; " +
        "[(lambda p: p.write_text('\\n'.join(x.rstrip() for x in p.read_text(encoding='utf-8').splitlines())+'\\n', encoding='utf-8'))(Path(x)) for x in sys.argv[1:]]",
        str(log_path), str(OUTPUT_LOG)])
    subprocess.check_call(["git", "add", str(log_path), str(OUTPUT_LOG)])
    subprocess.check_call(["git", "diff", "--cached", "--check"])
    subprocess.check_call(["git", "commit", "-m", "Stage111: record AMFIPass and live runtime audit"])
    subprocess.check_call(["git", "push", "origin", BRANCH])
    emit("STAGE111_LOG_PUBLICATION=PUSHED")
    emit("STAGE111_COMMIT=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print("STAGE111_ABORTED: command failed: " + repr(e), file=sys.stderr)
        sys.exit(e.returncode if e.returncode else 1)
    except Exception as e:
        print("STAGE111_ABORTED: " + repr(e), file=sys.stderr)
        sys.exit(2)
