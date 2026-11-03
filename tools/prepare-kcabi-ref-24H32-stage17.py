#!/usr/bin/env python3
"""Build the exact reference set for Stage 17 RX/TX queue lifecycle methods."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
import tarfile
from collections import OrderedDict
from pathlib import Path

TARGET_CLASSES = (
    "IOSkywalkPacketQueue",
    "IOSkywalkPacketBufferPool",
    "IOSkywalkMemorySegment",
    "IOSkywalkPacketBuffer",
    "IOSkywalkPacket",
    "IOSkywalkNetworkPacket",
    "IOSkywalkRxSubmissionQueue",
    "IOSkywalkRxCompletionQueue",
    "IOSkywalkTxSubmissionQueue",
    "IOSkywalkTxCompletionQueue",
    "IOSkywalkInterface",
    "IOSkywalkNetworkInterface",
    "IOSkywalkEthernetInterface",
)
SYMBOL_TOKEN = re.compile(r"(?<![A-Za-z0-9_])(__Z[A-Za-z0-9_]+(?:\.[A-Za-z0-9_.]+)?)")
INDEX_ROW = re.compile(r"^\s*0x[0-9a-fA-F]+\t[^\t]*\t(__Z\S+)\t")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_class_member(symbol: str, class_name: str) -> bool:
    prefix = rf"^__ZN[KVRO]*{len(class_name)}{re.escape(class_name)}(?=\d|E)"
    return re.match(prefix, symbol) is not None


def safe_tar_members(tf: tarfile.TarFile):
    members = tf.getmembers()
    if not members:
        raise ValueError("Stage 14 archive is empty")
    for member in members:
        path = Path(member.name)
        if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
            raise ValueError(f"Unsafe Stage 14 archive member: {member.name}")
    return members


def read_member(tf: tarfile.TarFile, member: tarfile.TarInfo) -> str:
    stream = tf.extractfile(member)
    if stream is None:
        raise ValueError(f"Unable to read archive member: {member.name}")
    return stream.read().decode("utf-8", "replace")


def prepare(stage14_archive: Path, out: Path) -> dict:
    if not stage14_archive.is_file():
        raise ValueError(f"Stage 14 archive not found: {stage14_archive}")
    by_name: dict[str, list[tarfile.TarInfo]] = {}
    method_lists: dict[str, list[str]] = {}
    previous_symbols: list[str] = []
    stage14_kc_sha = None

    with tarfile.open(stage14_archive, "r:gz") as tf:
        members = safe_tar_members(tf)
        for member in members:
            if not member.isfile():
                continue
            name = Path(member.name).name
            if name.endswith(".methods.txt"):
                by_name.setdefault(name, []).append(member)
            elif name == "INDEX.txt" and "/asm/" in ("/" + member.name):
                for line in read_member(tf, member).splitlines():
                    m = INDEX_ROW.match(line)
                    if m:
                        previous_symbols.append(m.group(1))
            elif name == "source.json":
                try:
                    source = json.loads(read_member(tf, member))
                    if source.get("build") == "24H32":
                        stage14_kc_sha = source.get("sha256")
                except json.JSONDecodeError:
                    pass

        all_symbols: OrderedDict[str, None] = OrderedDict()
        class_counts: dict[str, int] = {}
        missing_lists: list[str] = []
        for class_name in TARGET_CLASSES:
            file_name = class_name + ".methods.txt"
            candidates = by_name.get(file_name, [])
            if len(candidates) != 1:
                missing_lists.append(f"{class_name}: expected one {file_name}; found {len(candidates)}")
                continue
            symbols = [s for s in SYMBOL_TOKEN.findall(read_member(tf, candidates[0]))
                       if is_class_member(s, class_name)]
            # Preserve first-seen order and de-duplicate exact Itanium symbols.
            unique = list(OrderedDict((s, None) for s in symbols))
            if not unique:
                missing_lists.append(f"{class_name}: method list contained no exact class-owned Itanium symbols")
                continue
            class_counts[class_name] = len(unique)
            for symbol in unique:
                all_symbols.setdefault(symbol, None)
        if missing_lists:
            raise ValueError("Stage 17 queue/ownership method inventory incomplete:\n" + "\n".join(missing_lists))

        for symbol in previous_symbols:
            all_symbols.setdefault(symbol, None)

    if not stage14_kc_sha:
        raise ValueError("Stage 14 source.json with 24H32 kernel-collection SHA-256 was not found")

    out.mkdir(parents=True, exist_ok=True)
    ref_file = out / "rtl88wifi-24H32-queue-ownership-stage17.asm.txt"
    ref_file.write_text("\n".join(f"# 0x0 {symbol}" for symbol in sorted(all_symbols)) + "\n",
                        encoding="utf-8")
    manifest = {
        "stage": 17,
        "target": "macOS 15.8.1 (24H32), x86_64",
        "stage14_archive": stage14_archive.name,
        "stage14_archive_sha256": sha256_file(stage14_archive),
        "kernel_collection_sha256": stage14_kc_sha,
        "target_classes": list(TARGET_CLASSES),
        "class_method_counts": class_counts,
        "target_class_method_symbol_count": sum(class_counts.values()),
        "previous_stage14_disassembly_symbols": len(set(previous_symbols)),
        "reference_symbol_count": len(all_symbols),
        "reference_file": ref_file.name,
    }
    (out / "STAGE17-METHOD-MANIFEST.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("Stage 17 method inventory:")
    for name in TARGET_CLASSES:
        print(f"  {name}: {class_counts[name]} exact method symbols")
    print(f"Stage 17 target method symbols: {manifest['target_class_method_symbol_count']}")
    print(f"Stage 17 combined reference symbols: {manifest['reference_symbol_count']}")
    print(f"Stage 14 kernel collection SHA-256: {stage14_kc_sha}")
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage14-archive", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    try:
        prepare(args.stage14_archive, args.out)
    except (OSError, ValueError, tarfile.TarError) as exc:
        ap.error(str(exc))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
