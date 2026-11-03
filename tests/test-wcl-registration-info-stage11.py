#!/usr/bin/env python3
"""Stage 11 guardrails for the opaque 24H32 RegistrationInfo builder."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLRegistrationInfo.hpp"
INFRA_HPP = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp"
INFRA_CPP = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp"
CONTROLLER = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp"
QUEUES = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLSkywalkQueues.cpp"

header = HEADER.read_text()
infra_hpp = INFRA_HPP.read_text()
infra_cpp = INFRA_CPP.read_text()

# Opaque storage must match the exact size/alignment and the Apple-producer
# writes established by the 24H32 disassembly.
for token in (
    "constexpr size_t kSize = 0x130;",
    "constexpr uint64_t kVersionAndSize = 0x0000013000000001ULL;",
    "constexpr size_t kOpaqueSlot0C = 0x0c;",
    "constexpr size_t kOpaqueSlot14 = 0x14;",
    "constexpr size_t kOpaqueSlot24 = 0x24;",
    "constexpr size_t kOpaqueSlot40 = 0x40;",
    "constexpr size_t kHardwareAddress = 0x108;",
    "constexpr uint32_t kOpaqueValue0C = 3;",
    "constexpr uint32_t kOpaqueValue14 = 2;",
    "constexpr uint64_t kOpaqueValue24 = 0x0000008000000080ULL;",
    "constexpr uint32_t kOpaqueValue40 = 0;",
    "struct alignas(8) Storage",
    "static_assert(sizeof(Storage) == kSize",
    "static_assert(alignof(Storage) >= 8",
):
    assert token in header, f"missing RegistrationInfo ABI guard: {token}"

# The interface keeps the payload alive in its own object and uses Apple's
# exact initializer before applying the small audited caller-side delta.
assert "RTW88WCLRegistrationInfo24H32::Storage _registrationInfo = {};" in infra_hpp
assert "bool _registrationInfoPrepared = false;" in infra_hpp
assert infra_cpp.count("clearRegistrationInfo();") >= 4  # init overloads, failures, stop/free
builder_start = infra_cpp.index("bool RTW88WCLInfraInterface::prepareRegistrationInfo(")
builder_end = infra_cpp.index("bool RTW88WCLInfraInterface::start(", builder_start)
builder = infra_cpp[builder_start:builder_end]
assert "initRegistrationInfo(info, 1, sizeof(_registrationInfo.bytes))" in builder
assert "applyAppleProducerWrites(_registrationInfo, address.octet)" in builder
assert "matchesApple24H32Template(_registrationInfo, address.octet)" in builder
assert builder.index("initRegistrationInfo(") < builder.index("applyAppleProducerWrites(")
assert builder.index("matchesApple24H32Template(") < builder.index("_registrationInfoPrepared = true;")

# Stage 11 must not use the newly built payload to register queues or publish
# a BSD interface. Keep the start path fail-closed and registration calls fenced.
def strip_comments(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"//[^\n]*", "", source)

infra_code = strip_comments(infra_cpp)
controller_code = strip_comments(CONTROLLER.read_text())
queue_code = strip_comments(QUEUES.read_text())
start_start = infra_code.index("bool RTW88WCLInfraInterface::start(")
start_end = infra_code.index("void RTW88WCLInfraInterface::stop(", start_start)
start_code = infra_code[start_start:start_end]
assert "return false;" in start_code
assert "prepareRegistrationInfo(" not in start_code
for code in (infra_code, controller_code, queue_code):
    assert not re.search(r"(?:->|\.)\s*register(?:Infra)?EthernetInterface\s*\(", code)

# Compile and execute the header-level layout/write-preservation test.
compiler = os.environ.get("CXX", "c++")
with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage11-") as tmp:
    binary = Path(tmp) / "registration-info-test"
    subprocess.run(
        [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2",
         str(ROOT / "tests/wcl_registration_info_stage11_test.cpp"), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True)

print("PASS: RegistrationInfo buffer is 0x130 bytes and 8-byte aligned")
print("PASS: builder follows initRegistrationInfo(option=1, size=0x130)")
print("PASS: Apple 24H32 opaque writes are applied without touching other bytes")
print("PASS: payload builder remains disconnected from start/registration")
