#!/usr/bin/env python3
"""Expand the 24H32 kcabi reference with all methods of Skywalk queue/pool classes.

The first kcabi pass provides the class method lists. This helper converts the
selected classes' exact emitted Itanium symbols into a second-pass reference,
so kcabi emits complete function bodies for queue, packet-buffer-pool,
queue-set, and logical-link lifecycle review. It does not infer or rename ABI
members and does not modify the kernel collection.
"""
from __future__ import annotations

import argparse
import re
from collections import OrderedDict
from pathlib import Path

# These are the IOSkywalk classes whose queue and pool lifetimes must be
# reviewed before any registration call is enabled.
TARGET_CLASSES = (
    "IOSkywalkPacketQueue",
    "IOSkywalkPacketBufferPool",
    "IOSkywalkQueueSet",
    "IOSkywalkLogicalLink",
)

# kcabi method-list formatting can vary between builds: some rows are numbered
# address/symbol tuples, while others embed the exact mangled name in a
# descriptive row. Extract only complete Itanium symbol tokens, not prose.
SYMBOL_TOKEN = re.compile(r"(?<![A-Za-z0-9_])(__Z[A-Za-z0-9_]+(?:\.[A-Za-z0-9_.]+)?)")
REFERENCE_ROW = re.compile(r"^#\s+0x[0-9a-fA-F]+\s+(__Z\S+)\s*$")


def is_class_member(symbol: str, class_name: str) -> bool:
    # Itanium member names begin __ZN, optionally followed by CV/ref
    # qualifiers, then the decimal byte length and class name. This excludes
    # symbols that merely mention the class in a parameter type.
    prefix = rf"^__ZN[KVRO]*{len(class_name)}{re.escape(class_name)}(?=\d|E)"
    return re.match(prefix, symbol) is not None


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


def index_class_methods(methods_root: Path, class_name: str) -> list[str]:
    """Recover class-owned symbols from kcabi's symbol index when method rows
    do not carry mangled names. Never synthesize or demangle a symbol.
    """
    found: list[str] = []
    seen: set[str] = set()
    for path in sorted(methods_root.rglob("INDEX.txt")):
        if path.is_symlink() or not path.is_file():
            continue
        for symbol in symbols_in_file(path):
            if is_class_member(symbol, class_name) and symbol not in seen:
                seen.add(symbol)
                found.append(symbol)
    return found


def diagnostic_preview(path: Path, limit: int = 18) -> str:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"<cannot read: {exc}>"
    if not raw.strip():
        return "<empty file>"
    return "\n".join(repr(line) for line in raw.splitlines()[:limit])


def reference_symbols(reference: Path | None) -> set[str]:
    found: set[str] = set()
    if reference is None:
        return found
    if not reference.is_dir():
        raise ValueError(f"reference directory does not exist: {reference}")
    for path in reference.rglob("*.asm.txt"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                match = REFERENCE_ROW.match(line.strip())
                if match:
                    found.add(match.group(1))
    return found


def collect_class_methods(methods_root: Path) -> OrderedDict[str, list[str]]:
    if not methods_root.is_dir():
        raise ValueError(f"methods root does not exist: {methods_root}")

    result: OrderedDict[str, list[str]] = OrderedDict()
    problems: list[str] = []
    for class_name in TARGET_CLASSES:
        candidates = sorted(methods_root.rglob(f"{class_name}.methods.txt"))
        if len(candidates) != 1:
            raise ValueError(
                f"expected exactly one {class_name}.methods.txt under {methods_root}; "
                f"found {len(candidates)}"
            )
        method_file = candidates[0]
        symbols = [sym for sym in symbols_in_file(method_file)
                   if is_class_member(sym, class_name)]
        source = "method list"
        if not symbols:
            symbols = index_class_methods(methods_root, class_name)
            source = "kcabi INDEX.txt fallback"
        if not symbols:
            size = method_file.stat().st_size
            preview = diagnostic_preview(method_file)
            problems.append(
                f"{class_name}: no exact Itanium symbols; method list={method_file} "
                f"({size} bytes); index fallback found 0 class-owned symbols; "
                f"method-list preview:\n{preview}"
            )
            continue
        result[class_name] = symbols
        print(f"{class_name}: {len(symbols)} exact method symbols ({source})")
    if problems:
        raise ValueError("queue/pool method extraction incomplete:\n" + "\n".join(problems))
    return result


def prepare(methods_root: Path, out: Path, reference: Path | None = None) -> OrderedDict[str, list[str]]:
    by_class = collect_class_methods(methods_root)
    symbols = reference_symbols(reference)
    for methods in by_class.values():
        symbols.update(methods)

    out.mkdir(parents=True, exist_ok=True)
    target = out / "rtl88wifi-24H32-skywalk-queue-pool-stage12.asm.txt"
    target.write_text(
        "\n".join(f"# 0x0 {symbol}" for symbol in sorted(symbols)) + "\n",
        encoding="utf-8",
    )
    return by_class


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--methods-root", required=True, type=Path,
                        help="first-pass kcabi 24H32 output directory")
    parser.add_argument("--out", required=True, type=Path,
                        help="second-pass kcabi reference directory")
    parser.add_argument("--reference", type=Path,
                        help="optional seed reference directory to retain prior targets")
    args = parser.parse_args()
    try:
        by_class = prepare(args.methods_root, args.out, args.reference)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    total = 0
    for class_name, symbols in by_class.items():
        total += len(symbols)
        print(f"{class_name}: {len(symbols)} exact method symbols")
    print(f"Stage 12 queue/pool method symbols: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
