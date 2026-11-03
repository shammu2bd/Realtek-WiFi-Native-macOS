#!/usr/bin/env python3
"""Host-side synthetic tests for Stage 16 evidence correlation."""
from __future__ import annotations
import importlib.util
import json
import tempfile
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/audit-skywalk-packet-semantics-stage16.py"
spec = importlib.util.spec_from_file_location("stage16_audit", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(mod)


def make_tar(path: Path, root: Path, arcname: str) -> None:
    with tarfile.open(path, "w:gz") as tf:
        tf.add(root, arcname=arcname)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="stage16-tests-") as td:
        base = Path(td)
        p14 = base / "p14" / "24H32"
        p15 = base / "p15" / "stage15"
        p14.mkdir(parents=True)
        (p14 / "sizes.txt").write_text(
            "IOSkywalkPacket 0x70 com.apple.iokit.IOSkywalkFamily\n"
            "IOSkywalkPacketBuffer 0x90 com.apple.iokit.IOSkywalkFamily\n"
            "IOSkywalkMemorySegment 0x78 com.apple.iokit.IOSkywalkFamily\n")
        body = p15 / "bodies"
        body.mkdir(parents=True)
        methods = []
        offset_pairs = list(mod.FIELD_GETTERS.items())
        for i, ((owner, method), offset) in enumerate(offset_pairs):
            name = f"{owner}-{method}-0-body.asm.txt"
            if i % 3 == 0:
                assembly = (
                    f"# 0x1000 __Zsynthetic_{i}\n"
                    f"1000: mov rax, qword ptr [rdi + {hex(offset)}]\n1004: ret\n")
            elif i % 3 == 1:
                assembly = (
                    f"# 0x1000 __Zsynthetic_{i}\n"
                    "1000: push rbx\n1001: mov rbx, rdi\n"
                    f"1004: mov rax, qword ptr [rbx + {hex(offset)}]\n"
                    "1008: pop rbx\n1009: ret\n")
            else:
                assembly = (
                    f"# 0x1000 __Zsynthetic_{i}\n"
                    "1000: push rbp\n1001: mov rbp, rsp\n"
                    "1004: mov qword ptr [rbp - 0x8], rdi\n"
                    "1008: mov r12, qword ptr [rbp - 0x8]\n"
                    f"100c: mov rax, qword ptr [r12 + {hex(offset)}]\n"
                    "1010: pop rbp\n1011: ret\n")
            (body / name).write_text(assembly)
            methods.append({"class": owner, "method": method, "status": "PASS",
                            "symbols": [f"__Zsynthetic_{i}"],
                            "disassembly_files": [f"bodies/{name}"]})
        # Pad report method list to exact Stage15 count with non-field methods.
        while len(methods) < mod.EXPECTED_STAGE15_METHODS:
            methods.append({"class": "IOSkywalkPacket", "method": f"extra{len(methods)}",
                            "status": "PASS", "symbols": ["__Zextra"],
                            "disassembly_files": [f"bodies/{next(iter(p.name for p in body.iterdir()))}"]})
        stage14_tar = base / "stage14.tar.gz"
        stage15_tar = base / "stage15.tar.gz"
        make_tar(stage14_tar, base / "p14", "24H32")
        stage14_hash = mod.sha256_file(stage14_tar)
        (p15 / "STAGE15-ABI-ACCESSOR-AUDIT.json").write_text(json.dumps({
            "stage": 15, "status": "PASS", "input_sha256": stage14_hash,
            "required_method_count": 18, "methods_with_disassembly": 18,
            "method_audit": methods,
        }))
        make_tar(stage15_tar, base / "p15", "stage15")
        extracted14 = base / "e14"; extracted15 = base / "e15"
        mod.safe_extract(stage14_tar, extracted14)
        mod.safe_extract(stage15_tar, extracted15)
        extracted15 = mod.one_file(extracted15, "STAGE15-ABI-ACCESSOR-AUDIT.json").parent
        audit = mod.parse_method_audit(extracted15)
        assert audit["input_sha256"] == stage14_hash
        sizes = mod.parse_sizes(extracted14)
        assert sizes == mod.TARGET_CLASS_SIZES
        alias_fixture = extracted15 / "bodies" / "alias-fixture.asm.txt"
        alias_fixture.write_text(
            "# alias fixture\n"
            "1000: push rbp\n"
            "1001: mov rbp, rsp\n"
            "1004: mov qword ptr [rbp - 0x8], rdi\n"
            "1008: mov r12, qword ptr [rbp - 0x8]\n"
            "100c: mov rax, qword ptr [r12 + 0x30]\n"
            "1010: pop rbp\n"
            "1011: ret\n")
        alias_offsets, alias_evidence = mod.inspect_this_reads(
            extracted15, {"disassembly_files": ["bodies/alias-fixture.asm.txt"]})
        assert 0x30 in alias_offsets, (alias_offsets, alias_evidence)
        unrelated = extracted15 / "bodies" / "unrelated-register.asm.txt"
        unrelated.write_text(
            "# RBX is not derived from this\n"
            "1000: mov rax, qword ptr [rbx + 0x30]\n"
            "1004: ret\n")
        unrelated_offsets, _ = mod.inspect_this_reads(
            extracted15, {"disassembly_files": ["bodies/unrelated-register.asm.txt"]})
        assert not unrelated_offsets, unrelated_offsets
        for ((owner, method), expected) in offset_pairs:
            row = mod.find_method_row(audit, owner, method)
            got, _ = mod.inspect_this_reads(extracted15, row)
            assert expected in got, (owner, method, expected, got)
        # Give source_checks a small deterministic project fixture; the
        # synthetic audit must not depend on unrelated files in the repo.
        project = base / "project"
        source_root = project / "driver/RTL88WiFi/src/kext/wcl24h32"
        source_root.mkdir(parents=True)
        (source_root / "RTW88WCLSkywalkRxAdapter.cpp").write_text("\n".join([
            "pool->allocatePacket(1, &packet, 1);",
            "if (result != kIOReturnSuccess || !packet)",
            "packet->getPacketType() != kIOSkywalkPacketTypeNetwork",
            "packet->getPacketBufferPool() != pool",
            "packet->getPacketBufferCount() != 1",
            "packet->getPacketBuffers(buffers, 1) != 1 || !buffers[0]",
            "if (!segment)", "if (!memory)",
            "RTW88WCLResolvePacketBufferAddress(span);",
            "packet->setDataOffsetAndLength(0, packetLength);",
            "buffer->getDataLength() != packetLength",
            "mbuf_copydata(source, 0, packetLength, destination);",
            "packet->setCompletionStatus(0);", "*outPacket = packet;",
            "if (!valid)\n        (void)pool->deallocatePacket(packet);",
            "mbuf_freem(source);",
            "if (!accepted) {\n                    (void)_rxPool->deallocatePacket(packet);",
        ]))
        (source_root / "RTW88WCLController.cpp").write_text(
            "return self->_stagedRxPackets.push(preparedPacket);\n"
            "completion-queue registration/ownership is still fenced\n"
            "refusing publication until Skywalk datapath is ready\n")
        (source_root / "RTW88WCLPacketSpanValidation.hpp").write_text(
            "RTW88WCLPacketSpanIsValid UINT64_MAX - span.dataOffset "
            "UINT64_MAX - relative UINTPTR_MAX\n")
        packet_header = project / mod.PACKET_HEADER_RELATIVE
        packet_header.parent.mkdir(parents=True, exist_ok=True)
        packet_header.write_text("\n".join(
            f"UInt32 {field}; // {offset} (0x{offset:x})" for field, offset in mod.PACKET_HEADER_FIELD_OFFSETS.items()
        ) + "\n")
        result = mod.audit(stage14_tar, stage15_tar, project, base / "stage16-out")
        assert result["status"] == "PASS", result
        assert len(result["field_getter_layout_audit"]) == 9
        assert mod.FIELD_GETTERS[("IOSkywalkPacket", "getPacketBufferCount")] == 0x64
        assert mod.FIELD_GETTERS[("IOSkywalkPacket", "getPacketBuffers")] == 0x64
        assert len(result["rx_source_and_ownership_checks"]) == 11
        assert result["packet_header_layout_audit"]["status"] == "PASS"
        assert mod.TARGET_CLASS_SIZES["IOSkywalkPacket"] == 0x70
        print("PASS: Stage 16 full synthetic audit (archive linkage, 0x70 packet boundary, header, sizes, getters, source invariants)")


if __name__ == "__main__":
    main()
