#!/usr/bin/env python3
"""Source-boundary checks for the isolated ABI-neutral native PCI owner."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / "driver/RTL88WiFi/src/kext/wcl24h32"
header = (base / "RTW88WCLPCIBackend.hpp").read_text()
source = (base / "RTW88WCLPCIBackend.cpp").read_text()
makefile = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

assert "class RTW88WCLPCIBackend final : public OSObject, public RTW88HwOps" in header
assert "IOPCIDevice *_pciDev" in header
assert "IOMemoryMap *_mmioMap" in header
assert "IOInterruptEventSource *_interruptSource" in header
assert "RTW88DMAEntry *_dmaList" in header
assert "RTW88DMAEntry *_dmaPendingFree" in header
assert not re.search(r"#include[^\n]*IO80211Controller", header + source)
assert not re.search(r"class\s+RTW88WCLPCIBackend[^\{]*IO80211InfraProtocol", header + source)

# Resource acquisition has matching rollback paths and a serialized global
# compat lease. The native owner is not allowed to silently steal the legacy
# RTW88 process-global PCI/DMA callback table.
for token in (
    "__atomic_compare_exchange_n(&g_pci_dev_instance",
    "rtw88_compat_init()",
    "rtw88_compat_exit()",
    "closeResources();",
    "_workLoop->removeEventSource(_interruptSource)",
    "releaseDMAEntries();",
    "_pciDev->setBusMasterEnable(false)",
):
    assert token in source, token
assert "if (_radioRunning)\n        return kIOReturnBusy;" in source
assert "_interruptSource->disable();" in source
assert "rtw88_trigger_interrupt();" in source

# The backend must compile in isolation and must never enter the legacy link.
assert "$(WCL24H32_PCI_BACKEND_OBJ)" in makefile
assert "$(WCL24H32_PCI_BACKEND_OBJ:.o=.d)" in makefile
link_rule = re.search(r"AIRPORT_ALL_OBJS\s*:=([^\n]+)", makefile)
assert link_rule
assert "WCL24H32_PCI_BACKEND_OBJ" not in link_rule.group(1)

print("PASS: ABI-neutral PCI/MMIO/DMA owner, exclusive compat lease, rollback and compile-only isolation")
