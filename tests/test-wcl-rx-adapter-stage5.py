#!/usr/bin/env python3
"""Host stress/source checks for the staged WCL RX mbuf handoff."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
compiler = shutil.which("clang++") or shutil.which("c++")
assert compiler, "clang++ or c++ is required"

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage5-") as temp:
    binary = Path(temp) / "wcl_mbuf_ring_test"
    subprocess.run([
        compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
        "-pthread", str(ROOT / "tests/wcl_mbuf_ring_test.cpp"),
        "-o", str(binary)
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT)

ring = (BASE / "RTW88WCLMbufRing.hpp").read_text()
rx_h = (BASE / "RTW88WCLSkywalkRxAdapter.hpp").read_text()
rx_cpp = (BASE / "RTW88WCLSkywalkRxAdapter.cpp").read_text()
span_h = (BASE / "RTW88WCLPacketSpanValidation.hpp").read_text()
queues_h = (BASE / "RTW88WCLSkywalkQueues.hpp").read_text()
queues_cpp = (BASE / "RTW88WCLSkywalkQueues.cpp").read_text()
controller_h = (BASE / "RTW88WCLController.hpp").read_text()
controller_cpp = (BASE / "RTW88WCLController.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert "static_assert((Capacity & (Capacity - 1)) == 0" in ring
assert "__atomic_compare_exchange_n" in ring
assert "lock-free MPMC ring" in ring
assert "RTW88WCLMbufRing<mbuf_t, kCapacity>" in rx_h
assert "enqueueFrame(mbuf_t packet)" in rx_h
assert "mbuf_pkthdr_len(packet)" in rx_cpp
assert "mbuf_copydata(source, 0, packetLength, destination)" in rx_cpp
assert "mbuf_freem(source)" in rx_cpp
assert "allocatePacket(1, &packet, 1)" in rx_cpp
assert "deallocatePacket(packet)" in rx_cpp
assert "IOSkywalkNetworkPacket" in rx_cpp
assert "getMemorySegmentOffset()" in rx_cpp
assert "RTW88WCLResolvePacketBufferAddress" in rx_cpp
assert "preparedFrames()" in rx_h
assert "kRxBufferSize = 4096" in queues_h
assert "rxOptions.bufferSize = kRxBufferSize" in queues_cpp
assert "rxPacketPool() const" in queues_h
assert "removeEventSource(this)" in rx_cpp
assert "signalWorkAvailable()" in rx_cpp
assert "kDrainBudget = 32" in rx_h
assert "removeEventSource(this)" in rx_cpp
assert "RTW88WCLSkywalkRxAdapter" in controller_h
assert "_rxAdapter->enqueueFrame(packet)" in controller_cpp
assert "allocatePacket(length)" in controller_cpp
assert "_rxAdapter->stop()" in controller_cpp
assert "WCL24H32_RX_ADAPTER_OBJ" in makefile
assert "$(WCL24H32_RX_ADAPTER_OBJ)" not in makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]

# The adapter may allocate/copy a packet, but it must not deliver to an
# unregistered completion queue or invoke private registration entry points.
for forbidden in ("enqueuePackets(", "registerEthernetInterface("):
    assert forbidden not in rx_cpp, forbidden
assert "return self->_stagedRxPackets.push(preparedPacket);" in controller_cpp

with tempfile.TemporaryDirectory(prefix="rtl88wcl-rx-address-") as temp:
    binary = Path(temp) / "wcl_rx_packet_address_test"
    subprocess.run([
        compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
        str(ROOT / "tests/wcl_rx_packet_address_test.cpp"), "-o", str(binary)
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT)

print("PASS: bounded 128-entry MPMC RX mbuf ring; 8 concurrent producers; no loss or duplication")
print("PASS: fragmented-mbuf copy into a pool-backed Skywalk RX packet with bounds checks")
print("PASS: prepared packets transfer into a bounded controller-owned ring")
print("PASS: RX queue registration/delivery remains disabled and native objects remain compile-only")
