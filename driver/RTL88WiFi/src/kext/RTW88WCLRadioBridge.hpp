/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * RTL88WiFi private Sequoia WCL development layer.
 *
 * This bridge is deliberately independent of Apple's private WCL classes.
 * It translates the core infrastructure operations needed by a future
 * IO80211InfraProtocol frontend into the already-tested RTW88IEEE80211 API.
 * The WCL controller/interface owns ABI dispatch, message posting and
 * Skywalk packet lifetime; this class owns none of those objects.
 */
#pragma once

#include <stdint.h>
#include <sys/mbuf.h>
#include <IOKit/IOReturn.h>

#include "RTW88IEEE80211.hpp"

struct RTW88StateResult;

struct RTW88WCLRadioEvent {
    RTW88Event event;
    uint32_t scanGeneration;
    uint32_t joinGeneration;
    uint32_t value;
};

class RTW88WCLRadioEventSink {
public:
    /* Implementations must enqueue the event onto the native WCL work queue.
     * Do not call IO80211Controller::postMessage from the RTW88 callback's
     * arbitrary execution context. */
    virtual void onRTW88WCLRadioEvent(const RTW88WCLRadioEvent &event) = 0;
    virtual ~RTW88WCLRadioEventSink() {}
};

class RTW88WCLRadioBridge final : public RTW88EventDelegate {
public:
    RTW88WCLRadioBridge() = default;
    ~RTW88WCLRadioBridge() override;

    RTW88WCLRadioBridge(const RTW88WCLRadioBridge &) = delete;
    RTW88WCLRadioBridge &operator=(const RTW88WCLRadioBridge &) = delete;

    /* Non-owning attachment. The native frontend must own an otherwise
     * unclaimed radio event delegate; refusing to replace an existing
     * delegate prevents an experimental WCL instance from silently stealing
     * callbacks from the currently-running legacy frontend. Stop/quiesce the
     * radio before detach/destruction so no callback can still be in flight. */
    IOReturn attach(RTW88IEEE80211 *radio, RTW88WCLRadioEventSink *sink);
    void detach();
    bool isAttached() const { return _radio != nullptr; }

    IOReturn startScan(const uint16_t *channels, uint32_t channelCount,
                        uint32_t *generationOut = nullptr);
    IOReturn abortScan();

    /* WCL SSIDs are length-delimited. The current radio backend accepts a
     * NUL-terminated string, so embedded-NUL SSIDs are rejected rather than
     * silently truncated until the backend itself is converted to a
     * length-delimited representation. A null/all-zero BSSID means wildcard. */
    IOReturn associate(const uint8_t *ssid, uint8_t ssidLength,
                       const uint8_t *bssidOrNull,
                       const uint8_t *pmkOrNull,
                       const uint8_t *rsnIEOrNull,
                       uint16_t rsnIELength,
                       bool externalSupplicant = false,
                       uint32_t *generationOut = nullptr);
    IOReturn abortJoin();
    IOReturn leaveNetwork();
    IOReturn setAssociationRSNIE(const uint8_t *ie, uint16_t length);
    void clearAssociationRSNIE();

    /* True once the backend is in CONNECTED state. When the optional external
     * supplicant path is selected, protected links also require PTK+GTK; native
     * WCL currently uses the backend's internal WPA2 handshake instead. Raw
     * AssocDone alone does not mean the controlled port is open. */
    bool connectionReady();
    bool associationProtected() const {
        return __atomic_load_n(&_associationProtected, __ATOMIC_ACQUIRE) != 0;
    }

    /* keyCipher must already be translated by the WCL frontend to the Linux
     * WLAN_CIPHER_SUITE_* value expected by RTW88IEEE80211. */
    IOReturn installKey(bool pairwise, uint8_t keyIndex, uint32_t keyCipher,
                        const uint8_t *key, uint8_t keyLength);

    IOReturn copyScanBSS(uint32_t index, RTW88BSS *out);
    IOReturn copyCurrentBSS(RTW88BSS *out);
    IOReturn copyChannels(RTW88Channel *out, uint32_t capacity, uint32_t *count);
    IOReturn getRSSI(int *rssi);
    IOReturn powerOn();
    IOReturn powerOff();
    IOReturn setMACAddress(const uint8_t address[6]);
    IOReturn getMACAddress(uint8_t address[6]);
    IOReturn getState(RTW88StateResult *state);

    /* This is only the backend hand-off. A Skywalk caller must translate its
     * packet to an mbuf with correct ownership before calling it, and must
     * preserve the backend's OUTPUT_STALL / OUTPUT_DROPPED semantics. */
    UInt32 outputEthernetPacket(mbuf_t packet);

    uint32_t scanGeneration() const {
        return __atomic_load_n(&_scanGeneration, __ATOMIC_ACQUIRE);
    }
    uint32_t joinGeneration() const {
        return __atomic_load_n(&_joinGeneration, __ATOMIC_ACQUIRE);
    }
    bool scanInFlight() const {
        return __atomic_load_n(&_scanInFlight, __ATOMIC_ACQUIRE) != 0;
    }
    bool joinPending() const {
        return __atomic_load_n(&_joinPending, __ATOMIC_ACQUIRE) != 0;
    }
    bool externalKeysReady() const {
        return _radio && _radio->externalKeysReady();
    }

    void rtw88Event(RTW88Event event, void *data) override;

private:
    static bool isZeroAddress(const uint8_t address[6]);
    static bool isValidBSSID(const uint8_t address[6]);

    RTW88IEEE80211 *_radio = nullptr;                 // non-owning
    RTW88WCLRadioEventSink *_sink = nullptr;           // non-owning
    uint32_t _scanGeneration = 0;   // accessed with __atomic builtins
    uint32_t _joinGeneration = 0;   // accessed with __atomic builtins
    uint32_t _scanInFlight = 0;     // accessed with __atomic builtins
    uint32_t _joinPending = 0;      // accessed with __atomic builtins
    uint32_t _associationProtected = 0; // accessed with __atomic builtins
    uint32_t _externalSupplicant = 0;   // accessed with __atomic builtins
};
