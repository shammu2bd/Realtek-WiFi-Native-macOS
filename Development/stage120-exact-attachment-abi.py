#!/usr/bin/env python3
"""Stage120: exact 24H32 IO80211 attachment and primary-interface ABI extraction.

READ ONLY: parses the installed BootKernelExtensions collection and current
source references. No source/build/sign/install/load/reboot/EFI/OC/SIP/NVRAM work.
"""
import hashlib, os, pathlib, re, shutil, subprocess, sys
from datetime import datetime, timezone

BRANCH = "work/stage120-exact-attachment-abi"
BASE = "c1832cab24534c7ddb23e8bcbfdfe2379c257714"
BOOTKC = pathlib.Path("/System/Library/KernelCollections/BootKernelExtensions.kc")
UPSTREAM = "https://raw.githubusercontent.com/watchthelight-labs/WTLKcAbi/cea28a5297633118177cee6a75e86d8bc57f1960"
EXPECTED = {
    "kcfile.py": "5d31e8a73e5cb175851e7407529456f223683589",
    "disasm.py": "d7777456f4700bc9815e765aed2313093ac133e9",
}
CLASSES = {
    "IO80211Controller": r"(attachInterface|detachInterface|getPrimarySkywalkInterface|dataLinkLayerAttachComplete)",
    "IO80211SkywalkInterface": r"(initEP9IOServiceP10ether_addr|startEP9IOService|stopEP9IOService)",
    "IO80211InfraInterface": r"(startEP9IOService|registerInfraEthernetInterface|stopEP9IOService)",
    "AppleBCMWLANSkywalkInterface": r"(initWithProviderAndParameters|startEP16AppleBCMWLANCore|startEP9IOService)",
    "AppleBCMWLANCore": r"(skywalkInfraInit|createSkywalkInterface|destroySkywalkInterface)",
}
VTABLE_CLASSES = tuple(CLASSES.keys())
VTABLE_PATTERN = re.compile(
    r"attachInterface|detachInterface|getPrimarySkywalkInterface|"
    r"dataLinkLayerAttachComplete|registerInfraEthernetInterface|"
    r"startEP9IOService|startEP16AppleBCMWLANCore|skywalkInfraInit|createSkywalkInterface",
    re.I,
)
DETAIL_LIMIT = 520

def git_blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

def run(args, timeout=90):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, timeout=timeout)
    return p.returncode, p.stdout or ""

