/* SPDX-License-Identifier: GPL-2.0-only
 * RTL88WiFi native Sequoia 24H32 IO80211InfraProtocol implementation slice.
 *
 * This translation unit is compile-only for now. It must remain separate from
 * the legacy Airport/IO80211FamilyLegacy translation units until the native
 * controller owns PCI/MMIO/DMA and the Skywalk datapath is integrated.
 */
#include "RTW88WCLController.hpp"
#include "RTW88WCLInfraInterface.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>
#include <string.h>

#define super IO80211InfraProtocol
OSDefineMetaClassAndStructors(RTW88WCLInfraInterface, IO80211InfraProtocol)

namespace {
enum : unsigned int {
    kWCLMessageDeauth = 203,
    kWCLMessageAssocComplete = 211,
    kWCLMessageConnectComplete = 213,
    kWCLMessageJoinAbortComplete = 214,
    kWCLMessageLinkStatus = 216,
    kWCLMessageLqmUpdate = 39,
    kWCLMessageScanResult = 201,
    kWCLMessageScanDone = 237
};

struct RTW88WCLBeaconMetadata {
    uint32_t ieLength;
    uint16_t channelSpec;
    uint8_t ssid[32];
    uint8_t ssidLength;
    uint8_t channel;
    uint8_t reserved0;
    uint8_t bssid[6];
    uint8_t reserved1;
    int32_t rssi;
    int16_t noise;
    int16_t snr;
    uint16_t interval;
    uint16_t capability;
    uint32_t flags;
};
static_assert(sizeof(RTW88WCLBeaconMetadata) == 64,
              "Sequoia WCL beacon message header size");

enum : uint32_t {
    kWCLBeaconSSIDPresent = 1U << 1,
    kWCLBeaconRSSIValid = 1U << 14
};

struct RTW88WCLAssociationEvent {
    uint16_t status;
    uint16_t reason;
    uint8_t mlo;
    uint8_t bssid[6];
    uint8_t reserved;
    uint32_t mloData[2];
    int32_t driverStatus;
    int32_t driverReason;
};
static_assert(sizeof(RTW88WCLAssociationEvent) == 28,
              "Sequoia WCL association event size");

struct RTW88WCLConnectionPeer {
    uint8_t bssid[6];
    uint16_t reserved;
    int32_t driverStatus;
    int32_t driverReason;
};
static_assert(sizeof(RTW88WCLConnectionPeer) == 16,
              "Sequoia WCL connection peer size");

struct RTW88WCLConnectionEvent {
    uint16_t status;
    uint16_t reason;
    RTW88WCLConnectionPeer peers[10];
};
static_assert(sizeof(RTW88WCLConnectionEvent) == 164,
              "Sequoia WCL connection event size");

struct RTW88WCLLinkStatusEvent {
    uint8_t bssid[6];
    uint8_t up;
    uint8_t reserved;
    int32_t reason;
};
static_assert(sizeof(RTW88WCLLinkStatusEvent) == 12,
              "Sequoia WCL link status event size");

struct RTW88WCLLqmUpdate {
    uint8_t rssiValid;
    uint8_t reserved[3];
    int32_t rssi;
    uint8_t tail[0x150 - 8];
};
static_assert(sizeof(RTW88WCLLqmUpdate) == 0x150,
              "Sequoia WCL LQM update size");

static bool isZeroAddress(const uint8_t *address, size_t length)
{
    if (!address) return true;
    uint8_t aggregate = 0;
    for (size_t i = 0; i < length; ++i) aggregate |= address[i];
    return aggregate == 0;
}

static bool validInformationElements(const uint8_t *ies, size_t length)
{
    if (length && !ies) return false;
    size_t offset = 0;
    while (offset < length) {
        if (length - offset < 2) return false;
        const size_t elementLength = ies[offset + 1];
        if (elementLength > length - offset - 2) return false;
        offset += 2 + elementLength;
    }
    return true;
}

/* WCL's 24H32 setCIPHER_KEY path carries PMK/PMKSA/MSK semantics. It is not
 * the legacy PTK/GTK key slot. The current RTW88 WCL path supplies the PMK in
 * ASSOCIATE and runs the internal WPA2 handshake; enterprise PMKSA insertion
 * is not implemented here, so setCIPHER_KEY must fail closed. */

static uint16_t channelFlags(const RTW88Channel &channel)
{
    uint32_t flags = APPLE80211_C_FLAG_20MHZ;
    flags |= channel.number <= 14 ? APPLE80211_C_FLAG_2GHZ
                                  : APPLE80211_C_FLAG_5GHZ;
    if (channel.radar) flags |= APPLE80211_C_FLAG_DFS;
    if (!channel.passive && !channel.radar) flags |= APPLE80211_C_FLAG_ACTIVE;
    return static_cast<uint16_t>(flags);
}
} // namespace

