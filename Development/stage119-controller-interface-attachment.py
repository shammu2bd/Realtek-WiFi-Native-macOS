#!/usr/bin/env python3
"""Stage119: exact 24H32 controller/interface attachment ABI evidence.

Read-only. It inspects the previously extracted 24H32 kernel Mach-O files and
current native source. It never edits source, OpenCore, EFI, SIP, or NVRAM.
It does not build, sign, install, load/unload, reboot, or run hardware tests.
"""
from __future__ import print_function
import os, plistlib, re, subprocess
from datetime import datetime, timezone
from pathlib import Path

BRANCH = "work/stage119-controller-interface-attachment"
BASE = "29ceb4febe5821e3fb280804b0b7a4f958b9f4d2"
LOG_DIR = Path("Development/Logs")
OUTPUT_LOG = Path("Development/output.log")
SCRIPT = Path("Development/stage119-controller-interface-attachment.py")
ALLOWLIST = Path("Development/Allowlist/stage119-controller-interface-attachment.gitblob")
SOURCE = Path("driver/RTL88WiFi/src/kext/wcl24h32")
INFO = Path("driver/RTL88WiFi/RTL88WiFiNative.kext/Contents/Info.plist")
CACHE_CANDIDATES = [
    Path.home() / "Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source/run log/stage54/run-20261102-132405-fb0df18fd221/kc-cache",
    Path.home() / "Developer/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source/run log/stage54/run-20261102-132405-fb0df18fd221/kc-cache",
]
SYMBOLS = {
    "IO80211Controller_attachInterface": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN17IO80211Controller15attachInterfaceEP8OSObjectP9IOService"),
    "IO80211Controller_detachInterface": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN17IO80211Controller15detachInterfaceEP8OSObjectb"),
    "IO80211Controller_getPrimarySkywalkInterface": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN17IO80211Controller26getPrimarySkywalkInterfaceEv"),
    "IO80211SkywalkInterface_start": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN23IO80211SkywalkInterface5startEP9IOService"),
    "IO80211InfraInterface_start": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN21IO80211InfraInterface5startEP9IOService"),
    "IO80211InfraInterface_registerInfraEthernetInterface": (
        "com.apple.iokit.IO80211Family.macho",
        "__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_"),
    "AppleBCMWLANCore_createSkywalkInterface": (
        "com.apple.driver.AppleBCMWLANCoreMac.macho",
        "__ZN16AppleBCMWLANCore22createSkywalkInterfaceEPP28AppleBCMWLANSkywalkInterfaceP33apple80211SkywalkIfCreateParams_tP23IO80211VirtualInterface"),
    "AppleBCMWLANCore_skywalkInfraInit": (
        "com.apple.driver.AppleBCMWLANCoreMac.macho",
        "__ZN16AppleBCMWLANCore16skywalkInfraInitEv"),
}

lines = []
def emit(s=""):
    line = str(s).rstrip()
    print(line, flush=True)
    lines.append(line)
def block(name, value, max_lines=420, max_chars=520):
    emit("----- " + name + " -----")
    selected = (value or "").splitlines()
    if not selected:
        emit("(no output)")
    for line in selected[:max_lines]:
        emit(line[:max_chars] + (" ...[truncated]" if len(line) > max_chars else ""))
    if len(selected) > max_lines:
        emit("... " + str(len(selected) - max_lines) + " additional lines omitted")
    emit("----- END " + name + " -----")
def run(args, timeout=60):
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
def read_source(path):
    try: return path.read_text(encoding="utf-8", errors="replace")
    except Exception: return ""