def main():
    root = pathlib.Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], universal_newlines=True).strip()).resolve()
    os.chdir(str(root))
    branch = subprocess.check_output(
        ["git", "branch", "--show-current"], universal_newlines=True).strip()
    if branch != BRANCH:
        raise RuntimeError("wrong branch: " + branch)
    if subprocess.check_output(["git", "status", "--porcelain"],
                               universal_newlines=True).strip():
        raise RuntimeError("worktree must be clean before Stage120")
    subprocess.check_call(["git", "cat-file", "-e", BASE + "^{commit}"])
    subprocess.check_call(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
    if not BOOTKC.is_file():
        raise RuntimeError("BootKernelExtensions.kc not found: " + str(BOOTKC))
    version = subprocess.check_output(["sw_vers", "-productVersion"], universal_newlines=True).strip()
    build = subprocess.check_output(["sw_vers", "-buildVersion"], universal_newlines=True).strip()
    arch = subprocess.check_output(["uname", "-m"], universal_newlines=True).strip()
    if (version, build, arch) != ("15.8.1", "24H32", "x86_64"):
        raise RuntimeError("wrong target: %s/%s/%s" % (version, build, arch))
    objdump = subprocess.check_output(["xcrun", "--find", "llvm-objdump"],
                                      universal_newlines=True).strip()
    if not objdump or not pathlib.Path(objdump).is_file():
        raise RuntimeError("Xcode llvm-objdump unavailable")
    os.environ["LLVM_OBJDUMP"] = objdump

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = root / "Development" / "Logs" / ("stage120-" + stamp)
    tools = out / "tools"
    cache = out / "kc-cache"
    out.mkdir(parents=True, exist_ok=False)
    tools.mkdir()
    cache.mkdir()
    detail_path = out / "controller-attachment-abi.txt"
    discovery_path = out / "class-and-vtable-index.txt"
    status_path = out / "method-status.txt"
    lines = []
    def emit(s=""):
        lines.append(str(s))
    emit("========== STAGE120 EXACT CONTROLLER ATTACHMENT ABI ==========")
    emit("UTC_STAMP=" + stamp)
    emit("BRANCH=" + BRANCH)
    emit("HEAD=" + subprocess.check_output(["git","rev-parse","HEAD"], universal_newlines=True).strip())
    emit("BASE=" + BASE)
    emit("TARGET=" + version + "/" + build + "/" + arch)
    emit("BOOTKC=" + str(BOOTKC))
    emit("BOOTKC_SHA256=" + hashlib.sha256(BOOTKC.read_bytes()).hexdigest())
    emit("LLVM_OBJDUMP=" + objdump)
    emit("SCOPE=EXACT_METHOD_SYMBOLS_VTABLE_SLOTS_AND_DISASSEMBLY")
    emit("SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN")
    emit("OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN HARDWARE_TEST=NOT_RUN")

    for name, want in EXPECTED.items():
        dest = tools / name
        rc, output = run(["curl", "-fsSLo", str(dest), UPSTREAM + "/" + name], 90)
        if rc != 0 or not dest.is_file():
            raise RuntimeError("could not retrieve pinned parser " + name + ": " + output[-1000:])
        got = git_blob_sha(dest.read_bytes())
        emit("PARSER_" + name + "_GIT_BLOB=" + got)
        emit("PARSER_" + name + "_PIN=" + want)
        if got != want:
            raise RuntimeError("pinned parser hash mismatch: " + name)

    sys.path.insert(0, str(tools))
    from kcfile import KC
    import disasm
    kc = KC(str(BOOTKC))
    parser = disasm.Disassembler(kc, str(cache))

    found = {}
    discovery = [
        "STAGE120_EXACT_24H32_METHOD_AND_VTABLE_INDEX",
        "BOOTKC_SHA256=" + kc.sha256(),
        "FILESET_ENTRY_COUNT=" + str(len(kc.entries)),
        "OBJDUMP=" + objdump,
    ]
    for cls, pattern in CLASSES.items():
        methods = kc.methods(cls)
        hits = [(va, name) for va, name in methods if re.search(pattern, name, re.I)]
        found[cls] = hits
        discovery.append("\nCLASS=" + cls + " METHOD_COUNT=" + str(len(methods)) +
                         " TARGET_MATCHES=" + str(len(hits)))
        for va, name in hits[:180]:
            owner = kc.owner(va) or kc.sym_owner.get(va) or "UNKNOWN"
            sym_owner = kc.sym_owner.get(va) or "UNKNOWN"
            discovery.append("METHOD class=%s address=0x%x owner=%s sym_owner=%s symbol=%s" %
                             (cls, va, owner, sym_owner, name))

    vtable_lines = ["STAGE120_EXACT_VTABLE_SLOTS"]
    for cls in VTABLE_CLASSES:
        try:
            vtable = kc.vtable(cls)
        except Exception as exc:
            vtable_lines.append("VTABLE_CLASS=%s ERROR=%s" % (cls, repr(exc)))
            continue
        if vtable is None:
            vtable_lines.append("VTABLE_CLASS=%s NOT_FOUND" % cls)
            continue
        vtable_lines.append("\nVTABLE_CLASS=%s ENTRIES=%d" % (cls, len(vtable)))
        count = 0
        for index, entry in enumerate(vtable):
            if len(entry) < 4:
                continue
            target = entry[2]
            name = entry[3] or ""
            if VTABLE_PATTERN.search(name):
                owner = kc.owner(target) or kc.sym_owner.get(target) or "UNKNOWN"
                vtable_lines.append(
                    "VTABLE_SLOT class=%s offset=0x%x index=%d target=0x%x owner=%s symbol=%s" %
                    (cls, index * 8, index, target, owner, name))
                count += 1
        vtable_lines.append("VTABLE_TARGET_MATCH_COUNT=%d" % count)

    wanted = []
    for cls, hits in found.items():
        for va, name in hits:
            if any(k in name for k in (
                "attachInterface", "detachInterface", "getPrimarySkywalkInterface",
                "dataLinkLayerAttachComplete", "registerInfraEthernetInterface",
                "skywalkInfraInit", "createSkywalkInterface", "startEP16AppleBCMWLANCore"
            )):
                wanted.append((cls, name, va))
    # Deduplicate addresses while preserving the class and first discovered symbol.
    unique = {}
    for item in wanted:
        unique[item[2]] = item
    wanted = list(unique.values())
    disassembly = []
    statuses = []
    missing = []
    carved = {}
    for cls, name, va in wanted:
        owner = kc.owner(va) or kc.sym_owner.get(va)
        sym_owner = kc.sym_owner.get(va)
        if not owner or owner != sym_owner:
            statuses.append("METHOD_STATUS class=%s symbol=%s result=OWNER_MISMATCH owner=%s sym_owner=%s" %
                            (cls, name, owner, sym_owner))
            continue
        segments = [x for x in kc.entry_segs.get(owner, [])
                    if x[1] <= va < x[1] + x[2] and (x[5] & 4)]
        if not segments:
            statuses.append("METHOD_STATUS class=%s symbol=%s result=NO_EXECUTABLE_SEGMENT" % (cls, name))
            continue
        end = kc.next_sym(va) or (va + 0x1000)
        if end <= va or end > va + 0x20000:
            end = va + 0x1000
        if owner not in carved:
            safe = re.sub(r"[^A-Za-z0-9_.-]", "_", owner)
            path = cache / (safe + ".macho")
            kc.carve(owner, str(path))
            carved[owner] = path
        path = carved[owner]
        disassembly.append("\n===== METHOD class=%s symbol=%s address=0x%x owner=%s range=0x%x..0x%x =====" %
                           (cls, name, va, owner, va, end))
        attempts = [
            ["-d","-M","intel","--no-show-raw-insn","--start-address=0x%x" % va,
             "--stop-address=0x%x" % end, str(path)],
            ["-d","--no-show-raw-insn","--start-address=0x%x" % va,
             "--stop-address=0x%x" % end, str(path)],
            ["-d","--start-address=0x%x" % va,"--stop-address=0x%x" % end,str(path)],
        ]
        success = False
        count = 0
        for attempt, args in enumerate(attempts, 1):
            rc, stdout = run([objdump] + args, 90)
            parsed_addresses, parsed_instructions = parser._parse(stdout)
            count = len(parsed_addresses)
            disassembly.append("OBJDUMP_ATTEMPT=%d EXIT=%d INSTRUCTIONS=%d" %
                               (attempt, rc, count))
            if stdout.strip():
                out_lines = stdout.splitlines()
                disassembly.append("DISASSEMBLY_BEGIN")
                disassembly.extend(out_lines[:DETAIL_LIMIT])
                if len(out_lines) > DETAIL_LIMIT:
                    disassembly.append("...DISASSEMBLY_TRUNCATED...")
                disassembly.append("DISASSEMBLY_END")
            if rc == 0 and count:
                success = True
                break
        status = "PASS" if success else "REVIEW_REQUIRED"
        statuses.append("METHOD_STATUS class=%s address=0x%x instructions=%d result=%s symbol=%s" %
                        (cls, va, count, status, name))
        # The disassembly itself is retained for call-edge inspection.
    for cls in ("IO80211Controller", "IO80211SkywalkInterface",
                "IO80211InfraInterface", "AppleBCMWLANSkywalkInterface",
                "AppleBCMWLANCore"):
        if not found.get(cls):
            missing.append("NO_TARGET_METHODS_FOUND class=" + cls)

    for line in statuses:
        emit(line)
    attach_found = any("attachInterface" in x[1] for x in wanted)
    detach_found = any("detachInterface" in x[1] for x in wanted)
    primary_found = any("getPrimarySkywalkInterface" in x[1] for x in wanted)
    infra_register_found = any("registerInfraEthernetInterface" in x[1] for x in wanted)
    emit("ATTACH_INTERFACE_METHOD_FOUND=" + str(attach_found))
    emit("DETACH_INTERFACE_METHOD_FOUND=" + str(detach_found))
    emit("PRIMARY_INTERFACE_GETTER_FOUND=" + str(primary_found))
    emit("APPLE_INFRA_REGISTRATION_METHOD_FOUND=" + str(infra_register_found))
    emit("METHODS_DISASSEMBLED=" + str(len(statuses)))
    emit("METHODS_REVIEW_REQUIRED=" + str(sum("REVIEW_REQUIRED" in x for x in statuses)))

    discovery_path.write_text("\n".join(discovery) + "\n", encoding="utf-8")
    vtable_path = out / "vtable-index.txt"
    vtable_path.write_text("\n".join(vtable_lines) + "\n", encoding="utf-8")
    status_path.write_text("\n".join(statuses + missing) + "\n", encoding="utf-8")
    detail_path.write_text("\n".join(emit_lines := lines) + "\n", encoding="utf-8")
    disasm_path = out / "selected-method-disassembly.txt"
    disasm_path.write_text("\n".join(disassembly) + "\n", encoding="utf-8")
    # Remove carved executable slices after preserving the text evidence.
    shutil.rmtree(cache, ignore_errors=True)
    summary = out / "summary.txt"
    summary_lines = [
        "STAGE120_EXACT_CONTROLLER_ATTACHMENT_ABI",
        "RESULT=ABI_INDEX_AND_DISASSEMBLY_CAPTURED",
        "ATTACH_INTERFACE_METHOD_FOUND=" + str(attach_found),
        "DETACH_INTERFACE_METHOD_FOUND=" + str(detach_found),
        "PRIMARY_INTERFACE_GETTER_FOUND=" + str(primary_found),
        "APPLE_INFRA_REGISTRATION_METHOD_FOUND=" + str(infra_register_found),
        "METHODS_DISASSEMBLED=" + str(len(statuses)),
        "METHODS_REVIEW_REQUIRED=" + str(sum("REVIEW_REQUIRED" in x for x in statuses)),
        "SOURCE_MODIFIED=NO BUILD=NOT_RUN SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN",
        "OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE",
        "DETAIL_LOG=" + str(detail_path),
        "METHOD_DISASSEMBLY=" + str(disasm_path),
        "VTABLE_INDEX=" + str(vtable_path),
        "CLASS_DISCOVERY=" + str(discovery_path),
        "METHOD_STATUS=" + str(status_path),
    ]
    summary.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    with (root / "Development" / "output.log").open("a", encoding="utf-8") as stream:
        stream.write("\n========== STAGE120 EXACT CONTROLLER ATTACHMENT ABI ==========\n")
        stream.write("\n".join(summary_lines) + "\n")
    print("\n".join(summary_lines))
    print("STAGE120_LOG_DIR=" + str(out))
    print("STAGE120_CANONICAL_LOG=Development/output.log")

if __name__ == "__main__":
    main()
