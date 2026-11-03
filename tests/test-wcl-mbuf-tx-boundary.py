#!/usr/bin/env python3
"""Source-boundary checks for the native controller's gated mbuf TX handoff.

This is not a Skywalk ring test. The real Skywalk packet/queue adapter remains
separate work and the native controller remains compile-only.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
controller_h = (base / "RTW88WCLController.hpp").read_text()
controller_cpp = (base / "RTW88WCLController.cpp").read_text()
infra_cpp = (base / "RTW88WCLInfraInterface.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert "UInt32 outputPacket(mbuf_t packet, void *param) override;" in controller_h
for state in (
    "kPacketPathDisabled", "kPacketPathActive", "kPacketPathQuiescing",
    "kPacketPathReleasing", "kPacketPathBinding",
):
    assert state in controller_h

# Packet admission requires all resource owners to exist and the radio probe
# to have completed; activation is not possible in the current fail-closed
# controller start path.
activate = controller_cpp[controller_cpp.index("IOReturn RTW88WCLController::activatePacketPath"):
                          controller_cpp.index("IOReturn RTW88WCLController::quiescePacketPath")]
for token in ("!_radio", "!_radioStarted", "!_pciBackend", "_pciBackend->isOpen()",
              "kPacketPathBinding", "interface->retain()", "kPacketPathActive"):
    assert token in activate, token

# Output owns every mbuf: a closed gate drops/frees, an open gate hands it to
# RTW88IEEE80211::outputPacket(), which documents consume-on-all-paths.
tx = controller_cpp[controller_cpp.index("UInt32 RTW88WCLController::outputPacket"):
                    controller_cpp.index("void RTW88WCLController::rtw88WCLResumeTransmit")]
for token in ("enterPacketPath()", "mbuf_freem(packet)", "_radio->outputPacket(packet)", "leavePacketPath()"):
    assert token in tx, token

# Quiesce blocks new traffic, waits for in-flight callers, and only then drops
# the retained interface reference. Controller resource release runs it first.
quiesce = controller_cpp[controller_cpp.index("IOReturn RTW88WCLController::quiescePacketPath"):
                         controller_cpp.index("UInt32 RTW88WCLController::outputPacket")]
for token in ("kPacketPathQuiescing", "_packetPathInFlight", "kPacketPathReleasing",
              "_packetPathInterface = nullptr", "interface->release()"):
    assert token in quiesce, token
release = controller_cpp[controller_cpp.index("void RTW88WCLController::releaseNativeResources()"):
                         controller_cpp.index("void RTW88WCLController::free()")]
assert release.index("quiescePacketPath()") < release.index("_radio->stop()")

# Interface only opens the TX gate after RTW88 power-up and closes it before
# radio power-down. RX remains dropped until a real Skywalk RX packet path exists.
enable = infra_cpp[infra_cpp.index("IOReturn RTW88WCLInfraInterface::enable"):
                   infra_cpp.index("IOReturn RTW88WCLInfraInterface::disable")]
disable = infra_cpp[infra_cpp.index("IOReturn RTW88WCLInfraInterface::disable"):
                    infra_cpp.index("SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters")]
assert enable.index("_bridge.powerOn()") < enable.index("activatePacketPath(this)")
assert "_bridge.powerOff();" in enable  # rollback if the packet gate cannot activate
assert disable.index("quiescePacketPath()") < disable.index("_bridge.powerOff()")
assert "mbuf_freem(packet);" in controller_cpp[controller_cpp.index("void RTW88WCLController::injectRxFrame"):
                                                controller_cpp.index("IOWorkLoop *RTW88WCLController::getRxWorkLoop")]

# Still compile-only: do not contaminate the legacy IO80211Controller link.
link_rule = re.search(r"AIRPORT_ALL_OBJS\s*:=([^\n]+)", makefile)
assert link_rule
assert "WCL24H32_CONTROLLER_OBJ" not in link_rule.group(1)
print("PASS: bounded activation/quiesce state machine and consume-once mbuf TX handoff; Skywalk RX stays fail-closed")
