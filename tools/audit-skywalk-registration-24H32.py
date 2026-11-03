#!/usr/bin/env python3
"""Collect focused 24H32 Skywalk registration ABI evidence from a kcabi tarball.

The ordinary mode emits keyword context, as before. The focused mode emits the
complete disassembly bodies for registration/deregistration entry points and
known Apple registration/start call paths, plus matching symbol-index rows.
The script reads regular tar members in memory and never extracts archive paths.
It reports evidence; it does not infer C++ types or claim runtime correctness.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Iterable

PATTERN = re.compile(
    r"registerEthernetInterface|initRegistrationInfo|deregisterEthernetInterface|"
    r"registerNetworkInterface|deregisterNetworkInterface|registerInfraEthernetInterface|"
    r"IOSkywalkEthernetInterface|IOSkywalkNetworkInterface",
    re.IGNORECASE,
)
CONTEXT = 12
MAX_MEMBER = 16 * 1024 * 1024
MAX_MATCH_LINES_PER_MEMBER = 240
MAX_FOCUSED_ASM_MEMBER = 256 * 1024
MAX_FOCUSED_ASM_TOTAL = 1024 * 1024

# IO80211InfraInterface::start has an indirect call through [vtable + 0xc00].
# The Stage 9 report incorrectly labelled it as registration. The 24H32 row
# actually resolves to setInterfaceOFDMDesense; registration is a separate
# direct call from AppleBCMWLANSkywalkInterface::start.
VTABLE_DISPATCH_CHECKS = (
    (
        "IO80211InfraInterface.vtable.txt",
        0xC00,
        "IO80211InfraInterface::start side-call (not registration)",
        "__ZN21IO80211InfraInterface23setInterfaceOFDMDesenseE18apple80211_channelx",
    ),
)

# These paths cover the two Ethernet registration overloads, their network
# superclass counterparts, deregistration and the known 24H32 Apple call paths.
# Substring matching deliberately tolerates minor kcabi filename variation.
FOCUSED_ASM_PATTERNS = (
    "registerEthernetInterface",
    "deregisterEthernetInterface",
    "registerNetworkInterface",
    "deregisterNetworkInterface",
    "registerInfraEthernetInterface",
    "IO80211InfraInterface5startEP9IOService",
    "AppleBCMWLANSkywalkInterface5startEP",
    "IOSkywalkLegacyEthernet5startEP9IOService",
)
INDEX_TERMS = (
    "registerEthernetInterface",
    "deregisterEthernetInterface",
    "registerNetworkInterface",
    "deregisterNetworkInterface",
    "registerInfraEthernetInterface",
    "initRegistrationInfo",
    "IO80211InfraInterface5startEP9IOService",
    "AppleBCMWLANSkywalkInterface5startEP",
    "IOSkywalkLegacyEthernet5startEP9IOService",
)


def safe_member_name(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts


def _read_regular_members(archive_path: Path) -> Iterable[tuple[str, int, bytes]]:
    try:
        tar = tarfile.open(archive_path, mode="r:gz")
    except (tarfile.TarError, OSError) as exc:
        raise RuntimeError(f"cannot open gzip tar archive: {exc}") from exc

    with tar:
        for member in tar.getmembers():
            if not member.isfile() or not safe_member_name(member.name):
                continue
            if member.size > MAX_MEMBER:
                continue
            stream = tar.extractfile(member)
            if stream is None:
                continue
            raw = stream.read(MAX_MEMBER + 1)
            if len(raw) <= MAX_MEMBER:
                yield member.name, member.size, raw


def scan_archive(archive_path: Path, include_full_asm: bool = False) -> str:
    archive_bytes = archive_path.read_bytes()
    digest = hashlib.sha256(archive_bytes).hexdigest()
    blocks = [
        "RTL88WiFi Sequoia 24H32 Skywalk registration evidence",
        f"Archive: {archive_path}",
        f"SHA-256: {digest}",
        "Note: evidence output is for manual ABI review, not an ABI conclusion.",
        "",
    ]
    scanned = 0
    matched_members = 0
    matched_lines_total = 0
    focused_paths: list[str] = []
    focused_total = 0
    index_lines: list[str] = []
    vtable_dispatch_rows: list[str] = []
    focused_text_by_path: dict[str, str] = {}

    for name, declared_size, raw in _read_regular_members(archive_path):
        scanned += 1
        text = raw.decode("utf-8", errors="replace")
        lines = text.splitlines()
        path_hit = bool(PATTERN.search(name))
        hits = [i for i, line in enumerate(lines) if PATTERN.search(line)]

        if include_full_asm:
            for vtable_name, target_offset, description, expected_target in VTABLE_DISPATCH_CHECKS:
                if PurePosixPath(name).name == vtable_name:
                    found = False
                    for line in lines:
                        match = re.match(r"^\s*(\d+)\s+(0x[0-9a-fA-F]+)\s+(\S+)", line)
                        if match and int(match.group(2), 16) == target_offset:
                            actual_target = match.group(3)
                            status = "OK" if actual_target == expected_target else "MISMATCH"
                            vtable_dispatch_rows.append(
                                f"{description}: {status}; slot {match.group(1)}, "
                                f"offset {match.group(2)}, target {actual_target}; "
                                f"expected {expected_target}"
                            )
                            found = True
                    if not found:
                        vtable_dispatch_rows.append(
                            f"{description}: offset {target_offset:#x} NOT FOUND in {name}"
                        )

        if include_full_asm and name.startswith("24H32/asm/"):
            if name.endswith("INDEX.txt"):
                for line in lines:
                    if any(term.lower() in line.lower() for term in INDEX_TERMS):
                        index_lines.append(f"{name}: {line}")
            elif any(term.lower() in name.lower() for term in FOCUSED_ASM_PATTERNS):
                if len(raw) <= MAX_FOCUSED_ASM_MEMBER and focused_total + len(raw) <= MAX_FOCUSED_ASM_TOTAL:
                    focused_paths.append(name)
                    focused_text_by_path[name] = text
                    focused_total += len(raw)
                    blocks.append(f"===== COMPLETE DISASSEMBLY: {name} ({declared_size} bytes) =====")
                    blocks.extend(f"{i + 1}: {line}" for i, line in enumerate(lines))
                    blocks.append("")
                else:
                    blocks.append(f"[SKIP focused disassembly over output bound: {name} ({declared_size} bytes)]")
                    blocks.append("")

        if include_full_asm and name in focused_paths:
            continue

        if not hits and not path_hit:
            continue
        matched_members += 1
        blocks.append(f"===== {name} ({declared_size} bytes) =====")
        if path_hit and not hits:
            blocks.append("[member path matches a registration-related name; no text-line hit]")
        if hits:
            selected: set[int] = set()
            for i in hits:
                selected.update(range(max(0, i - CONTEXT), min(len(lines), i + CONTEXT + 1)))
            ordered = sorted(selected)
            if len(ordered) > MAX_MATCH_LINES_PER_MEMBER:
                ordered = ordered[:MAX_MATCH_LINES_PER_MEMBER]
                blocks.append(f"[context capped at {MAX_MATCH_LINES_PER_MEMBER} lines]")
            matched_lines_total += len(hits)
            last = -2
            for i in ordered:
                if i != last + 1:
                    blocks.append("...")
                value = lines[i]
                if len(value) > 1200:
                    value = value[:1200] + " ... [line truncated]"
                blocks.append(f"{i + 1}: {value}")
                last = i
        blocks.append("")

    if include_full_asm:
        apple_start = next((body for path, body in focused_text_by_path.items()
                            if "AppleBCMWLANSkywalkInterface5startEP" in path), "")
        infra_registration = next((body for path, body in focused_text_by_path.items()
                                   if "registerInfraEthernetInterface" in path), "")
        ethernet_registration = next((body for path, body in focused_text_by_path.items()
                                      if "IOSkywalkEthernetInterface25registerEthernetInterface"
                                      in path and "EPP20IOSkywalkPacketQueue" in path), "")
        network_registration = next((body for path, body in focused_text_by_path.items()
                                     if "IOSkywalkNetworkInterface24registerNetworkInterface"
                                     in path and "EPP20IOSkywalkPacketQueue" in path), "")
        direct_registration_call = bool(re.search(
            r"call\s+[^\n]*__ZN21IO80211InfraInterface30registerInfraEthernetInterface", apple_start
        ))
        # The Apple caller tests the returned EAX status, records ZF with
        # SETE, and branches on the same flags: zero is the success path.
        apple_zero_success = False
        if direct_registration_call:
            status_test = re.search(r"test\s+(r\w+d),\s*\1", apple_start)
            if status_test:
                after_test = apple_start[status_test.end():]
                status_sete = re.search(r"sete\s+r\w+b", after_test)
                if status_sete:
                    apple_zero_success = bool(re.search(r"\bje\s+", after_test[status_sete.end():]))
        infra_forwards_status = bool(
            re.search(r"call\s+[^\n]*__ZN26IOSkywalkEthernetInterface25registerEthernetInterface"
                      r"EPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue", infra_registration)
            and re.search(r"mov\s+r14d,\s*eax", infra_registration)
            and re.search(r"mov\s+eax,\s*r14d", infra_registration)
        )
        ethernet_forwards_status = bool(
            re.search(r"call\s+[^\n]*__ZN25IOSkywalkNetworkInterface24registerNetworkInterface"
                      r"EPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueue", ethernet_registration)
        )
        registration_contract_rows = []
        if direct_registration_call:
            registration_contract_rows.append(
                "AppleBCMWLANSkywalkInterface::start calls registerInfraEthernetInterface directly (not via vtable)."
            )
        else:
            registration_contract_rows.append(
                "Apple registration call site: NOT VERIFIED in focused Apple start body."
            )
        if apple_zero_success and infra_forwards_status and ethernet_forwards_status:
            registration_contract_rows.append(
                "Return convention: IOReturn status in EAX; Ethernet and infra wrappers forward the "
                "registration result, and Apple branches to success only when EAX==0."
            )
        else:
            registration_contract_rows.append(
                "Return convention: INCOMPLETE; review Apple caller and full wrapper return paths."
            )
        registration_contract_rows.append(
            "This is an ABI declaration finding only; queue/pool ownership and RegistrationInfo field semantics remain separate checks."
        )

        blocks.extend([
            "===== VTABLE DISPATCH CHECKS =====",
            *(
                vtable_dispatch_rows
                if vtable_dispatch_rows
                else ["IO80211InfraInterface vtable dispatch slot: NOT FOUND in archive"]
            ),
            "The [vtable + 0xc00] call is not the registration entry point; the registration call is direct from Apple start.",
            "",
            "===== REGISTRATION CALL / RETURN CONTRACT =====",
            *registration_contract_rows,
            "",
            "===== MATCHING SYMBOL INDEX ROWS =====",
            *index_lines,
            "",
            "===== FOCUSED DISASSEMBLY SUMMARY =====",
            f"complete focused asm members emitted: {len(focused_paths)}",
            f"complete focused asm bytes emitted: {focused_total}",
            f"index rows emitted: {len(index_lines)}",
            "Focused path coverage:",
            *[
                f"  {pattern}: " + (
                    "; ".join(path for path in focused_paths if pattern.lower() in path.lower())
                    if any(pattern.lower() in path.lower() for path in focused_paths)
                    else "NOT FOUND in archive"
                )
                for pattern in FOCUSED_ASM_PATTERNS
            ],
            "A missing body means this archive did not contain that matching asm member.",
            "Review register arguments, call sites, return-value tests, output writes, and cleanup paths manually.",
            "",
        ])

    blocks.extend([
        "===== SUMMARY =====",
        f"regular members scanned: {scanned}",
        f"members with relevant path/text: {matched_members}",
        f"matching text lines: {matched_lines_total}",
        "The IOReturn convention is reported only when the Apple direct call and status-forwarding bodies match the inspected 24H32 patterns.",
        "Private RegistrationInfo field semantics, queue/pool directions, and packet completion ownership still require separate review.",
    ])
    return "\n".join(blocks) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="RTL88WiFi-Sequoia-24H32-kcabi.tar.gz")
    parser.add_argument("--output", type=Path, default=Path("build/24H32-registration-audit.txt"))
    parser.add_argument(
        "--full-registration-asm", action="store_true",
        help="include complete focused registration/deregistration and Apple call-path disassemblies",
    )
    parser.add_argument(
        "--stdout", action="store_true",
        help="write report to stdout instead of creating a separate audit file",
    )
    args = parser.parse_args()
    if not args.archive.is_file():
        parser.error(f"archive does not exist: {args.archive}")
    try:
        result = scan_archive(args.archive, include_full_asm=args.full_registration_asm)
    except (RuntimeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.stdout:
        sys.stdout.write(result)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result)
        print(f"Wrote registration ABI evidence: {args.output}")
    print(f"Archive SHA-256: {hashlib.sha256(args.archive.read_bytes()).hexdigest()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
