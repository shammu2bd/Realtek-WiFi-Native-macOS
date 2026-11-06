#!/usr/bin/env python3
"""Stage113 executable-derived OSBundleLibraries synchronization tests."""
import importlib.util
import pathlib
import plistlib
import tempfile
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/sync-native-dependencies-from-linked-binary.py"
spec = importlib.util.spec_from_file_location("stage113_sync", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

GOOD = {
    "com.apple.iokit.IO80211Family": "1200.13.1",
    "com.apple.iokit.IOSkywalkFamily": "1.0",
    "com.apple.iokit.IOPCIFamily": "2.9",
    "com.apple.iokit.IONetworkingFamily": "3.4",
    "com.apple.kpi.private": "24.6.0",
    "com.apple.kpi.unsupported": "24.6.0",
}
xml = plistlib.dumps({"OSBundleLibraries": GOOD}, fmt=plistlib.FMT_XML).decode()
assert module.parse_kmutil_libraries("No variant specified, falling back to release\n" + xml) == GOOD

for bad in (
    {"com.apple.iokit.IO80211FamilyLegacy": "1.0"},
    {"com.apple.iokit.IO80211Family": "1200.13.1"},
    {},
):
    payload = plistlib.dumps({"OSBundleLibraries": bad}, fmt=plistlib.FMT_XML).decode()
    try:
        module.parse_kmutil_libraries(payload)
    except ValueError:
        pass
    else:
        raise AssertionError(f"invalid dependency set was accepted: {bad}")

with tempfile.TemporaryDirectory() as temp:
    bundle = pathlib.Path(temp) / "RTL88WiFiNative.kext"
    contents = bundle / "Contents"
    binary = contents / "MacOS" / "RTL88WiFiNative"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"test Mach-O placeholder")
    plist = {
        "CFBundleIdentifier": "io.github.x1ren41l.RTL88WiFi",
        "CFBundleExecutable": "RTL88WiFiNative",
        "OSBundleLibraries": {"com.apple.kpi.private": "WRONG"},
        "IOKitPersonalities": {"Native": {"IOClass": "RTW88WCLController"}},
    }
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle)
    def fake_runner(command, **kwargs):
        assert command == ["/usr/bin/kmutil", "libraries", "--bundle-path", str(bundle), "--xml"]
        return SimpleNamespace(returncode=0, stdout=xml, stderr="")
    actual = module.synchronize(bundle, runner=fake_runner)
    with (contents / "Info.plist").open("rb") as handle:
        written = plistlib.load(handle)
    assert actual == GOOD
    assert written["OSBundleLibraries"] == GOOD
    assert written["CFBundleIdentifier"] == plist["CFBundleIdentifier"]
    assert written["IOKitPersonalities"] == plist["IOKitPersonalities"]

print("PASS: kmutil XML preamble parsing")
print("PASS: required native dependencies enforced")
print("PASS: legacy IO80211FamilyLegacy dependency rejected")
print("PASS: linked dependency dictionary replaces stale plist metadata")
print("PASS: unrelated bundle identity and personality metadata preserved")
