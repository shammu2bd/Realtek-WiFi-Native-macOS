#!/usr/bin/env python3
"""Stage 15: read-only audit of packet/buffer accessors against Stage 14 ABI.

This tool does not modify Kext sources, instantiate kernel objects, or enable
Skywalk callbacks. It checks that the methods the current packet adapters call
are represented in the exact 24H32 kcabi method lists and disassembly archive.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
from collections import OrderedDict
from pathlib import Path
from typing import Iterable

TARGET_CLASSES = (
    "IOSkywalkPacketQueue",
    "IOSkywalkPacketBufferPool",
    "IOSkywalkQueueSet",
    "IOSkywalkLogicalLink",
    "IOSkywalkMemorySegment",
    "IOSkywalkPacketBuffer",
    "IOSkywalkPacket",
    "IOSkywalkNetworkPacket",
)

# These are the kernel APIs directly called by the current packet view and RX
# adapter. This is a presence/body audit, not a claim about semantics or safety.
REQUIRED_METHODS = OrderedDict([
    ("IOSkywalkPacket", (
        "getPacketType",
        "getPacketBufferPool",
        "getPacketBufferCount",
        "getPacketBuffers",
        "getDataOffset",
        "getDataLength",
        "setDataOffsetAndLength",
    )),
    ("IOSkywalkPacketBufferPool", (
        "allocatePacket",
        "deallocatePacket",
    )),
    ("IOSkywalkPacketBuffer", (
        "getPacketBufferPool",
        "getMemorySegment",
        "getMemorySegmentOffset",
        "getBufferSize",
        "getDataOffset",
        "getDataLength",
    )),
    ("IOSkywalkMemorySegment", (
        "getMemoryDescriptor",
        "getVirtualAddress",
    )),
    ("IOSkywalkNetworkPacket", (
        "setCompletionStatus",
    )),
])

SYMBOL_TOKEN = re.compile(r"(?<![A-Za-z0-9_])(__Z[A-Za-z0-9_]+(?:\.[A-Za-z0-9_.]+)?)")
REFERENCE_ROW = re.compile(r"^#\s+0x[0-9a-fA-F]+\s+(__Z\S+)\s*$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def symbols_in_file(path: Path) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            for match in SYMBOL_TOKEN.finditer(line):
                symbol = match.group(1)
                if symbol not in seen:
                    seen.add(symbol)
                    found.append(symbol)
    return found


def find_demangler(explicit: str | None = None) -> str:
    candidates = [explicit] if explicit else []
    candidates.extend([
        shutil.which("llvm-cxxfilt"),
        shutil.which("c++filt"),
        "/opt/local/libexec/llvm-20/bin/llvm-cxxfilt",
        "/opt/local/libexec/llvm-19/bin/llvm-cxxfilt",
        "/opt/local/bin/llvm-cxxfilt-mp-20",
        "/opt/local/bin/llvm-c++filt-mp-20",
    ])
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise RuntimeError(
        "No C++ Itanium demangler found. Set --demangler to c++filt or llvm-cxxfilt."
    )


def demangle(symbols: Iterable[str], demangler: str) -> dict[str, str]:
    unique = list(dict.fromkeys(symbols))
    if not unique:
        return {}

    # Mach-O kernel symbols carry the platform's extra leading underscore
    # (__Z...). GNU c++filt/llvm-cxxfilt generally wants _Z..., while Apple's
    # c++filt may want the original __Z spelling. Try both forms and accept
    # only output that the selected demangler actually changed.
    decoded: dict[str, str] = {}
    pending = unique[:]
    attempts = (
        lambda symbol: symbol[1:] if symbol.startswith("__Z") else symbol,
        lambda symbol: symbol,
    )
    for make_input in attempts:
        if not pending:
            break
        inputs = [make_input(symbol) for symbol in pending]
        result = subprocess.run(
            [demangler], input="\n".join(inputs) + "\n", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"Demangler failed ({result.returncode}): {result.stderr.strip()}"
            )
        lines = result.stdout.splitlines()
        if len(lines) != len(pending):
            raise RuntimeError(
                f"Demangler returned {len(lines)} rows for {len(pending)} symbols."
            )
        still_pending: list[str] = []
        for symbol, demangler_input, output in zip(pending, inputs, lines):
            output = output.strip()
            if output and output != demangler_input:
                decoded[symbol] = output
            else:
                still_pending.append(symbol)
        pending = still_pending

    if pending:
        preview = ", ".join(pending[:3])
        raise RuntimeError(
            f"Could not demangle {len(pending)} kernel symbol(s) using either "
            f"Mach-O (__Z) or normalized (_Z) spelling. Examples: {preview}. "
            "Try --demangler with the matching llvm-cxxfilt/c++filt binary."
        )
    return decoded


def safe_extract_tar(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        if not members:
            raise RuntimeError("Stage 14 archive is empty.")
        for member in members:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise RuntimeError(f"Unsafe archive path rejected: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise RuntimeError(f"Non-regular archive entry rejected: {member.name}")
            target = (root / name).resolve()
            if target != root and root not in target.parents:
                raise RuntimeError(f"Archive path escapes extraction root: {member.name}")
        tar.extractall(destination, members=members)


def locate_stage_root(extracted: Path) -> Path:
    candidates = [p for p in extracted.rglob("rtl88wifi-target.txt") if p.is_file()]
    if len(candidates) == 1:
        return candidates[0].parent
    if len(candidates) > 1:
        raise RuntimeError(f"Expected one rtl88wifi-target.txt; found {len(candidates)}")
    candidates = [p for p in extracted.rglob("IOSkywalkPacket.methods.txt") if p.is_file()]
    if len(candidates) == 1:
        return candidates[0].parent
    raise RuntimeError(
        "Cannot locate Stage 14 kcabi output: expected rtl88wifi-target.txt and/or "
        "one IOSkywalkPacket.methods.txt."
    )


def collect_method_lists(stage_root: Path) -> tuple[dict[str, list[str]], dict[str, Path]]:
    results: dict[str, list[str]] = {}
    paths: dict[str, Path] = {}
    problems: list[str] = []
    for class_name in TARGET_CLASSES:
        candidates = sorted(stage_root.rglob(f"{class_name}.methods.txt"))
        if len(candidates) != 1:
            problems.append(
                f"{class_name}: expected exactly one method list; found {len(candidates)}"
            )
            continue
        path = candidates[0]
        symbols = symbols_in_file(path)
        if not symbols:
            problems.append(f"{class_name}: method list is empty: {path}")
            continue
        results[class_name] = symbols
        paths[class_name] = path
    if problems:
        raise RuntimeError("Stage 14 method-list coverage incomplete:\n" + "\n".join(problems))
    return results, paths


def collect_disassembly(stage_root: Path) -> dict[str, list[Path]]:
    result: dict[str, list[Path]] = {}
    for path in sorted(stage_root.rglob("*.asm.txt")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                match = REFERENCE_ROW.match(line.strip())
                if match:
                    result.setdefault(match.group(1), []).append(path)
    return result


def audit_archive(archive: Path, output_dir: Path, demangler_path: str | None = None) -> dict:
    if not archive.is_file():
        raise RuntimeError(f"Stage 14 archive not found: {archive}")
    demangler = find_demangler(demangler_path)
    digest = sha256_file(archive)
    work_dir = output_dir / "stage15-work"
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="rtl88wifi-stage15-") as temp:
        extracted = Path(temp) / "unpacked"
        safe_extract_tar(archive, extracted)
        stage_root = locate_stage_root(extracted)
        class_symbols, method_paths = collect_method_lists(stage_root)
        all_symbols = [symbol for values in class_symbols.values() for symbol in values]
        demangled = demangle(all_symbols, demangler)
        disassembly = collect_disassembly(stage_root)

        rows: list[dict] = []
        body_dir = work_dir / "bodies"
        body_dir.mkdir(parents=True)
        for owner, methods in REQUIRED_METHODS.items():
            for method in methods:
                matches = [
                    symbol for symbol, name in demangled.items()
                    if name.startswith(f"{owner}::{method}(")
                    or name.startswith(f"{owner}::{method}<")
                ]
                bodies = [path for symbol in matches for path in disassembly.get(symbol, [])]
                if not matches:
                    state = "MISSING_SYMBOL"
                elif not bodies:
                    state = "MISSING_DISASSEMBLY"
                else:
                    state = "PASS"
                copied: list[str] = []
                for index, path in enumerate(dict.fromkeys(bodies)):
                    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", path.name)
                    destination = body_dir / f"{owner}-{method}-{index}-{safe_name}"
                    shutil.copy2(path, destination)
                    copied.append(destination.relative_to(work_dir).as_posix())
                rows.append({
                    "class": owner,
                    "method": method,
                    "status": state,
                    "symbols": matches,
                    "disassembly_files": copied,
                })

        class_counts = {name: len(values) for name, values in class_symbols.items()}
        passed = sum(row["status"] == "PASS" for row in rows)
        missing = [row for row in rows if row["status"] != "PASS"]
        result = {
            "stage": 15,
            "status": "PASS" if not missing else "INCOMPLETE",
            "platform": "macOS 15.8.1 (24H32), x86_64",
            "input_archive": archive.name,
            "input_sha256": digest,
            "demangler": demangler,
            "class_method_counts": class_counts,
            "required_method_count": len(rows),
            "methods_with_disassembly": passed,
            "missing_methods": missing,
            "method_audit": rows,
            "method_list_paths": {k: str(v.relative_to(stage_root)) for k, v in method_paths.items()},
        }
        target_metadata = stage_root / "rtl88wifi-target.txt"
        if target_metadata.is_file():
            shutil.copy2(target_metadata, work_dir / "rtl88wifi-target.txt")

    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "STAGE15-ABI-ACCESSOR-AUDIT.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report = [
        "# Stage 15 — generic Skywalk packet-access ABI audit",
        "",
        f"**Status:** {result['status']}",
        "",
        f"- Input archive: `{archive.name}`",
        f"- Input SHA-256: `{digest}`",
        f"- Platform: `{result['platform']}`",
        f"- Demangler: `{demangler}`",
        f"- Method lists: {len(class_counts)} / {len(TARGET_CLASSES)} classes",
        f"- Required accessor methods with disassembly: {passed} / {len(rows)}",
        "",
        "## Method-list inventory",
        "",
    ]
    for class_name in TARGET_CLASSES:
        report.append(f"- `{class_name}`: {class_counts.get(class_name, 0)} exact symbols")
    report.extend(["", "## Required driver-call audit", "", "| Class | Method | Result | Matched symbols |", "|---|---|---:|---|"])
    for row in rows:
        symbols = ", ".join(f"`{s}`" for s in row["symbols"]) or "—"
        report.append(f"| `{row['class']}` | `{row['method']}` | **{row['status']}** | {symbols} |")
    report.extend([
        "",
        "## Interpretation and safety boundary",
        "",
        "A PASS means the exact method name was present in the matching class method list "
        "and at least one corresponding disassembly reference was collected. It does not "
        "prove argument semantics, locking rules, packet ownership transitions, mapping "
        "lifetime, or that calling the method from a callback is safe.",
        "",
        "This stage is read-only. It does not alter Kext source, register queues, enable "
        "TX/RX callbacks, publish an interface, or start the radio.",
        "",
    ])
    (work_dir / "STAGE15-ABI-ACCESSOR-AUDIT.md").write_text("\n".join(report), encoding="utf-8")

    archive_out = output_dir / "RTL88WiFi-Sequoia-24H32-stage15-packet-accessor-audit.tar.gz"
    output_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_out, "w:gz") as tar:
        tar.add(work_dir, arcname="stage15")
    result["output_archive"] = archive_out.name
    # The archive cannot contain its own checksum. Store the final digest in a
    # sibling sidecar after packaging; keep the embedded JSON self-consistent.
    result.pop("output_sha256", None)
    (work_dir / "STAGE15-ABI-ACCESSOR-AUDIT.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    with tarfile.open(archive_out, "w:gz") as tar:
        tar.add(work_dir, arcname="stage15")
    result["output_sha256"] = sha256_file(archive_out)
    (output_dir / (archive_out.name + ".sha256")).write_text(
        result["output_sha256"] + "  " + archive_out.name + "\n", encoding="utf-8"
    )
    print(f"Stage 15 status: {result['status']}")
    print(f"Stage 14 input SHA-256: {digest}")
    print(f"Accessor methods with disassembly: {passed}/{len(rows)}")
    for row in rows:
        print(f"{row['class']}::{row['method']}: {row['status']}")
    print(f"Stage 15 report: {work_dir / 'STAGE15-ABI-ACCESSOR-AUDIT.md'}")
    print(f"Created Stage 15 archive: {archive_out}")
    print(f"Stage 15 archive SHA-256: {result['output_sha256']}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--archive", type=Path,
        default=Path("build/sequoia-abi-24H32-stage14") /
        "RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz",
    )
    parser.add_argument(
        "--out", type=Path,
        default=Path("build/sequoia-abi-24H32-stage15"),
    )
    parser.add_argument("--demangler", help="Explicit path to c++filt or llvm-cxxfilt")
    args = parser.parse_args()
    try:
        result = audit_archive(args.archive, args.out, args.demangler)
    except (OSError, tarfile.TarError, RuntimeError, ValueError) as exc:
        parser.error(str(exc))
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
