#!/usr/bin/env python3
"""Stage116: corrected, bounded, read-only native-kext diagnostics for macOS 24H32.

Reads only an already-mounted EFI/config and current runtime state. Does not mount or
write EFI, sign/build/install/load/unload, alter SIP/NVRAM, or perform radio tests.
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

BRANCH = "work/stage116-native-diagnostics-repair"
BASE = "4ae7d887b43ce2f9038820f249decc43b651c678"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", DEFAULT_CONFIG))
NATIVE_NAME = "RTL88WiFiNative.kext"
NATIVE_ID = "io.github.x1ren41l.rtl88wifi"
NATIVE_EXEC = "RTL88WiFiNative"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage116-native-diagnostics-repair.py")
ALLOWLIST = Path("Development/Allowlist/stage116-native-diagnostics-repair.gitblob")

lines = []

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def block(name, value, max_lines=70, max_chars=520):
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

def record(name, args, timeout=30, max_lines=60):
    rc, out = run(args, timeout)
    emit(name + "_EXIT=" + str(rc))
    block(name, out, max_lines)
    return rc, out

def digest(path):
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

def safe_plist_text(value):
    if isinstance(value, bytes):
        return value.hex()
    return str(value)

def classify_signature(display_rc, display, verify_rc, verify):
    combined = (display + "\n" + verify).lower()
    if "code object is not signed at all" in combined or "code object is not signed" in combined:
        return "UNSIGNED"
    if verify_rc == 0:
        return "VERIFY_PASS"
    signed_metadata = any(token in combined for token in (
        "authority=", "teamidentifier=", "cdhash=", "signature=adhoc", "signature="))
    if signed_metadata:
        return "SIGNED_VERIFY_FAILED"
    if display_rc not in (0, 1, 127):
        return "DISPLAY_ERROR"
    return "VERIFY_INDETERMINATE"

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
    log_path = LOG_DIR / ("stage116-native-diagnostics-repair-" + stamp + ".log")
    version_rc, version = run(["sw_vers", "-productVersion"], 10)
    build_rc, build = run(["sw_vers", "-buildVersion"], 10)
    arch_rc, arch = run(["uname", "-m"], 10)
    host_ok = (version_rc, build_rc, arch_rc) == (0, 0, 0) and (version.strip(), build.strip(), arch.strip()) == ("15.8.1", "24H32", "x86_64")

    emit("========== STAGE116 CORRECTED NATIVE-KEXT DIAGNOSTICS ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + version.strip() + " (" + build.strip() + ") " + arch.strip())
    emit("TARGET_MATCH_24H32=" + str(host_ok))
    emit("SCOPE=READ_ONLY_ALREADY_MOUNTED_EFI_CORRECTED_KMUTIL_DIAGNOSTICS_NODE_SCOPED_IOREGISTRY_BOUNDED_LOG")
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN")
    emit("MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("NOTE=KMUTIL_PRINT_DIAGNOSTICS_USES_-p_BUNDLE_PATH; NO_STAGING_OR_LOAD_ACTIONS")

    sip_rc, sip = record("SIP_STATUS", ["csrutil", "status"], 12, 8)
    emit("SIP_STATE=" + ("ENABLED" if re.search(r"status:\s*enabled|is enabled", sip, re.I) else "NOT_CONFIRMED"))
    boot_rc, boot = record("LIVE_BOOT_ARGS", ["sysctl", "-n", "kern.bootargs"], 12, 8)
    emit("LIVE_BOOT_ARGS_VALUE=" + boot.strip()[:700].replace("\n", " "))
    nv_rc, nv = run(["nvram", "-p"], 12)
    emit("LIVE_NVRAM_READ_EXIT=" + str(nv_rc))
    nv_lines = [x for x in nv.splitlines() if re.search(r"opencore-version|boot-args|csr-active-config", x, re.I)]
    block("LIVE_NVRAM_RELEVANT", "\n".join(nv_lines), 16, 420)

    cfg = {}
    cfg_root = None
    native_bundle = None
    native_info = {}
    native_rows = []
    relevant_order = []
    config_state = "NOT_ASSESSED"
    open_core_debug_target = None

    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint = record("OPENCORE_CONFIG_PLUTIL", ["plutil", "-lint", str(CONFIG)], 12, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as stream:
                    cfg = plistlib.load(stream)
                cfg_root = CONFIG.parent.resolve()
                config_state = "PARSED"
                kernel = cfg.get("Kernel", {}) or {}
                for index, entry in enumerate(kernel.get("Add", []) or []):
                    bp = str(entry.get("BundlePath", ""))
                    basename = Path(bp).name
                    if any(k in basename.lower() for k in ("lilu", "amfipass", "rtl88wifinative")):
                        relevant_order.append({"index": index, "bundle_path": bp, "enabled": entry.get("Enabled") is True})
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
                        any(isinstance(v, dict) and v.get("IOClass") == "RTW88WCLController"
                            for v in (info.get("IOKitPersonalities", {}) or {}).values()))
                    if not is_native:
                        continue
                    exe_rel = str(entry.get("ExecutablePath", ""))
                    exe = (bundle / exe_rel).resolve() if bundle and exe_rel else None
                    exists = bool(exe and inside(exe, bundle) and exe.is_file())
                    row = {
                        "index": index, "enabled": entry.get("Enabled") is True,
                        "arch": str(entry.get("Arch", "UNKNOWN")),
                        "min_kernel": str(entry.get("MinKernel", "")),
                        "max_kernel": str(entry.get("MaxKernel", "")),
                        "bundle_path": bp, "resolved_bundle": str(bundle) if bundle else "UNRESOLVED",
                        "bundle_id": str(info.get("CFBundleIdentifier", "")),
                        "plist_executable": str(info.get("CFBundleExecutable", "")),
                        "executable_path": exe_rel, "executable_exists": exists,
                        "sha256": digest(exe) if exists else "MISSING",
                    }
                    native_rows.append(row)
                    if bundle:
                        native_bundle, native_info = bundle, info

                emit("OPENCORE_CONFIG_PATH=" + str(CONFIG))
                emit("RELEVANT_KERNEL_ADD_ORDER=" + json.dumps(relevant_order, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_ROWS=" + json.dumps(native_rows, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_COUNT=" + str(len(native_rows)))
                emit("NATIVE_KERNEL_ADD_ENABLED_COUNT=" + str(sum(1 for row in native_rows if row["enabled"])))
                hash_match = bool(native_rows) and all(row["sha256"] == EXPECTED_NATIVE_SHA for row in native_rows)
                emit("NATIVE_EXECUTABLE_SHA_MATCH_STAGE113=" + str(hash_match))
                blocked = [str(row.get("BundleIdentifier", "")) for row in kernel.get("Block", []) or []
                           if row.get("Enabled") is True and str(row.get("BundleIdentifier", "")).lower()
                           in ("com.apple.iokit.ioskywalkfamily", "com.apple.iokit.io80211familylegacy")]
                emit("RELEVANT_ENABLED_KERNEL_BLOCKS=" + (",".join(blocked) if blocked else "NONE"))

                for personality_name, person in (native_info.get("IOKitPersonalities", {}) or {}).items():
                    if isinstance(person, dict) and person.get("IOClass") == "RTW88WCLController":
                        match = person.get("IOPCIMatch", "")
                        if isinstance(match, bytes):
                            match = match.hex()
                        emit("NATIVE_PERSONALITY=" + json.dumps({
                            "name": str(personality_name), "IOClass": person.get("IOClass"),
                            "IOProviderClass": person.get("IOProviderClass"),
                            "IOPCIMatch": match, "IOProbeScore": person.get("IOProbeScore")}, sort_keys=True))

                nv_add = cfg.get("NVRAM", {}).get("Add", {}) or {}
                nvdata = next((value for key, value in nv_add.items()
                               if str(key).upper() == "7C436110-AB2A-4BBB-A880-FE41995C9F82"), {})
                emit("CONFIGURED_BOOT_ARGS=" + str(nvdata.get("boot-args", ""))[:700])
                emit("CONFIGURED_CSR_ACTIVE_CONFIG_HEX=" + safe_plist_text(nvdata.get("csr-active-config", b"")))
                security = cfg.get("Misc", {}).get("Security", {}) or {}
                debug = cfg.get("Misc", {}).get("Debug", {}) or {}
                open_core_debug_target = debug.get("Target", None)
                emit("SECURE_BOOT_MODEL=" + str(security.get("SecureBootModel", "UNKNOWN")))
                emit("VAULT=" + str(security.get("Vault", "UNKNOWN")))
                emit("OPENCORE_DEBUG_TARGET=" + str(open_core_debug_target))
                emit("OPENCORE_DEBUG_DISPLAY_LEVEL=" + str(debug.get("DisplayLevel", "UNKNOWN")))
                emit("OPENCORE_DEBUG_LOGGING_DISABLED=" + str(open_core_debug_target == 0))
            except Exception as exc:
                config_state = "PARSE_ERROR"
                emit("OPENCORE_CONFIG_ERROR=" + repr(exc))
        else:
            config_state = "PLUTIL_FAIL"
    else:
        emit("OPENCORE_CONFIG_READABILITY=NOT_MOUNTED_OR_NOT_READABLE_NO_MOUNT_ATTEMPTED")
    emit("OPENCORE_CONFIG_RESULT=" + config_state)

    signature_state = "NOT_ASSESSED"
    km_diag_rc = 127
    km_diag = ""
    if native_bundle:
        for path in (native_bundle, native_bundle / "Contents" / "Info.plist", native_bundle / "Contents" / "MacOS" / NATIVE_EXEC):
            try:
                st = path.stat()
                emit("NATIVE_EFI_STAT=" + json.dumps({
                    "path": str(path), "uid": st.st_uid, "gid": st.st_gid,
                    "mode": oct(st.st_mode & 0o777), "size": st.st_size if path.is_file() else None
                }, sort_keys=True))
            except OSError as exc:
                emit("NATIVE_EFI_STAT_ERROR=" + repr(exc))
        ls_rc, ls = record("NATIVE_EFI_ACL", ["ls", "-lde@", str(native_bundle),
                           str(native_bundle / "Contents"), str(native_bundle / "Contents" / "Info.plist"),
                           str(native_bundle / "Contents" / "MacOS" / NATIVE_EXEC)], 12, 24)
        cd_rc, cd = record("NATIVE_CODESIGN_DISPLAY", ["codesign", "-dv", "--verbose=4", str(native_bundle)], 18, 35)
        cv_rc, cv = record("NATIVE_CODESIGN_VERIFY", ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(native_bundle)], 20, 35)
        signature_state = classify_signature(cd_rc, cd, cv_rc, cv)
        emit("NATIVE_SIGNATURE_CLASSIFICATION=" + signature_state)

        # Correct kmutil syntax: bundle paths are supplied with -p/--bundle-path.
        km_diag_rc, km_diag = record("NATIVE_KMUTIL_PRINT_DIAGNOSTICS",
            ["kmutil", "print-diagnostics", "-p", str(native_bundle)], 55, 100)
        diag = [line for line in km_diag.splitlines()
                if re.search(r"bad code signature|authenticating extension failed|invalid ownership|not signed|signature|permission|owner|not loadable|validation", line, re.I)]
        block("KMUTIL_DIAGNOSTIC_FINDINGS", "\n".join(diag), 70, 520)
        emit("KMUTIL_DIAGNOSTICS_COMMAND_ACCEPTED=" + str(km_diag_rc != 1 or "Unexpected argument" not in km_diag))
        emit("KMUTIL_EXPLICIT_BAD_SIGNATURE_LINE_COUNT=" + str(sum(1 for line in diag if re.search(r"bad code signature", line, re.I))))
        emit("KMUTIL_INVALID_OWNERSHIP_LINE_COUNT=" + str(sum(1 for line in diag if re.search(r"invalid ownership", line, re.I))))
        emit("KMUTIL_PERMISSION_OR_OWNER_LINE_COUNT=" + str(sum(1 for line in diag if re.search(r"permission|owner|ownership", line, re.I))))
        km_lib_rc, km_lib = record("NATIVE_KMUTIL_LIBRARIES",
            ["kmutil", "libraries", "-p", str(native_bundle), "--xml"], 40, 25)
        emit("KMUTIL_LIBRARIES_RESULT=" + ("PASS" if km_lib_rc == 0 else "NOT_PASS"))
    else:
        emit("NATIVE_SIGNATURE_CLASSIFICATION=NOT_ASSESSED_NO_RESOLVED_NATIVE_BUNDLE")
        emit("NATIVE_KMUTIL_PRINT_DIAGNOSTICS_EXIT=127")

    loaded_rc, loaded = run(["kmutil", "showloaded", "--show", "all", "--bundle-identifier", NATIVE_ID], 35)
    emit("KMUTIL_NATIVE_QUERY_EXIT=" + str(loaded_rc))
    native_loaded = bool(loaded_rc == 0 and re.search(re.escape(NATIVE_ID), loaded, re.I))
    block("KMUTIL_NATIVE_LOADED_QUERY", loaded, 25, 500)
    emit("NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))

    ioreg_states = {}
    for cls in ("RTW88WCLController", "RTW88WCLInfraInterface"):
        rc, output = run(["ioreg", "-p", "IOService", "-r", "-c", cls, "-l", "-w0"], 20)
        found = bool(rc == 0 and re.search(r"<class\s+" + re.escape(cls) + r"(?:[,>])", output))
        ioreg_states[cls] = "MATCH" if found else ("NO_MATCH" if rc == 0 else "UNKNOWN")
        emit("IOREG_" + cls + "_EXIT=" + str(rc))
        block("IOREG_" + cls, output, 16, 480)
        emit("IOREG_" + cls + "_STATE=" + ioreg_states[cls])

    # -r asks ioreg to return the matched node and its subtree, not the whole root tree.
    pci_rc, pci = run(["ioreg", "-p", "IOService", "-n", "pci10ec,c821", "-r", "-l", "-w0"], 20)
    pci_match = bool(pci_rc == 0 and re.search(r"pci10ec,c821(?:@[^\s]+)?\s+<class\s+IOPCIDevice", pci, re.I))
    emit("IOREG_RTL8821CE_NODE_QUERY_EXIT=" + str(pci_rc))
    block("IOREG_RTL8821CE_NODE", pci, 35, 520)
    emit("IOREG_RTL8821CE_NODE_MATCH=" + str(pci_match))

    # Bound the unified-log query to native-driver identifiers and a six-hour window.
    predicate = ('eventMessage CONTAINS[c] "RTL88WiFiNative" OR '
                 'eventMessage CONTAINS[c] "RTW88WCL" OR '
                 'eventMessage CONTAINS[c] "io.github.x1ren41l.rtl88wifi"')
    log_rc, log_output = run(["log", "show", "--last", "6h", "--style", "compact", "--predicate", predicate], 35)
    emit("NATIVE_TARGETED_UNIFIED_LOG_EXIT=" + str(log_rc))
    explicit_reject = False
    selected = []
    if log_rc == 0:
        selected = [line for line in log_output.splitlines()
                    if re.search(r"RTL88WiFiNative|RTW88WCL|io\.github\.x1ren41l\.rtl88wifi", line, re.I)]
        block("NATIVE_TARGETED_UNIFIED_LOG", "\n".join(selected), 80, 560)
        explicit_reject = any(re.search(r"bad code signature|not validly signed|signature.*(invalid|reject)|reject.*signature|authenticat.*fail", line, re.I)
                              for line in selected)
        emit("NATIVE_SPECIFIC_SIGNATURE_REJECTION_LOG=" + str(explicit_reject))
        emit("NATIVE_TARGETED_LOG_LINE_COUNT=" + str(len(selected)))
    else:
        block("NATIVE_TARGETED_UNIFIED_LOG_ERROR", log_output, 12, 400)
        emit("NATIVE_SPECIFIC_SIGNATURE_REJECTION_LOG=UNKNOWN")

    oc_logs = []
    if cfg_root and (cfg_root / "Logs").is_dir():
        candidates = sorted([path for path in (cfg_root / "Logs").iterdir()
                              if path.is_file() and path.suffix.lower() in (".txt", ".log")],
                             key=lambda path: path.stat().st_mtime, reverse=True)[:5]
        for path in candidates:
            oc_logs.append(path)
            try:
                content = path.read_text(encoding="utf-8", errors="replace").splitlines()
                hits = [line for line in content if re.search(
                    r"RTL88WiFi|RTW88|AMFIPass|Lilu|kext|signature|inject|load(ed|ing)?|reject|fail|error", line, re.I)]
                emit("OPENCORE_LOG_FILE=" + str(path))
                block("OPENCORE_LOG_" + path.name, "\n".join(hits[-35:]), 35, 520)
            except OSError as exc:
                emit("OPENCORE_LOG_READ_ERROR=" + repr(exc))
    emit("OPENCORE_LOG_FILES_FOUND=" + str(len(oc_logs)))

    enabled = sum(1 for row in native_rows if row["enabled"])
    hash_match = bool(native_rows) and all(row["sha256"] == EXPECTED_NATIVE_SHA for row in native_rows)
    diagnosis = "INCONCLUSIVE_READ_ONLY_EVIDENCE"
    if config_state != "PARSED":
        diagnosis = "OPENCORE_CONFIG_UNAVAILABLE_OR_INVALID"
    elif len(native_rows) != 1 or enabled != 1:
        diagnosis = "NATIVE_KERNEL_ADD_ENTRY_MISSING_DISABLED_OR_DUPLICATED"
    elif not hash_match:
        diagnosis = "EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_VALIDATED_BINARY"
    elif native_loaded:
        diagnosis = "NATIVE_KEXT_PRESENT_BUT_CONTROLLER_MATCH_REQUIRES_REVIEW"
    elif re.search(r"invalid ownership|bad code signature|authenticating extension failed|code object is not signed|not signed", km_diag, re.I):
        diagnosis = "KMUTIL_DIAGNOSTIC_REPORTS_AUTH_OR_OWNERSHIP_ISSUE_OPENCORE_CAUSALITY_UNPROVEN"
    elif km_diag_rc not in (0, 1):
        diagnosis = "KMUTIL_DIAGNOSTICS_NOT_COMPLETED_OTHER_CAUSE_UNRESOLVED"
    elif signature_state == "UNSIGNED":
        diagnosis = "UNSIGNED_BUNDLE_CONFIRMED_BUT_BOOT_REJECTION_NOT_PROVEN"
    elif signature_state == "SIGNED_VERIFY_FAILED":
        diagnosis = "SIGNED_BUNDLE_VERIFY_FAILURE_CAUSE_REQUIRES_REVIEW"
    elif signature_state == "VERIFY_PASS":
        diagnosis = "SIGNATURE_VERIFIES_BUT_INJECTION_OR_MATCHING_REMAINS_UNRESOLVED"
    else:
        diagnosis = "SIGNATURE_STATE_INDETERMINATE"

    emit("STAGE116_PRIMARY_DIAGNOSIS=" + diagnosis)
    emit("STAGE116_SIGNATURE_CLASSIFICATION=" + signature_state)
    emit("STAGE116_KMUTIL_DIAGNOSTICS_EXIT=" + str(km_diag_rc))
    emit("STAGE116_NATIVE_SPECIFIC_REJECTION_LOG=" + str(explicit_reject))
    emit("STAGE116_RTL8821CE_NODE_MATCH=" + str(pci_match))
    emit("STAGE116_NATIVE_CONTROLLER_IOREGISTRY=" + ioreg_states.get("RTW88WCLController", "UNKNOWN"))
    emit("STAGE116_NATIVE_INTERFACE_IOREGISTRY=" + ioreg_states.get("RTW88WCLInfraInterface", "UNKNOWN"))
    emit("STAGE116_OPENCORE_LOG_FILES=" + str(len(oc_logs)))
    emit("STAGE116_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW")
    emit("STAGE116_ACTIVATION=BLOCKED")
    emit("SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE116 CORRECTED NATIVE-KEXT DIAGNOSTICS ==========\n")
        stream.write("STAGE116_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW\n")
        stream.write("STAGE116_PRIMARY_DIAGNOSIS=" + diagnosis + "\n")
        stream.write("STAGE116_SIGNATURE_CLASSIFICATION=" + signature_state + "\n")
        stream.write("STAGE116_KMUTIL_DIAGNOSTICS_EXIT=" + str(km_diag_rc) + "\n")
        stream.write("STAGE116_NATIVE_SPECIFIC_REJECTION_LOG=" + str(explicit_reject) + "\n")
        stream.write("STAGE116_RTL8821CE_NODE_MATCH=" + str(pci_match) + "\n")
        stream.write("STAGE116_NATIVE_CONTROLLER_IOREGISTRY=" + ioreg_states.get("RTW88WCLController", "UNKNOWN") + "\n")
        stream.write("STAGE116_NATIVE_INTERFACE_IOREGISTRY=" + ioreg_states.get("RTW88WCLInfraInterface", "UNKNOWN") + "\n")
        stream.write("STAGE116_DETAIL_LOG=" + str(log_path) + "\n")
        stream.write("STAGE116_ACTIVATION=BLOCKED PR4_MERGE=BLOCKED\n")
    emit("STAGE116_DETAIL_LOG=" + str(log_path))
    emit("STAGE116_CANONICAL_LOG=" + str(OUTPUT_LOG))

if __name__ == "__main__":
    main()
