#!/usr/bin/env python3
"""Stage122 contract test for the read-only runtime diagnostic runner."""

from pathlib import Path
import re
import subprocess

runner_path = Path("Development/stage122-readonly-runtime-diagnostics.sh")
source_path = Path("driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp")
controller_path = Path("driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp")

assert runner_path.is_file(), "Stage122 runner is missing"
assert source_path.is_file(), "Stage121 interface source is missing"
assert controller_path.is_file(), "Stage121 controller source is missing"

runner = runner_path.read_text(encoding="utf-8")
interface_source = source_path.read_text(encoding="utf-8")
controller_source = controller_path.read_text(encoding="utf-8")

assert 'EXPECTED_BRANCH="work/stage122-primary-interface-runtime-diagnostics"' in runner
assert "kmutil showloaded" in runner
assert "ioreg" in runner
assert "log show" in runner
assert "ifconfig -a" in runner
assert "networksetup -listallhardwareports" in runner
assert "system_profiler SPAirPortDataType" in runner

required_runtime_markers = (
    "Apple primary Skywalk interface attached and getter-verified",
    "Apple primary Skywalk interface detached and getter-verified",
    "native 24H32 infrastructure interface registered",
    "native 24H32 infrastructure interface published",
)
for marker in required_runtime_markers:
    assert marker in runner, f"Missing runtime evidence marker: {marker}"

assert "_controller->getPrimarySkywalkInterface()" in interface_source
assert "primary != this" in interface_source
assert "Apple primary Skywalk interface attached and getter-verified" in interface_source
assert "Apple primary Skywalk interface detached and getter-verified" in interface_source
assert "_infraInterface->registerService()" in controller_source

# These executable mutation/activation paths are forbidden in this observer.
forbidden = (
    "sudo ",
    "kextload",
    "kextunload",
    "kextutil",
    "kmutil load",
    "kmutil install",
    "kmutil unload",
    "diskutil ",
    "bless ",
    "nvram ",
    "networksetup -set",
    "ifconfig en",
    "launchctl kickstart",
    "reboot",
    "shutdown ",
)
for token in forbidden:
    assert token not in runner, f"Forbidden mutation/activation token present: {token}"

syntax = subprocess.run(
    ["bash", "-n", str(runner_path)],
    capture_output=True,
    text=True,
    check=False,
)
assert syntax.returncode == 0, syntax.stderr

assert "PRIMARY_INTERFACE_GETTER_VERIFIED" in runner
assert "NOT_OBSERVED" in runner
assert "STAGE122_COLLECTOR_RESULT" in runner
assert "git push origin" in runner

print("STAGE122_SOURCE_CONTRACT=PASS")
print("STAGE122_READ_ONLY_BOUNDARY=PASS")
print("STAGE122_RUNTIME_MARKER_COVERAGE=PASS")
print("STAGE122_SHELL_SYNTAX=PASS")
