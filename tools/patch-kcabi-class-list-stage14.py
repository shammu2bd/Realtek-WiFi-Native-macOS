#!/usr/bin/env python3
"""Add IOSkywalkMemorySegment to an isolated WTLKcAbi dump.py copy for Stage 14.

The upstream dump.py has an explicit CLASSES allow-list. Stage 14 needs the
MemorySegment vtable/method report, but the default allow-list omits the class.
This helper patches only the temporary copy made by the Stage 14 collector; it
never edits the user's $HOME/src/kcabi checkout.
"""
from __future__ import annotations
import argparse
import re
from pathlib import Path

CLASS_BLOCK = re.compile(
    r"(?ms)^(?P<indent>[ \t]*)CLASSES[ \t]*=[ \t]*'''(?P<body>.*?)'''\.split\(\)"
)
TARGET_CLASS = "IOSkywalkMemorySegment"
ANCHOR_CLASS = "IOSkywalkPacketBuffer"


def patch_dump(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"dump.py is not a regular file: {path}")
    source = path.read_text(encoding="utf-8")
    matches = list(CLASS_BLOCK.finditer(source))
    if len(matches) != 1:
        raise ValueError(
            f"expected exactly one CLASSES = '''...'''.split() block in {path}; found {len(matches)}"
        )
    match = matches[0]
    classes = match.group("body").split()
    if TARGET_CLASS in classes:
        return False
    if ANCHOR_CLASS not in classes or "IOSkywalkPacketBufferPool" not in classes:
        raise ValueError(
            "kcabi dump.py class list does not contain the expected generic Skywalk packet-buffer anchors"
        )

    # Keep the addition beside the packet-buffer-related class names.
    new_body, count = re.subn(
        rf"(\b{re.escape(ANCHOR_CLASS)}\b)",
        rf"\1 {TARGET_CLASS}",
        match.group("body"),
        count=1,
    )
    if count != 1 or TARGET_CLASS not in new_body.split():
        raise ValueError("could not insert IOSkywalkMemorySegment into kcabi CLASSES list")

    updated_block = (
        match.group("indent")
        + "CLASSES = '''"
        + new_body
        + "'''.split()"
    )
    updated = source[:match.start()] + updated_block + source[match.end():]
    path.write_text(updated, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", required=True, type=Path, help="dump.py in the temporary kcabi staging copy")
    args = parser.parse_args()
    try:
        changed = patch_dump(args.dump)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    action = "added" if changed else "already present"
    print(f"Stage 14 kcabi class list: {TARGET_CLASS} {action}")
    print(f"Patched temporary copy only: {args.dump}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
