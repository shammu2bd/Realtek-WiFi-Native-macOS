#!/usr/bin/env python3
"""Read-only 24H32 Skywalk lifecycle/TX-completion evidence scanner.

This scanner never extracts archive paths and never infers ABI behavior from
symbol presence alone. It inventories symbol/index records and emits complete
matching assembly members when those bodies are present in the supplied kcabi.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath

MAX_MEMBER = 16 * 1024 * 1024
MAX_ASM_MEMBER = 512 * 1024
MAX_ASM_TOTAL = 4 * 1024 * 1024

REGEX = re.compile(
    r"registerInfraEthernetInterface|registerEthernetInterface|"
    r"deregisterEthernetInterface|registerNetworkInterface|"
    r"deregisterNetworkInterface|deregisterLogicalLink|"
    r"initRegistrationInfo|copyRegistrationInfo",
    re.IGNORECASE,
)
TX_REGEX = re.compile(
    r"IOSkywalkTxSubmissionQueue|IOSkywalkTxCompletionQueue|"
    r"TxCompletion|txCompletion|recordCompletionPackets|"
    r"logTxCompletionPacket|logSkywalkTxReqPacket|"
    r"completePackets|enqueuePackets|enqueuePacket|"
    r"dequeuePackets|complete.*packet|packet.*complete",
    re.IGNORECASE,
)
START_REGEX = re.compile(
    r"IO80211InfraInterface5startEP9IOService|"
    r"AppleBCMWLANSkywalkInterface.*5startEP|"
    r"IOSkywalkLegacyEthernet5startEP9IOService",
    re.IGNORECASE,
)
INDEX_OR_METHOD_REGEX = re.compile(
    REGEX.pattern + "|" + TX_REGEX.pattern + "|" + START_REGEX.pattern,
    re.IGNORECASE,
)

ASM_PATH = "24H32/asm/"


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts


def read_members(path: Path):
    try:
        archive = tarfile.open(path, mode="r:gz")
    except (OSError, tarfile.TarError) as exc:
        raise RuntimeError(f"cannot open gzip tar archive: {exc}") from exc
    with archive:
        for member in archive.getmembers():
            if not member.isfile() or not safe_name(member.name):
                continue
            if member.size > MAX_MEMBER:
                continue
            stream = archive.extractfile(member)
            if stream is None:
                continue
            raw = stream.read(MAX_MEMBER + 1)
            if len(raw) <= MAX_MEMBER:
                yield member.name, member.size, raw


def run(path: Path) -> int:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    lines = [
        "RTL88WiFi Sequoia 24H32 lifecycle and TX-completion evidence",
        f"Archive: {path}",
        f"SHA-256: {digest}",
        "Mode: READ_ONLY_ARCHIVE_SCAN",
        "Interpretation: symbol presence is not proof of callability, semantics, or ownership.",
        "",
    ]

    scanned = 0
    index_rows: list[str] = []
    registration_members: list[str] = []
    tx_members: list[str] = []
    start_members: list[str] = []
    asm_candidates: list[tuple[str, int, str]] = []
    asm_bytes = 0
    skipped_asm: list[str] = []

    for name, declared_size, raw in read_members(path):
        scanned += 1
        text = raw.decode("utf-8", errors="replace")
        base = PurePosixPath(name).name

        if INDEX_OR_METHOD_REGEX.search(name + "\n" + text):
            if REGEX.search(name + "\n" + text):
                registration_members.append(name)
            if TX_REGEX.search(name + "\n" + text):
                tx_members.append(name)
            if START_REGEX.search(name + "\n" + text):
                start_members.append(name)

        if base == "INDEX.txt" or name.endswith(".methods.txt"):
            for row in text.splitlines():
                if INDEX_OR_METHOD_REGEX.search(row):
                    index_rows.append(f"{name}: {row}")

        if name.startswith(ASM_PATH) and name.endswith(".asm.txt"):
            # Match both mangled/address-based filenames and demangled symbols
            # embedded in the assembly header, comments, or instructions.
            if INDEX_OR_METHOD_REGEX.search(name + "\n" + text):
                if len(raw) > MAX_ASM_MEMBER or asm_bytes + len(raw) > MAX_ASM_TOTAL:
                    skipped_asm.append(f"{name} ({declared_size} bytes)")
                else:
                    asm_candidates.append((name, declared_size, text))
                    asm_bytes += len(raw)

    lines.extend([
        "===== SCAN COUNTS =====",
        f"regular archive members scanned: {scanned}",
        f"registration-related members: {len(set(registration_members))}",
        f"TX-completion-related members: {len(set(tx_members))}",
        f"start/caller-related members: {len(set(start_members))}",
        f"complete matching assembly bodies emitted: {len(asm_candidates)}",
        f"complete matching assembly bytes emitted: {asm_bytes}",
        "",
        "===== REGISTRATION / DEREGISTRATION SYMBOL ROWS =====",
        *(index_rows if index_rows else ["NO_MATCHING_SYMBOL_ROWS"]),
        "",
        "===== RELEVANT ARCHIVE MEMBER INVENTORY =====",
        "Registration-related members:",
        *(f"  {x}" for x in sorted(set(registration_members))),
        "TX-completion-related members:",
        *(f"  {x}" for x in sorted(set(tx_members))),
        "Apple/start/caller-related members:",
        *(f"  {x}" for x in sorted(set(start_members))),
        "",
        "===== COMPLETE MATCHING ASSEMBLY BODIES =====",
    ])

    if asm_candidates:
        for name, size, body in asm_candidates:
            lines.append(f"----- {name} ({size} bytes) -----")
            lines.extend(f"{i}: {line}" for i, line in enumerate(body.splitlines(), 1))
            lines.append("")
    else:
        lines.append("NO_MATCHING_ASSEMBLY_BODIES_FOUND")
        lines.append("")

    lines.extend([
        "===== SIZE-LIMITED ASSEMBLY MEMBERS =====",
        *(skipped_asm if skipped_asm else ["none"]),
        "",
        "===== REVIEW STATUS =====",
        "STAGE91_EVIDENCE_SCAN: COMPLETE",
        "REGISTRATION_CALL_CONTRACT: MANUAL_REVIEW_REQUIRED",
        "DEREGISTRATION_AND_ROLLBACK_CONTRACT: MANUAL_REVIEW_REQUIRED",
        "TX_COMPLETION_QUEUE_ACTION_CONTRACT: MANUAL_REVIEW_REQUIRED",
        "PACKET_OWNERSHIP_TRANSFER: NOT_ESTABLISHED_BY_SYMBOL_SCAN",
        "TX_CALLBACK_ACTIVATION: MUST_REMAIN_FAIL_CLOSED",
        "",
    ])
    sys.stdout.write("\n".join(lines))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    if not args.archive.is_file():
        print(f"ERROR: archive does not exist: {args.archive}", file=sys.stderr)
        return 2
    try:
        return run(args.archive)
    except (OSError, RuntimeError, tarfile.TarError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
