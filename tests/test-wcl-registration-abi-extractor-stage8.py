#!/usr/bin/env python3
"""Stage 8 tests for bounded full-function 24H32 ABI evidence extraction."""
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/audit-skywalk-registration-24H32.py"
MAKEFILE = (ROOT / "driver/RTL88WiFi/Makefile").read_text()

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage8-") as temp:
    temp_path = Path(temp)
    archive = temp_path / "kcabi-fixture.tar.gz"
    fixture_members = {
        "24H32/asm/ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j.asm.txt": (
            "# registration overload\n"
            "1000: mov rdi, rbx\n"
            "1004: call register helper\n"
            "1009: test eax, eax\n"
            "100b: jne failure\n"
            "1010: ret\n"
        ),
        "24H32/asm/ZN21IO80211InfraInterface5startEP9IOService.asm.txt": (
            "# infra start path\n"
            "2000: call registerInfraEthernetInterface\n"
            "2005: test eax, eax\n"
            "2007: js failure\n"
            "2009: ret\n"
        ),
        "24H32/asm/INDEX.txt": (
            "1: ffffff8000001000 com.apple.iokit.IOSkywalkFamily registerEthernetInterface 71\n"
            "2: ffffff8000002000 com.apple.iokit.IO80211Family IO80211InfraInterface5startEP9IOService 53\n"
        ),
        "24H32/not-an-asm.txt": "registerEthernetInterface context line\nother line\n",
        "../escape.txt": "must not appear\n",
    }
    with tarfile.open(archive, "w:gz") as tar:
        for name, value in fixture_members.items():
            data = value.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            import io
            tar.addfile(info, io.BytesIO(data))

    focused = subprocess.run(
        [sys.executable, str(SCRIPT), str(archive), "--full-registration-asm", "--stdout"],
        check=True, text=True, capture_output=True, cwd=ROOT,
    ).stdout
    assert "COMPLETE DISASSEMBLY" in focused
    assert "1000: mov rdi, rbx" in focused
    assert "1009: test eax, eax" in focused
    assert "2000: call registerInfraEthernetInterface" in focused
    assert "MATCHING SYMBOL INDEX ROWS" in focused
    assert "registerEthernetInterface 71" in focused
    assert "complete focused asm members emitted: 2" in focused
    assert "must not appear" not in focused

    ordinary = subprocess.run(
        [sys.executable, str(SCRIPT), str(archive), "--stdout"],
        check=True, text=True, capture_output=True, cwd=ROOT,
    ).stdout
    assert "registerEthernetInterface context line" in ordinary
    assert "COMPLETE DISASSEMBLY" not in ordinary

assert "wcl-abi-audit-24h32:" in MAKEFILE
assert "--full-registration-asm --stdout" in MAKEFILE
assert "ABI_ARCHIVE ?= $(HOME)/Downloads/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz" in MAKEFILE
print("PASS: full target function bodies and Apple call paths are emitted")
print("PASS: symbol-index rows accompany complete disassembly evidence")
print("PASS: legacy keyword-context mode remains compatible")
print("PASS: unsafe archive paths are ignored; focused output stays bounded")
print("PASS: Makefile audit target appends evidence through stdout only")
