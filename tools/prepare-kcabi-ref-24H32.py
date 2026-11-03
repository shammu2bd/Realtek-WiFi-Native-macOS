#!/usr/bin/env python3
"""Prepare an explicit kcabi reference list for 24H32 registration ABI methods.

WTLKcAbi's dump.py disassembles the functions named by a reference dump. This
helper creates a small synthetic reference dump for methods that are present
in the 24H32 method lists but are not part of kcabi's default extra list.
Existing KCABI_REF asm references are merged by symbol name; source files are
read only and the generated reference is written only under --out.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

# Exact Itanium C++ symbols from the 24H32 method lists. The method names are
# deliberately exact: if a symbol changes on another build, kcabi will report
# it missing instead of us guessing a new signature.
TARGET_SYMBOLS = (
    "__ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCorePN26IOSkywalkEthernetInterface16RegistrationInfoE",
    "__ZN28AppleBCMWLANSkywalkInterface4stopEP9IOService",
    "__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_",
    "__ZN21IO80211InfraInterface5startEP9IOService",
    "__ZN26IOSkywalkEthernetInterface20initRegistrationInfoEPNS_16RegistrationInfoEjm",
    "__ZN26IOSkywalkEthernetInterface20copyRegistrationInfoEPKNS_16RegistrationInfoE",
    "__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j",
    "__ZN26IOSkywalkEthernetInterface27deregisterEthernetInterfaceEj",
    "__ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS6_j",
    "__ZN25IOSkywalkNetworkInterface24registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j",
    "__ZN25IOSkywalkNetworkInterface24registerNetworkInterfaceEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS6_j",
    "__ZN25IOSkywalkNetworkInterface26deregisterNetworkInterfaceEj",
    "__ZN25IOSkywalkNetworkInterface39registerNetworkInterfaceWithLogicalLinkEPKNS_16RegistrationInfoEP20IOSkywalkLogicalLinkP25IOSkywalkPacketBufferPoolS6_j",
    "__ZN25IOSkywalkNetworkInterface21deregisterLogicalLinkEv",
)

SYMBOL_LINE = re.compile(r"^#\s+0x[0-9a-fA-F]+\s+(__\S+)\s*$")


def symbols_from_reference(reference: Path | None) -> set[str]:
    found: set[str] = set()
    if reference is None:
        return found
    if not reference.is_dir():
        raise ValueError(f"reference directory does not exist: {reference}")
    for path in reference.rglob("*.asm.txt"):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            with path.open("r", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    match = SYMBOL_LINE.match(line.strip())
                    if match:
                        found.add(match.group(1))
        except OSError as exc:
            raise ValueError(f"cannot read reference member {path}: {exc}") from exc
    return found


def prepare(out: Path, reference: Path | None = None) -> tuple[int, int]:
    out.mkdir(parents=True, exist_ok=True)
    symbols = symbols_from_reference(reference)
    before = len(symbols)
    symbols.update(TARGET_SYMBOLS)
    target = out / "rtl88wifi-24H32-registration-targets.asm.txt"
    target.write_text(
        "\n".join(f"# 0x0 {symbol}" for symbol in sorted(symbols)) + "\n",
        encoding="utf-8",
    )
    return len(TARGET_SYMBOLS), len(symbols) - before


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="temporary kcabi --ref directory")
    parser.add_argument("--reference", type=Path, help="optional existing KCABI_REF directory to merge")
    args = parser.parse_args()
    try:
        target_count, extra_count = prepare(args.out, args.reference)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(f"Prepared {target_count} exact 24H32 registration symbols; merged {extra_count} reference symbols.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
