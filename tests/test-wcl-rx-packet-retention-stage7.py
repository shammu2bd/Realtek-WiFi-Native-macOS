#!/usr/bin/env python3
"""Stage 7 checks for bounded retained RX packet ownership and safe recycle."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
compiler = shutil.which("clang++") or shutil.which("c++")
assert compiler, "clang++ or c++ is required"

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage7-") as temp:
    binary = Path(temp) / "wcl_mbuf_ring_test"
    subprocess.run([
        compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
        "-pthread", str(ROOT / "tests/wcl_mbuf_ring_test.cpp"),
        "-o", str(binary)
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT)

header = (BASE / "RTW88WCLController.hpp").read_text()
source = (BASE / "RTW88WCLController.cpp").read_text()
ring = (BASE / "RTW88WCLMbufRing.hpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert '#include "RTW88WCLMbufRing.hpp"' in header
assert "kStagedRxPacketCapacity = 128" in header
assert "RTW88WCLMbufRing<IOSkywalkPacket *, kStagedRxPacketCapacity> _stagedRxPackets" in header
assert "_stagedRxPackets.reset()" in source
assert "return self->_stagedRxPackets.push(preparedPacket);" in source
assert "IOReturn RTW88WCLController::recycleStagedRxPackets()" in source
recycle = source[source.index("IOReturn RTW88WCLController::recycleStagedRxPackets"):
                 source.index("bool RTW88WCLController::stagedRxFrame")]
assert "_skywalkQueues->rxPacketPool()" in recycle
assert "pool->deallocatePacket(packet)" in recycle
assert "disposalRequired = true" in recycle
assert "pool->disposeAllPackets()" in recycle

release = source[source.index("void RTW88WCLController::releaseNativeResources()"):
                 source.index("void RTW88WCLController::free()")]
ordered = ("_rxAdapter->stop()", "recycleStagedRxPackets()", "_skywalkQueues->destroyQueues()")
pos = [release.index(item) for item in ordered]
assert pos == sorted(pos), f"RX ownership teardown order incorrect: {list(zip(ordered, pos))}"
assert "does not allocate after reset()" in ring
assert "failed push leaves ownership with the caller" in ring
assert "$(KEXT_SRC)/wcl24h32/RTW88WCLMbufRing.hpp" in makefile
assert "bounded RX packet owner; compile-only" in makefile
link_rule = makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]
assert "WCL24H32_CONTROLLER_OBJ" not in link_rule
for forbidden in ("enqueuePackets(", "registerEthernetInterface("):
    assert forbidden not in source, forbidden

print("PASS: 128-entry bounded native RX packet ownership ring")
print("PASS: MPMC pointer ring wrap and 48,000-item concurrent stress")
print("PASS: pool disposal safely handles packet recycle errors after quiescence")
print("PASS: RX adapter stops, retained packets recycle, then pools release")
print("PASS: registration/delivery remain fenced; native controller stays compile-only")
