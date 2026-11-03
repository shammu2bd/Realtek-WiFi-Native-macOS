"""Bounded associated-STA scan policy regression tests.

Compiles the same pure helpers used by the kext, then checks that the scan
entry points enable connected scans without aging the unscanned BSS cache.
This does not simulate RF timing, CoreWiFi or hardware behavior.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
header = root / 'driver/RTL88WiFi/src/kext/RTW88RoamScanPolicy.hpp'
cpp = root / 'driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp'
ctrl = root / 'driver/RTL88WiFi/src/kext/RTL88WiFi.cpp'
src = cpp.read_text()
ctl = ctrl.read_text()

assert 'const bool connectedScan = (_state == RTW88_STATE_CONNECTED);' in src
assert 'if (!aborted && !partialScan)' in src
assert 'if (!connectedScan) {' in src and '_scanGeneration++;' in src
assert 'const bool firmwareScan = !connectedScan' in src
assert 'cmdScan(requested, d->num_channels)' in ctl
assert 'software-connected' in src
assert 'if (_scanReturnState != RTW88_STATE_IDLE)' in src and '_manualScanAbort = true;' in src
assert 'requested BSS missing from cache; starting one full refresh before join' in src
assert '_missingBssRescanAttempted' in src
worker = src[src.index('void RTW88IEEE80211::runManualScan()'):src.index('/* ------------------------------------------------------------------ */\n/*  Connect', src.index('void RTW88IEEE80211::runManualScan()'))]
assert worker.rindex('_manualScanChannelCount = 0;') < worker.index('scanDone(aborted);'), 'old worker must release scan state before deferred callback'
assert worker.index('_manualScanAbort = false;') < worker.index('scanDone(aborted);'), 'old worker must not clear a new scan abort flag'

program = r'''
#include <cassert>
#include <cstdint>
#include "RTW88RoamScanPolicy.hpp"
int main() {
    using namespace RTW88RoamScan;
    uint16_t channels[kMaxMeshChannels] = {};
    uint32_t count = 0;
    assert(requestedContains(nullptr, 0, 36));
    const uint16_t requested[] = { 6, 36, 149 };
    assert(requestedContains(requested, 3, 36));
    assert(!requestedContains(requested, 3, 44));
    assert(appendUnique(channels, &count, kMaxMeshChannels, 36, 6));
    assert(!appendUnique(channels, &count, kMaxMeshChannels, 6, 6)); // home
    assert(!appendUnique(channels, &count, kMaxMeshChannels, 36, 6)); // duplicate
    assert(appendUnique(channels, &count, kMaxMeshChannels, 149, 6));
    for (uint16_t c = 1; c <= 20; ++c)
        (void)appendUnique(channels, &count, kMaxMeshChannels, c, 6);
    assert(count == kMaxMeshChannels);
    assert(!appendUnique(channels, &count, kMaxMeshChannels, 161, 6)); // capped
    assert(channels[0] == 36 && channels[1] == 149);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as td:
    srcfile = Path(td) / 'test.cpp'
    exe = Path(td) / 'test'
    srcfile.write_text(program)
    subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-I', str(header.parent), str(srcfile), '-o', str(exe)],
                   check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: bounded connected-scan policy and source integration guards')
