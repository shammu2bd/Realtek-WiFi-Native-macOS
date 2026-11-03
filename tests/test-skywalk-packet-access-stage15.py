#!/usr/bin/env python3
"""Host regression tests for Stage 15 packet-access ABI audit."""
from __future__ import annotations

import importlib.util
import os
import shutil
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "audit-skywalk-packet-access-stage15.py"
spec = importlib.util.spec_from_file_location("stage15_audit", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fake_symbol(owner: str, method: str) -> str:
    # Generate a syntactically valid Itanium no-argument const member symbol.
    return f"__ZNK{len(owner)}{owner}{len(method)}{method}Ev"


def test_target_inventory_is_exact() -> None:
    assert len(module.TARGET_CLASSES) == 8
    assert module.TARGET_CLASSES == (
        "IOSkywalkPacketQueue", "IOSkywalkPacketBufferPool", "IOSkywalkQueueSet",
        "IOSkywalkLogicalLink", "IOSkywalkMemorySegment", "IOSkywalkPacketBuffer",
        "IOSkywalkPacket", "IOSkywalkNetworkPacket",
    )
    assert sum(map(len, module.REQUIRED_METHODS.values())) == 18


def test_demangler_handles_kernel_double_underscore_symbols() -> None:
    demangler = shutil.which("c++filt") or shutil.which("llvm-cxxfilt")
    assert demangler, "c++filt or llvm-cxxfilt is required for Stage 15 tests"
    symbol = fake_symbol("IOSkywalkPacket", "getDataLength")
    result = module.demangle([symbol], demangler)
    assert result[symbol].startswith("IOSkywalkPacket::getDataLength(")


def test_demangler_falls_back_to_macho_spelling() -> None:
    # Simulate an Apple-style demangler that accepts __Z... but leaves _Z...
    # untouched. This reproduces the compatibility edge found on the target Mac.
    with tempfile.TemporaryDirectory(prefix="rtl88wifi-stage15-demangler-") as temp:
        fake = Path(temp) / "macho-cxxfilt"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "for line in sys.stdin:\n"
            "    value = line.rstrip('\\n')\n"
            "    if value.startswith('__ZNK15IOSkywalkPacket13getDataLengthEv'):\n"
            "        print('IOSkywalkPacket::getDataLength() const')\n"
            "    else:\n"
            "        print(value)\n"
        )
        fake.chmod(0o755)
        symbol = fake_symbol("IOSkywalkPacket", "getDataLength")
        result = module.demangle([symbol], str(fake))
        assert result[symbol] == "IOSkywalkPacket::getDataLength() const"


def test_archive_audit_passes_with_complete_fixture() -> None:
    demangler = shutil.which("c++filt") or shutil.which("llvm-cxxfilt")
    assert demangler, "c++filt or llvm-cxxfilt is required for Stage 15 tests"
    with tempfile.TemporaryDirectory(prefix="rtl88wifi-stage15-test-") as temp:
        temp_path = Path(temp)
        fixture = temp_path / "input"
        root = fixture / "24H32"
        root.mkdir(parents=True)
        all_symbols: list[str] = []
        for owner in module.TARGET_CLASSES:
            names = module.REQUIRED_METHODS.get(owner, ("fixtureOnly",))
            lines = []
            for method in names:
                symbol = fake_symbol(owner, method)
                all_symbols.append(symbol)
                lines.append(f"# 0x0 {symbol}")
            (root / f"{owner}.methods.txt").write_text("\n".join(lines) + "\n")
        (root / "rtl88wifi-target.txt").write_text(
            "macOS product version: 15.8.1\nmacOS build: 24H32\narchitecture: x86_64\n"
        )
        asm_dir = root / "functions"
        asm_dir.mkdir()
        for index, symbol in enumerate(all_symbols):
            (asm_dir / f"function-{index}.asm.txt").write_text(
                f"# 0x1000 {symbol}\n0x1000: retq\n"
            )
        archive = temp_path / "stage14-fixture.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(root, arcname="24H32")
        result = module.audit_archive(archive, temp_path / "out", demangler)
        assert result["status"] == "PASS"
        assert result["required_method_count"] == 18
        assert result["methods_with_disassembly"] == 18
        assert (temp_path / "out" / result["output_archive"]).is_file()


def test_archive_path_traversal_is_rejected() -> None:
    with tempfile.TemporaryDirectory(prefix="rtl88wifi-stage15-path-test-") as temp:
        temp_path = Path(temp)
        archive = temp_path / "bad.tar.gz"
        payload = temp_path / "payload.txt"
        payload.write_text("bad")
        with tarfile.open(archive, "w:gz") as tar:
            info = tarfile.TarInfo("../escape.txt")
            info.size = payload.stat().st_size
            with payload.open("rb") as stream:
                tar.addfile(info, stream)
        try:
            module.safe_extract_tar(archive, temp_path / "out")
        except RuntimeError as exc:
            assert "Unsafe archive path" in str(exc)
        else:
            raise AssertionError("path traversal archive was not rejected")


if __name__ == "__main__":
    test_target_inventory_is_exact()
    test_demangler_handles_kernel_double_underscore_symbols()
    test_demangler_falls_back_to_macho_spelling()
    test_archive_audit_passes_with_complete_fixture()
    test_archive_path_traversal_is_rejected()
    print("PASS: Stage 15 packet-access ABI audit tests")