def main():
    root = Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip()).resolve()
    os.chdir(str(root))
    branch = subprocess.check_output(
        ["git", "branch", "--show-current"], universal_newlines=True).strip()
    if branch != BRANCH: raise RuntimeError("wrong branch: " + branch)
    dirty = subprocess.check_output(
        ["git", "status", "--porcelain"], universal_newlines=True)
    if dirty.strip(): raise RuntimeError("worktree must be clean before run:\n" + dirty)
    subprocess.check_call(["git", "cat-file", "-e", BASE + "^{commit}"])
    subprocess.check_call(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
    pin_lines = ALLOWLIST.read_text(encoding="utf-8").splitlines()
    pin = pin_lines[0].split()[0] if pin_lines and pin_lines[0].split() else ""
    actual_blob = subprocess.check_output(
        ["git", "hash-object", str(SCRIPT)], universal_newlines=True).strip()
    if not pin or pin != actual_blob: raise RuntimeError("runner blob does not match allowlist")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_path = LOG_DIR / ("stage119-controller-interface-attachment-" + stamp + ".log")
    emit("========== STAGE119 CONTROLLER / INTERFACE ATTACHMENT ABI ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git","rev-parse","HEAD"], universal_newlines=True).strip())
    emit("BASE_COMMIT=" + BASE)
    emit("RUNNER_GIT_BLOB_SHA=" + actual_blob)
    emit("SCOPE=READ_ONLY_24H32_KERNEL_ABI_AND_NATIVE_SOURCE_ATTACHMENT_REACHABILITY")
    emit("SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD_UNLOAD=NOT_RUN")
    emit("OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN HARDWARE_TEST=NOT_RUN")

    cache_env = os.environ.get("ABI_CACHE_ROOT", "").strip()
    cache = Path(cache_env).expanduser() if cache_env else next(
        (p for p in CACHE_CANDIDATES if p.is_dir()), CACHE_CANDIDATES[0])
    emit("ABI_CACHE_ROOT=" + str(cache))
    emit("ABI_CACHE_EXISTS=" + str(cache.is_dir()))
    xcrun_rc, objdump_path = run(["xcrun", "--find", "llvm-objdump"], 20)
    objdump = objdump_path.strip().splitlines()[-1] if xcrun_rc == 0 and objdump_path.strip() else ""
    emit("LLVM_OBJDUMP_LOOKUP_EXIT=" + str(xcrun_rc))
    emit("LLVM_OBJDUMP_PATH=" + (objdump or "NOT_FOUND"))
    if not objdump or not Path(objdump).is_file():
        emit("ABI_DISASSEMBLY_STATUS=BLOCKED_LLVM_OBJDUMP_UNAVAILABLE")
    elif not cache.is_dir():
        emit("ABI_DISASSEMBLY_STATUS=BLOCKED_STAGE54_KERNEL_MACHO_CACHE_MISSING")
    else:
        for label, (filename, symbol) in SYMBOLS.items():
            macho = cache / filename
            emit("\n===== ABI_SYMBOL=" + label + " =====")
            emit("MACHO=" + str(macho))
            emit("SYMBOL=" + symbol)
            if not macho.is_file():
                emit("MACHO_STATE=MISSING")
                continue
            rc, output = run([objdump, "--disassemble-symbols=" + symbol, str(macho)], 60)
            emit("OBJDUMP_EXIT=" + str(rc))
            emit("SYMBOL_DISASSEMBLY_FOUND=" + str(("Disassembly of section" in output) and (symbol in output)))
            block("DISASSEMBLY_" + label, output, 430, 520)

    controller_cpp = read_source(SOURCE / "RTW88WCLController.cpp")
    controller_hpp = read_source(SOURCE / "RTW88WCLController.hpp")
    interface_cpp = read_source(SOURCE / "RTW88WCLInfraInterface.cpp")
    interface_hpp = read_source(SOURCE / "RTW88WCLInfraInterface.hpp")
    abi_hpp = read_source(SOURCE / "RTW88WCL24H32ABI.hpp")
    match = {}
    match["CONTROLLER_USES_IO_SERVICE_CHILD_ATTACH"] = bool(re.search(r"_infraInterface->attach\s*\(\s*this\s*\)", controller_cpp))
    match["CONTROLLER_CALLS_IO80211_ATTACH_INTERFACE"] = bool(re.search(r"\battachInterface\s*\(", controller_cpp))
    match["CONTROLLER_CALLS_IO80211_DETACH_INTERFACE"] = bool(re.search(r"\bdetachInterface\s*\(", controller_cpp))
    match["CONTROLLER_OVERRIDES_PRIMARY_INTERFACE_GETTER"] = bool(re.search(r"getPrimarySkywalkInterface\s*\(", controller_hpp + controller_cpp))
    match["CONTROLLER_START_CREATES_AND_STARTS_INFRA"] = all(
        x in controller_cpp for x in ("new RTW88WCLInfraInterface", "_infraInterface->init(this, &address)",
                                      "_infraInterface->attach(this)", "_infraInterface->start(this)"))
    match["CONTROLLER_START_REGISTER_SERVICE"] = "_infraInterface->registerService()" in controller_cpp
    match["INTERFACE_START_CALLS_APPLE_INFRA_BASE_START"] = bool(re.search(r"super::start\s*\(\s*provider\s*\)", interface_cpp))
    match["INTERFACE_START_CALLS_REGISTRATION_HELPER"] = "registerInfraEthernetInterface(" in interface_cpp
    match["INTERFACE_START_COMMITS_REGISTRATION"] = "commitRegistrationTransaction()" in interface_cpp
    match["ABI_DECLARES_ATTACH_INTERFACE"] = "attachInterface(OSObject *, IOService *)" in abi_hpp
    match["ABI_DECLARES_DETACH_INTERFACE"] = "detachInterface(OSObject *, bool)" in abi_hpp
    for name, value in match.items(): emit(name + "=" + str(value))
    emit("SOURCE_RESULT=" + ("CONTROLLER_GENERIC_ATTACH_PRESENT_PRIVATE_ATTACH_CALL_ABSENT" if
        match["CONTROLLER_USES_IO_SERVICE_CHILD_ATTACH"] and not match["CONTROLLER_CALLS_IO80211_ATTACH_INTERFACE"]
        else "REVIEW_SOURCE_ATTACHMENT_PATTERN"))
    if INFO.is_file():
        try:
            with INFO.open("rb") as stream: plist = plistlib.load(stream)
            personalities = plist.get("IOKitPersonalities", {}) or {}
            person = next((v for v in personalities.values()
                           if isinstance(v, dict) and v.get("IOClass") == "RTW88WCLController"), {})
            emit("PERSONALITY_IOCLASS=" + str(person.get("IOClass", "MISSING")))
            emit("PERSONALITY_PROVIDER=" + str(person.get("IOProviderClass", "MISSING")))
            emit("PERSONALITY_PCI_MATCH=" + str(person.get("IOPCIMatch", "MISSING")))
            emit("PERSONALITY_INFO_PLIST_PARSE=PASS")
        except Exception as exc: emit("PERSONALITY_INFO_PLIST_PARSE=FAIL " + repr(exc))
    else: emit("PERSONALITY_INFO_PLIST=MISSING")

    emit("STAGE119_RESULT=ABI_EVIDENCE_CAPTURED_SOURCE_UNCHANGED")
    emit("STAGE119_ATTACHMENT_IMPLEMENTATION=WAITING_FOR_EXACT_APPLE_ATTACH_METHOD_SEMANTICS")
    emit("STAGE119_OC_EFI_SIP_NVRAM=UNCHANGED")
    log_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    with OUTPUT_LOG.open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE119 CONTROLLER / INTERFACE ATTACHMENT ABI ==========\n")
        stream.write("STAGE119_RESULT=ABI_EVIDENCE_CAPTURED_SOURCE_UNCHANGED\n")
        stream.write("STAGE119_ATTACHMENT_IMPLEMENTATION=WAITING_FOR_EXACT_APPLE_ATTACH_METHOD_SEMANTICS\n")
        stream.write("STAGE119_ABI_CACHE=" + str(cache) + "\n")
        stream.write("STAGE119_DETAIL_LOG=" + str(log_path) + "\n")
        stream.write("STAGE119_SOURCE_MODIFIED=NO OPENCORE_CHANGE=NONE\n")
    emit("STAGE119_DETAIL_LOG=" + str(log_path))
    emit("STAGE119_CANONICAL_LOG=" + str(OUTPUT_LOG))

if __name__ == "__main__":
    main()
