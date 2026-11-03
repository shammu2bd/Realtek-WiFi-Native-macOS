#!/usr/bin/env python3
"""Host regression tests for Stage 17 queue/ownership evidence preparation."""
from __future__ import annotations
import importlib.util
import json
import re
import tarfile
import tempfile
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module

patcher = load("stage17_class_patcher", ROOT / "tools/patch-kcabi-class-list-stage17.py")
prepare = load("stage17_ref_prepare", ROOT / "tools/prepare-kcabi-ref-24H32-stage17.py")
audit = load("stage17_audit", ROOT / "tools/audit-skywalk-queue-ownership-stage17.py")


def build_stage14_fixture(root: Path) -> Path:
    dump = root / "stage14" / "24H32"
    (dump / "asm").mkdir(parents=True)
    (dump / "source.json").write_text(json.dumps({"build": "24H32", "product_version": "15.8.1", "sha256": "a"*64}))
    (dump / "asm" / "INDEX.txt").write_text("# address\towner\tsymbol\tinstructions\n0x1000\tcom.apple.iokit.IOSkywalkFamily\t__ZoldStage14v\t4\n")
    for cls in prepare.TARGET_CLASSES:
        symbol = f"__ZN{len(cls)}{cls}4testEv"
        (dump / f"{cls}.methods.txt").write_text(f"0x1000\t{symbol}\n")
        (dump / f"{cls}.vtable.txt").write_text(f"# {cls}: 1 slots\n")
    archive = root / "stage14.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        tf.add(dump, arcname="24H32")
    return archive



