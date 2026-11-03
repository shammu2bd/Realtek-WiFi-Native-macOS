#!/usr/bin/env python3
"""Host tests/source guard for the staged Skywalk -> mbuf TX adapter."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
compiler = shutil.which("clang++") or shutil.which("c++")
assert compiler, "clang++ or c++ is required"

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage4-") as temp:
    binary = Path(temp) / "wcl_tx_completion_slots_test"
    subprocess.run([
        compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
        "-pthread", str(ROOT / "tests/wcl_tx_completion_slots_test.cpp"),
        "-o", str(binary)
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT)

kext = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
adapter_h = (kext / "RTW88WCLSkywalkTxAdapter.hpp").read_text()
adapter_cpp = (kext / "RTW88WCLSkywalkTxAdapter.cpp").read_text()
queues_cpp = (kext / "RTW88WCLSkywalkQueues.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert "RTW88WCLResolveEthernetTxPacket" in adapter_cpp
assert "mbuf_allocpacket(MBUF_DONTWAIT" in adapter_cpp
assert "mbuf_copyback(mbuf, 0, length, bytes, MBUF_DONTWAIT)" in adapter_cpp
assert "outputPacketWithCompletion" in adapter_cpp
assert "TicketPool::complete(ticket, transmitted)" in adapter_cpp
assert "drainCompletions" in adapter_cpp
assert "No Skywalk API" in adapter_cpp
assert "kIOReturnNotReady" in queues_cpp, "queue callback must remain fail-closed"
assert "WCL24H32_TX_ADAPTER_OBJ" in makefile
assert "$(WCL24H32_TX_ADAPTER_OBJ)" not in makefile.split("AIRPORT_ALL_OBJS :=", 1)[1].split("\n", 1)[0]

print("PASS: 128-slot TX completion pool; concurrent callbacks; exactly-once drain")
print("PASS: bounded/non-blocking mbuf conversion and RTW88 hardware-completion hook")
print("PASS: adapter remains compile-only; Skywalk queue callbacks remain fail-closed")
