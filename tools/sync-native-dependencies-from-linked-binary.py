#!/usr/bin/env python3
"""Synchronize native kext OSBundleLibraries from the linked Mach-O's kmutil view.

Run after linking and assembling the bundle. This intentionally derives the
dependency dictionary from the executable rather than copying legacy metadata.
It never signs, installs, loads, or changes EFI state.
"""
from __future__ import annotations

import argparse
import pathlib
import plistlib
import subprocess
import sys
from typing import Callable

REQUIRED = {
    "com.apple.iokit.IO80211Family",
    "com.apple.iokit.IOSkywalkFamily",
    "com.apple.iokit.IOPCIFamily",
    "com.apple.iokit.IONetworkingFamily",
}
FORBIDDEN = {"com.apple.iokit.IO80211FamilyLegacy"}


def parse_kmutil_libraries(output: str) -> dict[str, str]:
    """Parse kmutil's XML plist, tolerating its non-XML status preamble."""
    marker = output.find("<plist")
    if marker < 0:
        raise ValueError("kmutil libraries output contains no plist document")
    start = output.rfind("<?xml", 0, marker)
    if start < 0:
        start = marker
    document = output[start:]
    parsed = plistlib.loads(document.encode("utf-8"))
    libraries = parsed.get("OSBundleLibraries") if isinstance(parsed, dict) else None
    if not isinstance(libraries, dict) or not libraries:
        raise ValueError("kmutil output has no non-empty OSBundleLibraries dictionary")
    normalized: dict[str, str] = {}
    for identifier, version in libraries.items():
        if not isinstance(identifier, str) or not isinstance(version, (str, int, float)):
            raise ValueError(f"invalid dependency entry: {identifier!r}={version!r}")
        value = str(version).strip()
        if not value:
            raise ValueError(f"empty dependency version for {identifier}")
        normalized[identifier] = value
    missing = sorted(REQUIRED - normalized.keys())
    forbidden = sorted(FORBIDDEN & normalized.keys())
    if missing:
        raise ValueError("linked executable is missing required dependencies: " + ", ".join(missing))
    if forbidden:
        raise ValueError("linked executable unexpectedly depends on legacy framework: " + ", ".join(forbidden))
    return normalized


def synchronize(bundle: pathlib.Path, runner: Callable = subprocess.run) -> dict[str, str]:
    plist_path = bundle / "Contents" / "Info.plist"
    executable_name = None
    with plist_path.open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info.get("CFBundleExecutable")
    if executable_name != "RTL88WiFiNative":
        raise ValueError(f"unexpected CFBundleExecutable: {executable_name!r}")
    binary = bundle / "Contents" / "MacOS" / executable_name
    if not binary.is_file():
        raise ValueError(f"linked executable not found: {binary}")
    result = runner(
        ["/usr/bin/kmutil", "libraries", "--bundle-path", str(bundle), "--xml"],
        check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"kmutil libraries failed ({result.returncode}): {result.stderr.strip()}"
        )
    libraries = parse_kmutil_libraries(result.stdout)
    info["OSBundleLibraries"] = libraries
    temporary = plist_path.with_suffix(".plist.stage113.tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    temporary.replace(plist_path)
    return libraries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=pathlib.Path)
    args = parser.parse_args()
    libraries = synchronize(args.bundle)
    print("STAGE113_DEPENDENCY_SYNC=PASS")
    print(f"EXECUTABLE={args.bundle / 'Contents/MacOS/RTL88WiFiNative'}")
    for identifier, version in sorted(libraries.items()):
        print(f"LINKED_DEPENDENCY={identifier} {version}")
    print("IO80211FamilyLegacy=ABSENT")
    print(f"PLIST={args.bundle / 'Contents/Info.plist'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, plistlib.InvalidFileException, ValueError, RuntimeError) as exc:
        print(f"STAGE113_DEPENDENCY_SYNC=FAIL: {exc}", file=sys.stderr)
        raise SystemExit(2)
