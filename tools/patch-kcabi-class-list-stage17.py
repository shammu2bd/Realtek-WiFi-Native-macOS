#!/usr/bin/env python3
"""Patch the temporary WTLKcAbi dump to collect only the Stage 17 target methods."""
from __future__ import annotations
import argparse
import re
from pathlib import Path

REQUIRED_CLASSES = (
    "IOSkywalkPacketQueue", "IOSkywalkPacketBufferPool", "IOSkywalkMemorySegment",
    "IOSkywalkPacketBuffer", "IOSkywalkPacket", "IOSkywalkNetworkPacket",
    "IOSkywalkRxSubmissionQueue", "IOSkywalkRxCompletionQueue",
    "IOSkywalkTxSubmissionQueue", "IOSkywalkTxCompletionQueue",
    "IOSkywalkInterface", "IOSkywalkNetworkInterface", "IOSkywalkEthernetInterface",
)


def patch(path: Path) -> bool:
    if not path.is_file():
        raise ValueError(f"kcabi dump.py not found: {path}")
    source = path.read_text(encoding="utf-8")
    class_match = re.search(r"(?m)^CLASSES\s*=\s*'''(.*?)'''.split\(\)", source, re.S)
    if not class_match:
        raise ValueError("Unexpected kcabi dump.py layout: CLASSES triple-quoted block not found")
    tokens = class_match.group(1).split()
    missing = [name for name in REQUIRED_CLASSES if name != "IOSkywalkMemorySegment" and name not in tokens]
    if missing:
        raise ValueError("kcabi class list is missing required queue/ownership classes: " + ", ".join(missing))

    changed = False
    if "IOSkywalkMemorySegment" not in tokens:
        name = "IOSkywalkPacketBuffer"
        if tokens.count(name) != 1:
            raise ValueError("Expected exactly one IOSkywalkPacketBuffer token in kcabi class list")
        body = re.sub(r"(\bIOSkywalkPacketBuffer\b)", r"\1 IOSkywalkMemorySegment", class_match.group(1), count=1)
        source = source[:class_match.start(1)] + body + source[class_match.end(1):]
        changed = True
        class_match = re.search(r"(?m)^CLASSES\s*=\s*'''(.*?)'''.split\(\)", source, re.S)

    target_block = "\nSTAGE17_TARGET_CLASSES = (\n" + "".join(f"    {name!r},\n" for name in REQUIRED_CLASSES) + ")\n"
    if "STAGE17_TARGET_CLASSES = (" not in source:
        source = source[:class_match.end()] + target_block + source[class_match.end():]
        changed = True
    else:
        target_match = re.search(r"(?m)^STAGE17_TARGET_CLASSES\s*=\s*\((.*?)^\)\s*$", source, re.S)
        if not target_match:
            raise ValueError("Malformed STAGE17_TARGET_CLASSES allow-list")
        names = tuple(re.findall(r"['\"]([^'\"]+)['\"]", target_match.group(1)))
        if names != REQUIRED_CLASSES:
            raise ValueError("STAGE17_TARGET_CLASSES does not exactly match the required 13 classes")

    marker = "    # STAGE17: executable methods for the exact 13 target classes only"
    required_body = (
        "    stage17_executable_methods = []\n"
        "    for cls in STAGE17_TARGET_CLASSES:\n"
        "        for _method_va, method_name in kc.methods(cls):\n"
        "            if is_code(kc, method_name):\n"
        "                funcs[method_name] = None\n"
        "                stage17_executable_methods.append((cls, method_name))\n"
        "    stage17_executable_methods = sorted(set(stage17_executable_methods))\n"
        "    write(os.path.join(out, 'stage17-executable-methods.txt'),\n"
        "          ['# class\\tsymbol'] + ['%s\\t%s' % row for row in stage17_executable_methods])\n"
    )
    if marker not in source:
        # Replace the previous Stage 17 implementation if an older overlay already patched this file.
        old_body = (
            "    # STAGE17: include every executable class method in the disassembly set\n"
            "    # The reference dump alone only covers prior-stage methods and is not a complete class inventory.\n"
            "    stage17_executable_methods = []\n"
            "    for cls in CLASSES:\n"
            "        for _method_va, method_name in kc.methods(cls):\n"
            "            if is_code(kc, method_name):\n"
            "                funcs[method_name] = None\n"
            "                stage17_executable_methods.append((cls, method_name))\n"
            "    stage17_executable_methods = sorted(set(stage17_executable_methods))\n"
            "    write(os.path.join(out, 'stage17-executable-methods.txt'),\n"
            "          ['# class\\tsymbol'] + ['%s\\t%s' % row for row in stage17_executable_methods])\n"
        )
        new_body = (
            marker + "\n"
            "    # CLASSES remains broad for upstream vtable/size collection; this manifest is intentionally narrow.\n"
            + required_body
        )
        if old_body in source:
            source = source.replace(old_body, new_body, 1)
            changed = True
        else:
            sentinel = "    funcs = {}\n    for cls in CLASSES:\n        for kind in ('C1Ev', 'C2Ev'):\n"
            if source.count(sentinel) != 1:
                raise ValueError("Unexpected kcabi dump.py layout: functions initialization block not found exactly once")
            injected = "    funcs = {}\n" + new_body + "    for cls in CLASSES:\n        for kind in ('C1Ev', 'C2Ev'):\n"
            source = source.replace(sentinel, injected, 1)
            changed = True
    else:
        if required_body not in source:
            raise ValueError("Stage 17 target-class executable-method implementation is incomplete")

    # Final fail-closed verification: exact allow-list and loop are both required.
    class_match = re.search(r"(?m)^CLASSES\s*=\s*'''(.*?)'''.split\(\)", source, re.S)
    target_match = re.search(r"(?m)^STAGE17_TARGET_CLASSES\s*=\s*\((.*?)^\)\s*$", source, re.S)
    if not class_match or not target_match:
        raise ValueError("Patched kcabi dump.py is missing a class list")
    if any(name not in class_match.group(1).split() for name in REQUIRED_CLASSES):
        raise ValueError("Patched kcabi class list failed verification")
    if tuple(re.findall(r"['\"]([^'\"]+)['\"]", target_match.group(1))) != REQUIRED_CLASSES:
        raise ValueError("Patched Stage 17 target-class allow-list failed verification")
    if marker not in source or "for cls in STAGE17_TARGET_CLASSES:" not in source:
        raise ValueError("Patched dump.py does not restrict Stage 17 inventory to target classes")
    if changed:
        path.write_text(source, encoding="utf-8")
    return changed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dump_py", type=Path)
    args = ap.parse_args()
    try:
        changed = patch(args.dump_py)
    except (OSError, ValueError) as exc:
        ap.error(str(exc))
    print("Stage 17 kcabi patch: " + ("updated temporary dump.py" if changed else "already complete"))
    print("Verified classes: " + ", ".join(REQUIRED_CLASSES))
    print("Verified: Stage 17 executable-method manifest contains only the 13 target classes")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