bool RTW88WCLInfraInterface::init()
{
    if (!super::init())
        return false;
    clearRegistrationInfo();
    _controller = nullptr;
    _workQueue = nullptr;
    _scanFilter = {};
    bzero(_targetBSSID, sizeof(_targetBSSID));
    _scanActive = false;
    _activeScanGeneration = 0;
    _activeJoinGeneration = 0;
    _assocNotified = false;
    _connectNotified = false;
    _stopping = false;
    return true;
}

bool RTW88WCLInfraInterface::init(IOService *provider, ether_addr *address)
{
    if (!provider || !address || !super::init())
        return false;

    _controller = OSDynamicCast(RTW88WCLController, provider);
    if (!_controller)
        return false;

    if (!IO80211SkywalkInterface::init(provider, address))
        return false;

    clearRegistrationInfo();
    return true;
}

IOReturn RTW88WCLInfraInterface::attachRadio(RTW88IEEE80211 *radio)
{
    if (!radio || !_controller)
        return kIOReturnBadArgument;
    if (_bridge.isAttached() || _workQueue)
        return kIOReturnBusy;

    IOWorkLoop *workLoop = _controller->getWorkLoop();
    if (!workLoop)
        return kIOReturnNotReady;

    RTW88WCLWorkQueue *queue = new RTW88WCLWorkQueue;
    if (!queue)
        return kIOReturnNoMemory;
    if (!queue->init(this, workLoop, this)) {
        queue->release();
        return kIOReturnNoResources;
    }

    IOReturn status = _bridge.attach(radio, queue);
    if (status != kIOReturnSuccess) {
        queue->stop();
        queue->release();
        return status;
    }
    _workQueue = queue;
    _stopping = false;
    return kIOReturnSuccess;
}

void RTW88WCLInfraInterface::detachRadio()
{
    _stopping = true;
    /* Quiesce the producer first, then remove the work source. The controller
     * must stop the radio before destroying its backend object. */
    _bridge.detach();
    if (_workQueue) {
        _workQueue->stop();
        _workQueue->release();
        _workQueue = nullptr;
    }
    _scanActive = false;
    _activeScanGeneration = 0;
    _activeJoinGeneration = 0;
    _assocNotified = false;
    _connectNotified = false;
}

void RTW88WCLInfraInterface::free()
{
    clearRegistrationInfo();
    detachRadio();
    _controller = nullptr;
    super::free();
}

void RTW88WCLInfraInterface::clearRegistrationInfo()
{
    RTW88WCLRegistrationInfo24H32::clear(_registrationInfo);
    _registrationInfoPrepared = false;
}

bool RTW88WCLInfraInterface::prepareRegistrationInfo(const ether_addr &address)
{
    using namespace RTW88WCLRegistrationInfo24H32;

    clearRegistrationInfo();
    auto *info = reinterpret_cast<IOSkywalkEthernetInterface::RegistrationInfo *>(
        _registrationInfo.bytes);

    /* 24H32 initRegistrationInfo requires option 1 and the exact 0x130 size.
     * It supplies the other opaque slots through this interface's virtual
     * hooks; do not replace it with a guessed local structure initializer.
     */
    if (!initRegistrationInfo(info, 1, sizeof(_registrationInfo.bytes))) {
        clearRegistrationInfo();
        return false;
    }

    if (!applyAppleProducerWrites(_registrationInfo, address.octet) ||
        !matchesApple24H32Template(_registrationInfo, address.octet)) {
        clearRegistrationInfo();
        return false;
    }

    _registrationInfoPrepared = true;
    return true;
}

bool RTW88WCLInfraInterface::start(IOService *provider)
{
    /* The native controller has not yet completed PCI/DMA ownership transfer,
     * Skywalk registration-info allocation or RX/TX ring registration. Never
     * publish a half-initialized Wi-Fi service. */
    if (provider) {
        provider->setProperty("RTW88WCLInfraInterfaceStage",
                              "24H32 protocol handlers; Skywalk datapath pending");
    }
    return false;
}

