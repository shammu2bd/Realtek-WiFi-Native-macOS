/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Private Sequoia WCL -> RTW88 radio control bridge.
 */
#include "RTW88WCLRadioBridge.hpp"
#include "RTW88UserClient.hpp"

#include <IOKit/IOLib.h>
#include <string.h>

RTW88WCLRadioBridge::~RTW88WCLRadioBridge()
{
    detach();
}

IOReturn RTW88WCLRadioBridge::attach(RTW88IEEE80211 *radio,
                                     RTW88WCLRadioEventSink *sink)
{
    if (!radio || !sink)
        return kIOReturnBadArgument;
    if (_radio)
        return kIOReturnBusy;
    if (radio->_delegate && radio->_delegate != this)
        return kIOReturnBusy;

    _radio = radio;
    _sink = sink;
    __atomic_store_n(&_scanInFlight, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_externalSupplicant, 0U, __ATOMIC_RELEASE);
    _radio->setEventDelegate(this);
    return kIOReturnSuccess;
}

void RTW88WCLRadioBridge::detach()
{
    RTW88IEEE80211 *radio = _radio;
    _sink = nullptr;
    __atomic_store_n(&_scanInFlight, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
    __atomic_store_n(&_externalSupplicant, 0U, __ATOMIC_RELEASE);

    /* The backend exposes its current delegate because it historically had
     * one owning controller. Do not erase a delegate installed by a newer
     * frontend instance. */
    if (radio && radio->_delegate == this)
        radio->setEventDelegate(nullptr);
    _radio = nullptr;
}

bool RTW88WCLRadioBridge::isZeroAddress(const uint8_t address[6])
{
    if (!address) return true;
    uint8_t aggregate = 0;
    for (unsigned i = 0; i < 6; ++i) aggregate |= address[i];
    return aggregate == 0;
}

bool RTW88WCLRadioBridge::isValidBSSID(const uint8_t address[6])
{
    return address && !isZeroAddress(address) && !(address[0] & 0x01);
}

IOReturn RTW88WCLRadioBridge::startScan(const uint16_t *channels,
                                        uint32_t channelCount,
                                        uint32_t *generationOut)
{
    if (generationOut) *generationOut = 0;
    if (!_radio) return kIOReturnNotReady;
    if ((channelCount && !channels) || channelCount > 128)
        return kIOReturnBadArgument;
    if (__atomic_load_n(&_scanInFlight, __ATOMIC_ACQUIRE) != 0)
        return kIOReturnBusy;

    /* Filter malformed channel hints but preserve the caller's order. The
     * RTW88 backend performs the hardware/regulatory capability selection. */
    uint16_t normalized[128] = {};
    uint32_t normalizedCount = 0;
    for (uint32_t i = 0; i < channelCount; ++i) {
        const uint16_t channel = channels[i];
        if (channel == 0 || channel > 196)
            return kIOReturnBadArgument;
        bool duplicate = false;
        for (uint32_t j = 0; j < normalizedCount; ++j) {
            if (normalized[j] == channel) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate)
            normalized[normalizedCount++] = channel;
    }

    /* Publish the transaction before asking the backend to start it. The
     * backend is asynchronous, but it may complete quickly; publishing after
     * cmdScan() returned would allow a completion callback to be lost and
     * leave the bridge stuck in scan-in-flight state. */
    const uint32_t generation =
        __atomic_add_fetch(&_scanGeneration, 1U, __ATOMIC_ACQ_REL);
    if (generationOut) *generationOut = generation;
    __atomic_store_n(&_scanInFlight, 1U, __ATOMIC_RELEASE);

    const IOReturn status = _radio->cmdScan(
        normalizedCount ? normalized : nullptr, normalizedCount);
    if (status != kIOReturnSuccess &&
        __atomic_load_n(&_scanGeneration, __ATOMIC_ACQUIRE) == generation)
        __atomic_store_n(&_scanInFlight, 0U, __ATOMIC_RELEASE);
    return status;
}

IOReturn RTW88WCLRadioBridge::abortScan()
{
    if (!_radio) return kIOReturnNotReady;
    if (!__atomic_load_n(&_scanInFlight, __ATOMIC_ACQUIRE))
        return kIOReturnSuccess;

    const IOReturn status = _radio->cmdAbortScan();
    if (status != kIOReturnSuccess)
        return status;

    /* scanDone() normally clears the flag and emits the completion event.
     * A successful backend abort can also reach its bounded forced-idle path;
     * in that case synthesize exactly one bridge-level completion. */
    RTW88StateResult state = {};
    if (_radio->cmdGetState(&state) == kIOReturnSuccess &&
        state.state != RTW88_STATE_SCANNING &&
        __atomic_exchange_n(&_scanInFlight, 0U, __ATOMIC_ACQ_REL)) {
        RTW88WCLRadioEvent event = {};
        event.event = kRTW88EventScanDone;
        event.value = 1; // synthesized completion means aborted
        event.scanGeneration = __atomic_load_n(&_scanGeneration, __ATOMIC_ACQUIRE);
        if (_sink) _sink->onRTW88WCLRadioEvent(event);
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLRadioBridge::associate(const uint8_t *ssid,
                                        uint8_t ssidLength,
                                        const uint8_t *bssidOrNull,
                                        const uint8_t *pmkOrNull,
                                        const uint8_t *rsnIEOrNull,
                                        uint16_t rsnIELength,
                                        bool externalSupplicant,
                                        uint32_t *generationOut)
{
    if (generationOut) *generationOut = 0;
    if (!_radio) return kIOReturnNotReady;
    if (!ssid || ssidLength == 0 || ssidLength > 32)
        return kIOReturnBadArgument;
    if (bssidOrNull && !isZeroAddress(bssidOrNull) && !isValidBSSID(bssidOrNull))
        return kIOReturnBadArgument;
    if ((rsnIELength && !rsnIEOrNull) || rsnIELength > 512)
        return kIOReturnBadArgument;
    if (rsnIELength) {
        if (rsnIELength < 2 || rsnIEOrNull[0] != 48 ||
            static_cast<uint16_t>(rsnIEOrNull[1] + 2U) != rsnIELength)
            return kIOReturnBadArgument;
    }

    char ssidString[33] = {};
    if (memchr(ssid, 0, ssidLength) != nullptr)
        return kIOReturnUnsupported; // backend still uses a C-string SSID
    memcpy(ssidString, ssid, ssidLength);
    ssidString[ssidLength] = '\0';

    const uint8_t *bssid = isZeroAddress(bssidOrNull) ? nullptr : bssidOrNull;

    RTW88StateResult state = {};
    if (_radio->cmdGetState(&state) == kIOReturnSuccess &&
        (state.state == RTW88_STATE_AUTHENTICATING ||
         state.state == RTW88_STATE_ASSOCIATING ||
         state.state == RTW88_STATE_HANDSHAKING ||
         state.state == RTW88_STATE_CONNECTED)) {
        if (_radio->matchesPendingJoin(ssidString, bssid, pmkOrNull)) {
            if (generationOut)
                *generationOut = __atomic_load_n(&_joinGeneration, __ATOMIC_ACQUIRE);
            return kIOReturnSuccess;
        }
        const IOReturn disconnectStatus = _radio->cmdDisconnect();
        if (disconnectStatus != kIOReturnSuccess)
            return disconnectStatus;
    }

    if (rsnIELength) {
        const IOReturn rsnStatus = _radio->cmdSetAssocRsnIE(rsnIEOrNull, rsnIELength);
        if (rsnStatus != kIOReturnSuccess)
            return rsnStatus;
    } else {
        _radio->clearAssocRsnIE();
    }

    const uint32_t protectedAssociation = (rsnIELength != 0 || pmkOrNull != nullptr) ? 1U : 0U;
    __atomic_store_n(&_associationProtected, protectedAssociation, __ATOMIC_RELEASE);

    /* cmdConnect() schedules authentication asynchronously and can emit a
     * backend event before returning to us. Publish the join generation and
     * pending flag first so that the event is associated with this request. */
    const uint32_t generation =
        __atomic_add_fetch(&_joinGeneration, 1U, __ATOMIC_ACQ_REL);
    if (generationOut) *generationOut = generation;
    __atomic_store_n(&_joinPending, 1U, __ATOMIC_RELEASE);
    __atomic_store_n(&_externalSupplicant, externalSupplicant ? 1U : 0U,
                     __ATOMIC_RELEASE);
    const IOReturn status = _radio->cmdConnect(
        ssidString, nullptr, pmkOrNull, bssid, externalSupplicant);
    if (status != kIOReturnSuccess &&
        __atomic_load_n(&_joinGeneration, __ATOMIC_ACQUIRE) == generation) {
        __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_externalSupplicant, 0U, __ATOMIC_RELEASE);
    }
    bzero(ssidString, sizeof(ssidString));
    return status;
}

IOReturn RTW88WCLRadioBridge::abortJoin()
{
    if (!_radio) return kIOReturnNotReady;
    const IOReturn status = _radio->cmdDisconnect();
    if (status == kIOReturnSuccess) {
        __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_externalSupplicant, 0U, __ATOMIC_RELEASE);
    }
    return status;
}

IOReturn RTW88WCLRadioBridge::leaveNetwork()
{
    return abortJoin();
}

IOReturn RTW88WCLRadioBridge::setAssociationRSNIE(const uint8_t *ie,
                                                  uint16_t length)
{
    if (!_radio) return kIOReturnNotReady;
    if (!ie || length < 2 || length > 512 || ie[0] != 48 ||
        static_cast<uint16_t>(ie[1] + 2U) != length)
        return kIOReturnBadArgument;
    const IOReturn status = _radio->cmdSetAssocRsnIE(ie, length);
    if (status == kIOReturnSuccess)
        __atomic_store_n(&_associationProtected, 1U, __ATOMIC_RELEASE);
    return status;
}

void RTW88WCLRadioBridge::clearAssociationRSNIE()
{
    if (_radio) _radio->clearAssocRsnIE();
    __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
}

bool RTW88WCLRadioBridge::connectionReady()
{
    if (!_radio)
        return false;
    RTW88StateResult state = {};
    if (_radio->cmdGetState(&state) != kIOReturnSuccess ||
        state.state != RTW88_STATE_CONNECTED)
        return false;
    const bool external =
        __atomic_load_n(&_externalSupplicant, __ATOMIC_ACQUIRE) != 0;
    return !external || !associationProtected() || _radio->externalKeysReady();
}

IOReturn RTW88WCLRadioBridge::installKey(bool pairwise, uint8_t keyIndex,
                                         uint32_t keyCipher,
                                         const uint8_t *key,
                                         uint8_t keyLength)
{
    if (!_radio) return kIOReturnNotReady;
    if (!key || keyLength == 0)
        return kIOReturnBadArgument;
    return _radio->cmdInstallExternalKey(pairwise, keyIndex, keyCipher,
                                         key, keyLength);
}

IOReturn RTW88WCLRadioBridge::copyScanBSS(uint32_t index, RTW88BSS *out)
{
    return _radio ? _radio->copyScanBSS(index, out) : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::copyCurrentBSS(RTW88BSS *out)
{
    return _radio ? _radio->copyCurrentBSS(out) : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::copyChannels(RTW88Channel *out,
                                           uint32_t capacity,
                                           uint32_t *count)
{
    return _radio ? _radio->copyChannels(out, capacity, count) : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::getRSSI(int *rssi)
{
    return _radio ? _radio->cmdGetRSSI(rssi) : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::getState(RTW88StateResult *state)
{
    return _radio ? _radio->cmdGetState(state) : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::powerOn()
{
    return _radio ? _radio->cmdPowerOn() : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::powerOff()
{
    return _radio ? _radio->cmdPowerOff() : kIOReturnNotReady;
}

IOReturn RTW88WCLRadioBridge::setMACAddress(const uint8_t address[6])
{
    if (!_radio) return kIOReturnNotReady;
    if (!address) return kIOReturnBadArgument;
    return _radio->setMACAddress(address);
}

IOReturn RTW88WCLRadioBridge::getMACAddress(uint8_t address[6])
{
    if (!_radio) return kIOReturnNotReady;
    if (!address) return kIOReturnBadArgument;
    _radio->getMACAddress(address);
    return kIOReturnSuccess;
}

UInt32 RTW88WCLRadioBridge::outputEthernetPacket(mbuf_t packet)
{
    return _radio ? _radio->outputPacket(packet) : static_cast<UInt32>(kIOReturnNotReady);
}

void RTW88WCLRadioBridge::rtw88Event(RTW88Event eventType, void *data)
{
    RTW88WCLRadioEvent event = {};
    event.event = eventType;
    event.scanGeneration = __atomic_load_n(&_scanGeneration, __ATOMIC_ACQUIRE);
    event.joinGeneration = __atomic_load_n(&_joinGeneration, __ATOMIC_ACQUIRE);
    if (data && (eventType == kRTW88EventScanDone ||
                 eventType == kRTW88EventDeauth))
        event.value = *static_cast<const uint32_t *>(data);

    switch (eventType) {
    case kRTW88EventScanDone:
        /* Suppress a late completion after abortScan() already synthesized
         * the completion for a backend forced-idle path. */
        if (!__atomic_exchange_n(&_scanInFlight, 0U, __ATOMIC_ACQ_REL))
            return;
        break;
    case kRTW88EventAssocDone:
        /* This is the raw 802.11 association boundary. For WPA2/WCL the
         * controlled port is still closed until Apple installs PTK and GTK;
         * the WCL interface must check externalKeysReady() before reporting
         * the full connection as usable. */
        __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
        break;
    case kRTW88EventDisconnected:
        __atomic_store_n(&_joinPending, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_associationProtected, 0U, __ATOMIC_RELEASE);
        __atomic_store_n(&_externalSupplicant, 0U, __ATOMIC_RELEASE);
        break;
    case kRTW88EventDeauth:
    case kRTW88EventRSSIChanged:
    case kRTW88EventConnected:
        /* Delivered to the WCL event queue; connectionReady() queries the
         * backend state before the interface publishes link-up. */
        break;
    }

    RTW88WCLRadioEventSink *sink = _sink;
    if (sink)
        sink->onRTW88WCLRadioEvent(event);
}
