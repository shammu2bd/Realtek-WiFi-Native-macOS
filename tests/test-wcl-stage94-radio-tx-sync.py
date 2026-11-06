#!/usr/bin/env python3
"""Stage94 read-only integration audit for the native radio TX state gate."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.cpp"
HPP = ROOT / "driver/RTL88WiFi/src/kext/RTW88IEEE80211.hpp"
GATE = ROOT / "driver/RTL88WiFi/src/kext/RTW88TxStateGate.hpp"
BA = ROOT / "driver/RTL88WiFi/src/kext/RTW88TxBAState.hpp"

def read(path):
    if not path.is_file():
        raise RuntimeError(f"missing audit input: {path.relative_to(ROOT)}")
    return path.read_text()

def function(source, signature):
    start = source.find(signature)
    if start < 0:
        raise RuntimeError(f"function not found: {signature}")
    opening = source.find("{", start)
    if opening < 0:
        raise RuntimeError(f"function body not found: {signature}")
    depth = 0
    quote = None
    escaped = False
    line_comment = False
    block_comment = False
    i = opening
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif quote:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
        elif ch == "/" and nxt == "/":
            line_comment = True
            i += 1
        elif ch == "/" and nxt == "*":
            block_comment = True
            i += 1
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1
    raise RuntimeError(f"unterminated function: {signature}")

cpp = read(CPP)
hpp = read(HPP)
gate = read(GATE)
ba = read(BA)
passed = []
failed = []

def check(name, condition, detail):
    (passed if condition else failed).append((name, detail))

# The low-level reader/writer gate is lock-free and has a gap-free downgrade.
check("GATE_READER_ADMISSION",
      "tryEnterTransmit()" in gate and
      "__atomic_compare_exchange_n(&_state, &observed, desired" in gate and
      "if (observed & kMutationBit)" in gate,
      "TX admission uses an atomic reader increment and rejects while a writer owns the gate")
check("GATE_WRITER_DRAIN",
      "tryBeginMutation()" in gate and
      "observed | kMutationBit" in gate and
      "bool ready() const" in gate,
      "writer closes admission and waits for all active reader leases")
check("GATE_GAP_FREE_DOWNGRADE",
      "TransmitLease downgrade()" in gate and
      "__atomic_compare_exchange_n(&gate->_state, &expected, 1U" in gate and
      "if (!ready())" in gate,
      "WPA key writer converts atomically into one TX reader without reopening admission")

# Every direct RTW88 ops->tx entry lives in a function that owns/validates a reader.
direct_functions = {
    "txDataFrame": "bool RTW88IEEE80211::txDataFrame(",
    "txMgmtFrame": "bool RTW88IEEE80211::txMgmtFrame(",
    "txNullFunc": "bool RTW88IEEE80211::txNullFunc(",
    "txAWDLDataFrame": "bool RTW88IEEE80211::txAWDLDataFrame("
}
direct_count = 0
for name, signature in direct_functions.items():
    body = function(cpp, signature)
    direct_count += body.count("_hw->ops->tx(")
    check(f"TX_SUBMIT_{name}",
          body.count("_hw->ops->tx(") == 1 and
          ("tryEnterTransmit()" in body or "existingLease" in body) and
          "_powered" in body,
          f"{name} has one RTW88 submit, validates/holds a reader lease, and checks powered state first")
check("NO_UNGUARDED_DIRECT_TX",
      cpp.count("_hw->ops->tx(") == direct_count and direct_count == 4,
      "all four direct RTW88 TX submissions are inside the audited leased functions")

output = function(cpp, "UInt32 RTW88IEEE80211::outputPacketWithCompletion(")
check("WCL_TX_ENTRY_LEASE",
      "tryEnterTransmit()" in output and
      output.find("tryEnterTransmit()") < output.find("txDataFrame(") and
      "&txLease" in output and "associatedVisible()" in output,
      "WMM/native packet callback acquires before reading connection state and carries the lease into frame submission")

probe = function(cpp, "bool RTW88IEEE80211::txProbeRequest()")
check("PROBE_POWERED_FAST_PATH",
      "tryEnterTransmit()" in probe and
      "!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE)" in probe and
      "txMgmtFrame(frame" in probe and "&txLease" in probe,
      "probe request returns before dereferencing hardware when radio is powered off")

# Frame-specific EAPOL protection has no mutable global 'next frame' flag.
data_tx = function(cpp, "bool RTW88IEEE80211::txDataFrame(")
eapol_tx = function(cpp, "bool RTW88IEEE80211::sendEAPOLKey(")
check("PER_FRAME_EAPOL_PROTECTION",
      "bool protectEapol" in data_tx and
      "RTW88ShouldProtectTxFrame(" in data_tx and
      "existingLease" in eapol_tx and
      "txDataFrame(m, nullptr, nullptr, nullptr, 2, 0," in eapol_tx and
      "_eapolTxProtect" not in cpp,
      "EAPOL encryption choice is a per-call argument; no shared protect-next-frame flag remains")

handle_eapol = function(cpp, "void RTW88IEEE80211::handleEAPOL(")
check("WPA_HANDSHAKE_WRITER_SNAPSHOT",
      handle_eapol.count("beginTxStateMutation()") >= 3 and
      handle_eapol.count("mutation.downgrade()") == 3 and
      handle_eapol.count("&txLease") >= 3 and
      "__atomic_load_n(&_powered, __ATOMIC_ACQUIRE)" in handle_eapol,
      "G1/M1/M3 authenticate and publish keys/nonces/replay under writer, then send the matching response on a downgraded reader")

check("M3_KEY_READY_ATOMIC",
      all("__atomic_" in line for line in cpp.splitlines() if "_m3KeysInstalled" in line),
      "every M3 key-ready access is atomic, including RX clear-unencrypted filtering")
check("NO_LEGACY_EAPOL_OR_BA_FLAGS",
      "_eapolTxProtect" not in cpp + hpp and "_txBaActive" not in cpp + hpp,
      "shared EAPOL protection and split BA active/TID fields are removed")

# PTK/GTK and station pointer replacement/retirement are writer-controlled.
clear_keys = function(cpp, "void RTW88IEEE80211::clearKeys()")
release_sta = function(cpp, "void RTW88IEEE80211::releaseSta()")
install_under = function(cpp, "bool RTW88IEEE80211::installKeyUnderMutation(")
check("KEY_AND_STATION_WRITER_BARRIERS",
      "beginTxStateMutation()" in clear_keys and
      "beginTxStateMutation()" in release_sta and
      "mutation->ready()" in install_under and
      "installKeyUnderMutation" in cpp,
      "key clearing/replacement and station retirement wait for TX readers to drain")
check("REPLACEMENT_KEY_FAILURE_PRESERVES_OLD",
      install_under.find("_hw->ops->set_key(_hw, SET_KEY") <
      install_under.find("IOFree(oldKey") and
      "previous key retained" in install_under,
      "candidate SET_KEY succeeds before the old software key object is freed")

# BA active+TID is a single atomic word; BA mutation paths drain WMM readers.
check("PACKED_BA_SNAPSHOT",
      "snapshot() const" in ba and
      "__atomic_load_n(&_state, __ATOMIC_ACQUIRE)" in ba and
      "__atomic_store_n(&_state" in ba and
      "_txBAState.snapshot()" in data_tx and
      "_txBaActive" not in cpp + hpp,
      "TX observes active+TID from one packed atomic BA snapshot")
back_action = function(cpp, "void RTW88IEEE80211::handleBackAction(")
check("BA_MUTATIONS_DRAIN_TX",
      back_action.count("beginTxStateMutation()") >= 2 and
      "_txBAState.activate(tid)" in back_action and
      "_txBAState.clear()" in back_action,
      "ADDBA response and DELBA state changes are serialized against all WMM submitters")

# Sequence/PN values are monotonically allocated, never reset by key/STA teardown.
check("MONOTONIC_SEQUENCE_AND_PN",
      "resetCCMP()" not in cpp and "resetQoS()" not in cpp and
      "nextCCMP(&packetNumber)" in data_tx and
      "_txSequenceNumbers.nextQoS" in cpp,
      "no CCMP PN or QoS sequence reset remains in radio teardown/rekey paths")

# Shared target BSS and channel changes are writer-protected.
retry = function(cpp, "bool RTW88IEEE80211::retryOtherBss(")
channel = function(cpp, "void RTW88IEEE80211::setConnectedChandef(")
restore = function(cpp, "void RTW88IEEE80211::restoreConnectedChannel()")
scan = function(cpp, "void RTW88IEEE80211::runManualScan()")
check("TARGET_BSS_RETRY_PUBLICATION",
      "beginTxStateMutation()" in retry and
      retry.find("beginTxStateMutation()") < retry.find("memcpy(&_targetBSS") and
      retry.find("IOLockUnlock(_bssLock)") < retry.find("mutation.finish()"),
      "retry-to-another-BSS target/RSN publication is atomic to TX and does not wait for the gate while holding the BSS lock")
check("CHANNEL_AND_WIDTH_MUTATION",
      ("beginTxStateMutation()" in channel or "existingMutation" in channel) and
      "beginTxStateMutation()" in restore and
      "beginTxStateMutation()" in scan,
      "HT/VHT width, connected restore and manual scan retunes share TX writer admission")

# Shutdown must not hold the radio writer while RTW88 drains RX/NAPI or PCI workers.
power_off = function(cpp, "void RTW88IEEE80211::powerOff()")
stop = function(cpp, "void RTW88IEEE80211::stop()")
stop_core = power_off.find("hw->ops->stop")
stop_last_finish = power_off.rfind("mutation.finish();", 0, stop_core)
check("POWEROFF_RELEASES_WRITER_BEFORE_CORE_DRAIN",
      stop_core > 0 and stop_last_finish >= 0 and
      power_off.find("__atomic_store_n(&_powered, false") < stop_core and
      "_coreStopping" in power_off,
      "powered=false and reader drain complete before ops->stop runs with no writer held")
check("STOP_RELEASES_WRITER_BEFORE_REMOVAL",
      stop.find("powerOff();") < stop.find("remove_interface") <
      stop.find("rtw_pci_remove(") and
      "ops->stop" not in stop,
      "VIF/PCI teardown follows the out-of-gate core stop/drain sequence")
power_on = function(cpp, "IOReturn RTW88IEEE80211::powerOn()")
check("POWERON_PUBLISHES_AFTER_RESTORE",
      power_on.find("hw->ops->start(hw)") < power_on.find("rtw88_restore_interface(hw, vif)") <
      power_on.find("__atomic_store_n(&_powered, true") and
      "_coreStarting" in power_on,
      "radio accepts TX only after core start and interface restoration are complete")

check("NO_MECHANICAL_ATOMIC_CORRUPTION",
      "__atomic_store_n(&_scanReturnState, =" not in cpp and
      "setRadioState(=" not in cpp and
      not re.search(r"^\s*_(?:state|scanReturnState|associatedVisible|powered|manualScanChannelCount|manualScanOnHomeChannel)\s*=", cpp, re.M),
      "no malformed atomic predicates or plain writes to published radio/scan/power state")
check("STOPPING_BLOCKS_HANDSHAKE_RX",
      "__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE)" in
      function(cpp, "void RTW88IEEE80211::handleEAPOL(") and
      "_stopping" in hpp and "_coreStarting" in hpp and "_coreStopping" in hpp,
      "late EAPOL RX and overlapping lifecycle start/stop are fenced")

print("RTL88WIFI STAGE94 RADIO TX SYNCHRONIZATION AUDIT")
print("SCOPE=READ_ONLY_SOURCE_AND_PORTABLE_MODEL_AUDIT")
for name, detail in passed:
    print(f"PASS: {name}: {detail}")
for name, detail in failed:
    print(f"BLOCKER: {name}: {detail}")
print(f"PASS_COUNT={len(passed)}")
print(f"BLOCKER_COUNT={len(failed)}")
print("NATIVE_ACTIVATION=BLOCKED")
if failed:
    print("STAGE94_RESULT=BLOCKED")
    sys.exit(20)
print("STAGE94_RESULT=PASS_SOURCE_AUDIT_ONLY")
