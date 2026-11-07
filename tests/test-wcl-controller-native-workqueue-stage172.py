#!/usr/bin/env python3
"""Stage172 source-contract tests for native IO80211WorkQueue integration.

These checks cover the driver source contract only. The target-Mac compile/link
and runtime KEXT validation are separate steps.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WCL = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"

def section(source: str, start: str, end: str) -> str:
    first = source.index(start)
    last = source.index(end, first)
    return source[first:last]

def check(name: str, condition: bool, detail: str) -> None:
    print(f"{'PASS' if condition else 'FAIL'}: {name}: {detail}")
    if not condition:
        raise AssertionError(name)

def main() -> None:
    header = (WCL / "RTW88WCLController.hpp").read_text()
    source = (WCL / "RTW88WCLController.cpp").read_text()

    check(
        "controller overrides both Apple work-queue hooks",
        "bool createWorkQueue() override;" in header
        and "IO80211WorkQueue *getWorkQueue() const override;" in header,
        "the native subclass supplies the exact 24H32 controller hooks",
    )
    check(
        "controller keeps a dedicated queue owner",
        "IO80211WorkQueue *_workQueue = nullptr;" in header
        and "IOWorkLoop *_workLoop = nullptr;" in header,
        "Apple IO80211WorkQueue and the driver IOWorkLoop remain distinct",
    )
    check(
        "factory import is pinned to exact Apple symbol",
        "rtw88wclCreateIO80211WorkQueue(void)" in source
        and '__asm__("__ZN16IO80211WorkQueue9workQueueEv")' in source,
        "the link references Apple's 24H32 workQueue() factory",
    )

    init = section(
        source,
        "bool RTW88WCLController::init(OSDictionary *properties)",
        "bool RTW88WCLController::createWorkQueue()",
    )
    check(
        "factory-owned pointer starts null",
        "_workQueue = nullptr;" in init,
        "no uninitialized queue pointer is exposed",
    )

    create = section(
        source,
        "bool RTW88WCLController::createWorkQueue()",
        "bool RTW88WCLController::createWorkLoop()",
    )
    getter = section(
        source,
        "IO80211WorkQueue *RTW88WCLController::getWorkQueue() const",
        "bool RTW88WCLController::createWorkLoop()",
    )
    check(
        "queue factory is idempotent and fail-closed",
        "if (_workQueue)" in create
        and "rtw88wclCreateIO80211WorkQueue()" in create
        and "if (!queue)" in create
        and "_workQueue = reinterpret_cast<IO80211WorkQueue *>(queue);" in create,
        "one controller-owned factory reference is acquired or start fails",
    )
    check(
        "getter returns only the owned queue",
        "return _workQueue;" in getter,
        "the base class receives the controller-owned queue",
    )

    start = section(
        source,
        "bool RTW88WCLController::start(IOService *provider)",
        "void RTW88WCLController::stop(IOService *provider)",
    )
    check(
        "Apple queue exists before base controller start",
        start.index("createWorkQueue()") < start.index("super::start(provider)"),
        "PostOffice/command-gate creation cannot observe a null work queue",
    )
    check(
        "generic workloop remains a separate resource",
        "createWorkLoop()" in start and "_workLoop" in start,
        "the existing driver RX/TX event consumers retain their own IOWorkLoop",
    )

    free = section(
        source,
        "void RTW88WCLController::free()",
        "bool RTW88WCLController::isCommandProhibited(int command)",
    )
    check(
        "queue is released only after Apple base free",
        free.index("super::free();") < free.index(
            "reinterpret_cast<IOWorkLoop *>(_workQueue)->release();"
        ) < free.index("_workQueue = nullptr;"),
        "PostOffice/timer teardown completes before the owning reference is dropped",
    )
    check(
        "failed child teardown quarantines queue owner",
        free.index("if (cleanupStatus != kIOReturnSuccess)") <
        free.index("return;") <
        free.index("super::free();"),
        "the existing fail-closed resource quarantine remains intact",
    )

    stop = section(
        source,
        "void RTW88WCLController::stop(IOService *provider)",
        "IOReturn RTW88WCLController::releaseNativeResources()",
    )
    check(
        "stop does not release queue prematurely",
        "_workQueue" not in stop,
        "the work queue remains available through the base free lifecycle",
    )

    print("STAGE172_SOURCE_CONTRACT=PASS")

if __name__ == "__main__":
    main()
