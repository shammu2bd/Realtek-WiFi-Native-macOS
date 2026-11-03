#!/usr/bin/env python3
"""Stage 16: read-only packet-buffer layout and RX ownership audit.

Inputs are the exact Stage 14 kcabi archive and the Stage 15 accessor audit
archive. This stage correlates Stage 15's disassembly evidence with documented
x86_64 object offsets, validates the Stage 14 instance sizes, and statically
checks the staged RX conversion/ownership fences in the current source tree.

A positive result is evidence of field-layout consistency and source-level
ordering only. It is not proof of undocumented Apple API contracts and does
not enable, register, submit, or publish any Skywalk TX/RX datapath.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

# Exact 24H32 IOSkywalkFamily MetaClass instance sizes extracted from
# BootKernelExtensions.kc. IOSkywalkPacket is 0x70 in this build; the
# vendored older header incorrectly extended it with a slot-reference field.
TARGET_CLASS_SIZES = {
    "IOSkywalkPacket": 0x70,
    "IOSkywalkPacketBuffer": 0x90,
    "IOSkywalkMemorySegment": 0x78,
}

# Getter -> field offset, grounded in Stage 15's exact 24H32 method bodies.
# The vendored legacy SDK header incorrectly placed mActualNumBuffers at 0x60.
# 24H32 getPacketBufferCount AND getPacketBuffers both read the 32-bit count
# at this+0x64, so require both methods to agree before accepting the layout.
FIELD_GETTERS = {
    ("IOSkywalkPacket", "getPacketBufferPool"): 0x40,
    ("IOSkywalkPacket", "getPacketBufferCount"): 0x64,
    ("IOSkywalkPacket", "getPacketBuffers"): 0x64,
    ("IOSkywalkPacketBuffer", "getMemorySegment"): 0x58,
    ("IOSkywalkPacketBuffer", "getMemorySegmentOffset"): 0x70,
    ("IOSkywalkPacketBuffer", "getDataLength"): 0x7C,
    ("IOSkywalkPacketBuffer", "getDataOffset"): 0x80,
    ("IOSkywalkMemorySegment", "getMemoryDescriptor"): 0x20,
    ("IOSkywalkMemorySegment", "getVirtualAddress"): 0x30,
}

EXPECTED_STAGE15_METHODS = 18
SIZE_ROW = re.compile(r"^(IOSkywalk\w+)\s+(0x[0-9a-fA-F]+|\?)\s+", re.M)
INSN_ROW = re.compile(r"^\s*[0-9a-fA-F]+:\s+([A-Za-z][A-Za-z0-9.]*)\s*(.*?)\s*$")
# x86_64 SysV passes `this` in RDI. Optimized methods can preserve it in a
# callee-saved register or spill/reload it through a stack slot before reading
# a member. Track only unadjusted aliases of `this`; do not guess through
# arithmetic, pointer chasing, or non-zero LEA adjustments.
REG_ALIASES = {
    "rax": "rax", "eax": "rax", "ax": "rax", "al": "rax", "ah": "rax",
    "rbx": "rbx", "ebx": "rbx", "bx": "rbx", "bl": "rbx", "bh": "rbx",
    "rcx": "rcx", "ecx": "rcx", "cx": "rcx", "cl": "rcx", "ch": "rcx",
    "rdx": "rdx", "edx": "rdx", "dx": "rdx", "dl": "rdx", "dh": "rdx",
    "rsi": "rsi", "esi": "rsi", "si": "rsi", "sil": "rsi",
    "rdi": "rdi", "edi": "rdi", "di": "rdi", "dil": "rdi",
    "rbp": "rbp", "ebp": "rbp", "bp": "rbp", "bpl": "rbp",
    "rsp": "rsp", "esp": "rsp", "sp": "rsp", "spl": "rsp",
    **{f"r{i}{suffix}": f"r{i}" for i in range(8, 16)
       for suffix in ("", "d", "w", "b")},
}
MEM_OPERAND = re.compile(
    r"\[\s*(?P<base>[a-z0-9]+)\s*"
    r"(?:(?P<sign>[+-])\s*(?P<disp>0x[0-9a-fA-F]+|[0-9]+)\s*)?\]", re.I)
LOAD_MNEMONICS = {"mov", "movzx", "movsx", "movsxd", "movabs", "movq", "movl", "movw", "movb"}
CALLER_SAVED = {"rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if not members:
            raise RuntimeError(f"Archive is empty: {archive}")
        for m in members:
            p = Path(m.name)
            if p.is_absolute() or ".." in p.parts or not (m.isfile() or m.isdir()):
                raise RuntimeError(f"Unsafe archive member: {m.name}")
            out = (root / p).resolve()
            if out != root and root not in out.parents:
                raise RuntimeError(f"Archive path escapes destination: {m.name}")
        tf.extractall(destination, members=members)


def one_file(root: Path, name: str) -> Path:
    found = [p for p in root.rglob(name) if p.is_file()]
    if len(found) != 1:
        raise RuntimeError(f"Expected exactly one {name}; found {len(found)}")
    return found[0]


def parse_sizes(stage14_root: Path) -> dict[str, int]:
    path = one_file(stage14_root, "sizes.txt")
    sizes = {}
    for name, raw in SIZE_ROW.findall(path.read_text(encoding="utf-8", errors="replace")):
        if raw != "?":
            sizes[name] = int(raw, 16)
    return sizes


def parse_method_audit(stage15_root: Path) -> dict:
    path = one_file(stage15_root, "STAGE15-ABI-ACCESSOR-AUDIT.json")
    result = json.loads(path.read_text(encoding="utf-8"))
    if result.get("stage") != 15 or result.get("status") != "PASS":
        raise RuntimeError("Stage 15 archive is not marked PASS")
    if result.get("required_method_count") != EXPECTED_STAGE15_METHODS:
        raise RuntimeError("Stage 15 report does not contain the expected 18 methods")
    if result.get("methods_with_disassembly") != EXPECTED_STAGE15_METHODS:
        raise RuntimeError("Stage 15 report does not contain disassembly for all 18 methods")
    return result


def find_method_row(stage15: dict, owner: str, method: str) -> dict:
    rows = [r for r in stage15.get("method_audit", [])
            if r.get("class") == owner and r.get("method") == method]
    if len(rows) != 1 or rows[0].get("status") != "PASS":
        raise RuntimeError(f"Stage 15 has no unique PASS row for {owner}::{method}")
    return rows[0]


def _split_operands(operands: str) -> list[str]:
    """Split Intel operands on commas outside square brackets."""
    parts, start, depth = [], 0, 0
    for index, char in enumerate(operands):
        if char == "[":
            depth += 1
        elif char == "]":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            parts.append(operands[start:index].strip())
            start = index + 1
    parts.append(operands[start:].strip())
    return parts


def _register(text: str) -> str | None:
    token = text.strip().lower()
    return REG_ALIASES.get(token)


def _memory(text: str) -> tuple[str, int] | None:
    match = MEM_OPERAND.search(text)
    if not match:
        return None
    base = _register(match.group("base"))
    if base is None:
        return None
    disp = int(match.group("disp"), 0) if match.group("disp") else 0
    if match.group("sign") == "-":
        disp = -disp
    return base, disp


def inspect_this_reads(stage15_root: Path, row: dict) -> tuple[set[int], list[str]]:
    """Collect direct member loads through RDI and conservative RDI aliases.

    Handles `mov rbx, rdi`, `mov [rsp+slot], rdi`, and the matching stack
    reload. Any unknown arithmetic or pointer adjustment is deliberately not
    followed, preventing an arbitrary object's fields from being accepted as
    `this` fields.
    """
    offsets: set[int] = set()
    evidence: list[str] = []
    for relative in row.get("disassembly_files", []):
        path = (stage15_root / relative).resolve()
        if stage15_root.resolve() not in path.parents or not path.is_file():
            raise RuntimeError(f"Missing or unsafe Stage 15 method body: {relative}")
        aliases = {"rdi"}
        stack_aliases: set[tuple[str, int]] = set()
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            insn = INSN_ROW.match(line)
            if not insn:
                continue
            mnemonic, operand_text = insn.groups()
            mnemonic = mnemonic.lower()
            ops = _split_operands(operand_text)
            if not ops:
                continue

            # Calls can clobber the SysV caller-saved registers. Callee-saved
            # aliases (RBX/RBP/R12-R15) remain valid by ABI convention.
            if mnemonic.startswith("call"):
                aliases.difference_update(CALLER_SAVED)
                continue

            if len(ops) >= 2:
                destination, source = ops[0], ops[1]
                dst_reg = _register(destination)
                src_reg = _register(source)
                dst_mem = _memory(destination)
                src_mem = _memory(source)

                if mnemonic == "mov" and dst_reg:
                    aliases.discard(dst_reg)
                    if src_reg in aliases:
                        aliases.add(dst_reg)
                    elif src_mem and src_mem[0] in ("rsp", "rbp") and src_mem in stack_aliases:
                        aliases.add(dst_reg)
                elif mnemonic == "lea" and dst_reg:
                    aliases.discard(dst_reg)
                    # Only zero-adjustment LEA is an identity alias of this.
                    if src_mem and src_mem[0] in aliases and src_mem[1] == 0:
                        aliases.add(dst_reg)
                elif mnemonic == "mov" and dst_mem and dst_mem[0] in ("rsp", "rbp"):
                    if src_reg in aliases:
                        stack_aliases.add(dst_mem)
                    else:
                        stack_aliases.discard(dst_mem)
                elif mnemonic in LOAD_MNEMONICS and dst_reg and src_mem:
                    # A load destination is not itself an alias of `this`.
                    aliases.discard(dst_reg)

                # Count only actual value loads from an aliased `this` base.
                # Stores have the memory operand on the destination side.
                if mnemonic in LOAD_MNEMONICS and src_mem and src_mem[0] in aliases:
                    disp = src_mem[1]
                    offsets.add(disp)
                    if disp in FIELD_GETTERS.values():
                        evidence.append(line.strip())

                # Invalidate aliases on common arithmetic/bitwise writes.
                elif dst_reg and mnemonic in {
                    "add", "sub", "and", "or", "xor", "imul", "shl", "shr",
                    "sar", "inc", "dec", "neg", "not", "pop", "xchg",
                }:
                    aliases.discard(dst_reg)
            elif len(ops) == 1:
                # A single-operand write can replace a tracked alias.
                dst_reg = _register(ops[0])
                if dst_reg and mnemonic in {"pop", "inc", "dec", "neg", "not"}:
                    aliases.discard(dst_reg)
    return offsets, evidence


def source_checks(project_root: Path) -> list[dict]:
    adapter = project_root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkRxAdapter.cpp"
    controller = project_root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp"
    span = project_root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPacketSpanValidation.hpp"
    for p in (adapter, controller, span):
        if not p.is_file():
            raise RuntimeError(f"Required project source file missing: {p}")
    a = adapter.read_text(encoding="utf-8", errors="replace")
    c = controller.read_text(encoding="utf-8", errors="replace")
    s = span.read_text(encoding="utf-8", errors="replace")

    copy_pos = a.find("mbuf_copydata(source,")
    checks = [
        ("allocation is non-blocking and validates result", bool(re.search(
            r"allocatePacket\s*\(\s*1\s*,\s*&packet\s*,\s*1\s*\).*?", a, re.S))
         and "!= kIOReturnSuccess || !packet" in a),
        ("packet class, pool and single-buffer identity are checked", all(x in a for x in (
            "getPacketType() != kIOSkywalkPacketTypeNetwork",
            "getPacketBufferPool() != pool", "getPacketBufferCount() != 1"))),
        ("buffer, segment and memory descriptor null checks exist", all(x in a for x in (
            "getPacketBuffers(buffers, 1) != 1 || !buffers[0]", "if (!segment)", "if (!memory)"))),
        ("span bounds and pointer-overflow checks precede memcpy", all(x in s for x in (
            "RTW88WCLPacketSpanIsValid", "UINT64_MAX - span.dataOffset",
            "UINT64_MAX - relative", "UINTPTR_MAX")) and
            a.find("RTW88WCLResolvePacketBufferAddress") < copy_pos and copy_pos >= 0),
        ("packet and buffer data offsets/lengths are verified before copy", 
            0 <= a.find("setDataOffsetAndLength") < copy_pos and
            0 <= a.find("buffer->getDataLength() != packetLength") < copy_pos),
        ("completion status is set before packet is handed to caller",
            a.find("setCompletionStatus(0)") < a.find("*outPacket = packet")),
        ("allocated packet is returned on conversion failure",
            "if (!valid)\n        (void)pool->deallocatePacket(packet);" in a),
        ("mbuf is freed after workloop conversion on both success/failure",
            "mbuf_freem(source);" in a),
        ("sink rejection returns packet to the pool",
            "if (!accepted) {\n                    (void)_rxPool->deallocatePacket(packet);" in a),
        ("staged RX sink retains packet only in bounded owner ring",
            "return self->_stagedRxPackets.push(preparedPacket);" in c),
        ("RX completion queue is explicitly kept behind publication fence",
            "completion-queue registration/ownership is still fenced" in c and
            "refusing publication until Skywalk datapath is ready" in c),
    ]
    return [{"check": name, "status": "PASS" if ok else "FAIL"} for name, ok in checks]


PACKET_HEADER_RELATIVE = Path(
    "driver/RTL88WiFi/MacKernelSDK/Headers/IOKit/skywalk/IOSkywalkPacket.h"
)
PACKET_HEADER_FIELD_OFFSETS = {
    "mReserved": 0x20,
    "mPacketHandle": 0x28,
    "mPacketBuffers": 0x30,
    "mSourceQueue": 0x38,
    "mBufferPool": 0x40,
    "mBuflet": 0x48,
    "_reserved0": 0x50,
    "mPacketState": 0x58,
    "_unknownFlags": 0x5C,
    "mMaxNumBuffers": 0x60,
    "mActualNumBuffers": 0x64,
    "mPacketIndex": 0x68,
    "mTransferDirection": 0x6C,
}


def packet_header_layout_check(project_root: Path) -> dict:
    """Check vendored IOSkywalkPacket private layout against target-build facts."""
    path = project_root / PACKET_HEADER_RELATIVE
    if not path.is_file():
        return {"class": "IOSkywalkPacket", "status": "MISSING_HEADER",
                "path": str(PACKET_HEADER_RELATIVE)}
    header = path.read_text(encoding="utf-8", errors="replace")
    observed = {}
    for field in PACKET_HEADER_FIELD_OFFSETS:
        # Offset annotations are explicit hexadecimal comments, e.g. // 108 (0x6c).
        pattern = re.compile(
            rf"^\s*[^;\n]*\b{re.escape(field)}\b\s*;[^\n]*?0x([0-9a-fA-F]+)", re.M
        )
        match = pattern.search(header)
        if match:
            observed[field] = int(match.group(1), 16)
    mismatches = {
        field: {"expected": hex(expected),
                "observed": hex(observed[field]) if field in observed else None}
        for field, expected in PACKET_HEADER_FIELD_OFFSETS.items()
        if observed.get(field) != expected
    }
    removed_slot_api = all(token not in header for token in (
        "mSlotReference", "setSlotReference(", "getSlotReference("
    ))
    packet_size = TARGET_CLASS_SIZES["IOSkywalkPacket"]
    last_field_end = PACKET_HEADER_FIELD_OFFSETS["mTransferDirection"] + 4
    boundary_ok = last_field_end == packet_size == 0x70
    status = "PASS" if not mismatches and removed_slot_api and boundary_ok else "REVIEW_REQUIRED"
    return {
        "class": "IOSkywalkPacket",
        "status": status,
        "expected_instance_size": hex(packet_size),
        "last_field": "mTransferDirection",
        "last_field_offset": hex(PACKET_HEADER_FIELD_OFFSETS["mTransferDirection"]),
        "last_field_end": hex(last_field_end),
        "slot_reference_field_and_methods_removed": removed_slot_api,
        "field_offsets": {k: hex(v) for k, v in observed.items()},
        "field_offset_mismatches": mismatches,
    }


def audit(stage14_archive: Path, stage15_archive: Path,
          project_root: Path, output_dir: Path) -> dict:
    if not stage14_archive.is_file() or not stage15_archive.is_file():
        raise RuntimeError("Both Stage 14 and Stage 15 evidence archives are required")
    stage14_sha = sha256_file(stage14_archive)
    stage15_sha = sha256_file(stage15_archive)
    work = output_dir / "stage16-work"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="rtl88wifi-stage16-") as tmp:
        stage14_root = Path(tmp) / "stage14"
        stage15_extract = Path(tmp) / "stage15-unpacked"
        safe_extract(stage14_archive, stage14_root)
        safe_extract(stage15_archive, stage15_extract)
        stage15_json = one_file(stage15_extract, "STAGE15-ABI-ACCESSOR-AUDIT.json")
        stage15_root = stage15_json.parent
        stage15 = json.loads(stage15_json.read_text(encoding="utf-8"))
        if stage15.get("stage") != 15 or stage15.get("status") != "PASS":
            raise RuntimeError("Stage 15 archive is not marked PASS")
        if stage15.get("required_method_count") != EXPECTED_STAGE15_METHODS or stage15.get("methods_with_disassembly") != EXPECTED_STAGE15_METHODS:
            raise RuntimeError("Stage 15 archive does not contain all 18 accessor/disassembly checks")
        if stage15.get("input_sha256") != stage14_sha:
            raise RuntimeError(
                "Stage 15 report input SHA-256 does not match the supplied Stage 14 archive: "
                f"report={stage15.get('input_sha256')} actual={stage14_sha}"
            )
        sizes = parse_sizes(stage14_root)
        size_rows = []
        for cls, expected in TARGET_CLASS_SIZES.items():
            actual = sizes.get(cls)
            status = "PASS" if actual == expected else "MISMATCH" if actual is not None else "MISSING"
            size_rows.append({"class": cls, "expected_size": hex(expected),
                              "actual_size": hex(actual) if actual is not None else None,
                              "status": status})

        getter_rows = []
        bodies_dir = work / "field-access-evidence"
        bodies_dir.mkdir()
        for (owner, method), expected_offset in FIELD_GETTERS.items():
            row = find_method_row(stage15, owner, method)
            offsets, evidence = inspect_this_reads(stage15_root, row)
            status = "PASS" if expected_offset in offsets else "NEEDS_REVIEW"
            getter_rows.append({"class": owner, "method": method,
                                "expected_field_offset": hex(expected_offset),
                                "observed_this_displacements": [hex(x) for x in sorted(offsets)],
                                "status": status, "instruction_evidence": evidence})
            for i, rel in enumerate(row.get("disassembly_files", [])):
                src = (stage15_root / rel).resolve()
                if src.is_file():
                    dst = bodies_dir / f"{owner}-{method}-{i}-{src.name}"
                    shutil.copy2(src, dst)

        src_rows = source_checks(project_root)
        packet_header_row = packet_header_layout_check(project_root)
        size_ok = all(r["status"] == "PASS" for r in size_rows)
        getter_ok = all(r["status"] == "PASS" for r in getter_rows)
        source_ok = all(r["status"] == "PASS" for r in src_rows)
        header_ok = packet_header_row["status"] == "PASS"
        overall = "PASS" if size_ok and getter_ok and source_ok and header_ok else "REVIEW_REQUIRED"

        result = {
            "stage": 16,
            "status": overall,
            "platform": "macOS 15.8.1 (24H32), x86_64",
            "stage14_archive": stage14_archive.name,
            "stage14_sha256": stage14_sha,
            "stage15_archive": stage15_archive.name,
            "stage15_sha256": stage15_sha,
            "stage15_input_sha256": stage15.get("input_sha256"),
            "stage15_status": stage15.get("status"),
            "class_instance_sizes": size_rows,
            "packet_header_layout_audit": packet_header_row,
            "field_getter_layout_audit": getter_rows,
            "legacy_header_resolution": {
                "status": "RESOLVED_BY_24H32_KERNEL_EVIDENCE",
                "legacy_packet_instance_size": "0x78",
                "verified_24H32_packet_instance_size": "0x70",
                "legacy_slot_reference_field": "0x70 (outside target-build IOSkywalkPacket instance)",
                "slot_reference_methods_in_24H32": "not present in the collected IOSkywalkPacket method list",
                "legacy_header_count_offset": "0x60",
                "verified_24H32_count_offset": "0x64",
                "independent_methods": [
                    "IOSkywalkPacket::getPacketBufferCount",
                    "IOSkywalkPacket::getPacketBuffers",
                ],
                "note": "The vendored header was stale: 24H32 reports IOSkywalkPacket size 0x70; initWithPool writes max-buffer count at 0x60 and packet index at 0x68; both count readers use 0x64; transfer direction methods use 0x6c. The old slot-reference member at 0x70 and its methods are absent from the collected 24H32 class surface and are removed from the local header.",
            },
            "rx_source_and_ownership_checks": src_rows,
            "safety_boundary": "read-only; no Skywalk callbacks, queue registration, packet submission, or interface publication",
            "unresolved_contracts": [
                "Whether IOSkywalkMemorySegment/descriptor prepare-complete is required for this pool's allocated RX packet buffers.",
                "Exact ownership transition required before a future RX completion-queue submission.",
                "Exact queue registration and completion callback ABI required before publication.",
                "TX submission/completion queue handoff and teardown ordering.",
            ],
        }
        (work / "STAGE16-PACKET-SEMANTICS-AUDIT.json").write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        lines = [
            "# Stage 16 — packet-buffer layout and RX ownership audit", "",
            f"**Status:** {overall}", "",
            f"- Stage 14 SHA-256: `{stage14_sha}`",
            f"- Stage 15 SHA-256: `{stage15_sha}`",
            f"- Stage 15 status: `{stage15.get('status')}`",
            "", "## Instance-size cross-check", "",
            "| Class | Target-build expected size | Stage 14 size | Result |",
            "|---|---:|---:|---|",
        ]
        for r in size_rows:
            lines.append(f"| `{r['class']}` | `{r['expected_size']}` | `{r['actual_size'] or 'missing'}` | **{r['status']}** |")
        lines += ["", "## IOSkywalkPacket header boundary", "",
                  f"- Header audit: **{packet_header_row['status']}**",
                  f"- Verified instance size: `{packet_header_row.get('expected_instance_size', 'unknown')}`",
                  f"- Last in-object field: `{packet_header_row.get('last_field', 'unknown')}` at `{packet_header_row.get('last_field_offset', 'unknown')}`, ending at `{packet_header_row.get('last_field_end', 'unknown')}`",
                  f"- Slot-reference field/methods removed: `{packet_header_row.get('slot_reference_field_and_methods_removed', False)}`", "",
                  "## Getter field-offset evidence", "",
                  "Only a direct x86_64 `this` (`rdi`) displacement match is accepted. "
                  "Absence of a direct match is `NEEDS_REVIEW`, not proof of a bad ABI.", "",
                  "## Legacy SDK header discrepancy", "",
                  "The vendored legacy `IOSkywalkPacket.h` annotated `mActualNumBuffers` at `0x60`. "
                  "The target-build Stage 15 body for `getPacketBufferCount` reads a 32-bit value at `this+0x64`. "
                  "The independent `getPacketBuffers` method must read the same offset; this audit now requires both "
                  "methods to agree at `0x64`. The old comment is not treated as target-build ABI evidence.", "",
                  "| Method | 24H32 expected offset | Observed `this` displacements | Result |",
                  "|---|---:|---|---|"]
        for r in getter_rows:
            got = ", ".join(f"`{v}`" for v in r["observed_this_displacements"]) or "—"
            lines.append(f"| `{r['class']}::{r['method']}` | `{r['expected_field_offset']}` | {got} | **{r['status']}** |")
        lines += ["", "## RX source/ownership invariants", "", "| Check | Result |", "|---|---|"]
        for r in src_rows:
            lines.append(f"| {r['check']} | **{r['status']}** |")
        lines += ["", "## Open contracts — do not enable datapath yet", ""]
        lines += [f"- {item}" for item in result["unresolved_contracts"]]
        lines += ["", "## Safety boundary", "",
                  "This audit does not enable callbacks, register queues, submit packets, or publish an interface. "
                  "A PASS only establishes the listed size/offset/source invariants; it does not establish "
                  "Apple's undocumented mapping, prepare/complete, ownership, or completion semantics.", ""]
        (work / "STAGE16-PACKET-SEMANTICS-AUDIT.md").write_text("\n".join(lines), encoding="utf-8")

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_out = output_dir / "RTL88WiFi-Sequoia-24H32-stage16-packet-semantics-audit.tar.gz"
    with tarfile.open(archive_out, "w:gz") as tf:
        tf.add(work, arcname="stage16")
    digest = sha256_file(archive_out)
    (output_dir / (archive_out.name + ".sha256")).write_text(
        digest + "  " + archive_out.name + "\n", encoding="utf-8")
    print(f"Stage 16 status: {overall}")
    for row in getter_rows:
        observed = ",".join(row["observed_this_displacements"]) or "none"
        print(f"GETTER_AUDIT: {row['class']}::{row['method']} expected={row['expected_field_offset']} observed={observed} status={row['status']}")
        for instruction in row["instruction_evidence"]:
            print(f"  EVIDENCE: {instruction}")
    print(f"Stage 14 input SHA-256: {stage14_sha}")
    print(f"Stage 15 input SHA-256: {stage15.get('input_sha256')}")
    print(f"Stage 16 field getters matched: {sum(x['status']=='PASS' for x in getter_rows)}/{len(getter_rows)}")
    print(f"Stage 16 source checks: {sum(x['status']=='PASS' for x in src_rows)}/{len(src_rows)}")
    print(f"Stage 16 packet header layout: {packet_header_row['status']}")
    print(f"Stage 16 archive: {archive_out}")
    print(f"Stage 16 archive SHA-256: {digest}")
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage14-archive", type=Path, required=True)
    ap.add_argument("--stage15-archive", type=Path, required=True)
    ap.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--out", type=Path, default=Path("build/sequoia-abi-24H32-stage16"))
    args = ap.parse_args()
    try:
        result = audit(args.stage14_archive, args.stage15_archive,
                       args.project_root.resolve(), args.out)
    except (OSError, tarfile.TarError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        ap.error(str(exc))
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
