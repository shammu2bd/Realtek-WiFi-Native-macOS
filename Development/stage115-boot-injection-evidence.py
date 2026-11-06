#!/usr/bin/env python3
"""Stage115: read-only OpenCore/native-kext evidence with conservative signature classification.

Reads only an already-mounted OpenCore EFI and current macOS runtime state.
Writes its report under Development/Logs and appends a short summary to Development/output.log.
Never mounts/writes EFI, edits config/NVRAM/SIP, signs, builds, installs, loads/unloads, or probes radio hardware.
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

BRANCH = "work/stage115-boot-injection-evidence"
BASE = "fb14a13657d3040dd1665136756069996a3e337c"
EXPECTED_NATIVE_SHA = "409137db0772c6f5326af89f9f6dc699f8f18a13eb9025bc194b58e5bb92cd0a"
DEFAULT_CONFIG = "/Volumes/EFI/EFI/OC/config.plist"
CONFIG = Path(os.environ.get("OPENCORE_CONFIG", DEFAULT_CONFIG))
NATIVE_NAME = "RTL88WiFiNative.kext"
NATIVE_ID = "io.github.x1ren41l.rtl88wifi"
NATIVE_EXEC = "RTL88WiFiNative"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage115-boot-injection-evidence.py")
ALLOWLIST = Path("Development/Allowlist/stage115-boot-injection-evidence.gitblob")

lines = []

def emit(value=""):
    line = str(value).rstrip()
    print(line, flush=True)
    lines.append(line)

def block(title, value, max_lines=60, max_chars=520):
    emit("----- " + title + " -----")
    selected = (value or "").splitlines()
    if not selected:
        emit("(no output)")
    for line in selected[:max_lines]:
        emit(line[:max_chars] + (" ...[truncated]" if len(line) > max_chars else ""))
    if len(selected) > max_lines:
        emit("... " + str(len(selected) - max_lines) + " additional lines omitted")
    emit("----- END " + title + " -----")

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

def record(label, args, timeout=30, max_lines=50):
    rc, out = run(args, timeout)
    emit(label + "_EXIT=" + str(rc))
    block(label, out, max_lines)
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

def decode_plist_value(value):
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8", "replace")
        except Exception:
            return value.hex()
    return value

def classify_signature(display_rc, display, verify_rc, verify):
    combined = (display + "\n" + verify).lower()
    if "code object is not signed at all" in combined or "code object is not signed" in combined:
        return "UNSIGNED"
    signature_metadata = any(token in combined for token in (
        "authority=", "teamidentifier=", "cdhash=", "signature=adhoc", "signature="))
    if verify_rc == 0:
        return "VERIFY_PASS"
    if signature_metadata:
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
    log_path = LOG_DIR / ("stage115-boot-injection-evidence-" + stamp + ".log")
    version_rc, version = run(["sw_vers", "-productVersion"], 10)
    build_rc, build = run(["sw_vers", "-buildVersion"], 10)
    arch_rc, arch = run(["uname", "-m"], 10)
    emit("========== STAGE115 BOOT-INJECTION / NATIVE-KEXT EVIDENCE ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("TARGET=" + version.strip() + " (" + build.strip() + ") " + arch.strip())
    emit("SCOPE=READ_ONLY_EXISTING_EFI_CONFIG_KEXT_METADATA_SIGNATURE_STATUS_BOOT_LOGS_RUNTIME_IOREGISTRY")
    emit("BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN")
    emit("MOUNT=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("NOTE=UNSIGNED_BUNDLE_IS_NOT_BY_ITSELF_PROOF_OF_AMFI_OR_BOOT-INJECTION_REJECTION")

    host_ok = (version_rc, build_rc, arch_rc) == (0, 0, 0) and (version.strip(), build.strip(), arch.strip()) == ("15.8.1", "24H32", "x86_64")
    emit("TARGET_MATCH_24H32=" + str(host_ok))
    sip_rc, sip = record("SIP_STATUS", ["csrutil", "status"], 12, 8)
    emit("SIP_STATE=" + ("ENABLED" if re.search(r"status:\s*enabled|is enabled", sip, re.I) else "NOT_CONFIRMED"))
    boot_rc, boot = record("LIVE_BOOT_ARGS", ["sysctl", "-n", "kern.bootargs"], 12, 8)
    emit("LIVE_BOOT_ARGS_VALUE=" + boot.strip()[:700].replace("\n", " "))
    nv_rc, nv = run(["nvram", "-p"], 15)
    emit("LIVE_NVRAM_READ_EXIT=" + str(nv_rc))
    nv_lines = [x for x in nv.splitlines() if re.search(r"opencore-version|boot-args|csr-active-config", x, re.I)]
    block("LIVE_NVRAM_RELEVANT", "\n".join(nv_lines), 16, 420)

    cfg = {}
    cfg_root = None
    volume = None
    native_bundle = None
    native_info = {}
    native_rows = []
    load_order = []
    config_state = "NOT_ASSESSED"
    if CONFIG.is_file() and os.access(str(CONFIG), os.R_OK):
        lint_rc, lint = record("OPENCORE_CONFIG_PLUTIL", ["plutil", "-lint", str(CONFIG)], 12, 8)
        if lint_rc == 0:
            try:
                with CONFIG.open("rb") as stream:
                    cfg = plistlib.load(stream)
                cfg_root = CONFIG.parent.resolve()
                volume = CONFIG.parents[2] if len(CONFIG.parents) > 2 else CONFIG.parent
                config_state = "PARSED"
                emit("OPENCORE_CONFIG_PATH=" + str(CONFIG))
                kernel = cfg.get("Kernel", {}) or {}
                add = kernel.get("Add", []) or []
                for index, entry in enumerate(add):
                    bp = str(entry.get("BundlePath", ""))
                    name = Path(bp).name
                    if any(t in name.lower() for t in ("lilu", "amfipass", "rtl88wifinative")):
                        load_order.append({"index": index, "bundle_path": bp, "enabled": entry.get("Enabled") is True})
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
                            info = {}
                    bid = str(info.get("CFBundleIdentifier", ""))
                    personality_values = (info.get("IOKitPersonalities", {}) or {}).values()
                    is_native = name == NATIVE_NAME or (
                        str(info.get("CFBundleExecutable", "")) == NATIVE_EXEC and
                        any(isinstance(v, dict) and v.get("IOClass") == "RTW88WCLController" for v in personality_values))
                    if not is_native:
                        continue
                    exe_rel = str(entry.get("ExecutablePath", ""))
                    exe = (bundle / exe_rel).resolve() if bundle and exe_rel else None
                    plist_rel = str(entry.get("PlistPath", ""))
                    executable_ok = bool(exe and inside(exe, bundle) and exe.is_file())
                    row = {
                        "index": index,
                        "enabled": entry.get("Enabled") is True,
                        "arch": str(entry.get("Arch", "UNKNOWN")),
                        "min_kernel": str(entry.get("MinKernel", "")),
                        "max_kernel": str(entry.get("MaxKernel", "")),
                        "bundle_path": bp,
                        "resolved_bundle": str(bundle) if bundle else "UNRESOLVED",
                        "bundle_id": bid,
                        "plist_executable": str(info.get("CFBundleExecutable", "")),
                        "entry_executable_path": exe_rel,
                        "entry_plist_path": plist_rel,
                        "executable_exists": executable_ok,
                        "sha256": digest(exe) if executable_ok else "MISSING",
                    }
                    native_rows.append(row)
                    if bundle:
                        native_bundle, native_info = bundle, info
                emit("RELEVANT_KERNEL_ADD_ORDER=" + json.dumps(load_order, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_ROWS=" + json.dumps(native_rows, sort_keys=True))
                emit("NATIVE_KERNEL_ADD_COUNT=" + str(len(native_rows)))
                emit("NATIVE_KERNEL_ADD_ENABLED_COUNT=" + str(sum(1 for r in native_rows if r["enabled"])))
                hash_match = bool(native_rows) and all(r["sha256"] == EXPECTED_NATIVE_SHA for r in native_rows)
                emit("NATIVE_EXECUTABLE_SHA_MATCH_STAGE113=" + str(hash_match))
                blocks = [str(e.get("BundleIdentifier", "")) for e in kernel.get("Block", []) or []
                          if e.get("Enabled") is True and str(e.get("BundleIdentifier", "")).lower() in
                          ("com.apple.iokit.ioskywalkfamily", "com.apple.iokit.io80211familylegacy")]
                emit("RELEVANT_ENABLED_KERNEL_BLOCKS=" + (",".join(blocks) if blocks else "NONE"))
                personalities = native_info.get("IOKitPersonalities", {}) or {}
                for pname, person in personalities.items():
                    if not isinstance(person, dict) or person.get("IOClass") != "RTW88WCLController":
                        continue
                    match = person.get("IOPCIMatch", "")
                    emit("NATIVE_PERSONALITY=" + json.dumps({
                        "name": str(pname), "IOClass": person.get("IOClass"),
                        "IOProviderClass": person.get("IOProviderClass"),
                        "IOPCIMatch": decode_plist_value(match),
                        "IOProbeScore": person.get("IOProbeScore")}, sort_keys=True))
                nvr_add = cfg.get("NVRAM", {}).get("Add", {}) or {}
                nvdata = next((v for k, v in nvr_add.items() if str(k).upper() == "7C436110-AB2A-4BBB-A880-FE41995C9F82"), {})
                configured_boot = decode_plist_value(nvdata.get("boot-args", ""))
                configured_csr = decode_plist_value(nvdata.get("csr-active-config", "UNKNOWN"))
                emit("CONFIGURED_BOOT_ARGS=" + str(configured_boot)[:700])
                emit("CONFIGURED_CSR_ACTIVE_CONFIG=" + str(configured_csr))
                sec = cfg.get("Misc", {}).get("Security", {}) or {}
                debug = cfg.get("Misc", {}).get("Debug", {}) or {}
                emit("SECURE_BOOT_MODEL=" + str(sec.get("SecureBootModel", "UNKNOWN")))
                emit("VAULT=" + str(sec.get("Vault", "UNKNOWN")))
                emit("OPENCORE_DEBUG_TARGET=" + str(debug.get("Target", "UNKNOWN")))
                emit("OPENCORE_DEBUG_DISPLAY_LEVEL=" + str(debug.get("DisplayLevel", "UNKNOWN")))
                emit("OPENCORE_CONFIG_INSPECTION=" + ("PASS" if native_rows else "WARN"))
            except Exception as exc:
                config_state = "PARSE_ERROR"
                emit("OPENCORE_CONFIG_ERROR=" + repr(exc))
        else:
            config_state = "PLUTIL_FAIL"
    else:
        emit("OPENCORE_CONFIG_READABILITY=NOT_MOUNTED_OR_NOT_READABLE_NO_MOUNT_ATTEMPTED")
    emit("OPENCORE_CONFIG_RESULT=" + config_state)

    signature_state = "NOT_ASSESSED"
    diagnostics = ""
    if native_bundle:
        expected = [native_bundle, native_bundle / "Contents" / "Info.plist", native_bundle / "Contents" / "MacOS" / NATIVE_EXEC]
        for path in expected:
            try:
                st = path.stat()
                emit("NATIVE_EFI_STAT=" + json.dumps({"path": str(path), "uid": st.st_uid, "gid": st.st_gid,
                      "mode": oct(st.st_mode & 0o777), "size": st.st_size if path.is_file() else None}, sort_keys=True))
            except OSError as exc:
                emit("NATIVE_EFI_STAT_ERROR=" + repr(exc))
        cd_rc, cd = record("NATIVE_CODESIGN_DISPLAY", ["codesign", "-dv", "--verbose=4", str(native_bundle)], 20, 40)
        cv_rc, cv = record("NATIVE_CODESIGN_VERIFY", ["codesign", "--verify", "--deep", "--strict", "--verbose=4", str(native_bundle)], 25, 40)
        signature_state = classify_signature(cd_rc, cd, cv_rc, cv)
        emit("NATIVE_SIGNATURE_CLASSIFICATION=" + signature_state)
        kd_rc, diagnostics = record("NATIVE_KMUTIL_DIAGNOSTICS", ["kmutil", "print-diagnostics", str(native_bundle)], 45, 85)
        diag_lines = [x for x in diagnostics.splitlines() if re.search(r"bad code signature|authenticating extension failed|invalid ownership|not signed|signature", x, re.I)]
        block("KMUTIL_SIGNATURE_OWNERSHIP_LINES", "\n".join(diag_lines), 35, 500)
        emit("KMUTIL_EXPLICIT_BAD_SIGNATURE_LINE_COUNT=" + str(sum(1 for x in diag_lines if re.search(r"bad code signature", x, re.I))))
        emit("KMUTIL_INVALID_OWNERSHIP_LINE_COUNT=" + str(sum(1 for x in diag_lines if re.search(r"invalid ownership", x, re.I))))
        kl_rc, kl = run(["kmutil", "libraries", "--bundle-path", str(native_bundle), "--xml"], 45)
        emit("KMUTIL_LIBRARIES_EXIT=" + str(kl_rc))
        if kl_rc == 0:
            emit("KMUTIL_LIBRARIES_QUERY=PASS")
        else:
            block("KMUTIL_LIBRARIES_OUTPUT", kl, 25, 450)
    else:
        emit("NATIVE_SIGNATURE_CLASSIFICATION=NOT_ASSESSED_NO_RESOLVED_NATIVE_BUNDLE")

    loaded_rc, loaded = run(["kmutil", "showloaded"], 45)
    emit("KMUTIL_SHOWLOADED_EXIT=" + str(loaded_rc))
    loaded_lines = [x for x in loaded.splitlines() if re.search(r"AMFIPass|Lilu|RTL88WiFi|RTW88|RtWlanU|IO80211Family|IOSkywalkFamily", x, re.I)]
    block("LOADED_RELEVANT_KEXTS", "\n".join(loaded_lines), 45, 500)
    native_loaded = any(NATIVE_ID.lower() in x.lower() or NATIVE_EXEC.lower() in x.lower() for x in loaded_lines)
    emit("NATIVE_KEXT_PRESENT_IN_SHOWLOADED=" + str(native_loaded))

    ioreg_states = {}
    for cls in ("RTW88WCLController", "RTW88WCLInfraInterface"):
        rc, out = run(["ioreg", "-p", "IOService", "-r", "-c", cls, "-l", "-w0"], 25)
        found = bool(rc == 0 and re.search(r"<class\s+" + re.escape(cls) + r"(?:[,>])", out))
        ioreg_states[cls] = "MATCH" if found else ("NO_MATCH" if rc == 0 else "UNKNOWN")
        emit("IOREG_" + cls + "_EXIT=" + str(rc))
        block("IOREG_" + cls, out, 14, 460)
        emit("IOREG_" + cls + "_STATE=" + ioreg_states[cls])
    pci_rc, pci = run(["ioreg", "-p", "IOService", "-n", "pci10ec,c821", "-l", "-w0"], 25)
    pci_present = pci_rc == 0 and "pci10ec,c821" in pci.lower()
    emit("IOREG_RTL8821CE_PCI_EXIT=" + str(pci_rc))
    block("IOREG_RTL8821CE_PCI", pci, 16, 460)
    emit("IOREG_RTL8821CE_PCI_PRESENT=" + str(pci_present))

    predicate = ('eventMessage CONTAINS[c] "RTL88WiFi" OR '
                 'eventMessage CONTAINS[c] "RTW88WCL" OR '
                 'eventMessage CONTAINS[c] "io.github.x1ren41l.rtl88wifi"')
    log_rc, runtime_logs = run(["log", "show", "--last", "24h", "--style", "compact", "--predicate", predicate], 65)
    emit("NATIVE_TARGETED_UNIFIED_LOG_EXIT=" + str(log_rc))
    if log_rc == 0:
        selected = [x for x in runtime_logs.splitlines() if re.search(r"RTL88WiFi|RTW88WCL|io\.github\.x1ren41l\.rtl88wifi", x, re.I)]
        block("NATIVE_TARGETED_UNIFIED_LOG", "\n".join(selected), 90, 560)
        explicit_reject = any(re.search(r"bad code signature|not validly signed|signature.*(invalid|reject)|reject.*signature|authenticat.*fail", x, re.I) for x in selected)
        emit("NATIVE_SPECIFIC_SIGNATURE_REJECTION_LOG=" + str(explicit_reject))
        emit("NATIVE_TARGETED_LOG_LINE_COUNT=" + str(len(selected)))
    else:
        selected = []
        explicit_reject = False
        block("NATIVE_TARGETED_UNIFIED_LOG_ERROR", runtime_logs, 12, 400)
        emit("NATIVE_SPECIFIC_SIGNATURE_REJECTION_LOG=UNKNOWN")

    oc_log_dir = (cfg_root / "Logs") if cfg_root else None
    oc_paths = []
    oc_hits = []
    if oc_log_dir and oc_log_dir.is_dir():
        try:
            oc_paths = sorted([p for p in oc_log_dir.iterdir() if p.is_file() and p.suffix.lower() in (".txt", ".log")],
                              key=lambda p: p.stat().st_mtime, reverse=True)[:5]
            for path in oc_paths:
                try:
                    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
                    hits = [x for x in content if re.search(r"RTL88WiFi|RTW88|AMFIPass|Lilu|kext|kernelcache|signature|inject|load(ed|ing)?|reject|fail|error", x, re.I)]
                    oc_hits.extend(hits)
                    emit("OPENCORE_LOG_FILE=" + str(path))
                    block("OPENCORE_LOG_RELEVANT_" + path.name, "\n".join(hits[-30:]), 30, 500)
                except OSError as exc:
                    emit("OPENCORE_LOG_READ_ERROR=" + repr(exc))
        except OSError as exc:
            emit("OPENCORE_LOG_ENUMERATION_ERROR=" + repr(exc))
    emit("OPENCORE_DEBUG_LOG_FILES_FOUND=" + str(len(oc_paths)))
    emit("OPENCORE_RELEVANT_LOG_LINE_COUNT=" + str(len(oc_hits)))

    enabled_count = sum(1 for row in native_rows if row["enabled"])
    hash_match = bool(native_rows) and all(row["sha256"] == EXPECTED_NATIVE_SHA for row in native_rows)
    diagnosis = "INCONCLUSIVE_READ_ONLY_EVIDENCE"
    if config_state != "PARSED":
        diagnosis = "OPENCORE_CONFIG_UNAVAILABLE_OR_INVALID"
    elif len(native_rows) != 1 or enabled_count != 1:
        diagnosis = "NATIVE_OPENCORE_KERNEL_ADD_ENTRY_MISSING_DISABLED_OR_DUPLICATED"
    elif not hash_match:
        diagnosis = "EFI_NATIVE_EXECUTABLE_DIFFERS_FROM_STAGE113_VALIDATED_BINARY"
    elif native_loaded:
        diagnosis = "NATIVE_BUNDLE_PRESENT_IN_KMUTIL_SHOWLOADED_CHECK_IOREGISTRY_FOR_ATTACH"
    elif signature_state == "SIGNED_VERIFY_FAILED" and explicit_reject:
        diagnosis = "SIGNED_BUNDLE_VERIFY_FAILURE_WITH_NATIVE_SPECIFIC_REJECTION_LOG"
    elif signature_state == "UNSIGNED" and explicit_reject:
        diagnosis = "UNSIGNED_BUNDLE_AND_NATIVE_SPECIFIC_REJECTION_LOG_PRESENT_CAUSAL_SCOPE_REQUIRES_REVIEW"
    elif signature_state == "UNSIGNED":
        diagnosis = "NATIVE_BUNDLE_IS_UNSIGNED_BUT_RUNTIME_REJECTION_NOT_PROVEN"
    elif signature_state == "VERIFY_PASS":
        diagnosis = "SIGNATURE_VERIFIES_BUT_NATIVE_BUNDLE_NOT_LOADED_INJECTION_OR_MATCHING_UNRESOLVED"
    elif signature_state == "SIGNED_VERIFY_FAILED":
        diagnosis = "SIGNED_BUNDLE_VERIFY_FAILED_BUT_NATIVE_SPECIFIC_RUNTIME_REJECTION_NOT_PROVEN"
    else:
        diagnosis = "SIGNATURE_STATE_INDETERMINATE_NATIVE_LOAD_CAUSE_UNPROVEN"
    emit("STAGE115_PRIMARY_DIAGNOSIS=" + diagnosis)
    emit("STAGE115_SIGNATURE_CLASSIFICATION=" + signature_state)
    emit("STAGE115_NATIVE_SPECIFIC_REJECTION_LOG=" + str(explicit_reject))
    emit("STAGE115_PCI_DEVICE_PRESENT=" + str(pci_present))
    emit("STAGE115_NATIVE_CONTROLLER_IOREGISTRY=" + ioreg_states.get("RTW88WCLController", "UNKNOWN"))
    emit("STAGE115_NATIVE_INTERFACE_IOREGISTRY=" + ioreg_states.get("RTW88WCLInfraInterface", "UNKNOWN"))
    emit("STAGE115_OPENCORE_LOG_FILES=" + str(len(oc_paths)))
    emit("STAGE115_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW")
    emit("STAGE115_ACTIVATION=BLOCKED")
    emit("SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE HARDWARE_TEST=NOT_RUN")
    emit("PR4_MERGE=BLOCKED")

    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE115 BOOT-INJECTION / NATIVE-KEXT EVIDENCE ==========\n")
        stream.write("STAGE115_RESULT=EVIDENCE_CAPTURED_REQUIRES_REVIEW\n")
        stream.write("STAGE115_PRIMARY_DIAGNOSIS=" + diagnosis + "\n")
        stream.write("STAGE115_SIGNATURE_CLASSIFICATION=" + signature_state + "\n")
        stream.write("STAGE115_NATIVE_SPECIFIC_REJECTION_LOG=" + str(explicit_reject) + "\n")
        stream.write("STAGE115_PCI_DEVICE_PRESENT=" + str(pci_present) + "\n")
        stream.write("STAGE115_NATIVE_CONTROLLER_IOREGISTRY=" + ioreg_states.get("RTW88WCLController", "UNKNOWN") + "\n")
        stream.write("STAGE115_NATIVE_INTERFACE_IOREGISTRY=" + ioreg_states.get("RTW88WCLInfraInterface", "UNKNOWN") + "\n")
        stream.write("STAGE115_DETAIL_LOG=" + str(log_path) + "\n")
        stream.write("STAGE115_ACTIVATION=BLOCKED PR4_MERGE=BLOCKED\n")
    emit("STAGE115_DETAIL_LOG=" + str(log_path))
    emit("STAGE115_CANONICAL_LOG=" + str(OUTPUT_LOG))

if __name__ == "__main__":
    main()
