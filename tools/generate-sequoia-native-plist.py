#!/usr/bin/env python3
"""Generate the isolated Sequoia native RTL88WiFi bundle Info.plist.

The dependency versions are resolved from the running target Mac. No framework
version is guessed, and the legacy RTL88WiFi.kext template is never modified.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import platform
import plistlib
import subprocess
import sys
from typing import Optional


REQUIRED_SYSTEM = "15.8.1"
REQUIRED_BUILD = "24H32"
REQUIRED_ARCH = "x86_64"

NATIVE_DEPENDENCIES = (
    "com.apple.iokit.IO80211Family",
    "com.apple.iokit.IOSkywalkFamily",
    "com.apple.iokit.IOPCIFamily",
)
SEARCH_ROOTS = (
    pathlib.Path("/System/Library/Extensions"),
    pathlib.Path("/System/Library/DriverExtensions"),
    pathlib.Path("/Library/Extensions"),
)


def system_value(flag: str) -> str:
    try:
        return subprocess.check_output(
            ["/usr/bin/sw_vers", flag], text=True, stderr=subprocess.STDOUT
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"Cannot query target macOS version ({flag}): {exc}")


def find_kext_bundle(bundle_identifier: str) -> Optional[tuple[pathlib.Path, str]]:
    """Resolve one installed kext bundle without descending into nested plugins."""
    for root in SEARCH_ROOTS:
        if not root.is_dir():
            continue
        matches: list[tuple[pathlib.Path, str]] = []
        for current, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [
                name for name in dirs
                if name not in {"Caches", "PlugIns", "Frameworks"}
            ]
            if "Info.plist" not in files or not current.endswith(".kext/Contents"):
                continue
            plist_path = pathlib.Path(current) / "Info.plist"
            try:
                with plist_path.open("rb") as handle:
                    info = plistlib.load(handle)
            except (OSError, plistlib.InvalidFileException, ValueError):
                continue
            if info.get("CFBundleIdentifier") != bundle_identifier:
                continue
            version = info.get("CFBundleVersion") or info.get("OSBundleCompatibleVersion")
            if version is not None and str(version).strip():
                matches.append((plist_path, str(version).strip()))
        if matches:
            # Prefer the sealed System volume if duplicate identifiers exist.
            matches.sort(
                key=lambda item: (
                    0 if str(item[0]).startswith("/System/Library/Extensions/") else 1,
                    str(item[0]),
                )
            )
            return matches[0]
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-plist", required=True, type=pathlib.Path)
    parser.add_argument("--controller-header", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    version = system_value("-productVersion")
    build = system_value("-buildVersion")
    arch = platform.machine()
    if version != REQUIRED_SYSTEM or build != REQUIRED_BUILD or arch != REQUIRED_ARCH:
        raise SystemExit(
            "NATIVE_PLIST_GENERATION_BLOCKED: expected "
            f"macOS {REQUIRED_SYSTEM} ({REQUIRED_BUILD}) {REQUIRED_ARCH}; "
            f"found macOS {version} ({build}) {arch}"
        )

    if not args.base_plist.is_file():
        raise SystemExit(f"Legacy source plist not found: {args.base_plist}")
    if not args.controller_header.is_file():
        raise SystemExit(f"Native controller header not found: {args.controller_header}")
    header_text = args.controller_header.read_text(encoding="utf-8", errors="replace")
    if "class RTW88WCLController" not in header_text:
        raise SystemExit("Native controller class declaration was not found.")

    with args.base_plist.open("rb") as handle:
        base = plistlib.load(handle)

    bundle_id = base.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise SystemExit("Legacy source plist has no valid CFBundleIdentifier.")
    if base.get("CFBundleExecutable") != "RTL88WiFi":
        raise SystemExit("Unexpected legacy executable; refusing to derive native metadata.")

    personalities = base.get("IOKitPersonalities") or {}
    if not any(
        isinstance(personality, dict) and personality.get("IOClass") == "RTL88WiFi"
        for personality in personalities.values()
    ):
        raise SystemExit("Could not identify the original RTL88WiFi PCI personalities.")

    resolved: dict[str, str] = {}
    for identifier in NATIVE_DEPENDENCIES:
        match = find_kext_bundle(identifier)
        if match is None:
            raise SystemExit(
                f"Cannot resolve installed Apple dependency {identifier}; "
                "no guessed version will be written."
            )
        resolved[identifier] = match[1]

    libraries = dict(base.get("OSBundleLibraries") or {})
    libraries.pop("com.apple.iokit.IO80211FamilyLegacy", None)
    for identifier, exact_version in resolved.items():
        libraries[identifier] = exact_version

    # Keep the network family entry aligned to the target if it is present.
    networking_id = "com.apple.iokit.IONetworkingFamily"
    if networking_id in libraries:
        match = find_kext_bundle(networking_id)
        if match is not None:
            libraries[networking_id] = match[1]

    if "com.apple.iokit.IO80211FamilyLegacy" in libraries:
        raise SystemExit("Native plist must not depend on IO80211FamilyLegacy.")
    for identifier in NATIVE_DEPENDENCIES:
        if identifier not in libraries:
            raise SystemExit(f"Required native dependency missing: {identifier}")

    native = dict(base)
    native["CFBundleIdentifier"] = bundle_id
    native["CFBundleExecutable"] = "RTL88WiFiNative"
    native["CFBundleName"] = "RTL88WiFi Native"
    native["LSMinimumSystemVersion"] = "15.0"
    native["OSBundleLibraries"] = libraries
    native["IOKitPersonalities"] = {
        "RTL88WiFiNative_8821CE": {
            "CFBundleIdentifier": bundle_id,
            "IOClass": "RTW88WCLController",
            "IOMatchCategory": "IODefaultMatchCategory",
            "IOProbeScore": 5000,
            "IOProviderClass": "IOPCIDevice",
            "IOPCIMatch": "0xC82110EC 0xB82110EC",
        }
    }
    native["OSBundleRequired"] = "Network-Root"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(native, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    temporary.replace(args.output)

    print(f"NATIVE_PLIST_GENERATION=PASS")
    print(f"TARGET=macOS {version} ({build}) {arch}")
    print(f"CFBundleIdentifier={bundle_id}")
    print("CFBundleExecutable=RTL88WiFiNative")
    for identifier in NATIVE_DEPENDENCIES:
        print(f"NATIVE_DEPENDENCY={identifier} {resolved[identifier]}")
    print("IO80211FamilyLegacy=ABSENT")
    print("PERSONALITY=RTW88WCLController PCI=0xC82110EC 0xB82110EC")
    print(f"OUTPUT={args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        print(f"NATIVE_PLIST_GENERATION_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
