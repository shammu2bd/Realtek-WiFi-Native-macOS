#!/usr/bin/env python3
"""Host tests for exact Stage 14 generic Skywalk segment/packet symbol expansion."""
from pathlib import Path
import importlib.util
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/prepare-kcabi-ref-24H32-stage14.py"
spec = importlib.util.spec_from_file_location("stage14_reference", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

PATCHER_PATH = ROOT / "tools/patch-kcabi-class-list-stage14.py"
patch_spec = importlib.util.spec_from_file_location("stage14_kcabi_patcher", PATCHER_PATH)
assert patch_spec and patch_spec.loader
patcher = importlib.util.module_from_spec(patch_spec)
patch_spec.loader.exec_module(patcher)

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage14-kcabi-patch-") as tmp:
    dump = Path(tmp) / "dump.py"
    dump.write_text("\n".join([
        "CLASSES = '''",
        "IOSkywalkPacketBufferPool IOSkywalkPacketBuffer IOSkywalkPacket",
        "'''.split()",
        "",
    ]), encoding="utf-8")
    assert patcher.patch_dump(dump) is True
    patched = dump.read_text(encoding="utf-8")
    assert patched.count("IOSkywalkMemorySegment") == 1
    assert "IOSkywalkPacketBuffer IOSkywalkMemorySegment IOSkywalkPacket" in patched
    assert patcher.patch_dump(dump) is False
print("PASS: Stage 14 adds MemorySegment to a temporary kcabi class list idempotently")

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage14-kcabi-invalid-") as tmp:
    dump = Path(tmp) / "dump.py"
    dump.write_text("\n".join(["CLASSES = '''", "IOService", "'''.split()", ""]), encoding="utf-8")
    try:
        patcher.patch_dump(dump)
    except ValueError as exc:
        assert "expected generic Skywalk packet-buffer anchors" in str(exc)
    else:
        raise AssertionError("unexpected kcabi class-list format must fail closed")
print("PASS: kcabi class-list patcher rejects an unexpected source layout")


def write_methods(root: Path, name: str, symbols: list[str]) -> None:
    (root / f"{name}.methods.txt").write_text(
        "\n".join(f"0xffffff8000001000\t{s}" for s in symbols) + "\n",
        encoding="utf-8",
    )


with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage14-ref-") as tmp:
    base = Path(tmp)
    root = base / "24H32"
    root.mkdir()
    per_class = {}
    for name in module.TARGET_CLASSES:
        init = f"__ZN{len(name)}{name}4initEv"
        free = f"__ZN{len(name)}{name}4freeEv"
        per_class[name] = [init, free]
        write_methods(root, name, [init, free, init])
    seed = base / "seed"
    seed.mkdir()
    seed_symbol = "__ZN21IO80211InfraInterface30registerInfraEthernetInterfaceEPN26IOSkywalkEthernetInterface16RegistrationInfoEPP20IOSkywalkPacketQueuejP25IOSkywalkPacketBufferPoolS7_"
    (seed / "seed.asm.txt").write_text(f"# 0x0 {seed_symbol}\n", encoding="utf-8")
    result = module.prepare(root, base / "out", seed)
    assert list(result) == list(module.TARGET_CLASSES)
    assert all(len(v) == 2 for v in result.values())
    ref = (base / "out/rtl88wifi-24H32-skywalk-segment-packet-stage14.asm.txt").read_text()
    assert seed_symbol in ref
    assert "IOSkywalkMemorySegment" in ref
    assert "IOSkywalkPacketBuffer" in ref
    assert "IOSkywalkNetworkPacket" in ref
    for methods in per_class.values():
        for symbol in methods:
            assert ref.count(symbol) == 1
print("PASS: all eight generic queue/pool and segment/packet class method lists are required")
print("PASS: exact Itanium symbols are preserved and de-duplicated")
print("PASS: Stage 8-10 registration seed symbols remain included")

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage14-index-") as tmp:
    base = Path(tmp)
    root = base / "24H32"
    root.mkdir()
    symbols = []
    for name in module.TARGET_CLASSES:
        (root / f"{name}.methods.txt").write_text("no raw symbol on this row\n", encoding="utf-8")
        symbols.extend([f"__ZN{len(name)}{name}4initEv", f"__ZNK{len(name)}{name}4freeEv"])
    (root / "INDEX.txt").write_text(
        "\n".join(f"0xffffff8000001000 com.apple.driver.IO80211 {s} 8" for s in symbols),
        encoding="utf-8",
    )
    result = module.collect_class_methods(root)
    assert all(len(v) == 2 for v in result.values())
print("PASS: exact class-member symbols can be recovered from INDEX.txt")

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage14-empty-") as tmp:
    base = Path(tmp)
    root = base / "24H32"
    root.mkdir()
    for name in module.TARGET_CLASSES:
        (root / f"{name}.methods.txt").write_text("demangled prose only\n", encoding="utf-8")
    try:
        module.collect_class_methods(root)
    except ValueError as exc:
        message = str(exc)
        assert "Stage 14 ABI extraction incomplete" in message
        assert all(name in message for name in module.TARGET_CLASSES)
    else:
        raise AssertionError("missing generic Skywalk class symbols must fail closed")
print("PASS: missing class symbols fail closed with class-by-class diagnostics")
