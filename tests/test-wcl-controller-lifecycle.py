#!/usr/bin/env python3
"""Source-boundary checks for the staged native WCL controller lifecycle.

This is not an IOKit runtime test. Xcode's target SDK build and device testing
remain required before any native controller can be activated.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
header = (base / "RTW88WCLController.hpp").read_text()
source = (base / "RTW88WCLController.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

# The controller is the owner/client for the ABI-neutral PCI object, RTW88
# event notifications and safe receive delegation.
for inheritance in (
    "public RTW88WCLPCIBackendClient",
    "public RTW88EventDelegate",
    "public RTW88RxDelegate",
):
    assert inheritance in header, inheritance
for method in (
    "rtw88WCLResumeTransmit() override",
    "rtw88Event(RTW88Event event, void *data) override",
    "allocateInputPacket(uint32_t length) override",
    "injectRxFrame(mbuf_t packet) override",
    "getRxWorkLoop() override",
    "setLinkStatus(UInt32 status) override",
):
    assert method in header, method

# Startup must acquire the real PCI provider, open the exclusive backend,
# create the RTW88 state machine and bind it. It intentionally does not probe
# or start the hardware while Skywalk queues are absent.
for token in (
    "OSDynamicCast(IOPCIDevice, provider)",
    "_pciBackend->open(pci, _workLoop, this)",
    "RTW88IEEE80211::createAirport(this, compatPCI)",
    "radio->setEventDelegate(this)",
    "bindRadioBackend(radio)",
    "refusing publication until Skywalk datapath is ready",
    "goto fail;",
):
    assert token in source, token
assert "_radio->start(" not in source, "radio must not be probed before Skywalk RX/TX exists"
assert "radio->start(" not in source, "radio must remain fail-closed in this stage"

# Teardown order: close the packet-path gate, stop RTW88 producers, remove
# the RX workloop consumer, release Skywalk pools, then fence PCI and destroy
# backend callback context.
release = source[source.index("void RTW88WCLController::releaseNativeResources()"):
                 source.index("void RTW88WCLController::free()")]
ordered = (
    "_radio->stop()",
    "_rxAdapter->stop()",
    "recycleStagedRxPackets()",
    "_skywalkQueues->destroyQueues()",
    "_pciBackend->setRadioRunning(false)",
    "unbindRadioBackend()",
    "_pciBackend->close()",
    "_pciBackend->release()",
)
positions = [release.index(token) for token in ordered]
assert positions == sorted(positions), f"unsafe teardown order: {list(zip(ordered, positions))}"
assert "return; // Keep callbacks, mappings and DMA owner alive on failure." in release

# RX is allocated with the controller's packet allocator, but only while the
# explicit packet-path gate is active. injectRxFrame hands ownership to the
# bounded RX staging source; the registered Skywalk RX completion queue is
# still absent, so the workloop sink intentionally drops frames.
rx_alloc = source[source.index("mbuf_t RTW88WCLController::allocateInputPacket"):
                  source.index("void RTW88WCLController::injectRxFrame")]
assert "enterPacketPath()" in rx_alloc
assert "allocatePacket(length)" in rx_alloc
assert "_rxAdapter->enqueueFrame(packet)" in source
assert "stagedRxFrame" in source
assert "IOSkywalkPacket *preparedPacket" in source
assert "IOWorkLoop *RTW88WCLController::getRxWorkLoop()" in source
assert "RTW88WCLSkywalkRxAdapter" in header
assert "_rxAdapter->stop()" in release
assert "recycleStagedRxPackets()" in release
assert "_stagedRxPackets.push(preparedPacket)" in source

# Controller, infra interface and backend remain compile-only and absent from
# the legacy link object set.
assert "$(WCL24H32_CONTROLLER_OBJ)" in makefile
link_rule = re.search(r"AIRPORT_ALL_OBJS\s*:=([^\n]+)", makefile)
assert link_rule and "WCL24H32_CONTROLLER_OBJ" not in link_rule.group(1)
assert "$(KEXT_SRC)/wcl24h32/RTW88WCLPCIBackend.hpp" in makefile

print("PASS: native controller owns staged PCI/RTW88 resources with RX producer/consumer teardown; radio and legacy link remain fail-closed")