def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_json_archive(path: Path, member_name: str, payload: dict) -> None:
    staging = path.parent / (path.stem + "-payload")
    staging.mkdir(parents=True, exist_ok=True)
    item = staging / member_name
    item.parent.mkdir(parents=True, exist_ok=True)
    item.write_text(json.dumps(payload), encoding="utf-8")
    with tarfile.open(path, "w:gz") as tf:
        tf.add(item, arcname=member_name)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="stage17-tests-") as td:
        base = Path(td)
        dump_py = base / "dump.py"
        class_names = "IOSkywalkPacketBuffer IOSkywalkRxCompletionQueue IOSkywalkRxSubmissionQueue IOSkywalkTxCompletionQueue IOSkywalkTxSubmissionQueue IOSkywalkPacketQueue IOSkywalkPacketBufferPool IOSkywalkPacket IOSkywalkNetworkPacket IOSkywalkInterface IOSkywalkNetworkInterface IOSkywalkEthernetInterface AppleBCMWLANCore AppleBCMWLANInfraProtocol AppleBCMWLANPCIeSkywalk"
        dump_source = "CLASSES = "+"'''"+"\n"+class_names+"\n"+"'''.split()\n\n    funcs = {}\n    for cls in CLASSES:\n        for kind in ('C1Ev', 'C2Ev'):\n"
        dump_py.write_text(dump_source)
        assert patcher.patch(dump_py) is True
        assert patcher.patch(dump_py) is False
        patched_dump = dump_py.read_text()
        assert "IOSkywalkMemorySegment" in patched_dump
        assert "for _method_va, method_name in kc.methods(cls):" in patched_dump
        assert "stage17-executable-methods.txt" in patched_dump
        assert "for cls in STAGE17_TARGET_CLASSES:" in patched_dump
        upstream_classes = patched_dump.split("CLASSES = " + chr(39)*3, 1)[1].split(chr(39)*3 + ".split()", 1)[0].split()
        assert "AppleBCMWLANCore" in upstream_classes
        target_block = patched_dump.split("STAGE17_TARGET_CLASSES = (", 1)[1].split("\n)", 1)[0]
        target_names = re.findall(r"['\"]([^'\"]+)['\"]", target_block)
        assert tuple(target_names) == patcher.REQUIRED_CLASSES
        assert "for cls in CLASSES:\n        for _method_va, method_name in kc.methods(cls):" not in patched_dump

        stage14 = build_stage14_fixture(base)
        ref_dir = base / "ref"
        manifest = prepare.prepare(stage14, ref_dir)
        assert manifest["stage"] == 17
        assert manifest["target_class_method_symbol_count"] == len(prepare.TARGET_CLASSES)
        ref_text = (ref_dir / manifest["reference_file"]).read_text()
        assert "__ZoldStage14v" in ref_text
        assert all(f"__ZN{len(c)}{c}4testEv" in ref_text for c in prepare.TARGET_CLASSES)
        saved_manifest = json.loads((ref_dir / "STAGE17-METHOD-MANIFEST.json").read_text())
        assert saved_manifest["kernel_collection_sha256"] == "a"*64

        # Source-level audit runs against the current real project tree; this
        # catches accidental activation or ownership/teardown regressions.
        rows = audit.source_audit(ROOT)
        failed = [x for x in rows if x["status"] != "PASS"]
        assert not failed, failed
        assert len(rows) == 19

        # Exercise archive cross-linking and the full Stage 17 report builder.
        stage14_sha = sha256(stage14)
        stage15 = base / "stage15.tar.gz"
        make_json_archive(stage15, "stage15-work/STAGE15-ABI-ACCESSOR-AUDIT.json", {
            "stage": 15, "status": "PASS", "input_sha256": stage14_sha,
        })
        stage15_sha = sha256(stage15)
        stage16 = base / "stage16.tar.gz"
        make_json_archive(stage16, "stage16-work/STAGE16-PACKET-SEMANTICS-AUDIT.json", {
            "stage": 16, "status": "PASS", "stage14_sha256": stage14_sha,
            "stage15_sha256": stage15_sha,
        })
        target = base / "stage17-dump"
        asm = target / "asm"
        asm.mkdir(parents=True)
        (target / "source.json").write_text(json.dumps({
            "build": "24H32", "product_version": "15.8.1", "sha256": "a"*64,
        }), encoding="utf-8")
        index_rows = ["# address\towner\tsymbol\tinstructions"]
        executable_rows = ["# class\tsymbol"]
        for cls in prepare.TARGET_CLASSES:
            symbol = f"__ZN{len(cls)}{cls}4testEv"
            data_symbol = f"__ZN{len(cls)}{cls}9metaClassE"
            (target / f"{cls}.methods.txt").write_text(
                f"0x1000\t{symbol}\n0x2000\t{data_symbol}\n", encoding="utf-8")
            executable_rows.append(f"{cls}\t{symbol}")
            index_rows.append(f"0x1000\tcom.apple.iokit.IOSkywalkFamily\t{symbol}\t4")
        (target / "stage17-executable-methods.txt").write_text("\n".join(executable_rows)+"\n", encoding="utf-8")
        (asm / "INDEX.txt").write_text("\n".join(index_rows)+"\n", encoding="utf-8")
        manifest_path = ref_dir / "STAGE17-METHOD-MANIFEST.json"
        report = audit.audit(stage14, stage15, stage16, target, manifest_path,
                             ROOT, base / "stage17-report")
        assert report["status"] == "PASS", report
        assert report["target_method_disassembly_count"] == len(prepare.TARGET_CLASSES)
        assert report["target_non_code_symbol_count"] == len(prepare.TARGET_CLASSES)
        assert report["activation_gate"].startswith("BLOCKED")
        print(f"PASS: Stage 17 synthetic method manifest ({len(prepare.TARGET_CLASSES)} classes)")
        print(f"PASS: Stage 17 source ownership fences ({len(rows)}/{len(rows)})")
        print("PASS: Stage 17 archive SHA linkage and full report builder")
        print("PASS: Stage 17 kcabi class-list and executable-method patch is idempotent")
        print("PASS: Stage 17 separates executable methods from non-code class symbols")
        print("PASS: Stage 17 target manifest excludes upstream AppleBCMWLAN classes")


if __name__ == "__main__":
    main()