void RTW88WCLInfraInterface::stop(IOService *provider)
{
    clearRegistrationInfo();
    detachRadio();
    if (provider)
        provider->setProperty("RTW88WCLInfraInterfaceStopped", kOSBooleanTrue);
    super::stop(provider);
}

IOReturn RTW88WCLInfraInterface::enable(unsigned int options)
{
    (void)options;
    if (_stopping || !_bridge.isAttached() || !_controller)
        return kIOReturnNotReady;

    /* Bring the RTW88 station path up first. Only then may the controller's
     * standard mbuf TX hook admit packets for this registered interface. */
    IOReturn status = _bridge.powerOn();
    if (status != kIOReturnSuccess)
        return status;

    status = _controller->activatePacketPath(this);
    if (status != kIOReturnSuccess) {
        _bridge.powerOff();
        return status;
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::disable(unsigned int options)
{
    (void)options;
    if (!_bridge.isAttached() || !_controller)
        return kIOReturnNotReady;

    /* Stop new mbuf submissions and wait for synchronous TX handoffs before
     * asking RTW88 to power down. A busy path leaves the radio running. */
    IOReturn status = _controller->quiescePacketPath();
    if (status != kIOReturnSuccess)
        return status;
    return _bridge.powerOff();
}

SInt32 RTW88WCLInfraInterface::initBSDInterfaceParameters(
    ifnet_init_eparams *params, sockaddr_dl **address)
{
    (void)params;
    (void)address;
    return kIOReturnUnsupported;
}

IOReturn RTW88WCLInfraInterface::setMacAddress(ether_addr &address)
{
    return _bridge.setMACAddress(address.octet);
}

IOReturn RTW88WCLInfraInterface::getHardwareAddress(ether_addr *address)
{
    if (!address) return kIOReturnBadArgument;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    return _bridge.getMACAddress(address->octet);
}

IOReturn RTW88WCLInfraInterface::setHardwareAddress(ether_addr *address)
{
    if (!address) return kIOReturnBadArgument;
    return setMacAddress(*address);
}

IO80211Controller *RTW88WCLInfraInterface::getController()
{
    return _controller;
}

bool RTW88WCLInfraInterface::isChipInterfaceReady()
{
    return !_stopping && _bridge.isAttached();
}

bool RTW88WCLInfraInterface::isDebounceOnGoing()
{
    return false;
}

IO80211LinkState RTW88WCLInfraInterface::linkState()
{
    if (!_bridge.isAttached() || !_bridge.connectionReady())
        return kIO80211NetworkLinkDown;
    return kIO80211NetworkLinkUp;
}

bool RTW88WCLInfraInterface::setLinkState(IO80211LinkState state,
                                           unsigned int reason,
                                           bool debounce,
                                           unsigned int duration)
{
    return IO80211InfraInterface::setLinkState(state, reason, debounce, duration);
}

int RTW88WCLInfraInterface::getAssocState()
{
    return linkState() == kIO80211NetworkLinkUp ? 1 : 0;
}

UInt RTW88WCLInfraInterface::getHardwareAssists()
{
    return 0;
}

bool RTW88WCLInfraInterface::bpfTap(unsigned int direction, unsigned int flags)
{
    (void)direction;
    (void)flags;
    return false;
}

void RTW88WCLInfraInterface::hwConfigNicProxyData(nicproxy_info_s *info)
{
    /* Proxy offload is not implemented; leave the opaque SDK structure alone. */
    (void)info;
}

IOReturn RTW88WCLInfraInterface::getCHANNEL(apple80211_channel_data *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    RTW88BSS bss = {};
    IOReturn status = _bridge.copyCurrentBSS(&bss);
    if (status != kIOReturnSuccess) return status;
    if (bss.channel == 0 || bss.channel > 196) return kIOReturnNotReady;

    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    data->channel.version = APPLE80211_VERSION;
    data->channel.channel = bss.channel;
    data->channel.flags = bss.channel <= 14 ? APPLE80211_C_FLAG_2GHZ
                                             : APPLE80211_C_FLAG_5GHZ;
    data->channel.flags |= APPLE80211_C_FLAG_20MHZ;
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::getRSSI(apple80211_rssi_data *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    int rssi = 0;
    IOReturn status = _bridge.getRSSI(&rssi);
    if (status != kIOReturnSuccess) return status;

    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    data->num_radios = 1;
    data->rssi_unit = APPLE80211_UNIT_DBM;
    data->rssi[0] = rssi;
    data->aggregate_rssi = rssi;
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::getSUPPORTED_CHANNELS(
    apple80211_sup_channel_data *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached()) return kIOReturnNotReady;

    RTW88Channel channels[APPLE80211_MAX_CHANNELS] = {};
    uint32_t count = 0;
    IOReturn status = _bridge.copyChannels(channels,
                                           APPLE80211_MAX_CHANNELS, &count);
    if (status != kIOReturnSuccess) return status;
    if (count > APPLE80211_MAX_CHANNELS) return kIOReturnNoResources;

    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    data->num_channels = count;
    for (uint32_t i = 0; i < count; ++i) {
        if (!channels[i].number || channels[i].number > 196)
            return kIOReturnError;
        data->supported_channels[i].version = APPLE80211_VERSION;
        data->supported_channels[i].channel = channels[i].number;
        data->supported_channels[i].flags = channelFlags(channels[i]);
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::setCIPHER_KEY(apple80211_key *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached()) return kIOReturnNotReady;

    /* The Sequoia WCL protocol uses cipher values PMK (6), PMKSA (7) and MSK
     * (9) here. The RTW88 internal WPA2-PSK path consumes its PMK from the
     * association request and performs the four-way handshake itself. The
     * backend has no WCL PMKSA/MSK cache insertion API yet. Do not reinterpret
     * this message as a PTK/GTK key install. */
    return kIOReturnUnsupported;
}

IOReturn RTW88WCLInfraInterface::setCLEAR_PMKSA_CACHE(void *data)
{
    (void)data;
    /* The existing RTW88 backend does not expose a PMKSA-cache removal API. */
    return kIOReturnUnsupported;
}

IOReturn RTW88WCLInfraInterface::setWCL_LEAVE_NETWORK(
    apple80211_leave_network *data)
{
    (void)data;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    IOReturn status = _bridge.leaveNetwork();
    if (status == kIOReturnSuccess) {
        /* Invalidate any deferred disconnect callback from the old join. */
        _activeJoinGeneration = 0;
        _connectNotified = false;
        _assocNotified = false;
        setCurrentApAddress(nullptr);
        setLinkState(kIO80211NetworkLinkDown, 0, false, 0);
        RTW88WCLLinkStatusEvent link = {};
        link.up = 0;
        postWCLMessage(kWCLMessageLinkStatus, &link, sizeof(link));
        bzero(_targetBSSID, sizeof(_targetBSSID));
    }
    return status;
}

IOReturn RTW88WCLInfraInterface::setWCL_SCAN_ABORT(void *data)
{
    (void)data;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    return _bridge.abortScan();
}

IOReturn RTW88WCLInfraInterface::setWCL_JOIN_ABORT(void *data)
{
    (void)data;
    if (!_bridge.isAttached()) return kIOReturnNotReady;
    IOReturn status = _bridge.abortJoin();
    if (status == kIOReturnSuccess) {
        _activeJoinGeneration = 0;
        _assocNotified = false;
        _connectNotified = false;
        postWCLMessage(kWCLMessageJoinAbortComplete, nullptr, 0);
        setCurrentApAddress(nullptr);
        setLinkState(kIO80211NetworkLinkDown, 0, false, 0);
        bzero(_targetBSSID, sizeof(_targetBSSID));
    }
    return status;
}

IOReturn RTW88WCLInfraInterface::setWCL_SCAN_REQ(apple80211ScanRequest *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached() || _stopping) return kIOReturnNotReady;
    if (_scanActive || _bridge.scanInFlight()) return kIOReturnBusy;

    const uint8_t *raw = reinterpret_cast<const uint8_t *>(data);
    const uint32_t channelCount = RTW88WCLRequest::read32(raw + 0x54);
    if (channelCount > 400) return kIOReturnBadArgument;
    const size_t requestLength = 0x58 + static_cast<size_t>(channelCount) * 12;
    RTW88WCLRequest::Scan request = {};
    if (!RTW88WCLRequest::decodeScan(data, requestLength, request))
        return kIOReturnBadArgument;

    /* The backend currently supports active scans only. A FAST request is
     * serviced as a fresh active scan because there is no separate cached-
     * scan transaction; passive/background requests fail closed rather than
     * being silently converted into active probe transmission. */
    if (request.type != APPLE80211_SCAN_TYPE_ACTIVE &&
        request.type != APPLE80211_SCAN_TYPE_FAST)
        return kIOReturnUnsupported;

    uint16_t channels[128] = {};
    uint32_t selected = 0;
    for (unsigned channel = 1; channel <= 196; ++channel) {
        if (!(request.channelBitmap[channel / 8] & (1U << (channel % 8))))
            continue;
        if (selected == sizeof(channels) / sizeof(channels[0]))
            return kIOReturnNoResources;
        channels[selected++] = static_cast<uint16_t>(channel);
    }

    if (request.channelCount != 0 && selected == 0)
        return kIOReturnUnsupported;

    ScanFilter filter = {};
    filter.identifier = request.identifier;
    filter.ssidLength = static_cast<uint8_t>(request.ssidLength);
    memcpy(filter.ssid, request.ssid, sizeof(filter.ssid));
    memcpy(filter.bssid, request.bssid, sizeof(filter.bssid));
    memcpy(filter.channelBitmap, request.channelBitmap,
           sizeof(filter.channelBitmap));
    filter.filterBSSID = !isZeroAddress(filter.bssid, sizeof(filter.bssid));
    filter.filterChannels = request.channelCount != 0;
    _scanFilter = filter;
    _scanActive = true;
    /* The bridge writes this generation before it enters the asynchronous
     * backend, so a fast completion cannot race the interface's filter state. */
    _activeScanGeneration = 0;
    setScanningState(request.identifier, true, nullptr, 0);

    IOReturn status = _bridge.startScan(selected ? channels : nullptr, selected,
                                        &_activeScanGeneration);
    if (status != kIOReturnSuccess) {
        _scanActive = false;
        _activeScanGeneration = 0;
        setScanningState(request.identifier, false, nullptr, 0);
    }
    return status;
}

IOReturn RTW88WCLInfraInterface::setWCL_ASSOCIATE(
    apple80211AssocCandidates *data)
{
    if (!data) return kIOReturnBadArgument;
    if (!_bridge.isAttached() || _stopping) return kIOReturnNotReady;

    const uint8_t *raw = reinterpret_cast<const uint8_t *>(data);
    const uint32_t candidates = RTW88WCLRequest::read32(raw + 0x214);
    if (candidates == 0 || candidates > 10) return kIOReturnBadArgument;
    const size_t requestLength = 0x218 + static_cast<size_t>(candidates) * 18;
    RTW88WCLRequest::Join request = {};
    if (!RTW88WCLRequest::decodeJoin(data, requestLength, request))
        return kIOReturnUnsupported;

    const uint8_t *pmk = request.keyLength == 32 ? request.key : nullptr;
    const uint8_t *rsn = request.rsnLength ? request.rsn : nullptr;
    _assocNotified = false;
    _connectNotified = false;
    memcpy(_targetBSSID, request.bssid, sizeof(_targetBSSID));
    /* The bridge writes this generation before cmdConnect() can schedule
     * authentication or produce an event. Duplicate pending joins reuse the
     * existing generation. */
    _activeJoinGeneration = 0;
    IOReturn status = _bridge.associate(request.ssid,
                                        static_cast<uint8_t>(request.ssidLength),
                                        request.bssid, pmk, rsn,
                                        request.rsnLength, false /* internal RTW88 supplicant */,
                                        &_activeJoinGeneration);
    bzero(request.key, sizeof(request.key));
    if (status != kIOReturnSuccess) {
        _activeJoinGeneration = 0;
        bzero(_targetBSSID, sizeof(_targetBSSID));
        return status;
    }
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::setWCL_LINK_UP_DONE(void *data)
{
    (void)data;
    maybePublishConnected();
    return kIOReturnSuccess;
}

IOReturn RTW88WCLInfraInterface::setWCL_LINK_STATE_UPDATE(
    apple80211_wcl_update_link_state *data)
{
    if (!data) return kIOReturnBadArgument;

    /* Sequoia 24H32 WCL wire layout: byte 6 indicates an up-state record,
     * byte 8 says the BSSID field is valid, byte 7 indicates link-up, and
     * bytes 12..15 carry the down-state debounce interval. These offsets
     * match the reviewed 24H32 WCL protocol layout; don't cast the opaque
     * private structure to an older apple80211 definition. */
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(data);
    if (bytes[6]) {
        if (bytes[8])
            setCurrentApAddress(reinterpret_cast<ether_addr *>(data));
        if (bytes[7])
            setLinkState(kIO80211NetworkLinkUp, 0, false, 0);
        return kIOReturnSuccess;
    }

    const uint32_t debounce = RTW88WCLRequest::read32(bytes + 12);
    setCurrentApAddress(nullptr);
    setLinkState(kIO80211NetworkLinkDown, 0, debounce != 0, debounce);
    return kIOReturnSuccess;
}

bool RTW88WCLInfraInterface::scanResultMatches(const RTW88BSS &bss) const
{
    if (bss.channel == 0 || bss.channel > 196 || bss.ssid_len > 32 ||
        bss.ies_len > sizeof(bss.ies) ||
        !validInformationElements(bss.ies, bss.ies_len)) return false;
    if (_scanFilter.filterBSSID &&
        memcmp(bss.bssid, _scanFilter.bssid, sizeof(_scanFilter.bssid)) != 0)
        return false;
    if (_scanFilter.ssidLength &&
        (bss.ssid_len != _scanFilter.ssidLength ||
         memcmp(bss.ssid, _scanFilter.ssid, _scanFilter.ssidLength) != 0))
        return false;
    if (_scanFilter.filterChannels &&
        !(_scanFilter.channelBitmap[bss.channel / 8] &
          (1U << (bss.channel % 8))))
        return false;
    return true;
}

IOReturn RTW88WCLInfraInterface::postWCLMessage(unsigned int message,
                                                 void *payload,
                                                 unsigned long length)
{
    if (!_controller) return kIOReturnNotReady;
    return _controller->postMessage(this, message, payload, length, true);
}

void RTW88WCLInfraInterface::publishScanResults(IOReturn status)
{
    if (!_controller) return;
    if (status == kIOReturnSuccess) {
        for (uint32_t index = 0; index < 128; ++index) {
            RTW88BSS bss = {};
            IOReturn copied = _bridge.copyScanBSS(index, &bss);
            if (copied == kIOReturnNotFound) break;
            if (copied != kIOReturnSuccess) break;
            if (!scanResultMatches(bss)) continue;

            uint8_t message[sizeof(RTW88WCLBeaconMetadata) + sizeof(bss.ies)] = {};
            RTW88WCLBeaconMetadata metadata = {};
            metadata.ieLength = bss.ies_len;
            metadata.channelSpec = static_cast<uint16_t>(bss.channel |
                (bss.channel <= 14 ? 0x1000 : 0xd000));
            memcpy(metadata.ssid, bss.ssid, bss.ssid_len);
            metadata.ssidLength = bss.ssid_len;
            metadata.channel = bss.channel;
            memcpy(metadata.bssid, bss.bssid, sizeof(metadata.bssid));
            metadata.rssi = bss.rssi;
            metadata.interval = bss.beacon_interval;
            metadata.capability = static_cast<uint16_t>(bss.capabilities);
            metadata.flags = kWCLBeaconRSSIValid;
            if (bss.ssid_len) metadata.flags |= kWCLBeaconSSIDPresent;
            memcpy(message, &metadata, sizeof(metadata));
            if (bss.ies_len)
                memcpy(message + sizeof(metadata), bss.ies, bss.ies_len);
            postWCLMessage(kWCLMessageScanResult, message,
                           sizeof(metadata) + bss.ies_len);
        }
    }

    _scanActive = false;
    _activeScanGeneration = 0;
    setScanningState(_scanFilter.identifier, false, nullptr, 0);
    postWCLMessage(kWCLMessageScanDone, &status, sizeof(status));
}

void RTW88WCLInfraInterface::postConnectionComplete(uint16_t status,
                                                     uint16_t reason,
                                                     IOReturn driverStatus)
{
    RTW88WCLConnectionEvent event = {};
    event.status = status;
    event.reason = reason;
    memcpy(event.peers[0].bssid, _targetBSSID, sizeof(_targetBSSID));
    event.peers[0].driverStatus = driverStatus;
    postWCLMessage(kWCLMessageConnectComplete, &event, sizeof(event));
}

void RTW88WCLInfraInterface::maybePublishConnected()
{
    /* setWCL_LINK_UP_DONE may be delivered after a leave/abort request. Never
     * publish an old backend CONNECTED state without a live join transaction. */
    if (!_activeJoinGeneration || _connectNotified || !_bridge.isAttached() ||
        !_bridge.connectionReady())
        return;

    _connectNotified = true;
    _assocNotified = true;
    postConnectionComplete(0, 0, kIOReturnSuccess);
    setLinkState(kIO80211NetworkLinkUp, 0, false, 0);

    RTW88WCLLinkStatusEvent link = {};
    memcpy(link.bssid, _targetBSSID, sizeof(link.bssid));
    link.up = 1;
    postWCLMessage(kWCLMessageLinkStatus, &link, sizeof(link));
}

void RTW88WCLInfraInterface::handleRTW88WCLRadioEvent(
    const RTW88WCLRadioEvent &event)
{
    if (_stopping) return;
    switch (event.event) {
        case kRTW88EventScanDone: {
            if (!_scanActive || event.scanGeneration != _activeScanGeneration)
                return; // stale completion from an aborted/superseded scan
            const IOReturn status = event.value ? kIOReturnAborted
                                                 : kIOReturnSuccess;
            publishScanResults(status);
            break;
        }
        case kRTW88EventConnected: {
            if (!_activeJoinGeneration ||
                event.joinGeneration != _activeJoinGeneration)
                return;
            if (!_assocNotified) {
                RTW88WCLAssociationEvent assoc = {};
                memcpy(assoc.bssid, _targetBSSID, sizeof(assoc.bssid));
                postWCLMessage(kWCLMessageAssocComplete, &assoc, sizeof(assoc));
                _assocNotified = true;
            }
            maybePublishConnected();
            break;
        }
        case kRTW88EventAssocDone: {
            if (!_activeJoinGeneration ||
                event.joinGeneration != _activeJoinGeneration)
                return; // stale association callback from an earlier join
            if (!_assocNotified) {
                RTW88WCLAssociationEvent assoc = {};
                memcpy(assoc.bssid, _targetBSSID, sizeof(assoc.bssid));
                postWCLMessage(kWCLMessageAssocComplete, &assoc, sizeof(assoc));
                _assocNotified = true;
            }
            maybePublishConnected();
            break;
        }
        case kRTW88EventDeauth: {
            if (!_activeJoinGeneration ||
                event.joinGeneration != _activeJoinGeneration)
                return;
            uint32_t reason = event.value;
            postWCLMessage(kWCLMessageDeauth, &reason, sizeof(reason));
            postConnectionComplete(1, static_cast<uint16_t>(reason),
                                   kIOReturnNotAttached);
            _connectNotified = false;
            _assocNotified = false;
            _activeJoinGeneration = 0;
            setCurrentApAddress(nullptr);
            setLinkState(kIO80211NetworkLinkDown, reason, false, 0);
            break;
        }
        case kRTW88EventDisconnected: {
            if (!_activeJoinGeneration ||
                event.joinGeneration != _activeJoinGeneration)
                return;
            if (_connectNotified || _assocNotified)
                postConnectionComplete(1, 0, kIOReturnNotAttached);
            _connectNotified = false;
            _assocNotified = false;
            _activeJoinGeneration = 0;
            setCurrentApAddress(nullptr);
            setLinkState(kIO80211NetworkLinkDown, 0, false, 0);
            RTW88WCLLinkStatusEvent link = {};
            memcpy(link.bssid, _targetBSSID, sizeof(link.bssid));
            link.up = 0;
            postWCLMessage(kWCLMessageLinkStatus, &link, sizeof(link));
            break;
        }
        case kRTW88EventRSSIChanged: {
            if (!_activeJoinGeneration ||
                event.joinGeneration != _activeJoinGeneration)
                return;
            int rssi = 0;
            if (_bridge.getRSSI(&rssi) == kIOReturnSuccess) {
                RTW88WCLLqmUpdate update = {};
                update.rssiValid = 1;
                update.rssi = rssi;
                postWCLMessage(kWCLMessageLqmUpdate, &update, sizeof(update));
            }
            break;
        }
    }
}

#undef super
