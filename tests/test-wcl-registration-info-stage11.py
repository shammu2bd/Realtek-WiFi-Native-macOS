#!/usr/bin/env python3
"""Stage 11 guardrails for the opaque 24H32 RegistrationInfo builder."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KEXT = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
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

# Stage 108 now uses the audited builder in a registration transaction.
# The controller may probe the RTW88 core to obtain the eFuse MAC, but it must
# keep the PCI interrupt gate closed until the interface registration commits.
controller = CONTROLLER.read_text()
queues = QUEUES.read_text()
infra_code = re.sub(r"/\*.*?\*/|//[^\n]*", "", infra_cpp, flags=re.S)
start_start = infra_code.index("bool RTW88WCLInfraInterface::start(")
start_end = infra_code.index("IOReturn RTW88WCLInfraInterface::shutdownForController(", start_start)
start_code = infra_code[start_start:start_end]
assert "prepareRegistrationInfo(address)" in start_code
assert "beginRegistrationTransaction()" in start_code
assert "registerInfraEthernetInterface(" in start_code
assert "commitRegistrationTransaction()" in start_code
assert start_code.index("beginRegistrationTransaction()") < start_code.index("registerInfraEthernetInterface(")
assert start_code.index("registerInfraEthernetInterface(") < start_code.index("commitRegistrationTransaction()")
assert "abortRegistrationTransaction()" in start_code

shutdown_start = infra_code.index("IOReturn RTW88WCLInfraInterface::shutdownForController()")
shutdown_end = infra_code.index("void RTW88WCLInfraInterface::stop(", shutdown_start)
shutdown_code = infra_code[shutdown_start:shutdown_end]
assert "beginDeregistrationTransaction()" in shutdown_code
assert "deregisterEthernetInterface(0)" in shutdown_code
assert "finishDeregistrationTransaction()" in shutdown_code
assert "abortDeregistrationTransaction()" in shutdown_code

controller_code = re.sub(r"/\*.*?\*/|//[^\n]*", "", controller, flags=re.S)
controller_start = controller_code.index("bool RTW88WCLController::start(")
controller_end = controller_code.index("void RTW88WCLController::stop(", controller_start)
controller_start_code = controller_code[controller_start:controller_end]
assert controller_start_code.index("_radio->start()") < controller_start_code.index("_infraInterface->start(this)")
assert controller_start_code.index("_infraInterface->start(this)") < controller_start_code.index("_infraInterface->registerService()")
assert controller_start_code.index("_infraInterface->registerService()") < controller_start_code.index("_pciBackend->setRadioRunning(true)")
assert "_infraInterface->shutdownForController()" in controller_code
release_start = controller_code.index("IOReturn RTW88WCLController::releaseNativeResources()")
release_end = controller_code.index("void RTW88WCLController::free()", release_start)
release_code = controller_code[release_start:release_end]
assert release_code.index("_infraInterface->shutdownForController()") < release_code.index("_skywalkQueues->destroyQueues()")
assert "RTW88WCLRegistrationTransaction::Transaction _registrationTransaction" in (KEXT / "RTW88WCLSkywalkQueues.hpp").read_text()
assert "_registrationTransaction.ownsQueues()" in queues
assert "setRegistered(bool registered)" not in queues
assert "IOSkywalkQueueSet::createWithQueues" not in queues
assert "IOSkywalkLogicalLinkInfo" not in queues

# Compile and execute the Stage11 payload-layout test plus the Stage108
# registration state-machine test using the host compiler.
compiler = os.environ.get("CXX", "c++")
compiler_flags = ["-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2"]
if os.uname().sysname == "Darwin":
    sdkroot = os.environ.get("SDKROOT")
    if not sdkroot:
        sdkroot = subprocess.check_output(
            ["xcrun", "--show-sdk-path"], text=True
        ).strip()
    compiler_flags.extend(["-stdlib=libc++", "-isysroot", sdkroot])
tests = (
    (ROOT / "tests/wcl_registration_info_stage11_test.cpp", "registration-info-test"),
    (ROOT / "tests/wcl_registration_transaction_stage108_test.cpp", "registration-transaction-test"),
)
with tempfile.TemporaryDirectory(prefix="rtl88wcl-registration-") as tmp:
    for source, name in tests:
        binary = Path(tmp) / name
        subprocess.run(
            [compiler, *compiler_flags, str(source), "-o", str(binary)],
            check=True,
        )
        subprocess.run([str(binary)], check=True)

print("PASS: RegistrationInfo buffer is 0x130 bytes and 8-byte aligned")
print("PASS: builder follows initRegistrationInfo(option=1, size=0x130)")
print("PASS: Stage108 registration/deregistration uses explicit queue-owner state")
print("PASS: controller registers and publishes the interface before PCI interrupt activation")
