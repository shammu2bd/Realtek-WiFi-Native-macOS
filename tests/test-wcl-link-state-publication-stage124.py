#!/usr/bin/env python3
"""Stage124 source contract: keep the native interface's current AP cache in sync."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
infra = (SRC / "RTW88WCLInfraInterface.cpp").read_text()
controller = (SRC / "RTW88WCLController.cpp").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body_between(source: str, begin: str, end: str) -> str:
    start = source.index(begin)
    finish = source.index(end, start)
    return source[start:finish]


connected = body_between(
    infra,
    "void RTW88WCLInfraInterface::maybePublishConnected()",
    "void RTW88WCLInfraInterface::handleRTW88WCLRadioEvent",
)
require("_activeJoinGeneration" in connected and
        "_bridge.connectionReady()" in connected,
        "connected publication must remain gated by a live, completed join")
require("memcpy(currentAP.octet, _targetBSSID, sizeof(currentAP.octet));" in connected,
        "current AP address must be copied from the validated join BSSID")
require("setCurrentApAddress(&currentAP);" in connected,
        "base IO80211InfraInterface current-AP cache must be populated")
require(
    connected.index("setCurrentApAddress(&currentAP);") <
    connected.index("postConnectionComplete(0, 0, kIOReturnSuccess);") <
    connected.index("setLinkState(kIO80211NetworkLinkUp"),
    "BSSID cache must be updated before connection and link-up publication",
)
require("postWCLMessage(kWCLMessageLinkStatus, &link, sizeof(link));" in connected,
        "existing WCL link-status event must remain published")

leave = body_between(
    infra,
    "IOReturn RTW88WCLInfraInterface::setWCL_LEAVE_NETWORK",
    "IOReturn RTW88WCLInfraInterface::setWCL_SCAN_ABORT",
)
require("setCurrentApAddress(nullptr);" in leave,
        "leave-network path must clear the base current-AP cache")

events = body_between(
    infra,
    "void RTW88WCLInfraInterface::handleRTW88WCLRadioEvent",
    "bool RTW88WCLInfraInterface::scanResultMatches",
)
require(events.count("setCurrentApAddress(nullptr);") >= 2,
        "deauth and disconnect paths must clear the current-AP cache")
require("setLinkState(kIO80211NetworkLinkDown" in events,
        "deauth/disconnect must continue publishing link-down")

caps = body_between(
    controller,
    "IOReturn RTW88WCLController::getCARD_CAPABILITIES",
    "IOReturn RTW88WCLController::getPOWER",
)
require("_infraInterface->isRegistered()" in caps and
        "interface != _infraInterface" in caps,
        "controller capability query must stay bound to the registered native interface")

power = body_between(
    controller,
    "IOReturn RTW88WCLController::getPOWER",
    "IOReturn RTW88WCLController::setPOWER",
)
require("_infraInterface->isInterfaceEnabled()" in power,
        "Wi-Fi power query must reflect the actual interface enable state")

print("STAGE124_LIVE_JOIN_GUARD=PASS")
print("STAGE124_CURRENT_AP_CACHE_FROM_JOIN_BSSID=PASS")
print("STAGE124_BSSID_BEFORE_LINK_UP=PASS")
print("STAGE124_LEAVE_DEAUTH_DISCONNECT_CLEAR=PASS")
print("STAGE124_CONTROLLER_CAPABILITY_AND_POWER_GATES=PASS")
