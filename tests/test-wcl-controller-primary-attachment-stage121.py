#!/usr/bin/env python3
"""Stage121 source contract for the 24H32 controller primary Skywalk attachment."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
controller = (SRC / "RTW88WCLController.cpp").read_text()
header = (SRC / "RTW88WCLInfraInterface.hpp").read_text()
source = (SRC / "RTW88WCLInfraInterface.cpp").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("IOReturn attachControllerInterface();" in header,
        "controller attach helper declaration missing")
require("IOReturn detachControllerInterface();" in header,
        "controller detach helper declaration missing")
require("bool _controllerAttached = false;" in header,
        "controller attachment ownership state missing")

attach = source.split("IOReturn RTW88WCLInfraInterface::attachControllerInterface()", 1)[1]
attach = attach.split("IOReturn RTW88WCLInfraInterface::detachControllerInterface()", 1)[0]
require("_controller->attachInterface(this, _controller)" in attach,
        "Apple attachInterface call or provider argument is incorrect")
require("primary = _controller->getPrimarySkywalkInterface();" in attach,
        "primary getter is not queried after attach")
require("if (primary != this)" in attach,
        "attach result is not validated against this interface")
require("_controllerAttached = true;" in attach,
        "attachment ownership is not committed after getter verification")

detach = source.split("IOReturn RTW88WCLInfraInterface::detachControllerInterface()", 1)[1]
detach = detach.split("bool RTW88WCLInfraInterface::start(IOService *provider)", 1)[0]
require("_controller->detachInterface(this, false)" in detach,
        "Apple detachInterface call missing")
require(detach.index("_controller->detachInterface(this, false)") <
        detach.index("_controller->getPrimarySkywalkInterface() == this"),
        "detach getter verification must follow detachInterface")
require("return kIOReturnBusy;" in detach,
        "failed Apple detach must retain the interface owner")

start = source.split("bool RTW88WCLInfraInterface::start(IOService *provider)", 1)[1]
start = start.split("IOReturn RTW88WCLInfraInterface::shutdownForController()", 1)[0]
require(start.index("super::start(provider)") <
        start.index("attachControllerInterface()") <
        start.index("registerInfraEthernetInterface("),
        "primary attachment must occur after base start and before registration")
require("shutdownForController()" in start,
        "failed primary attachment must unwind the interface base start")

shutdown = source.split("IOReturn RTW88WCLInfraInterface::shutdownForController()", 1)[1]
shutdown = shutdown.split("void RTW88WCLInfraInterface::stop(IOService *provider)", 1)[0]
require(shutdown.index("deregisterEthernetInterface(0)") <
        shutdown.index("finishDeregistrationTransaction()") <
        shutdown.index("super::stop(_controller)") <
        shutdown.index("detachControllerInterface()"),
        "teardown must deregister, commit, stop Apple base, then detach primary")

require("_infraInterface->detach(this);" in controller,
        "generic IOKit child detach must remain separate from Apple primary detach")
require("_infraInterface->shutdownForController()" in controller,
        "controller must preserve transactional interface shutdown")

print("STAGE121_SOURCE_CONTRACT=PASS")
print("STAGE121_ATTACH_AFTER_APPLE_BASE_START=PASS")
print("STAGE121_PRIMARY_GETTER_VERIFICATION=PASS")
print("STAGE121_DETACH_AFTER_DEREGISTRATION_AND_BASE_STOP=PASS")
print("STAGE121_GENERIC_CHILD_DETACH_PRESERVED=PASS")
