#!/usr/bin/env python3
"""Stage125 read-only source audit for native macOS Wi-Fi menu readiness.

This checks source contracts only. It does not compile, sign, install, load,
unload, activate hardware, or modify OpenCore/EFI/SIP/NVRAM.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "driver/RTL88WiFi/src/kext"
WCL = SRC / "wcl24h32"

PINNED = {
    "driver/RTL88WiFi/RTL88WiFiNative.kext/Contents/Info.plist":
        "7e2477a97fc10d504ba8566afb3200ce4feed112",
    "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.cpp":
        "253f8f6136788f8e8a063811172c9ed8eb1a906e",
    "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLController.hpp":
        "aab83ca0e963f85c4fd455ac82cfe50bf8fb6e54",
    "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.cpp":
        "7621f15b25d94e882c3a89cc6d90f980bdde6dcc",
    "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLInfraInterface.hpp":
        "f27344296e669defa0b46e0721ff4098d2a0e73c",
    "driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCL24H32InterfaceABI.hpp":
        "0e155ec7dda26701bf962bb1442d6a54be0becb2",
    "driver/RTL88WiFi/src/kext/RTW88WCLRadioBridge.cpp":
        "d358c6e066f5191dd9f07da0a27a70a44666ffc5",
    "driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp":
        "d5843f181554a13baefc91a7823827141244e955",
}

def check(name: str, condition: bool, detail: str) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"STAGE125_{name}={status}")
    print(f"  DETAIL={detail}")
    if not condition:
        raise AssertionError(f"{name}: {detail}")

def gap(name: str, condition: bool, detail: str) -> None:
    status = "CONFIRMED_GAP" if condition else "NOT_REPRODUCED"
    print(f"STAGE125_{name}={status}")
    print(f"  DETAIL={detail}")
    if not condition:
        raise AssertionError(f"Expected source gap not found: {name}")

def between(source: str, begin: str, end: str) -> str:
    start = source.index(begin)
    finish = source.index(end, start)
    return source[start:finish]

def git_blob_sha(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()

def main() -> None:
    for rel, expected in PINNED.items():
        data = (ROOT / rel).read_bytes()
        actual = git_blob_sha(data)
        check("SOURCE_PIN_" + Path(rel).stem.upper().replace(".", "_"),
              actual == expected,
              f"{rel}: expected {expected}, actual {actual}")

    plist = (ROOT / "driver/RTL88WiFi/RTL88WiFiNative.kext/Contents/Info.plist").read_text()
    controller = (WCL / "RTW88WCLController.cpp").read_text()
    controller_h = (WCL / "RTW88WCLController.hpp").read_text()
    infra = (WCL / "RTW88WCLInfraInterface.cpp").read_text()
    infra_h = (WCL / "RTW88WCLInfraInterface.hpp").read_text()
    abi = (WCL / "RTW88WCL24H32InterfaceABI.hpp").read_text()
    bridge = (SRC / "RTW88WCLRadioBridge.cpp").read_text()
    radio = (SRC / "RTW88IEEE80211.cpp").read_text()

    check("PCI_PERSONALITY_MATCH",
          "IOProviderClass</key>\n\t\t\t<string>IOPCIDevice</string>" in plist
          and "<string>RTW88WCLController</string>" in plist
          and "0xC82110EC" in plist and "0xB82110EC" in plist,
          "Native IOPCIDevice personality binds RTL8821CE-compatible PCI IDs.")
    check("NATIVE_FRAMEWORK_DEPENDENCIES",
          "com.apple.iokit.IO80211Family</key>" in plist
          and "com.apple.iokit.IOSkywalkFamily</key>" in plist
          and "com.apple.iokit.IONetworkingFamily</key>" in plist
          and "com.apple.iokit.IO80211FamilyLegacy" not in plist,
          "Native IO80211Family/Skywalk dependencies are present; Legacy dependency is absent.")

    controller_start = between(
        controller,
        "bool RTW88WCLController::start(IOService *provider)",
        "void RTW88WCLController::stop(IOService *provider)")
    check("CONTROLLER_PUBLICATION_ORDER",
          controller_start.index("_infraInterface->start(this)") <
          controller_start.index("_infraInterface->registerService()") <
          controller_start.index("_pciBackend->setRadioRunning(true)"),
          "Infra registration precedes service publication and PCI interrupt activation.")

    interface_start = between(
        infra,
        "bool RTW88WCLInfraInterface::start(IOService *provider)",
        "IOReturn RTW88WCLInfraInterface::shutdownForController()")
    check("APPLE_PRIMARY_INTERFACE_ATTACH",
          interface_start.index("super::start(provider)") <
          interface_start.index("attachControllerInterface()") <
          interface_start.index("registerInfraEthernetInterface("),
          "Apple base start precedes primary-interface attach and native Skywalk registration.")
    attach = between(
        infra,
        "IOReturn RTW88WCLInfraInterface::attachControllerInterface()",
        "IOReturn RTW88WCLInfraInterface::detachControllerInterface()")
    check("PRIMARY_GETTER_VERIFICATION",
          "_controller->attachInterface(this, _controller)" in attach
          and "_controller->getPrimarySkywalkInterface()" in attach
          and "primary != this" in attach,
          "Apple primary attach is followed by exact getter-pointer verification.")
    check("SKYWALK_REGISTRATION_TRANSACTION",
          "registerInfraEthernetInterface(" in interface_start
          and "commitRegistrationTransaction()" in interface_start
          and "_registered = true;" in interface_start,
          "Registration commits only after Apple's 24H32 helper succeeds.")
    bsd = between(
        infra,
        "SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(",
        "IOReturn RTW88WCLInfraInterface::setMacAddress")
    check("BSD_INITIALIZER_DELEGATION",
          "IO80211InfraInterface::initBSDInterfaceParameters(params, address)" in bsd,
          "BSD parameter construction is delegated to Apple's base initializer.")

    scan = between(
        infra,
        "IOReturn RTW88WCLInfraInterface::setWCL_SCAN_REQ(",
        "IOReturn RTW88WCLInfraInterface::setWCL_ASSOCIATE(")
    scan_results = between(
        infra,
        "void RTW88WCLInfraInterface::publishScanResults(",
        "void RTW88WCLInfraInterface::postConnectionComplete(")
    scan_events = between(
        infra,
        "void RTW88WCLInfraInterface::handleRTW88WCLRadioEvent(",
        "\n#undef super")
    check("ACTIVE_SCAN_REQUEST_PATH",
          "_bridge.startScan(" in scan and "setScanningState(request.identifier, true" in scan,
          "WCL scan requests reach the radio bridge and publish scanning state.")
    check("SCAN_RESULTS_AND_COMPLETION",
          "kWCLMessageScanResult" in scan_results
          and "kWCLMessageScanDone" in scan_results
          and "event.scanGeneration != _activeScanGeneration" in scan_events
          and "publishScanResults(status)" in scan_events,
          "Scan result payloads and completion notifications are emitted with generation gating.")
    check("JOIN_AND_LINK_PATH",
          "_bridge.associate(" in infra
          and "kWCLMessageAssocComplete" in scan_events
          and "kWCLMessageLinkStatus" in scan_events,
          "Association, completion, and link-status event paths exist.")
    connected = between(
        infra,
        "void RTW88WCLInfraInterface::maybePublishConnected()",
        "void RTW88WCLInfraInterface::handleRTW88WCLRadioEvent")
    check("STAGE124_CURRENT_AP_CACHE",
          "setCurrentApAddress(&currentAP);" in connected
          and connected.index("setCurrentApAddress(&currentAP);") <
          connected.index("setLinkState(kIO80211NetworkLinkUp"),
          "Current BSSID cache is set before link-up publication.")

    for method, end in [
        ("IOReturn RTW88WCLInfraInterface::getCHANNEL(", "IOReturn RTW88WCLInfraInterface::getRSSI("),
        ("IOReturn RTW88WCLInfraInterface::getRSSI(", "IOReturn RTW88WCLInfraInterface::getSUPPORTED_CHANNELS("),
        ("IOReturn RTW88WCLInfraInterface::getSUPPORTED_CHANNELS(", "IOReturn RTW88WCLInfraInterface::setCIPHER_KEY("),
    ]:
        body = between(infra, method, end)
        check("IMPLEMENTED_" + method.split("::")[1].split("(")[0],
              "kIOReturnSuccess" in body,
              f"{method.split('::')[1].split('(')[0]} has a success-return path.")

    power_get = between(
        controller,
        "IOReturn RTW88WCLController::getPOWER(",
        "IOReturn RTW88WCLController::setPOWER(")
    power_set = between(
        controller,
        "IOReturn RTW88WCLController::setPOWER(",
        "IOReturn RTW88WCLController::getCOUNTRY_CODE(")
    enable = between(
        infra,
        "IOReturn RTW88WCLInfraInterface::enable(",
        "IOReturn RTW88WCLInfraInterface::disable(")
    disable = between(
        infra,
        "IOReturn RTW88WCLInfraInterface::disable(",
        "SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(")
    check("POWER_GETTER_SOURCE",
          "_infraInterface->isInterfaceEnabled()" in power_get,
          "Controller getPOWER reports the inherited Apple interface-enabled flag.")
    check("POWER_SETTER_DISPATCH",
          "_infraInterface->enable(0)" in power_set
          and "_infraInterface->disable(0)" in power_set,
          "Controller setPOWER dispatches ON/OFF to the native interface.")
    gap("POWER_FLAG_SYNCHRONIZATION",
        "setInterfaceEnable(" not in enable + disable
        and "super::enable(" not in enable
        and "super::disable(" not in disable
        and "_infraInterface->isInterfaceEnabled()" in power_get,
        "Custom enable/disable power the RTW88 bridge and packet path, but do not explicitly call Apple setInterfaceEnable or the base enable/disable; getPOWER reads Apple's isInterfaceEnabled flag. Reconcile this state before claiming power/menu readiness.")

    country_get = between(
        controller,
        "IOReturn RTW88WCLController::getCOUNTRY_CODE(",
        "IOReturn RTW88WCLController::setCOUNTRY_CODE(")
    country_set = between(
        controller,
        "IOReturn RTW88WCLController::setCOUNTRY_CODE(",
        "IOReturn RTW88WCLController::setGET_DEBUG_INFO(")
    gap("REGULATORY_COUNTRY_CALLBACKS",
        "return kIOReturnNotReady;" in country_get
        and "return data ? kIOReturnNotReady : kIOReturnBadArgument;" in country_set,
        "Both country-code callbacks fail with NotReady; regulatory-domain callback behavior is not implemented.")

    gap("PASSIVE_BACKGROUND_SCAN",
        "request.type != APPLE80211_SCAN_TYPE_ACTIVE" in scan
        and "request.type != APPLE80211_SCAN_TYPE_FAST" in scan
        and "return kIOReturnUnsupported;" in scan,
        "Only active/FAST scans are accepted; passive and background scan requests are rejected.")

    unsupported_count = infra_h.count("RTW88_WCL_UNSUPPORTED(")
    print(f"STAGE125_OPTIONAL_UNSUPPORTED_SELECTOR_MACROS={unsupported_count}")
    print("STAGE125_RUNTIME_BSD_IFNET_ENUMERATION=NOT_TESTED")
    print("STAGE125_COREWLAN_MENU_VISIBILITY=NOT_TESTED")
    print("STAGE125_RADIO_SCAN_AND_JOIN_HARDWARE=NOT_TESTED")
    print("STAGE125_DRIVER_SOURCE_MODIFIED=NO")
    print("STAGE125_BUILD=NOT_RUN")
    print("STAGE125_SIGNING=NOT_RUN INSTALL=NOT_RUN LOAD=NOT_RUN UNLOAD=NOT_RUN")
    print("STAGE125_OPENCORE_CHANGE=NONE EFI_WRITE=NONE SIP_CHANGE=NONE NVRAM_CHANGE=NONE REBOOT=NOT_RUN")
    print("STAGE125_STATIC_AUDIT=COMPLETE")
    print("STAGE125_READINESS=BLOCKED_PENDING_POWER_STATE_AND_REGULATORY_DOMAIN_REVIEW")

if __name__ == "__main__":
    main()
