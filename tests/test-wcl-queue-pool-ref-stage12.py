#!/usr/bin/env python3
"""Host tests for the two-pass Stage 12 Skywalk queue/pool ABI reference prep."""
from pathlib import Path
import importlib.util
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/prepare-kcabi-ref-24H32-stage12.py"
spec = importlib.util.spec_from_file_location("stage12_reference", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def write_methods(root: Path, class_name: str, rows: list[str]) -> None:
    path = root / f"{class_name}.methods.txt"
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")


with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage12-ref-") as tmp:
    base = Path(tmp)
    methods_root = base / "24H32"
    methods_root.mkdir()
    for class_name in module.TARGET_CLASSES:
        write_methods(methods_root, class_name, [
            "1: 0xffffff8000001000\t__ZN" + str(len(class_name)) + class_name + "4initEv",
            "2: 0xffffff8000001010\t__ZN" + str(len(class_name)) + class_name + "4freeEv",
            "...",
            # Duplicate symbols must be de-duplicated in deterministic order.
            "3: 0xffffff8000001000\t__ZN" + str(len(class_name)) + class_name + "4initEv",
        ])

    seed = base / "seed"
    seed.mkdir()
    (seed / "seed.asm.txt").write_text(
        "# 0x0 __ZN10SeedClass4initEv\n", encoding="utf-8"
    )
    out = base / "out"
    by_class = module.prepare(methods_root, out, seed)

    assert list(by_class) == list(module.TARGET_CLASSES)
    assert all(len(symbols) == 2 for symbols in by_class.values())
    reference = (out / "rtl88wifi-24H32-skywalk-queue-pool-stage12.asm.txt").read_text()
    assert "__ZN10SeedClass4initEv" in reference
    for symbols in by_class.values():
        for symbol in symbols:
            assert reference.count(symbol) == 1

print("PASS: all four queue/pool class method lists are required")
print("PASS: exact mangled method symbols are preserved and de-duplicated")
print("PASS: Stage 8-10 seed ABI targets remain included")

# kcabi versions may put a mangled method token inside a descriptive row, not
# at the end of a numbered address row. Keep exact token recovery covered.
with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage12-index-") as tmp:
    base = Path(tmp)
    methods_root = base / "24H32"
    methods_root.mkdir()
    for class_name in module.TARGET_CLASSES:
        write_methods(methods_root, class_name, ["<no symbol names in this format>"])
    index = methods_root / "INDEX.txt"
    class_symbols = []
    for class_name in module.TARGET_CLASSES:
        class_symbols.append("__ZN" + str(len(class_name)) + class_name + "4initEv")
        class_symbols.append("__ZNK" + str(len(class_name)) + class_name + "4freeEv")
    index.write_text("\n".join(f"0xffffff8000001000 com.apple.iokit.IOSkywalkFamily {sym} 4" for sym in class_symbols), encoding="utf-8")
    out = base / "out"
    by_class = module.prepare(methods_root, out)
    assert all(len(methods) == 2 for methods in by_class.values())
    assert all(any("4initEv" in sym for sym in methods) for methods in by_class.values())

with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage12-inline-") as tmp:
    base = Path(tmp)
    methods_root = base / "24H32"
    methods_root.mkdir()
    for class_name in module.TARGET_CLASSES:
        symbol = "__ZN" + str(len(class_name)) + class_name + "4initEv"
        write_methods(methods_root, class_name, [f"method address=0xffffff8000001000 symbol={symbol} trailing text"])
    by_class = module.collect_class_methods(methods_root)
    assert all(len(methods) == 1 for methods in by_class.values())

print("PASS: embedded mangled symbols and INDEX.txt fallback are supported")

# A genuinely symbol-free method list must fail closed with enough context.
with tempfile.TemporaryDirectory(prefix="rtl88wcl-stage12-empty-") as tmp:
    base = Path(tmp)
    methods_root = base / "24H32"
    methods_root.mkdir()
    for class_name in module.TARGET_CLASSES:
        write_methods(methods_root, class_name, ["only demangled prose; no mangled tokens"])
    try:
        module.collect_class_methods(methods_root)
    except ValueError as exc:
        message = str(exc)
        assert "queue/pool method extraction incomplete" in message
        assert all(name in message for name in module.TARGET_CLASSES)
        assert "method-list preview" in message
    else:
        raise AssertionError("symbol-free class method lists must fail closed")
print("PASS: missing class symbols fail closed with previews for all classes")
