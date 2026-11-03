#!/usr/bin/env python3
"""Source-level guard for the isolated Sequoia 24H32 WCL ABI surface.

This checks method-name coverage and ABI size assertions only. Xcode's real
SDK compile remains the authoritative signature/vtable check.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
abi_path = root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp"
impl_path = root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"
make_path = root / "driver/RTL88WiFi/Makefile"
abi = abi_path.read_text()
impl = impl_path.read_text()
make = make_path.read_text()

start = abi.index("class IO80211InfraProtocol")
end = abi.index("static_assert(sizeof(IO80211InfraProtocol)", start)
protocol = abi[start:end]
required = set(re.findall(r"RTW88_WCL_ABI_METHOD\(\s*(\w+)", protocol))
for line in protocol.splitlines():
    if "= 0;" in line:
        match = re.search(r"\b(\w+)\s*\(", line)
        if match and match.group(1) != "RTW88_WCL_ABI_METHOD":
            required.add(match.group(1))

implemented = set(re.findall(r"RTW88_WCL_UNSUPPORTED\(\s*(\w+)", impl))
for line in impl.splitlines():
    if "override" in line:
        match = re.search(r"\b(\w+)\s*\(", line)
        if match:
            implemented.add(match.group(1))

missing = sorted(required - implemented)
assert not missing, f"Unimplemented IO80211InfraProtocol methods: {missing}"
assert impl.count("setWCL_LINK_STATE_UPDATE(") == 1, "WCL link-state selector declaration duplicated/missing"
infra_source = (root / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp").read_text()
assert "request.type != APPLE80211_SCAN_TYPE_ACTIVE" in infra_source
assert "request.type != APPLE80211_SCAN_TYPE_FAST" in infra_source
assert "validInformationElements(bss.ies, bss.ies_len)" in infra_source
assert "if (!_activeJoinGeneration || _connectNotified" in infra_source

for cls, size in (
    ("IO80211SkywalkInterface", "0x118"),
    ("IO80211InfraInterface", "0x120"),
    ("IO80211InfraProtocol", "0x120"),
):
    expected = f"static_assert(sizeof({cls}) == {size}"
    assert expected in abi, f"Missing ABI size assertion: {expected}"

assert "WCL24H32_INFRA_OBJ" in make
assert "$(WCL24H32_INFRA_OBJ)" in make
assert "$(WCL24H32_INFRA_OBJ)" not in make.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0], \
       "Native interface object must stay out of the legacy Kext link"

print(f"PASS: {len(required)} pure protocol selectors covered; 24H32 interface sizes asserted; native interface object remains compile-only")
