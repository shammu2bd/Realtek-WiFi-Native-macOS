#!/usr/bin/env python3
"""Stage 9 exact-symbol kcabi reference and vtable-dispatch tests."""
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "tools/prepare-kcabi-ref-24H32.py"
AUDIT = ROOT / "tools/audit-skywalk-registration-24H32.py"
COLLECT = (ROOT / "tools/collect-sequoia-abi-24H32.sh").read_text()

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage9-") as temp:
    base = Path(temp)
    existing = base / "existing-ref"
    existing.mkdir()
    (existing / "old.asm.txt").write_text(
        "# 0x1234 __Z15existingFunctionv\n1000: ret\n", encoding="utf-8"
    )
    generated = base / "generated-ref"
    run = subprocess.run(
        [sys.executable, str(PREPARE), "--out", str(generated), "--reference", str(existing)],
        text=True, capture_output=True, check=True,
    )
    reference_text = (generated / "rtl88wifi-24H32-registration-targets.asm.txt").read_text()
    required = (
        "__ZN21IO80211InfraInterface30registerInfraEthernetInterface",
        "__ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCore",
        "__ZN26IOSkywalkEthernetInterface25registerEthernetInterface",
        "__ZN26IOSkywalkEthernetInterface27deregisterEthernetInterface",
        "__ZN25IOSkywalkNetworkInterface24registerNetworkInterface",
        "__ZN25IOSkywalkNetworkInterface26deregisterNetworkInterface",
        "__Z15existingFunctionv",
    )
    for symbol in required:
        assert symbol in reference_text, f"missing forced reference: {symbol}"
    assert "Prepared 14 exact 24H32 registration symbols" in run.stdout

    archive = base / "dispatch-fixture.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        import io
        members = {
            "24H32/IO80211InfraInterface.vtable.txt": (
                "# IO80211InfraInterface vtable\n"
                "383\t0xbf8\t__ZN21IO80211InfraInterface10someMethodEv\n"
                "384\t0xc00\t__ZN21IO80211InfraInterface23setInterfaceOFDMDesenseE18apple80211_channelx\n"
            ),
            "24H32/asm/ZN21IO80211InfraInterface30registerInfraEthernetInterface.fixture.asm.txt": (
                "# 0x1000 __ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_\n"
                "1000: call 0x2000 ; __ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j\n"
                "1005: mov r14d, eax\n1010: mov eax, r14d\n1015: ret\n"
            ),
            "24H32/asm/ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j.fixture.asm.txt": (
                "# 0x2500 __ZN26IOSkywalkEthernetInterface25registerEthernetInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j\n"
                "2500: call 0x2600 ; __ZN25IOSkywalkNetworkInterface24registerNetworkInterfaceEPKNS_16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_j\n"
                "2505: ret\n"
            ),
            "24H32/asm/ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCore.fixture.asm.txt": (
                "# 0x3000 __ZN28AppleBCMWLANSkywalkInterface5startEP16AppleBCMWLANCorePN26IOSkywalkEthernetInterface16RegistrationInfoE\n"
                "3000: call 0x1000 ; __ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_\n"
                "3005: test r12d, r12d\n3010: sete r15b\n3015: je 0x4000\n"
            ),
        }
        for name, value in members.items():
            data = value.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))

    report = subprocess.run(
        [sys.executable, str(AUDIT), str(archive), "--full-registration-asm", "--stdout"],
        text=True, capture_output=True, check=True,
    ).stdout
    assert "slot 384, offset 0xc00" in report
    assert "setInterfaceOFDMDesense" in report
    assert "not the registration entry point" in report
    assert "calls registerInfraEthernetInterface directly" in report
    assert "IOReturn status in EAX" in report
    assert "COMPLETE DISASSEMBLY" in report

assert "prepare-kcabi-ref-24H32.py" in COLLECT
assert "--ref \"$TMP_DIR/ref\"" in COLLECT
assert "--reference \"$KCABI_REF\"" in COLLECT
print("PASS: exact registration symbols are forced into kcabi disassembly")
print("PASS: existing KCABI_REF functions are merged without modifying the clone")
print("PASS: vtable slot 0xc00 resolves to setInterfaceOFDMDesense, not registration")
print("PASS: direct Apple registration call and IOReturn zero-success convention are identified")
print("PASS: the collector requests the explicit reference dump")
