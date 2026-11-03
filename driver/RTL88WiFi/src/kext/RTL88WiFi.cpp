/* Modified by X1REN41L on 2026-10-14 for RTL88WiFi 1.0.1; see the repository NOTICE.md. */
/* Modified on 2026-10-23 for RTL88WiFi 1.0.2 (noise reporting, AWDL radio policy); see NOTICE.md. */
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Native IO80211 controller for the RTL8822BE port.
 */
#include "RTL88WiFi.hpp"
#include "RTL88WiFiInterface.hpp"
#include "RTW88AssocWire.hpp"
#include "RTW88UserClient.hpp"
#include "RTW88LinkMetrics.hpp"

extern "C" {
#include "../compat/rtw88_compat.h"
}
extern "C" boolean_t preemption_enabled(void);

extern "C" void rtw88_trigger_interrupt(void);  /* esta si es la unica con extern "C" real, ver RTW88PCIDevice.cpp */  /* struct RTW88StateResult vive aca */
#include <IOKit/network/IOOutputQueue.h>  /* kIOReturnOutputDropped */
#include <IOKit/network/IOBasicOutputQueue.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOLib.h>                  /* kprintf */
#include <libkern/copyio.h>               /* copyin/copyout for legacy ioctl bridge */
#include <sys/errno.h>                    /* EINVAL/EFAULT/ENOMEM */
#include <libkern/version.h>              /* scan-cache bootstrap compatibility only */
#include <sys/random.h>                   /* kernel CSPRNG for private station MACs */
#include <net/kpi_interface.h>            /* ifnet_stat_increment_in/out */

#define IOLog rtw88_candidate_log

#define super IO80211Controller

/* Keep enough headroom in the 256-entry BE ring that rtw_tx() never reaches
 * its internal -ENOSPC/drop path. Resume with wide hysteresis so a coalesced
 * completion cannot park the IOOutputQueue on a marginal threshold. */
static constexpr unsigned int kRTW88TxStallAvail  = 96;
static constexpr unsigned int kRTW88TxResumeAvail = 160;

/* r10: IO80211Interface::outputStart() pulls up to getDataQueueDepth()
 * packets per access category from the ifnet send queue and pushes them into
 * the family's 256-entry IOGatedOutputQueue, which tail-drops when full. The
 * family default depth is 1024, so a saturating upload dropped ~30% of
 * packets there (UDP included). Pull at most 64 per call and leave packets in
 * the ifnet queue (AQM + flow advisory) while the BE queue is above 128.
 * r11: on hardware the queue size never read >= 128 at outputStart() time,
 * yet ~1% still tail-dropped under multi-stream load, one drop per TX stall:
 * every drop happens while outputPacket() stalls on a nearly full BE ring
 * and outputStart() keeps pulling. Gate on the stall itself as well. */
static constexpr UInt32 kRTW88DataQueueDepth = 64;
static constexpr UInt32 kRTW88TxQueueHigh    = 128;
static constexpr UInt32 kRTW88TxQueueLow     = 64;

enum : unsigned long {
    kRTW88PowerStateOff = 0,
    kRTW88PowerStateOn = 1,
    kRTW88PowerStateCount = 2,
};

/* IONetworkController asks subclasses to register power states through
 * registerWithPolicyMaker().  State 0 intentionally advertises no device
 * capability; state 1 means the PCI function is usable. */
static IOPMPowerState gRTW88PowerStates[kRTW88PowerStateCount] = {
    { kIOPMPowerStateVersion1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    { kIOPMPowerStateVersion1, kIOPMDeviceUsable, kIOPMPowerOn, kIOPMPowerOn,
      0, 0, 0, 0, 0, 0, 0, 0 },
};

/* APPLE80211_IOC_PRIVATE_MAC (238): the payload behind the "Private Wi-Fi
 * address" control in Network settings.  The SDK defines only the request
 * number.  This layout was read from Apple's own driver (AirPort_BrcmNIC::
 * getPRIVATE_MAC / setPRIVATE_MAC in the IO80211FamilyLegacy bundle) and from
 * the family's forwarding handlers, which insist on exactly 28 bytes:
 *   +0x04 enabled     non-zero = private address on
 *   +0x08 flags       control flags; Apple's driver stores them and returns them
 *   +0x0C interval_s  rotation interval in seconds; 0 = fixed (no rotation)
 *   +0x10 mac[6]      the current private address
 * Apple's driver leaves +0x00 (version) and the rest zero. */
struct rtw88_private_mac_data {
    uint32_t version;
    uint32_t enabled;
    uint32_t flags;
    uint32_t interval_s;
    uint8_t  mac[6];
    uint8_t  pad[2];
    uint32_t reserved;
};
static_assert(sizeof(rtw88_private_mac_data) == 28, "family handlers require a 28-byte payload");

static constexpr uint32_t kRTW88PrivateMacMaxIntervalS = 0xFFFFFFFFU / 1000U;
static constexpr uint32_t kRTW88PrivateMacRetryMs = 60000U;

static bool rtw88MacIsZero(const uint8_t mac[6])
{
    return !(mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]);
}

static bool rtw88MacIsUnicast(const uint8_t mac[6])
{
    return !rtw88MacIsZero(mac) && !(mac[0] & 0x01);
}

static void rtw88MakeLocallyAdministered(uint8_t mac[6])
{
    /* Keep the random payload but set local-admin and clear multicast bits. */
    mac[0] = (uint8_t)((mac[0] & 0xFCU) | 0x02U);
}

static void rtw88GeneratePrivateMAC(uint8_t mac[6])
{
    read_random(mac, 6);
    rtw88MakeLocallyAdministered(mac);
}

/* rtw88 does not measure a noise floor.  Chips that report a per-path RX SNR
 * (8822B/8822C, and 8821C since 1.0.2) give noise = RSSI - SNR.  When no
 * plausible SNR is available (idle 2.4 GHz link that only sees CCK beacons,
 * or no samples yet) fall back to the thermal-noise estimate for the current
 * channel width instead of reporting "unavailable", which macOS renders as
 * "0 dBm".  See RTW88LinkMetrics.hpp.  Always succeeds. */
static void rtw88LinkNoise(int rssi, unsigned widthMHz, int *noise, int *snr,
                           bool *measured = nullptr)
{
    int s = 0;
    const bool haveSnr = rtw88_get_rx_snr(&s);
    const RTW88Metrics::LinkNoise n = RTW88Metrics::linkNoise(rssi, haveSnr, s, widthMHz);
    *noise = n.noise;
    *snr = n.snr;
    if (measured) *measured = (n.source == RTW88Metrics::kSourceMeasured);
}

/* Operating width of a scanned BSS (HT/VHT Operation IEs), used only to pick
 * the thermal-noise estimate for networks we are not connected to. */
static unsigned rtw88BssWidthMHz(const RTW88BSS &b)
{
    RTW88BssOperation op;
    RTW88IEEE80211::parseBssOperation(b.ies, b.ies_len, &op);
    if (b.channel > 14 && op.vhtWidth == 1 && op.vhtSeg0 != 0) return 80;
    if (op.htStaWidth && (op.sco == 1 || op.sco == 3)) return 40;
    return 20;
}

/* The port has no channel regulatory database: regulatory_hint() is a stub
 * and rtw88's regd.c only maps a country code to a TX-power table, so
 * copyChannels() returns every channel the chip supports.  Filter the
 * 2.4 GHz edge channels reported to IO80211 by the active country code:
 * channel 14 is legal only in JP, channels 12-13 are not legal in the US,
 * CA and FCC territories.  Unknown or world codes (the default "ZZ",
 * Apple's "X*" codes) keep the full list. */
static bool rtw88ChannelAllowedInCountry(const uint8_t *cc, uint16_t ch)
{
    if (ch < 12 || ch > 14) return true;
    char a = (char)cc[0], b = (char)cc[1];
    if (a >= 'a' && a <= 'z') a = (char)(a - 'a' + 'A');
    if (b >= 'a' && b <= 'z') b = (char)(b - 'a' + 'A');
    if (a < 'A' || a > 'Z' || b < 'A' || b > 'Z' || a == 'X' || (a == 'Z' && b == 'Z'))
        return true;
    if (ch == 14) return a == 'J' && b == 'P';
    static const char fcc[][2] = {
        {'U','S'}, {'C','A'}, {'P','R'}, {'G','U'}, {'A','S'}, {'V','I'}, {'M','P'}, {'U','M'}
    };
    for (const auto &c : fcc)
        if (a == c[0] && b == c[1]) return false;
    return true;
}

static const char *rtw88AirportChipName(const struct pci_dev *pdev)
{
    if (!pdev) return "Realtek Wireless";
    switch (pdev->device) {
    case 0xB822: return "RTL8822BE";
    case 0xC822:
    case 0xC82F: return "RTL8822CE";
    case 0xC821:
    case 0xB821: return "RTL8821CE";
    default: return "Realtek Wireless";
    }
}

extern "C" void rtw88_airport_tx_resume_trampoline(void)
{
    if (g_pci_dev_instance)
        g_pci_dev_instance->resumeTxIfStalled();
}

OSDefineMetaClassAndStructors(RTL88WiFi, IO80211Controller)

bool RTL88WiFi::init(OSDictionary *props)
{
    return super::init(props);
}

/* Match the reference IO80211 driver's IO80211Controller lifecycle.  IONetworkController::
 * start() calls this virtual before RTL88WiFi::start() continues; using an
 * IO80211WorkLoop keeps controller IOCTL/VIF callbacks, our interrupt source
 * and RX injection on the same controller-owned workloop. */
bool RTL88WiFi::createWorkLoop()
{
    if (_workLoop)
        return true;
    _workLoop = IO80211WorkLoop::workLoop();
    IOLog("RTL88WiFi: createWorkLoop IO80211WorkLoop=%p\n", _workLoop);
    return _workLoop != nullptr;
}

IOWorkLoop *RTL88WiFi::getWorkLoop() const
{
    return _workLoop;
}

bool RTL88WiFi::start(IOService *provider)
{
    setProperty("DriverBuild", "1.0.11-rtl88wifi-r22-20261031");
    setProperty("STA_R10_TXQ_GATE", kOSBooleanTrue);
    setProperty("STA_R11_TXQ_STALL_GATE", kOSBooleanTrue);
    setProperty("STA_V19_DARWIN_ENOTSUP_FIX", kOSBooleanTrue);
    setProperty("STA_V20_POWERSAVE_PREFLIGHT_FIX", kOSBooleanTrue);
    IOLog("RTL88WiFi: start\n");
    _pciDev = OSDynamicCast(IOPCIDevice, provider);
    if (!_pciDev) {
        IOLog("RTL88WiFi: provider is not IOPCIDevice\n");
        return false;
    }
    if (!super::start(provider)) {
        _pciDev = nullptr;
        return false;
    }
    _superStarted = true;
    _pciDev->retain();

    /* Locks para tracking DMA -- antes faltaban por completo */
    _dmaLock = IOSimpleLockAlloc();
    _pendingFreeLock = IOSimpleLockAlloc();
    if (!_dmaLock || !_pendingFreeLock)
        return failStart(provider, "failed to allocate DMA locks");

    /* Habilitar bus mastering y espacio de memoria */
    _pciDev->setBusMasterEnable(true);
    _pciDev->setMemoryEnable(true);

    /* Mapear BAR2 -- rtw88 hardcodea bar_id=2 en pci.c */
    _mmioMap = _pciDev->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress2);
    if (!_mmioMap) {
        return failStart(provider, "failed to map BAR2");
    }
    _mmioBase = (volatile void *)_mmioMap->getVirtualAddress();
    IOLog("RTL88WiFi: BAR2 mapped at %p, size 0x%llx\n",
          (void *)_mmioBase, (unsigned long long)_mmioMap->getLength());

    /* Instalar callbacks compartidos de compat (mismos que usa RTW88PCIDevice,
     * ahora apuntando a esta instancia via el puntero generico RTW88HwOps*) */
    g_pci_dev_instance = this;
    rtw88_pci_io_ops    = &_pci_io_ops;
    rtw88_dma_ops       = &_dma_ops;

    if (rtw88_compat_init() != 0)
        return failStart(provider, "compat initialization failed");
    _compatInitialized = true;

    _compatPciDev = (struct pci_dev *)IOMallocZero(sizeof(struct pci_dev));
    if (!_compatPciDev)
        return failStart(provider, "failed to allocate compat PCI device");

    _compatPciDev->vendor  = _pciDev->configRead16(0x00);
    _compatPciDev->device  = _pciDev->configRead16(0x02);
    _compatPciDev->kext_dev = this;
    _compatPciDev->resource[2]     = (resource_size_t)_mmioBase;
    _compatPciDev->resource_len[2] = (resource_size_t)_mmioMap->getLength();

    IOLog("RTL88WiFi: PCI device %04x:%04x\n",
          _compatPciDev->vendor, _compatPciDev->device);

    /* super::start() has already called our createWorkLoop().  The reference IO80211 driver
     * relies on that controller-owned IO80211WorkLoop; do not create a second
     * parallel loop here. */
    if (!_workLoop)
        return failStart(provider, "IO80211 workloop unavailable after super::start");

    if (!setupInterrupt()) {
        return failStart(provider, "failed to set up interrupt");
    }

    rtw88_find_fw_dir();

    /* Crear la maquina de estados 802.11 -- AHORA con el pci_dev real,
     * en vez de nullptr como antes */
    _ieee80211 = RTW88IEEE80211::createAirport(this, _compatPciDev);
    if (!_ieee80211) {
        return failStart(provider, "failed to create IEEE80211 state machine");
    }
    _ieee80211->setEventDelegate(this);
    _ieee80211->setRxDelegate(this);

    /* 1.0.2 AWDL radio policy: read from the matched IOKit personality, so no
     * new kernel symbol (boot-arg parsing) is needed.  Absent or false means
     * the AWDL interface exists but never takes the radio off the AP channel. */
    {
        OSBoolean *awdlRadio = OSDynamicCast(OSBoolean, getProperty("RTL88WiFiAWDLRadio"));
        const bool allowAWDL = awdlRadio && awdlRadio->isTrue();
        _ieee80211->setAWDLRadioAllowed(allowAWDL);
        setProperty("AWDL_RADIO_POLICY", allowAWDL ? "enabled" : "disabled");
        IOLog("RTL88WiFi: AWDL radio policy: %s\n", allowAWDL ? "enabled (experimental)" : "disabled (stable default)");

        /* 1.0.4 band policy: default on; RTL88WiFiPrefer5GHz=false in the
         * personality honours the BSSID macOS asks for exactly. */
        OSBoolean *p5 = OSDynamicCast(OSBoolean, getProperty("RTL88WiFiPrefer5GHz"));
        const bool prefer5 = p5 ? p5->isTrue() : true;
        _ieee80211->setPrefer5GHzUpgrade(prefer5);
        setProperty("PREFER_5GHZ_POLICY", prefer5 ? "enabled" : "disabled");
    }

    rtw88_force_wifi_only();

    IOReturn probeRet = _ieee80211->start();
    if (probeRet != kIOReturnSuccess) {
        IOLog("RTL88WiFi: probe failed (0x%08x)\n", probeRet);
        return failStart(provider, "IEEE80211 start failed");
    }
    _ieeeStarted = true;

    _awdlManager = new RTW88AWDLManager;
    if (!_awdlManager || !_awdlManager->init(_ieee80211, _workLoop, this, &RTL88WiFi::awdlTimerFired))
        return failStart(provider, "failed to initialize AWDL/P2P manager");
    IOLog("RTL88WiFi: AWDL/P2P manager initialized (partial support)\n");

    /* The reference Ventura IO80211 driver publishes and selects the medium before
     * attachInterface().  This is deliberately kept in the legacy Ventura
     * frontend so OCLP's IO80211FamilyLegacy sees the same controller
     * lifecycle on Sonoma/Sequoia. */
    const IONetworkMedium *primaryMedium = nullptr;
    if (!createMediumTables(&primaryMedium) || !primaryMedium ||
        !setCurrentMedium(primaryMedium) || !setSelectedMedium(primaryMedium))
        return failStart(provider, "failed to publish/select Wi-Fi medium");
    IOLog("RTL88WiFi: medium table ready before attachInterface\n");

    /* Let IO80211/IONetworkController prepare and configure the client.
     * Calling init/attach directly bypasses the controller's lifecycle. */
    IOLog("RTL88WiFi: calling attachInterface (AirportItlwm lifecycle, attach=true)\n");
    /* The reference IO80211 driver passes its member pointer directly.  This matters when
     * attach=true because matching/registration can be synchronous: make the
     * primary interface visible to our callbacks before attachInterface()
     * returns instead of assigning it afterwards from a temporary. */
    if (!attachInterface((IONetworkInterface **)&_netif, true) || !_netif)
        return failStart(provider, "controller attachInterface failed");
    if (!OSDynamicCast(RTL88WiFiInterface, _netif)) {
        detachInterface(_netif, true);
        _netif->release();
        _netif = nullptr;
        return failStart(provider, "controller returned unexpected interface type");
    }
    _netifAttached = true;

    /* IO80211Controller owns an IOOutputQueue too. Backpressure it before the
     * Realtek BE ring reaches -ENOSPC; otherwise rtw_tx() frees the skb and
     * macOS incorrectly believes the packet was transmitted. */
    _txStalled = false;
    rtw88_set_tx_resume_cb(rtw88_airport_tx_resume_trampoline);
    if (_intrSrc) _intrSrc->enable();

    /* The reference IO80211 driver publishes a valid-but-not-yet-associated link, then both
     * the controller service and the interface.  The controller publication
     * is important for IO80211 clients that own virtual-interface lifecycle. */
    IO80211Controller::setLinkStatus(kIONetworkLinkValid);
    registerService();
    _netif->registerService();
    IOLog("RTL88WiFi: controller and network interface registered\n");

    // Legacy IO80211 on newer hosts may never request the AWDL interface.
    // Attach on a later workloop turn, after start/publication has completed.
    // Discovery failure must not fail the working STA startup.
    _awdlManager->scheduleDiscovery();

    _diagnosticsBuffer = (char *)IOMalloc(32768);
    _diagnosticsTimer = IOTimerEventSource::timerEventSource(this, &RTL88WiFi::diagnosticsTimerFired);
    if (!_diagnosticsBuffer || !_diagnosticsTimer ||
        _workLoop->addEventSource(_diagnosticsTimer) != kIOReturnSuccess)
        return failStart(provider, "diagnostics allocation failed");
    setProperty("DiagnosticLogging", kOSBooleanTrue);
    setProperty("DiagnosticLogCapacity", (uint64_t)32767, 32);
    _diagnosticsTimer->setTimeoutMS(1000);

    /* Private-address rotation is driven on the controller workloop.  Failure
     * to allocate this optional timer must not prevent ordinary Wi-Fi use; Fixed
     * still works through setHardwareAddress(), while Rotating reports a clear
     * diagnostic and remains safely on its current address. */
    _privateMacTimer = IOTimerEventSource::timerEventSource(this, &RTL88WiFi::privateMacTimerFired);
    if (_privateMacTimer && _workLoop->addEventSource(_privateMacTimer) == kIOReturnSuccess) {
        setProperty("PRIVATE_MAC_TIMER_AVAILABLE", kOSBooleanTrue);
    } else {
        if (_privateMacTimer) { _privateMacTimer->release(); _privateMacTimer = nullptr; }
        setProperty("PRIVATE_MAC_TIMER_AVAILABLE", kOSBooleanFalse);
        IOLog("RTL88WiFi: PRIVATE_MAC rotation timer unavailable; Fixed mode remains available\n");
    }
    IOLog("RTL88WiFi: 1.0.11 diagnostics enabled; fixes=assoc-open-empty-key,private-mac-legacy-and-skywalk-get-set,fixed-rotating-mac,mesh-roam,mesh-cache-refresh\n");
    IOLog("RTL88WiFi: device started successfully\n");
    return true;
}

void RTL88WiFi::diagnosticsTimerFired(OSObject *owner, IOTimerEventSource *timer)
{
    RTL88WiFi *self = OSDynamicCast(RTL88WiFi, owner);
    if (!self || self->_shutdown || !self->_diagnosticsBuffer) return;
    self->_diagnosticsSamples++;
    /* setPowerState runs on the PM thread, not this workloop. Publish the
     * register access before re-checking the transition flag; the PM path
     * sets the flag and then waits for this access to finish. */
    __atomic_store_n(&self->_diagnosticsInHardware, true, __ATOMIC_SEQ_CST);
    if (!__atomic_load_n(&self->_pmTransition, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&self->_dmaStopped, __ATOMIC_SEQ_CST) && self->_ieee80211 &&
        self->_ieee80211->isPowered()) {
        unsigned state = self->_ieee80211->rawState();
        bool visible = self->_ieee80211->associatedVisible();
        bool agg = self->_ieee80211->txAggregationActive();
        bool stalled = self->_txStalled;
        /* An idle periodic sample carries no new information; write it to
         * the ring only on change, TX backlog or stall, or once a minute,
         * so events (handshakes, disconnects) stay in the 32 KiB ring. */
        /* A queue entry seen on a single sample is a packet in flight;
         * only a queue that stays non-empty across two samples is backlog. */
        bool busy = rtw88_be_tx_busy() != 0;
        bool backlog = busy && self->_diagLastBusy;
        self->_diagLastBusy = busy;
        uint32_t gates = self->_txGateCount;
        bool toRing = !self->_diagRingPrimed || stalled || backlog ||
                      state != self->_diagLastState || visible != self->_diagLastVisible ||
                      agg != self->_diagLastAgg || stalled != self->_diagLastStalled ||
                      gates != self->_diagLastGateCount ||
                      self->_diagnosticsSamples - self->_diagLastRingSample >= kDiagHeartbeatSamples;
        self->_diagLastGateCount = gates;
        if (toRing) {
            IOOutputQueue *oq = self->getOutputQueue();
            /* r11: the family queue's own drop/stall counters, so drops can
             * be read from the ring without ioreg. */
            IONetworkData *qd = oq ? oq->getStatisticsData() : nullptr;
            const IOOutputQueueStats *qs =
                (qd && qd->getSize() >= sizeof(IOOutputQueueStats))
                    ? (const IOOutputQueueStats *)qd->getBuffer() : nullptr;
            IOLog("rtw88: DIAG sample=%llu state=%u visible=%d agg=%d rx_frames=%u be_avail=%u stalled=%d "
                  "txq=%u gated=%d gates=%u qdrop=%u qstall=%u\n",
                  self->_diagnosticsSamples, state, visible, agg,
                  self->_ieee80211->receivedFrameCount(), rtw88_be_tx_avail(), stalled,
                  oq ? oq->getSize() : 0, self->_txGated ? 1 : 0, gates,
                  qs ? qs->dropCount : 0, qs ? qs->stallCount : 0);
            self->_diagLastRingSample = self->_diagnosticsSamples;
            self->_diagRingPrimed = true;
        } else {
            kprintf("rtw88: DIAG sample=%llu state=%u visible=%d agg=%d rx_frames=%u be_avail=%u stalled=%d\n",
                    self->_diagnosticsSamples, state, visible, agg,
                    self->_ieee80211->receivedFrameCount(), rtw88_be_tx_avail(), stalled);
        }
        self->_diagLastState = state;
        self->_diagLastVisible = visible;
        self->_diagLastAgg = agg;
        self->_diagLastStalled = stalled;
        /* Safety net: a queue flushed without outputPacket() calls, or a ring
         * reclaimed without a TX-resume callback, must not leave the IO80211
         * queue stalled or the ifnet output thread waiting on a gate signal. */
        self->releaseTxStall();
        self->kickGatedOutput();
        /* 1.0.6: upkeep of the connected link (re-negotiates uplink A-MPDU if the
         * AP tore the Block Ack agreement down).  Inside the same guard as the
         * hardware reads above, so it cannot race a power transition. */
        self->_ieee80211->housekeeping();
        rtw88_debug_dump_tx_state_to(toRing);
    }
    __atomic_store_n(&self->_diagnosticsInHardware, false, __ATOMIC_SEQ_CST);
    uint64_t bytes = 0;
    uint32_t n = rtw88_copy_log(self->_diagnosticsBuffer, 32768, &bytes);
    self->setProperty("DiagnosticLog", self->_diagnosticsBuffer);
    self->setProperty("DiagnosticLogBytes", bytes, 64);
    self->setProperty("DiagnosticSamples", self->_diagnosticsSamples, 64);
    self->setProperty("DiagnosticLogWrapped", bytes > 32767 ? kOSBooleanTrue : kOSBooleanFalse);
    self->setProperty("DiagnosticLogSnapshotLength", (uint64_t)n, 32);
    timer->setTimeoutMS(5000);
}

void RTL88WiFi::waitForDiagnosticsIdle()
{
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    for (int i = 0; i < 1000 &&
         __atomic_load_n(&_diagnosticsInHardware, __ATOMIC_SEQ_CST); i++)
        IOSleep(1);
}

bool RTL88WiFi::failStart(IOService *provider, const char *reason)
{
    IOLog("RTL88WiFi: start failed: %s\n", reason ? reason : "unknown error");

    /* Match IO80211/IONetworkController ownership ordering: IO80211 must
     * stop while the controller workloop, interface and backend still exist.
     * Releasing those first can leave super::stop() touching freed state. */
    if (_superStarted) {
        super::stop(provider);
        _superStarted = false;
    }
    teardown();
    return false;
}

bool RTL88WiFi::setupInterrupt()
{
    _intrSrc = IOInterruptEventSource::interruptEventSource(
        this,
        OSMemberFunctionCast(IOInterruptEventSource::Action,
                             this, &RTL88WiFi::handleInterrupt),
        _pciDev, 0);
    if (!_intrSrc) {
        IOLog("RTL88WiFi: failed to create interrupt event source\n");
        return false;
    }
    if (_workLoop->addEventSource(_intrSrc) != kIOReturnSuccess) {
        _intrSrc->release();
        _intrSrc = nullptr;
        return false;
    }
    return true;
}

void RTL88WiFi::handleInterrupt(IOInterruptEventSource *src, int count)
{
    (void)src; (void)count;
    /* Controller workloop is a safe thread context. Retire DMA descriptors
     * deferred by a previous IRQ/NAPI pass before handling more traffic. */
    if (preemption_enabled())
        drainPendingFree();
    if (!__atomic_load_n(&_dmaStopped, __ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&_pmTransition, __ATOMIC_ACQUIRE) && _ieee80211)
        rtw88_trigger_interrupt();
}

UInt8 RTL88WiFi::pciReadByte(int offset)   { return _pciDev->configRead8((UInt8)offset); }
UInt16 RTL88WiFi::pciReadWord(int offset)  { return _pciDev->configRead16((UInt8)offset); }
UInt32 RTL88WiFi::pciReadDword(int offset) { return _pciDev->configRead32((UInt8)offset); }
void RTL88WiFi::pciWriteByte(int offset, UInt8 val)   { _pciDev->configWrite8((UInt8)offset, val); }
void RTL88WiFi::pciWriteWord(int offset, UInt16 val)  { _pciDev->configWrite16((UInt8)offset, val); }
void RTL88WiFi::pciWriteDword(int offset, UInt32 val) { _pciDev->configWrite32((UInt8)offset, val); }

int RTL88WiFi::pciFindCapability(int cap)
{
    if (!_pciDev || cap < 0 || cap > 0xff)
        return 0;

    UInt8 offset = 0;
    UInt32 value = _pciDev->findPCICapability((UInt8)cap, &offset);
    return value ? (int)offset : 0;
}

void *RTL88WiFi::allocCoherent(size_t size, IOPhysicalAddress *phys)
{
    /* DMA unmaps can be deferred by IRQ/NAPI. Reclaim them whenever allocation
     * returns to a sleepable thread so sustained traffic cannot grow the list. */
    if (preemption_enabled())
        drainPendingFree();

    IOBufferMemoryDescriptor *desc = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
        kernel_task,
        kIOMemoryPhysicallyContiguous | kIODirectionInOut | kIOMemoryKernelUserShared,
        size,
        0x00000000FFFFFFF0ULL);
    if (!desc) { IOLog("RTL88WiFi: dma alloc failed, size=%zu\n", size); return nullptr; }
    if (desc->prepare() != kIOReturnSuccess) { desc->release(); return nullptr; }

    IOPhysicalAddress pa = desc->getPhysicalAddress();
    void *va = desc->getBytesNoCopy();
    if (!va || !pa) { desc->complete(); desc->release(); return nullptr; }
    memset(va, 0, size);
    if (phys) *phys = pa;

    RTW88DMAEntry *entry = (RTW88DMAEntry *)IOMallocZero(sizeof(RTW88DMAEntry));
    if (!entry) { desc->complete(); desc->release(); return nullptr; }
    entry->desc = desc; entry->virt = va; entry->phys = pa; entry->size = size;

    IOSimpleLockLock(_dmaLock);
    entry->next = _dmaList;
    _dmaList = entry;
    IOSimpleLockUnlock(_dmaLock);
    return va;
}

void RTL88WiFi::freeCoherent(size_t size, void *virt, IOPhysicalAddress phys)
{
    IOSimpleLockLock(_dmaLock);
    RTW88DMAEntry **prev = &_dmaList;
    for (RTW88DMAEntry *e = _dmaList; e; e = e->next) {
        if (e->virt == virt) {
            *prev = e->next;
            IOSimpleLockUnlock(_dmaLock);
            if (preemption_enabled()) {
                e->desc->complete(); e->desc->release(); IOFree(e, sizeof(*e));
            } else {
                IOSimpleLockLock(_pendingFreeLock);
                e->next = _dmaPendingFree; _dmaPendingFree = e;
                IOSimpleLockUnlock(_pendingFreeLock);
            }
            return;
        }
        prev = &e->next;
    }
    IOSimpleLockUnlock(_dmaLock);
    IOLog("RTL88WiFi: freeCoherent: virt %p not found\n", virt);
}

void RTL88WiFi::freeCoherentByPhys(IOPhysicalAddress phys)
{
    IOSimpleLockLock(_dmaLock);
    RTW88DMAEntry **prev = &_dmaList;
    for (RTW88DMAEntry *e = _dmaList; e; e = e->next) {
        if (e->phys == phys) {
            *prev = e->next;
            IOSimpleLockUnlock(_dmaLock);
            if (preemption_enabled()) {
                e->desc->complete(); e->desc->release(); IOFree(e, sizeof(*e));
            } else {
                IOSimpleLockLock(_pendingFreeLock);
                e->next = _dmaPendingFree; _dmaPendingFree = e;
                IOSimpleLockUnlock(_pendingFreeLock);
            }
            return;
        }
        prev = &e->next;
    }
    IOSimpleLockUnlock(_dmaLock);
}

void RTL88WiFi::setBounceOrigVA(IOPhysicalAddress phys, void *orig_va)
{
    IOSimpleLockLock(_dmaLock);
    for (RTW88DMAEntry *e = _dmaList; e; e = e->next) {
        if (e->phys == phys) { e->orig_va = orig_va; break; }
    }
    IOSimpleLockUnlock(_dmaLock);
}

void RTL88WiFi::syncBounceForCpu(IOPhysicalAddress dma, size_t size)
{
    IOSimpleLockLock(_dmaLock);
    for (RTW88DMAEntry *e = _dmaList; e; e = e->next) {
        if (e->phys == dma && e->orig_va && e->virt) {
            size_t copy_len = (size <= e->size) ? size : e->size;
            IOSimpleLockUnlock(_dmaLock);
            memcpy(e->orig_va, e->virt, copy_len);
            return;
        }
    }
    IOSimpleLockUnlock(_dmaLock);
}

void RTL88WiFi::resumeTxIfStalled()
{
    /* IRQ bottom-half/NAPI run on the ordered compat datapath worker. This is a
     * safe place to retire deferred DMA mappings and kick a deliberately
     * stalled IO80211 output queue after TX descriptors have been reclaimed. */
    if (preemption_enabled())
        drainPendingFree();

    releaseTxStall();
    /* After the stall clears, so the gate opens on the same reclaim. */
    kickGatedOutput();
}

bool RTL88WiFi::releaseTxStall()
{
    if (!_txStalled || rtw88_be_tx_avail() < kRTW88TxResumeAvail)
        return false;

    _txStalled = false;
    IOOutputQueue *q = getOutputQueue();
    if (q)
        q->service(IOBasicOutputQueue::kServiceAsync);
    return true;
}

void RTL88WiFi::drainPendingFree()
{
    if (!_pendingFreeLock) return;
    IOSimpleLockLock(_pendingFreeLock);
    RTW88DMAEntry *list = _dmaPendingFree;
    _dmaPendingFree = nullptr;
    IOSimpleLockUnlock(_pendingFreeLock);
    for (RTW88DMAEntry *e = list; e; ) {
        RTW88DMAEntry *next = e->next;
        e->desc->complete(); e->desc->release(); IOFree(e, sizeof(*e));
        e = next;
    }
}

void RTL88WiFi::releaseDMAEntries()
{
    if (!_dmaLock) return;

    IOSimpleLockLock(_dmaLock);
    RTW88DMAEntry *list = _dmaList;
    _dmaList = nullptr;
    IOSimpleLockUnlock(_dmaLock);

    for (RTW88DMAEntry *entry = list; entry; ) {
        RTW88DMAEntry *next = entry->next;
        if (entry->desc) {
            entry->desc->complete();
            entry->desc->release();
        }
        IOFree(entry, sizeof(*entry));
        entry = next;
    }
}

void RTL88WiFi::teardown()
{
    __atomic_store_n(&_shutdown, true, __ATOMIC_RELEASE);
    if (_privateMacTimer) {
        _privateMacTimer->disable();
        _privateMacTimer->cancelTimeout();
        if (_workLoop) _workLoop->removeEventSource(_privateMacTimer);
        _privateMacTimer->cancelTimeout();
        _privateMacTimer->release();
        _privateMacTimer = nullptr;
    }
    if (_diagnosticsTimer) {
        /* A callback already running may re-arm after the first cancel;
         * removal waits for the workloop gate, then cancel any re-arm. */
        _diagnosticsTimer->disable();
        _diagnosticsTimer->cancelTimeout();
        if (_workLoop) _workLoop->removeEventSource(_diagnosticsTimer);
        _diagnosticsTimer->cancelTimeout();
        _diagnosticsTimer->release();
        _diagnosticsTimer = nullptr;
    }
    if (_diagnosticsBuffer) {
        IOFree(_diagnosticsBuffer, 32768);
        _diagnosticsBuffer = nullptr;
    }
    /* Stop asynchronous output-queue wakeups before interface teardown. */
    rtw88_set_tx_resume_cb(nullptr);
    _txStalled = false;
    (void)stopDMA();
    if (_intrSrc)
        _intrSrc->disable();

    if (_awdlManager)
        _awdlManager->reset();

    if (_ieee80211) {
        if (_ieeeStarted)
            _ieee80211->stop();
        _ieeeStarted = false;
        _ieee80211->release();
        _ieee80211 = nullptr;
    }

    if (_awdlManager) {
        delete _awdlManager;
        _awdlManager = nullptr;
    }

    if (_netif) {
        if (_netifAttached)
            detachInterface(_netif, true);
        _netifAttached = false;
        _netif->release();
        _netif = nullptr;
    }

    drainPendingFree();
    releaseDMAEntries();

    if (_compatInitialized) {
        rtw88_compat_exit();
        _compatInitialized = false;
    }

    if (_intrSrc) {
        if (_workLoop)
            _workLoop->removeEventSource(_intrSrc);
        _intrSrc->release();
        _intrSrc = nullptr;
    }
    if (_workLoop) {
        _workLoop->release();
        _workLoop = nullptr;
    }
    if (_compatPciDev) {
        IOFree(_compatPciDev, sizeof(*_compatPciDev));
        _compatPciDev = nullptr;
    }
    if (_mmioMap) {
        _mmioMap->release();
        _mmioMap = nullptr;
        _mmioBase = nullptr;
    }

    if (g_pci_dev_instance == this) {
        g_pci_dev_instance = nullptr;
        rtw88_pci_io_ops = nullptr;
        rtw88_dma_ops = nullptr;
    }

    if (_pciDev) {
        _pciDev->setBusMasterEnable(false);
        _pciDev->release();
        _pciDev = nullptr;
    }

    if (_pendingFreeLock) {
        IOSimpleLockFree(_pendingFreeLock);
        _pendingFreeLock = nullptr;
    }
    if (_dmaLock) {
        IOSimpleLockFree(_dmaLock);
        _dmaLock = nullptr;
    }
}

IOReturn RTL88WiFi::registerWithPolicyMaker(IOService *policyMaker)
{
    if (!policyMaker)
        return kIOReturnBadArgument;

    _pmPowerState = kRTW88PowerStateOn;
    setProperty("PM_REGISTERED", kOSBooleanTrue);
    setProperty("PM_STATE", "on");
    setProperty("PM_HIBERNATION_SAFE_REINIT", kOSBooleanTrue);
    return policyMaker->registerPowerDriver(this, gRTW88PowerStates,
                                            kRTW88PowerStateCount);
}

IOReturn RTL88WiFi::quiesceForSystemSleep()
{
    if (__atomic_exchange_n(&_pmTransition, true, __ATOMIC_ACQ_REL))
        return kIOReturnBusy;
    waitForDiagnosticsIdle();

    ++_pmSleepCount;
    setProperty("PM_STATE", "sleeping");
    setProperty("PM_SLEEP_COUNT", (uint64_t)_pmSleepCount, 32);

    _pmAWDLSyncWasEnabled = _awdlManager && _awdlManager->syncEnabled();
    if (_awdlManager)
        _awdlManager->suspendForPowerTransition();

    _pmRadioWasPowered = _ieee80211 && _ieee80211->isPowered();
    _txStalled = true;

    IOReturn radioRet = kIOReturnSuccess;
    if (_ieee80211 && _pmRadioWasPowered)
        radioRet = _ieee80211->suspendForSystemSleep();

    /* The Realtek core is now stopped and no longer owns descriptors.  Fence
     * PCI DMA only after rtw_core_stop()/rtw_pci_stop() synchronized the IRQ
     * bottom half.  This ordering is important for hibernate, where the PCI
     * function may lose all device state while kernel memory is restored. */
    IOReturn dmaRet = stopDMA();
    if (_pciDev)
        _pciDev->setMemoryEnable(false);

    if (preemption_enabled())
        drainPendingFree();

    _pmLastSleepResult = (radioRet != kIOReturnSuccess) ? radioRet : dmaRet;
    setProperty("PM_LAST_SLEEP_RESULT", (uint64_t)(uint32_t)_pmLastSleepResult, 32);
    setProperty("PM_RADIO_WAS_POWERED", _pmRadioWasPowered ? kOSBooleanTrue : kOSBooleanFalse);
    setProperty("PM_STATE", "off");
    __atomic_store_n(&_pmTransition, false, __ATOMIC_RELEASE);
    return _pmLastSleepResult;
}

IOReturn RTL88WiFi::restoreAfterSystemWake()
{
    if (__atomic_exchange_n(&_pmTransition, true, __ATOMIC_ACQ_REL))
        return kIOReturnBusy;
    waitForDiagnosticsIdle();

    ++_pmWakeCount;
    setProperty("PM_STATE", "waking");
    setProperty("PM_WAKE_COUNT", (uint64_t)_pmWakeCount, 32);

    IOReturn ret = kIOReturnSuccess;
    if (!_pciDev || !_ieee80211 || !_mmioMap || !_mmioBase) {
        ret = kIOReturnNotReady;
        goto out;
    }

    /* Hibernation resumes a memory image, not the NIC.  Re-enable the PCI
     * command bits unconditionally and keep _dmaStopped asserted while the
     * firmware/rings are reconstructed.  This prevents a restored OS event
     * source from dispatching an interrupt into a half-initialized rtw88. */
    _pciDev->setMemoryEnable(true);
    _pciDev->setBusMasterEnable(true);
    {
        const UInt16 cmd = _pciDev->configRead16(kIOPCIConfigCommand);
        if ((cmd & 0x0006U) != 0x0006U) {
            IOLog("RTL88WiFi: wake failed to restore PCI command bits (0x%04x)\n", cmd);
            ret = kIOReturnNotReady;
            goto out;
        }
    }

    /* Refresh the compat-visible BAR in case the platform firmware rewrote the
     * physical PCI BAR while preserving the IOMemoryMap virtual mapping. */
    if (_compatPciDev) {
        _compatPciDev->resource[2] = (resource_size_t)_mmioBase;
        _compatPciDev->resource_len[2] = (resource_size_t)_mmioMap->getLength();
    }

    if (_pmRadioWasPowered) {
        ret = _ieee80211->cmdPowerOn();
        if (ret != kIOReturnSuccess)
            goto out;
    }

    __atomic_store_n(&_dmaStopped, false, __ATOMIC_RELEASE);
    if (_intrSrc)
        _intrSrc->enable();

    _scanCacheBootstrapAttempted = false;
    _txStalled = false;
    /* Preserve the user-visible radio state across sleep.  If Wi-Fi was off
     * before suspend, do not restart AWDL discovery merely because the PCI
     * function returned to D0.  A later IO80211 enable() owns that restart. */
    if (_awdlManager && _pmRadioWasPowered) {
        if (_pmAWDLSyncWasEnabled)
            _awdlManager->resumeAfterPowerTransition();
        _awdlManager->scheduleDiscovery();
    }

    /* The infrastructure association is intentionally not resurrected from
     * hibernated RAM.  Firmware keys, RX PN state and AP sequence state are no
     * longer trustworthy after a cold PCI resume.  Report a valid-but-down
     * link so CoreWiFi performs a clean reassociation. */
    (void)setLinkStatus(kIONetworkLinkValid | kIONetworkLinkNoNetworkChange);
    if (_netif) {
        _netif->postMessage(APPLE80211_M_POWER_CHANGED);
        IOOutputQueue *q = getOutputQueue();
        if (q) q->service(IOBasicOutputQueue::kServiceAsync);
        kickGatedOutput();
    }

out:
    if (ret != kIOReturnSuccess) {
        /* Never leave bus mastering enabled after a failed firmware restore. */
        __atomic_store_n(&_dmaStopped, true, __ATOMIC_RELEASE);
        if (_intrSrc) _intrSrc->disable();
        if (_pciDev) _pciDev->setBusMasterEnable(false);
    }
    _pmLastWakeResult = ret;
    setProperty("PM_LAST_WAKE_RESULT", (uint64_t)(uint32_t)ret, 32);
    setProperty("PM_STATE", ret == kIOReturnSuccess ? "on" : "wake-failed");
    __atomic_store_n(&_pmTransition, false, __ATOMIC_RELEASE);
    return ret;
}

IOReturn RTL88WiFi::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice)
{
    (void)whatDevice;
    if (powerStateOrdinal >= kRTW88PowerStateCount)
        return IOPMNoSuchState;
    if (powerStateOrdinal == _pmPowerState)
        return IOPMAckImplied;

    IOReturn ret = kIOReturnSuccess;
    if (powerStateOrdinal == kRTW88PowerStateOff)
        ret = quiesceForSystemSleep();
    else
        ret = restoreAfterSystemWake();

    /* Power management must always receive a synchronous acknowledgement; a
     * driver-level failure is exposed through IORegistry instead of hanging the
     * machine's sleep/wake transition. */
    _pmPowerState = powerStateOrdinal;
    if (ret != kIOReturnSuccess)
        IOLog("RTL88WiFi: PM transition to state %lu failed 0x%x\n",
              powerStateOrdinal, ret);
    return IOPMAckImplied;
}

void RTL88WiFi::stop(IOService *provider)
{
    /* The reference IO80211 driver calls IO80211Controller::stop() before releasing its
     * workloop/HAL/interface state. Keep the same ordering here so superclass
     * teardown cannot observe a freed IO80211WorkLoop or Realtek backend. */
    if (_superStarted) {
        super::stop(provider);
        _superStarted = false;
    }
    teardown();
}

void RTL88WiFi::free()
{
    teardown();
    super::free();
}

const OSString *RTL88WiFi::newVendorString() const { return OSString::withCString("Apple"); }
const OSString *RTL88WiFi::newModelString() const  { return OSString::withCString("802.11ac"); }

IOReturn RTL88WiFi::enable(IONetworkInterface *iface)
{
    if (!_ieee80211 || __atomic_load_n(&_shutdown, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&_pmTransition, __ATOMIC_ACQUIRE) ||
        _pmPowerState == kRTW88PowerStateOff)
        return kIOReturnNotReady;
    if (__atomic_load_n(&_dmaStopped, __ATOMIC_ACQUIRE)) {
        if (!_pciDev) return kIOReturnNotReady;
        _pciDev->setBusMasterEnable(true);
        if (!(_pciDev->configRead16(kIOPCIConfigCommand) & 0x0004))
            return kIOReturnNotReady;
        __atomic_store_n(&_dmaStopped, false, __ATOMIC_RELEASE);
        if (_intrSrc) _intrSrc->enable();
        if (_awdlManager) _awdlManager->scheduleDiscovery();
    }
    _scanCacheBootstrapAttempted = false;
    /* Ventura can enable its queues without issuing POWER ON. Ensure the
     * hardware is running before handing interface state to IO80211. */
    IOReturn ret = _ieee80211->powerOn();
    if (ret != kIOReturnSuccess) return ret;
    ret = super::enable(iface);
    if (ret != kIOReturnSuccess) {
        _ieee80211->powerOff();
    } else {
        _txStalled = false;
        IOOutputQueue *q = getOutputQueue();
        if (q) q->service(IOBasicOutputQueue::kServiceAsync);
        kickGatedOutput();
    }
    IOLog("RTL88WiFi: IO80211 enable result=0x%x\n", ret);
    return ret;
}

IOReturn RTL88WiFi::disable(IONetworkInterface *iface)
{
    /* Keep the IO80211 service published, but actually quiesce the Realtek
     * radio.  v51 left firmware/DMA association state alive across an IO80211
     * Wi-Fi power cycle; the next enable then reused stale state.  A complete
     * cmdPowerOff()/powerOn() pair is also the safe primitive for sleep/wake
     * on hardware that cannot reliably survive PCI D3hot with rtw88 state
     * retained. */
    IOReturn ret = super::disable(iface);
    _txStalled = false;
    IOReturn powerRet = kIOReturnSuccess;
    if (_ieee80211) powerRet = _ieee80211->cmdPowerOff();
    (void)setLinkStatus(kIONetworkLinkValid | kIONetworkLinkNoNetworkChange);
    IOLog("RTL88WiFi: IO80211 disable result=0x%x radio-off=0x%x\n", ret, powerRet);
    if (ret == kIOReturnSuccess && powerRet != kIOReturnSuccess)
        return powerRet;
    return ret;
}

IOReturn RTL88WiFi::getPacketFilters(const OSSymbol *group, UInt32 *filters) const
{
    if (!group || !filters) return kIOReturnBadArgument;
    if (group == gIONetworkFilterGroup) {
        /* The reference IO80211 driver publishes these two filters to IO80211. */
        *filters = kIOPacketFilterMulticast | kIOPacketFilterPromiscuous;
        return kIOReturnSuccess;
    }
    return IOEthernetController::getPacketFilters(group, filters);
}

IOReturn RTL88WiFi::setMulticastMode(bool active)
{
    IOReturn ret = _ieee80211 ? _ieee80211->setReceiveMulticast(active) : kIOReturnNotReady;
    IOLog("RTL88WiFi: multicast active=%d result=0x%x\n", active, ret);
    return ret;
}

IOReturn RTL88WiFi::setMulticastList(IOEthernetAddress *addrs, UInt32 count)
{
    if (count && !addrs) return kIOReturnBadArgument;
    /* rtw88 configure_filter supports all-multicast, not an address table.
     * Use that documented fallback; the network stack handles membership. */
    return setMulticastMode(count != 0);
}

IOReturn RTL88WiFi::setPromiscuousMode(bool active)
{
    /* Match the reference IO80211 driver's IO80211 contract.  rtw88's normal STA receive
     * filter remains authoritative; this callback must not abort IO80211 setup. */
    (void)active;
    return kIOReturnSuccess;
}

bool RTL88WiFi::createMediumTables(const IONetworkMedium **primary)
{
    /* The reference Ventura IO80211 driver publishes the medium dictionary before
     * attachInterface().  Keep the same IO80211 lifecycle so the interface
     * is born with a selected/current medium already available. */
    OSDictionary *mediumDict = OSDictionary::withCapacity(1);
    if (!mediumDict)
        return false;

    IONetworkMedium *medium = IONetworkMedium::medium(0x80, 11000000);
    if (!medium) {
        mediumDict->release();
        return false;
    }

    bool ok = IONetworkMedium::addMedium(mediumDict, medium);
    if (ok && primary)
        *primary = medium;
    if (ok)
        ok = publishMediumDictionary(mediumDict);

    medium->release();
    mediumDict->release();
    return ok;
}

IONetworkInterface *RTL88WiFi::createInterface()
{
    IOLog("RTL88WiFi: createInterface entered (controller workloop=%p)\n",
          getWorkLoop());
    RTL88WiFiInterface *interface = OSTypeAlloc(RTL88WiFiInterface);
    if (!interface) {
        IOLog("RTL88WiFi: createInterface allocation failed\n");
        return nullptr;
    }
    if (!interface->init(this)) {
        IOLog("RTL88WiFi: createInterface IO80211Interface::init failed\n");
        interface->release();
        return nullptr;
    }
    IOLog("RTL88WiFi: createInterface initialized\n");
    return interface;
}

bool RTL88WiFi::configureInterface(IONetworkInterface *iface)
{
    /* Match the reference Ventura IO80211 driver: IO80211/IONetworkController performs the
     * interface configuration.  The medium table is published in start()
     * before attachInterface(), not created during the attach callback. */
    bool ok = super::configureInterface(iface);
    IOLog("RTL88WiFi: configureInterface super=%d\n", ok);
    return ok;
}

IOReturn RTL88WiFi::selectMedium(const IONetworkMedium *medium)
{
    if (!medium)
        return kIOReturnBadArgument;
    setSelectedMedium(medium);
    return kIOReturnSuccess;
}

UInt32 RTL88WiFi::getFeatures() const
{
    /* Preserve IONetworkController feature flags. IO80211-specific 802.11n
     * negotiation is handled by enableFeature(), as in the reference IO80211 driver. */
    return super::getFeatures();
}

UInt32 RTL88WiFi::outputPacket(mbuf_t m, void *param)
{
    (void)param;
    if (__atomic_load_n(&_pmTransition, __ATOMIC_ACQUIRE) ||
        _pmPowerState == kRTW88PowerStateOff) {
        _txStalled = true;
        return kIOReturnOutputStall;
    }
    if (__atomic_load_n(&_dmaStopped, __ATOMIC_ACQUIRE) || !_ieee80211) {
        if (m) mbuf_freem(m);
        kickGatedOutput();
        return kIOReturnOutputDropped;
    }

    if (preemption_enabled())
        drainPendingFree();

    /* During a connected off-channel AWDL window the single PHY is not on
     * the AP channel. Backpressure en0 instead of transmitting AP traffic on
     * the peer-to-peer channel. */
    if (_ieee80211->staTxBlockedByAWDL()) {
        _txStalled = true;
        return kIOReturnOutputStall;
    }

    const unsigned int avail = rtw88_be_tx_avail();
    if (_txStalled || avail < kRTW88TxStallAvail) {
        _txStalled = true;
        /* Do not consume m. IOBasicOutputQueue retries this exact packet when
         * resumeTxIfStalled() services the queue after descriptor reclamation. */
        return kIOReturnOutputStall;
    }

    /* The stack already accounts output bytes on this interface; add the
     * packet count only, so netstat/Activity Monitor are not stuck at zero. */
    UInt32 ret = _ieee80211->outputPacket(m);
    ifnet_t ifp = _netif ? _netif->getIfnet() : nullptr;
    if (ifp)
        ifnet_stat_increment_out(ifp, ret == kIOReturnOutputSuccess ? 1 : 0, 0,
                                 ret == kIOReturnOutputSuccess ? 0 : 1);
    kickGatedOutput();
    return ret;
}

IOReturn RTL88WiFi::getHardwareAddress(IOEthernetAddress *addr)
{
    if (!addr || !_ieee80211) return kIOReturnNotReady;
    _ieee80211->getMACAddress(addr->bytes);
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::setHardwareAddress(const IOEthernetAddress *addr)
{
    if (!addr || !_ieee80211)
        return kIOReturnBadArgument;

    /* CoreWiFi calls this before each join.  Honour the PRIVATE_MAC selector:
     * Off restores the EFuse address; Fixed adopts the host's selected address
     * (or the address explicitly supplied by PRIVATE_MAC); Rotating uses the
     * pending rotation when one is due.  Never rotate a live association. */
    uint8_t desired[6] = {};
    if (!_privMacEnabled) {
        _ieee80211->getPermanentMACAddress(desired);
    } else if (_privMacApplyPending && _privMacAddressValid) {
        memcpy(desired, _privMacAddress, sizeof(desired));
    } else if (_privMacRotatePending) {
        rtw88GeneratePrivateMAC(desired);
    } else {
        /* A non-zero address supplied by CoreWiFi is authoritative (Apple's
         * reference driver copies it unchanged).  Only addresses generated
         * locally by rtw88GeneratePrivateMAC() are forced to LAA unicast. */
        memcpy(desired, addr->bytes, sizeof(desired));
    }
    if (!rtw88MacIsUnicast(desired))
        return kIOReturnBadArgument;

    IOReturn ret = _ieee80211->setMACAddress(desired);
    if (ret == kIOReturnSuccess) {
        memcpy(_macAddr.bytes, desired, sizeof(_macAddr.bytes));
        if (_privMacEnabled) {
            memcpy(_privMacAddress, desired, sizeof(_privMacAddress));
            _privMacAddressValid = true;
        } else {
            bzero(_privMacAddress, sizeof(_privMacAddress));
            _privMacAddressValid = false;
        }
        _privMacApplyPending = false;
        _privMacRotatePending = false;
        if (_privMacEnabled && _privMacIntervalS)
            armPrivateMACTimer(_privMacIntervalS * 1000U);
        IOLog("RTL88WiFi: station MAC programmed (private=%u mode=%s)\n",
              _privMacEnabled ? 1U : 0U,
              !_privMacEnabled ? "off" : (_privMacIntervalS ? "rotating" : "fixed"));
    } else {
        IOLog("RTL88WiFi: station MAC update deferred/failed ret=0x%x\n", ret);
    }
    bzero(desired, sizeof(desired));
    return ret;
}

IOReturn RTL88WiFi::getHardwareAddressForInterface(IO80211Interface *iface,
                                                       IOEthernetAddress *addr)
{
    (void)iface;
    /* The reference IO80211 driver maps the infrastructure-interface query to the physical
     * controller address.  Virtual interfaces get their own address through
     * IO80211's attachVirtualInterface lifecycle. */
    return getHardwareAddress(addr);
}

/*
 * Ventura IO80211FamilyLegacy transport compatibility.
 *
 * the reference Ventura IO80211 driver implements apple80211Request() and leaves association/
 * security translation to IO80211FamilyLegacy. Preserve that path except for
 * scan and the validated 900/908-byte association prefix on newer hosts using
 * the restored Legacy/Skywalk stack.
 */
namespace {
static bool rtw88TryHostAssociation(RTL88WiFi *self, IO80211Interface *interface,
                                    apple80211req *req, SInt32 *result)
{
    if (!req->req_data || !RTW88AssocWire::supportedRequestSize(req->req_len)) return false;
    uint8_t prefix[RTW88AssocWire::PrefixSize] = {};
    RTW88AssocWire::Personal fields = {};
    const int error = copyin((user_addr_t)req->req_data, prefix, sizeof(prefix));
    const bool valid = !error && RTW88AssocWire::decode(prefix, sizeof(prefix), fields);
    RTW88AssocWire::wipe(prefix, sizeof(prefix));
    if (!valid) { RTW88AssocWire::wipe(&fields, sizeof(fields)); return false; }
    apple80211_assoc_data assoc = {};
    assoc.version = APPLE80211_VERSION;
    assoc.ad_mode = fields.mode; assoc.ad_auth_lower = fields.lower; assoc.ad_auth_upper = fields.upper;
    assoc.ad_ssid_len = fields.ssidLength;
    memcpy(assoc.ad_ssid, fields.ssid, fields.ssidLength);
    memcpy(assoc.ad_bssid.octet, fields.bssid, sizeof(fields.bssid));
    assoc.ad_key.version = APPLE80211_VERSION;
    assoc.ad_key.key_len = fields.keyLength; assoc.ad_key.key_cipher_type = fields.cipher;
    memcpy(assoc.ad_key.key, fields.key, fields.keyLength);
    RTW88AssocWire::wipe(&fields, sizeof(fields));
    self->setProperty("STA_ASSOC_HOST32_TRANSLATED", kOSBooleanTrue);
    *result = self->apple80211Request(SIOCSA80211, APPLE80211_IOC_ASSOCIATE, interface, &assoc);
    RTW88AssocWire::wipe(&assoc, sizeof(assoc));
    if (*result < 0 || *result >= 256) {
        const int e = self->errnoFromReturn(*result); *result = e ? e : EIO;
    }
    return true;
}
}

namespace {
static bool rtw88TryAssocFromSplitWrapper(RTL88WiFi *, IO80211Interface *, void *, SInt32 *);
}
SInt32 RTL88WiFi::apple80211_ioctl(IO80211Interface *interface,
                                      IO80211VirtualInterface *virtualInterface,
                                      ifnet_t net, unsigned long cmd,
                                      void *data)
{
    /* Ventura is the native ABI for this kext. */
    if (version_major < 23) {
        SInt32 sr = super::apple80211_ioctl(interface, virtualInterface, net, cmd, data);
        return sr;
    }

    if (!data || (cmd != SIOCGA80211 && cmd != SIOCSA80211)) {
        SInt32 sr = super::apple80211_ioctl(interface, virtualInterface, net, cmd, data);
        return sr;
    }

    auto *req = static_cast<struct apple80211req *>(data);
    if (!req) {
        return EINVAL;
    }

    const bool isGet = (cmd == SIOCGA80211);
    const bool isSet = (cmd == SIOCSA80211);
    /* v52: snapshot the BSD wrapper before handing the same pointer to
     * IO80211FamilyLegacy.  Do not re-read wrapper fields after super returns;
     * issue #4 showed this path executing around a power-cycle corruption. */
    const uint32_t reqType = req->req_type;
    const uint32_t reqVal = req->req_val;
    const uint32_t len = req->req_len;
    const user_addr_t reqData = (user_addr_t)req->req_data;

    /* BSD buffers are NOT generally apple80211Request() structures. The
     * Ventura family strips version from CARD_CAPABILITIES (16 -> 12 bytes),
     * strips version/length from SSID (40 -> <=32 bytes), and uses req_val
     * for scalar requests. Passing caller-sized buffers directly to typed
     * handlers both corrupts the wire format and can overrun an allocation.
     * Keep native marshalling for all but the proven STA scan/powersave
     * exceptions. In particular virtual-interface/AWDL requests must retain
     * their original interface routing through the family.
     */
    if (isSet && reqType == APPLE80211_IOC_ASSOCIATE)
        setProperty("STA_ASSOC_BSD_LEN", (uint64_t)len, 32);
    // Normalize the host format before the legacy family truncates/casts it.
    if (isSet && reqType == APPLE80211_IOC_ASSOCIATE && !virtualInterface &&
        interface && interface == _netif && RTW88AssocWire::supportedRequestSize(len)) {
        SInt32 ret = 0;
        if (rtw88TryHostAssociation(this, interface, req, &ret)) return ret;
    }
    const bool scanBridge = !virtualInterface &&
        ((isGet && reqType == APPLE80211_IOC_SCAN_RESULT) ||
         (isSet && (reqType == APPLE80211_IOC_SCAN_REQ ||
                    reqType == APPLE80211_IOC_SCAN_REQ_MULTIPLE)));
    const bool scalarPowerSave = !virtualInterface && isSet && len == 0 &&
        reqType == APPLE80211_IOC_POWERSAVE;
    const bool scalarDisassociate = !virtualInterface && isSet && len == 0 &&
        reqType == APPLE80211_IOC_DISASSOCIATE;
    const bool channelsBridge = !virtualInterface && isGet &&
        reqType == APPLE80211_IOC_CHANNELS_INFO;
    /* r7: IO80211FamilyLegacy's getCurrentNetwork handler unconditionally
     * returns EOPNOTSUPP (102), so CURRENT_NETWORK never reached our handler.
     * Sonoma passes 1228 bytes, as for SCAN_RESULT; fill the same 1164-byte
     * scan_result prefix and leave the caller extension zeroed. */
    const bool currentNetworkBridge = !virtualInterface && isGet &&
        interface && interface == _netif &&
        reqType == APPLE80211_IOC_CURRENT_NETWORK;
    /* The restored IO80211FamilyLegacy does not forward PRIVATE_MAC (238)
     * to apple80211Request on this host.  Bridge only the primary interface
     * and the exact 28-byte payload documented by Apple's own driver. */
    const bool privateMacBridge = !virtualInterface && interface && interface == _netif &&
        reqType == APPLE80211_IOC_PRIVATE_MAC;
    if (!scanBridge && !scalarPowerSave && !scalarDisassociate && !channelsBridge &&
        !currentNetworkBridge && !privateMacBridge) {
        const UInt32 before = __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED);
        SInt32 sr = super::apple80211_ioctl(interface, virtualInterface, net, cmd, data);
        if (virtualInterface && sr != 0) {
            setProperty("AWDL_BSD_ERROR_SELECTOR", (uint64_t)(uint32_t)reqType, 32);
            setProperty("AWDL_BSD_ERROR_LENGTH", (uint64_t)len, 32);
            setProperty("AWDL_BSD_ERROR_SET", isSet ? kOSBooleanTrue : kOSBooleanFalse);
            setProperty("AWDL_BSD_ERROR", (uint64_t)(uint32_t)sr, 32);
        }
        // A family-level rejection may occur before the split SET override.
        // Retry only a validated STA ASSOCIATE that never reached our handler.
        // Darwin ENOTSUP=45 and EOPNOTSUPP=102; Linux macros differ here.
        if (isSet && reqType == APPLE80211_IOC_ASSOCIATE && !virtualInterface &&
            interface && interface == _netif && (sr == 45 || sr == 102) &&
            __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED) == before) {
            SInt32 ret = 0;
            if (rtw88TryAssocFromSplitWrapper(this, interface, data, &ret)) {
                setProperty("STA_ASSOC_OUTER_FALLBACK", kOSBooleanTrue);
                if (ret == kIOReturnSuccess || (ret > 0 && ret < 256)) sr = ret;
                else { sr = errnoFromReturn(ret); if (!sr) sr = EIO; }
            }
        }
        setProperty("STA_V23_NATIVE_SELECTOR", (uint64_t)reqType, 32);
        setProperty("STA_V23_NATIVE_RET", (uint64_t)(uint32_t)sr, 32);
        if (sr != 0) {
            setProperty("STA_V23_NATIVE_ERROR_SELECTOR", (uint64_t)reqType, 32);
            setProperty("STA_V23_NATIVE_ERROR_RET", (uint64_t)(uint32_t)sr, 32);
            setProperty("STA_V23_NATIVE_ERROR_IS_SET", isSet ? kOSBooleanTrue : kOSBooleanFalse);
            if (isSet) {
                setProperty("STA_V23_NATIVE_SET_ERROR_SELECTOR", (uint64_t)reqType, 32);
                setProperty("STA_V23_NATIVE_SET_ERROR_RET", (uint64_t)(uint32_t)sr, 32);
            }
        }
        return sr;
    }

    /* A malformed userspace length must never become a giant kernel allocation. */
    if (len > 64U * 1024U) {
        return EINVAL;
    }

    /* Some Apple80211 SETs carry their value in req_val and intentionally
     * have no payload.  Modern CoreWiFi uses this for POWERSAVE=
     * MAX_THROUGHPUT (7) before association.  The restored Ventura family
     * otherwise returns Darwin ENOTSUP and aborts the join transaction. */
    if (len == 0) {
        if (isSet && reqType == APPLE80211_IOC_POWERSAVE) {
            if (reqVal < APPLE80211_POWERSAVE_MODE_DISABLED ||
                reqVal > APPLE80211_POWERSAVE_MODE_MAX_POWERSAVE)
                return EINVAL;
            _powerSaveLevel = (UInt32)reqVal;
            setProperty("STA_V20_POWERSAVE_SET", kOSBooleanTrue);
            setProperty("STA_V20_POWERSAVE_VALUE", (uint64_t)_powerSaveLevel, 32);
            IOLog("RTL88WiFi: v20 zero-len POWERSAVE SET value=%u accepted\n",
                  (unsigned)_powerSaveLevel);
            return 0;
        }
        if (reqType != APPLE80211_IOC_DISASSOCIATE) {
            SInt32 sr = super::apple80211_ioctl(interface, virtualInterface, net, cmd, data);
            return sr;
        }
        SInt32 r = apple80211Request(cmd, reqType, interface, nullptr);
        if (r == kIOReturnSuccess)
            return 0;
        if (r > 0 && r < 256)
            return r;
        int e = errnoFromReturn(r);
        return e ? e : EIO;
    }

    if (!(void *)reqData) {
        return EFAULT;
    }

    if (privateMacBridge)
        return handlePrivateMACBSDRequest(cmd, req, "legacy-ioctl");

    /* The restored family rejects the host CHANNELS_INFO layout with EINVAL
     * before reaching our handler. Retain this v21 scan-support exception,
     * but never give a caller-sized allocation to the typed handler.
     */
    if (channelsBridge) {
        setProperty("STA_V24_CHANNELS_CALLER_LEN", (uint64_t)len, 32);
        if (len < sizeof(apple80211_channels_info)) return EINVAL;
        void *out = IOMallocZero(len);
        if (!out) return ENOMEM;
        const SInt32 r = apple80211Request(cmd, reqType, interface, out);
        int e = 0;
        if (r == kIOReturnSuccess)
            e = copyout(out, reqData, len);
        else if (r > 0 && r < 256) e = r;
        else { e = errnoFromReturn(r); if (!e) e = EIO; }
        IOFree(out, len);
        setProperty("STA_V24_CHANNELS_BRIDGE_RET", (uint64_t)(uint32_t)e, 32);
        return e;
    }

    if (currentNetworkBridge) {
        if (len < sizeof(struct apple80211_scan_result)) return EINVAL;
        void *out = IOMallocZero(len);
        if (!out) return ENOMEM;
        const SInt32 r = apple80211Request(cmd, reqType, interface, out);
        int e = 0;
        if (r == kIOReturnSuccess)
            e = copyout(out, reqData, len);
        else if (r > 0 && r < 256) e = r;
        else { e = errnoFromReturn(r); if (!e) e = EIO; }
        IOFree(out, len);
        setProperty("STA_R7_CURRENT_NETWORK_LEN", (uint64_t)len, 32);
        setProperty("STA_R7_CURRENT_NETWORK_RET", (uint64_t)(uint32_t)e, 32);
        return e;
    }

    /* SCAN_RESULT is the only legacy Apple80211 request whose controller
     * callback uses a pointer-to-pointer result.  Handle it explicitly rather
     * than feeding a userspace-sized buffer to a Ventura structure. */
    if (isGet && reqType == APPLE80211_IOC_SCAN_RESULT) {
        struct apple80211_scan_result *result = nullptr;
        SInt32 r = apple80211Request(cmd, reqType, interface, &result);
        if (r != kIOReturnSuccess) {
            if (r > 0 && r < 256)
                return r;
            int e = errnoFromReturn(r);
            return e ? e : EIO;
        }
        if (!result)
            return ENOENT;

        void *out = IOMallocZero(len);
        if (!out)
            return ENOMEM;
        const size_t known = sizeof(struct apple80211_scan_result);
        const size_t n = len < known ? len : known;
        memcpy(out, result, n);
        const int ce = copyout(out, reqData, len);
        IOFree(out, len);
        return ce ? ce : 0;
    }

    /* Only scan SETs remain here. Require the entire structure before its
     * fields are accessed by the typed handler; never dispatch a short buffer.
     */
    const size_t scanSize = reqType == APPLE80211_IOC_SCAN_REQ ?
        sizeof(apple80211_scan_data) : sizeof(apple80211_scan_multiple_data);
    if (!isSet || !scanBridge || len < scanSize)
        return EINVAL;

    void *payload = IOMallocZero(len);
    if (!payload)
        return ENOMEM;

    if (isSet) {
        const int ce = copyin(reqData, payload, len);
        if (ce) {
            IOFree(payload, len);
            return ce;
        }
    }

    SInt32 r = apple80211Request(cmd, reqType, interface, payload);

    if (r == kIOReturnSuccess && isGet) {
        const int ce = copyout(payload, reqData, len);
        IOFree(payload, len);
        return ce ? ce : 0;
    }

    IOFree(payload, len);
    if (r == kIOReturnSuccess)
        return 0;
    if (r > 0 && r < 256)
        return r;

    const int e = errnoFromReturn(r);
    return e ? e : EIO;
}

/* Private Wi-Fi Address selector 238 travels through split GET/SET dispatchers
 * on Skywalk-based macOS. The previous bridge covered only the legacy ioctl
 * and one split SET ingress. Without split GET/SET routing, System Settings
 * can show the OS-selected mode while the selector remains unavailable. */
SInt32 RTL88WiFi::handlePrivateMACBSDRequest(unsigned request_type,
                                               struct apple80211req *req,
                                               const char *ingress)
{
    if (!req || !ingress ||
        (request_type != SIOCGA80211 && request_type != SIOCSA80211) ||
        req->req_type != APPLE80211_IOC_PRIVATE_MAC ||
        req->req_len != sizeof(rtw88_private_mac_data) || !req->req_data)
        return EINVAL;

    const bool isSet = request_type == SIOCSA80211;
    rtw88_private_mac_data payload = {};
    int error = 0;
    if (isSet) {
        error = copyin((user_addr_t)req->req_data, &payload, sizeof(payload));
        if (error) { bzero(&payload, sizeof(payload)); return error; }
    }

    const SInt32 native = apple80211Request(request_type,
                                           APPLE80211_IOC_PRIVATE_MAC,
                                           _netif, &payload);
    if (native == kIOReturnSuccess) {
        if (!isSet)
            error = copyout(&payload, (user_addr_t)req->req_data, sizeof(payload));
    } else if (native > 0 && native < 256) {
        error = native;
    } else {
        error = errnoFromReturn(native);
        if (!error) error = EIO;
    }

    if (isSet)
        setProperty("STA_PRIVATE_MAC_SET_SEEN", kOSBooleanTrue);
    else
        setProperty("STA_PRIVATE_MAC_GET_SEEN", kOSBooleanTrue);
    setProperty("STA_PRIVATE_MAC_LAST_RET", (uint64_t)(uint32_t)error, 32);
    IOLog("RTL88WiFi: PRIVATE_MAC %s ingress=%s result=%d\n",
          isSet ? "SET" : "GET", ingress, error);
    bzero(&payload, sizeof(payload));
    return error;
}

SInt32 RTL88WiFi::apple80211_ioctl_get(IO80211Interface *interface,
                                       IO80211VirtualInterface *virtualInterface,
                                       ifnet_t net, void *data)
{
    if (data && interface && interface == _netif && !virtualInterface) {
        auto *req = static_cast<struct apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_PRIVATE_MAC)
            return handlePrivateMACBSDRequest(SIOCGA80211, req, "legacy-split-get");
    }
    return super::apple80211_ioctl_get(interface, virtualInterface, net, data);
}

#if __IO80211_TARGET >= __MAC_10_15
SInt32 RTL88WiFi::apple80211_ioctl_get(IO80211SkywalkInterface *skywalkInterface,
                                       void *data)
{
    if (data && skywalkInterface &&
        skywalkInterface == getPrimarySkywalkInterface()) {
        auto *req = static_cast<struct apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_PRIVATE_MAC)
            return handlePrivateMACBSDRequest(SIOCGA80211, req, "skywalk-split-get");
    }
    return super::apple80211_ioctl_get(skywalkInterface, data);
}
#endif

#if __IO80211_TARGET >= __MAC_10_15
namespace {
/* Do not compare Apple IO80211 BSD errno returns against the Linux compat
 * ENOTSUP macro.  src/compat/linux/kernel.h intentionally remaps ENOTSUP to
 * Linux EOPNOTSUPP (95), while Darwin ENOTSUP is 45.  The split IO80211
 * methods return BSD/Darwin errno values, as confirmed on hardware. */
static constexpr SInt32 kRTW88DarwinENOTSUP = 45;

struct RTW88SplitTraceSnapshot {
    uint32_t words[10]; /* first 40 bytes: enough to identify apple80211req on x86_64 */
};

static void rtw88CaptureSplitTrace(const void *data, RTW88SplitTraceSnapshot *out)
{
    /* v52 safety hardening: the split IO80211 ingress does not provide a
     * payload length.  v51 copied 40 bytes unconditionally from an opaque
     * pointer purely for diagnostics.  That read can cross the actual object
     * boundary and is never required for request handling.  Keep the trace
     * structure zeroed instead of speculatively touching unknown memory. */
    (void)data;
    bzero(out, sizeof(*out));
}

static void rtw88PublishSplitTrace(RTL88WiFi *self,
                                   const RTW88SplitTraceSnapshot &snap,
                                   uint32_t path, SInt32 superRet)
{
    if (!self)
        return;

    /* Keep four unsupported calls rather than only the last one.  v16 proved
     * that this entry point is real, but not that every call here is ASSOCIATE.
     * These diagnostics are deliberately observation-only: no dispatch and no
     * mutation of the request payload. */
    static volatile UInt32 traceSequence = 0;
    const UInt32 seq = __atomic_add_fetch(&traceSequence, 1U, __ATOMIC_RELAXED);
    const UInt32 slot = (seq - 1U) & 3U;

    char key[64];
#define RTW88_TRACE_U32(suffix, value) do { \
        snprintf(key, sizeof(key), "STA_V17_TRACE%u_%s", slot, suffix); \
        self->setProperty(key, (uint64_t)(uint32_t)(value), 32); \
    } while (0)

    RTW88_TRACE_U32("SEQ", seq);
    RTW88_TRACE_U32("PATH", path); /* 1=iface+vif+skywalk, 2=skywalk-only */
    RTW88_TRACE_U32("SUPER_RET", superRet);

    /* apple80211req candidate fields if this really is the BSD wrapper. */
    RTW88_TRACE_U32("REQ_TYPE", snap.words[4]); /* offset 16 */
    RTW88_TRACE_U32("REQ_VAL",  snap.words[5]); /* offset 20 */
    RTW88_TRACE_U32("REQ_LEN",  snap.words[6]); /* offset 24 */

    /* Direct apple80211_assoc_data candidate fields.  RAW0..3 map to:
     * version; mode/auth-lower; auth-upper(+pad); ssid_len when direct. */
    RTW88_TRACE_U32("RAW0", snap.words[0]);
    RTW88_TRACE_U32("RAW1", snap.words[1]);
    RTW88_TRACE_U32("RAW2", snap.words[2]);
    RTW88_TRACE_U32("RAW3", snap.words[3]);
    RTW88_TRACE_U32("RAW7", snap.words[7]);
    RTW88_TRACE_U32("RAW8", snap.words[8]);
    RTW88_TRACE_U32("RAW9", snap.words[9]);
#undef RTW88_TRACE_U32
}

static bool rtw88AssocPayloadLooksValid(const apple80211_assoc_data *d)
{
    if (!d || d->version != APPLE80211_VERSION)
        return false;
    if (d->ad_mode != APPLE80211_AP_MODE_UNKNOWN &&
        d->ad_mode != APPLE80211_AP_MODE_INFRA &&
        d->ad_mode != APPLE80211_AP_MODE_ANY)
        return false;
    if (!d->ad_ssid_len || d->ad_ssid_len > APPLE80211_MAX_SSID_LEN)
        return false;

    bool nonzero = false;
    for (uint32_t i = 0; i < d->ad_ssid_len; ++i) {
        if (d->ad_ssid[i] != 0) nonzero = true;
        /* SSIDs are arbitrary bytes, but reject embedded NUL here because the
         * current backend join API is NUL-terminated and handleASSOCIATE does
         * the same validation. */
        if (d->ad_ssid[i] == 0) return false;
    }
    if (!nonzero) return false;

    const uint32_t personal = APPLE80211_AUTHTYPE_WPA_PSK |
                              APPLE80211_AUTHTYPE_WPA2_PSK |
                              APPLE80211_AUTHTYPE_SHA256_PSK;
    constexpr uint32_t sae = 0x00000200U;
    const bool hasWpa2 = (d->ad_auth_upper & APPLE80211_AUTHTYPE_WPA2_PSK) != 0;
    const bool knownUpper = (d->ad_auth_upper & ~(personal | sae)) == 0;
    const bool secure = (d->ad_auth_upper & personal) != 0 && knownUpper &&
                        (!(d->ad_auth_upper & sae) || hasWpa2);
    if (d->ad_auth_lower != APPLE80211_AUTHTYPE_OPEN)
        return false;
    if (d->ad_auth_upper != APPLE80211_AUTHTYPE_NONE && !secure)
        return false;
    if (secure && d->ad_key.key_len != 32)
        return false;
    if (!secure && d->ad_key.key_len != 0)
        return false;

    if (secure && d->ad_rsn_ie[0] != 0) {
        if (d->ad_rsn_ie[0] != 48)
            return false;
        const uint16_t n = (uint16_t)d->ad_rsn_ie[1] + 2U;
        if (n < 2 || n > APPLE80211_MAX_RSN_IE_LEN)
            return false;
    }
    return true;
}

static bool rtw88TryAssocFromSplitWrapper(RTL88WiFi *self,
                                           IO80211Interface *interface,
                                           void *data,
                                           SInt32 *result)
{
    if (!self || !data || !result)
        return false;

    auto *req = static_cast<apple80211req *>(data);
    if (req->req_type != APPLE80211_IOC_ASSOCIATE ||
        req->req_len < sizeof(apple80211_assoc_data) ||
        req->req_len > 64U * 1024U || !req->req_data)
        return false;

    apple80211_assoc_data assoc = {};
    const int ce = copyin((user_addr_t)req->req_data, &assoc, sizeof(assoc));
    if (ce != 0 || !rtw88AssocPayloadLooksValid(&assoc)) {
        self->setProperty("STA_SPLIT_ASSOC_WRAPPER_COPYIN_ERR", (uint64_t)(uint32_t)ce, 32);
        return false;
    }

    self->setProperty("STA_SPLIT_ASSOC_WRAPPER", kOSBooleanTrue);
    self->setProperty("STA_SPLIT_ASSOC_LEN", (uint64_t)req->req_len, 32);
    *result = self->apple80211Request(SIOCSA80211, APPLE80211_IOC_ASSOCIATE,
                                      interface, &assoc);
    self->setProperty("STA_SPLIT_ASSOC_FALLBACK_RET", (uint64_t)(uint32_t)*result, 32);
    bzero(&assoc, sizeof(assoc));
    return true;
}
}

SInt32 RTL88WiFi::apple80211_ioctl_set(IO80211Interface *interface,
                                           IO80211VirtualInterface *virtualInterface,
                                           IO80211SkywalkInterface *skywalkInterface,
                                           void *data)
{
    setProperty("STA_SPLIT_ASSOC_INGRESS", kOSBooleanTrue);
    RTW88SplitTraceSnapshot splitPre = {};
    rtw88CaptureSplitTrace(data, &splitPre);
    const UInt32 before = __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED);

    /* v19's hardware trace finally identified the opaque split SET exactly:
     * req_if_name="en0", req_type=APPLE80211_IOC_POWERSAVE (5),
     * req_val=APPLE80211_POWERSAVE_MODE_MAX_THROUGHPUT (7), req_len=0.
     * This is a real zero-payload Apple80211 request, not ASSOCIATE.  Handle
     * POWERSAVE by selector/value instead of blanket-ACKing an unknown SET. */
    if (data && interface && interface == _netif && !virtualInterface) {
        auto *req = static_cast<apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_POWERSAVE && req->req_len == 0) {
            if (req->req_val >= APPLE80211_POWERSAVE_MODE_DISABLED &&
                req->req_val <= APPLE80211_POWERSAVE_MODE_MAX_POWERSAVE) {
                _powerSaveLevel = (UInt32)req->req_val;
                static volatile UInt32 powerSaveSetCount = 0;
                const UInt32 n = __atomic_add_fetch(&powerSaveSetCount, 1U, __ATOMIC_RELAXED);
                setProperty("STA_V20_POWERSAVE_SET", kOSBooleanTrue);
                setProperty("STA_V20_POWERSAVE_VALUE", (uint64_t)_powerSaveLevel, 32);
                setProperty("STA_V20_POWERSAVE_SET_COUNT", (uint64_t)n, 32);
                IOLog("RTL88WiFi: v20 split POWERSAVE SET value=%u accepted (count=%u)\n",
                      (unsigned)_powerSaveLevel, (unsigned)n);
                return 0;
            }
        }
    }

    /* Some hosts send the 900/908-byte host32 ASSOCIATE envelope through the
     * split SET hook instead of apple80211_ioctl(). Normalize it here too,
     * before IO80211FamilyLegacy can reinterpret its 32-bit auth fields as
     * the Ventura 16-bit structure. */
    if (data && interface && interface == _netif && !virtualInterface) {
        auto *req = static_cast<apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_ASSOCIATE &&
            RTW88AssocWire::supportedRequestSize(req->req_len)) {
            SInt32 ret = 0;
            if (rtw88TryHostAssociation(this, interface, req, &ret))
                return ret;
        }
    }

    /* PRIVATE_MAC is a small documented payload, but some split SET paths
     * are rejected by the family before the controller selector is called.
     * Route only this selector for the primary interface, with exact length
     * checking and copyin, through the same native handler as the BSD bridge. */
    if (data && interface && interface == _netif && !virtualInterface) {
        auto *req = static_cast<apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_PRIVATE_MAC)
            return handlePrivateMACBSDRequest(SIOCSA80211, req, "legacy-split-set");
    }

    /* Let the restored Ventura family do the normal translation first.  This
     * preserves every working scan/Instant-Hotspot/discovery behavior from v15. */
    SInt32 sr = super::apple80211_ioctl_set(interface, virtualInterface,
                                            skywalkInterface, data);
    setProperty("STA_SPLIT_ASSOC_SUPER_RET", (uint64_t)(uint32_t)sr, 32);
    if (sr == kRTW88DarwinENOTSUP)
        rtw88PublishSplitTrace(this, splitPre, 1U, sr);

    const UInt32 after = __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED);
    if (after != before) {
        setProperty("STA_SPLIT_ASSOC_NATIVE_DISPATCH", kOSBooleanTrue);
        return sr;
    }

    /* Some restored-family builds hand the already-decoded Ventura ASSOCIATE
     * payload to this split hook.  Recognize it narrowly; never guess scan or
     * unrelated SET payloads. */
    if (rtw88AssocPayloadLooksValid(static_cast<apple80211_assoc_data *>(data))) {
        setProperty("STA_SPLIT_ASSOC_DIRECT", kOSBooleanTrue);
        SInt32 r = apple80211Request(SIOCSA80211, APPLE80211_IOC_ASSOCIATE,
                                     interface ? interface : _netif, data);
        setProperty("STA_SPLIT_ASSOC_FALLBACK_RET", (uint64_t)(uint32_t)r, 32);
        return r;
    }

    /* Other Ventura Legacy builds keep an apple80211req wrapper here. */
    SInt32 fallback = kIOReturnUnsupported;
    if (rtw88TryAssocFromSplitWrapper(this, interface ? interface : _netif,
                                      data, &fallback))
        return fallback;

    setProperty("STA_SPLIT_ASSOC_UNDECODED", kOSBooleanTrue);

    /* v20 no longer blanket-ACKs arbitrary ENOTSUP SETs.  The one observed on
     * hardware was decoded as POWERSAVE and is handled above.  If another
     * unsupported request appears, preserve the trace and return it unchanged
     * so the next blocker is visible instead of silently masking it. */
    if (sr == kRTW88DarwinENOTSUP && interface && interface == _netif && !virtualInterface) {
        setProperty("STA_V20_NEXT_ENOTSUP_VISIBLE", kOSBooleanTrue);
    }
    return sr;
}

SInt32 RTL88WiFi::apple80211_ioctl_set(IO80211SkywalkInterface *skywalkInterface,
                                           void *data)
{
    setProperty("STA_SPLIT_ASSOC_SKYWALK_INGRESS", kOSBooleanTrue);
    if (data && skywalkInterface &&
        skywalkInterface == getPrimarySkywalkInterface()) {
        auto *req = static_cast<struct apple80211req *>(data);
        if (req->req_type == APPLE80211_IOC_PRIVATE_MAC)
            return handlePrivateMACBSDRequest(SIOCSA80211, req, "skywalk-split-set");
    }
    RTW88SplitTraceSnapshot splitPre = {};
    rtw88CaptureSplitTrace(data, &splitPre);
    const UInt32 before = __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED);
    SInt32 sr = super::apple80211_ioctl_set(skywalkInterface, data);
    setProperty("STA_SPLIT_ASSOC_SKYWALK_SUPER_RET", (uint64_t)(uint32_t)sr, 32);
    if (sr == kRTW88DarwinENOTSUP)
        rtw88PublishSplitTrace(this, splitPre, 2U, sr);
    const UInt32 after = __atomic_load_n(&_nativeAssocDispatchCount, __ATOMIC_RELAXED);
    if (after != before) {
        setProperty("STA_SPLIT_ASSOC_NATIVE_DISPATCH", kOSBooleanTrue);
        return sr;
    }

    if (rtw88AssocPayloadLooksValid(static_cast<apple80211_assoc_data *>(data))) {
        setProperty("STA_SPLIT_ASSOC_DIRECT", kOSBooleanTrue);
        SInt32 r = apple80211Request(SIOCSA80211, APPLE80211_IOC_ASSOCIATE,
                                     _netif, data);
        setProperty("STA_SPLIT_ASSOC_FALLBACK_RET", (uint64_t)(uint32_t)r, 32);
        return r;
    }

    SInt32 fallback = kIOReturnUnsupported;
    if (rtw88TryAssocFromSplitWrapper(this, _netif, data, &fallback))
        return fallback;

    setProperty("STA_SPLIT_ASSOC_UNDECODED", kOSBooleanTrue);
    return sr;
}
#endif

/* Native IO80211 request payloads; compared against the reference IO80211 driver
 * Ventura's apple80211Request dispatcher.  The BSD wrapper above is only a
 * transport fallback when the restored family does not dispatch a request. */
SInt32 RTL88WiFi::apple80211Request(unsigned int request_type,
                                        int request_number,
                                        IO80211Interface *interface,
                                        void *data)
{
    setProperty("NATIVE_REQUEST_SEEN", kOSBooleanTrue);
    setProperty("NATIVE_REQUEST_TYPE", (uint64_t)request_type, 64);
    setProperty("NATIVE_REQUEST_SELECTOR", (uint64_t)(uint32_t)request_number, 32);
    if (request_number == APPLE80211_IOC_ASSOCIATE) {
        setProperty("NATIVE_ASSOCIATE_SEEN", kOSBooleanTrue);
        __atomic_add_fetch(&_nativeAssocDispatchCount, 1U, __ATOMIC_RELAXED);
    }
    kprintf("RTL88WiFi: apple80211Request type=0x%x selector=%d data=%p\n",
            request_type, request_number, data);

    if (!_ieee80211) return kIOReturnNotReady;
    if (request_type != SIOCGA80211 && request_type != SIOCSA80211)
        return kIOReturnBadArgument;
    bool isSet = (request_type == SIOCSA80211);
    if (!data && request_number != APPLE80211_IOC_DISASSOCIATE)
        return kIOReturnBadArgument;

    /* macOS 15/26's restored IO80211 path can deliver the newer 32-bit
     * ASSOCIATE wire prefix directly to apple80211Request().  The Ventura
     * apple80211_assoc_data in this SDK uses 16-bit mode/auth fields, so
     * interpreting that newer payload as the Ventura struct produces the
     * exact misleading signature seen on hardware (lower=0, upper=1,
     * ssid_len=0) for an otherwise ordinary open request.  Normalize only
     * when the complete, strict 32-bit prefix signature validates.  This
     * branch is only entered for the ASSOCIATE selector, whose payload is
     * defined by the host as an association request; the decoder reads only
     * its fixed 108-byte common prefix and never interprets the unknown tail.
     * Older Ventura payloads do not pass this decoder and keep the existing
     * native path unchanged. */
    if (isSet && request_number == APPLE80211_IOC_ASSOCIATE && data) {
        RTW88AssocWire::Personal fields = {};
        const bool host32 = RTW88AssocWire::decode(
            static_cast<const uint8_t *>(data), RTW88AssocWire::PrefixSize, fields);
        if (host32) {
            apple80211_assoc_data normalized = {};
            normalized.version = APPLE80211_VERSION;
            normalized.ad_mode = (uint16_t)fields.mode;
            normalized.ad_auth_lower = (uint16_t)fields.lower;
            normalized.ad_auth_upper = (uint16_t)fields.upper;
            normalized.ad_ssid_len = fields.ssidLength;
            memcpy(normalized.ad_ssid, fields.ssid, fields.ssidLength);
            memcpy(normalized.ad_bssid.octet, fields.bssid, sizeof(fields.bssid));
            normalized.ad_key.version = APPLE80211_VERSION;
            normalized.ad_key.key_len = fields.keyLength;
            normalized.ad_key.key_cipher_type = fields.cipher;
            if (fields.keyLength)
                memcpy(normalized.ad_key.key, fields.key, fields.keyLength);

            setProperty("STA_ASSOC_HOST32_TRANSLATED", kOSBooleanTrue);
            setProperty("STA_ASSOC_HOST32_SSID_LEN", (uint64_t)fields.ssidLength, 32);
            setProperty("STA_ASSOC_HOST32_AUTH_UPPER", (uint64_t)fields.upper, 32);
            IOLog("RTL88WiFi: normalized host 32-bit ASSOCIATE payload mode=%u lower=%u upper=0x%x ssidLen=%u keyLen=%u\n",
                  (unsigned)fields.mode, (unsigned)fields.lower,
                  (unsigned)fields.upper, (unsigned)fields.ssidLength,
                  (unsigned)fields.keyLength);

            const SInt32 normalizedRet = handleASSOCIATE(&normalized);
            setProperty("STA_ASSOC_HOST32_RET", (uint64_t)(uint32_t)normalizedRet, 32);
            setProperty("STA_ASSOC_NATIVE_RET", (uint64_t)(uint32_t)normalizedRet, 32);
            RTW88AssocWire::wipe(&normalized, sizeof(normalized));
            RTW88AssocWire::wipe(&fields, sizeof(fields));
            return normalizedRet;
        }
        RTW88AssocWire::wipe(&fields, sizeof(fields));
    }

    /* GET polling and background scan requests arrive several times per
     * second; keep them out of the bounded diagnostic ring (kprintf above
     * still records every request). */
    if (isSet && request_number != APPLE80211_IOC_SCAN_REQ &&
        request_number != APPLE80211_IOC_SCAN_REQ_MULTIPLE)
        IOLog("RTL88WiFi: IOCTL SET selector=%d\n", request_number);

    // COUNTRY_CODE_CHANGED synchronously requests COUNTRY_CODE again.
    // Keep both invocations outside the large general-purpose switch frame.
    if (request_number == APPLE80211_IOC_COUNTRY_CODE)
        return handleRequestCOUNTRY_CODE(isSet, data);
    const SInt32 ret = handleNativeRequest(request_type, request_number, interface, data);
    if (request_number == APPLE80211_IOC_ASSOCIATE)
        setProperty("STA_ASSOC_NATIVE_RET", (uint64_t)(uint32_t)ret, 32);
    if (!isSet)
        logGetResult(request_number, ret, data);
    return ret;
}

/* r7: the GETs airportd uses to judge the current link are logged to the
 * diagnostic ring only when their result or value changes, so join/leave
 * transitions become visible without the polling noise removed in r3. */
void RTL88WiFi::logGetResult(int request_number, SInt32 ret, const void *data)
{
    int slot;
    switch (request_number) {
    case APPLE80211_IOC_SSID:            slot = 0; break;
    case APPLE80211_IOC_CHANNEL:         slot = 1; break;
    case APPLE80211_IOC_BSSID:           slot = 2; break;
    case APPLE80211_IOC_STATE:           slot = 3; break;
    case APPLE80211_IOC_CURRENT_NETWORK: slot = 4; break;
    default: return;
    }
    uint32_t a = 0, b = 0;
    if (ret == kIOReturnSuccess && data) {
        switch (slot) {
        case 0: {
            const auto *d = (const struct apple80211_ssid_data *)data;
            a = d->ssid_len;
            break;
        }
        case 1: {
            const auto *d = (const struct apple80211_channel_data *)data;
            a = d->channel.channel; b = d->channel.flags;
            break;
        }
        case 2: {
            const auto *d = (const struct apple80211_bssid_data *)data;
            a = d->bssid.octet[3]; b = ((uint32_t)d->bssid.octet[4] << 8) | d->bssid.octet[5];
            break;
        }
        case 3: {
            const auto *d = (const struct apple80211_state_data *)data;
            a = d->state;
            break;
        }
        case 4: {
            const auto *d = (const struct apple80211_scan_result *)data;
            a = d->asr_channel.channel; b = d->asr_ssid_len;
            break;
        }
        }
    }
    const uint64_t sig = ((uint64_t)(uint32_t)ret << 32) ^ ((uint64_t)a << 16) ^ b;
    if (_getDiagLast[slot] == sig) return;
    _getDiagLast[slot] = sig;
    IOLog("RTL88WiFi: GET selector=%d ret=0x%x a=%u b=0x%x state=%d visible=%d\n",
          request_number, (unsigned)ret, a, b,
          _ieee80211 ? (int)_ieee80211->rawState() : -1,
          _ieee80211 ? (int)_ieee80211->associatedVisible() : -1);
}

__attribute__((__noinline__)) SInt32 RTL88WiFi::handleNativeRequest(
    unsigned int request_type, int request_number, IO80211Interface *interface, void *data)
{
    const bool isSet = request_type == SIOCSA80211;
    switch (request_number) {
    case APPLE80211_IOC_SSID:
        return handleSSID(isSet, (struct apple80211_ssid_data *)data);

    case APPLE80211_IOC_AUTH_TYPE:
        return handleAUTH_TYPE(isSet, (struct apple80211_authtype_data *)data);

    case APPLE80211_IOC_ASSOCIATE:
        return isSet ? handleASSOCIATE((struct apple80211_assoc_data *)data) : kIOReturnUnsupported;

    case APPLE80211_IOC_RSN_IE:
        return handleRSN_IE(isSet, (struct apple80211_rsn_ie_data *)data);

    case APPLE80211_IOC_AP_IE_LIST:
        return isSet ? kIOReturnUnsupported : handleAP_IE_LIST((struct apple80211_ap_ie_data *)data);

    case APPLE80211_IOC_CIPHER_KEY:
        return isSet ? handleCIPHER_KEY((struct apple80211_key *)data) : kIOReturnUnsupported;

    case APPLE80211_IOC_SCAN_REQ:
        if (!isSet) return kIOReturnUnsupported;
        return handleSCAN_REQ(data);

    case APPLE80211_IOC_SCAN_REQ_MULTIPLE:
        if (!isSet) return kIOReturnUnsupported;
        if (!data) return kIOReturnBadArgument;
        {
            auto *d = static_cast<apple80211_scan_multiple_data *>(data);
            if (d->num_channels > 128) return kIOReturnBadArgument;
            if (_scanInProgress) {
                IOLog("RTL88WiFi: SCAN_REQ_MULTIPLE coalesced with active scan\n");
                return kIOReturnSuccess;
            }

            uint16_t requested[128] = {};
            for (uint32_t i = 0; i < d->num_channels; ++i) {
                if (d->channels[i].channel > 255) return kIOReturnBadArgument;
                requested[i] = (uint16_t)d->channels[i].channel;
            }

            RTW88StateResult st = {};
            const bool connected =
                _ieee80211->cmdGetState(&st) == kIOReturnSuccess &&
                st.state == RTW88_STATE_CONNECTED;
            _scanInProgress = true;
            _scanCursor = 0;
            IOReturn ret = _ieee80211->cmdScan(requested, d->num_channels);
            if (ret == kIOReturnNotReady && connected) {
                /* No alternate channel was known/requested.  Preserve the old
                 * cache-only completion rather than disrupting a live link. */
                _scanInProgress = false;
                UInt32 result = 0;
                kprintf("RTL88WiFi: SCAN_REQ_MULTIPLE connected cache-only completion (no candidate channels)\n");
                _netif->postMessage(APPLE80211_M_SCAN_DONE, &result, sizeof(result));
                return kIOReturnSuccess;
            }
            if (ret) _scanInProgress = false;
            return ret;
        }

    case APPLE80211_IOC_SCANCACHE_CLEAR:
        /* Do not destroy the backend BSS tree while a scan may still be using
         * it.  Reset only the Apple-side enumeration cursor; the next hardware
         * scan refreshes/deduplicates entries by BSSID.  Sonoma's CoreWiFi may
         * use this as the only indication that it wants a fresh family cache,
         * so allow one new demand-driven bootstrap scan after a clear. */
        if (!isSet) return kIOReturnUnsupported;
        _scanCursor = 0;
        _scanCacheBootstrapAttempted = false;
        return kIOReturnSuccess;

    case APPLE80211_IOC_SCAN_RESULT:
        return isSet ? kIOReturnUnsupported : handleSCAN_RESULT((struct apple80211_scan_result **)data);

    case APPLE80211_IOC_RSSI: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        if (st.state != RTW88_STATE_CONNECTED) return 6;
        auto *d = static_cast<apple80211_rssi_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        d->num_radios = 1; d->rssi_unit = APPLE80211_UNIT_DBM;
        d->rssi[0] = d->aggregate_rssi = st.rssi;
        d->rssi_ext[0] = d->aggregate_rssi_ext = st.rssi;
        // Signed textual RSSI avoids decoding an unsigned IORegistry number.
        // These are observations, not an invented PHY speed or MCS value.
        char signal[16];
        snprintf(signal, sizeof(signal), "%d dBm", st.rssi);
        setProperty("RADIO_RSSI", signal);
        setProperty("RADIO_CHANNEL", (uint64_t)st.channel, 32);
        setProperty("RADIO_WIDTH_MHZ", (uint64_t)_ieee80211->channelWidthMHz(), 32);
        setProperty("RADIO_HW_NSS", (uint64_t)_ieee80211->txNSS(), 32);
        setProperty("RADIO_TX_AGGREGATION", _ieee80211->txAggregationActive() ? kOSBooleanTrue : kOSBooleanFalse);
        RTW88BSS currentBSS = {};
        if (_ieee80211->copyCurrentBSS(&currentBSS) == kIOReturnSuccess) {
            setProperty("RADIO_PAIRWISE_CIPHER", (uint64_t)currentBSS.cipher, 32);
            setProperty("RADIO_GROUP_CIPHER", (uint64_t)currentBSS.group_cipher, 32);
        }
        setProperty("RADIO_RX_FRAMES", (uint64_t)_ieee80211->receivedFrameCount(), 32);
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_DISASSOCIATE:
        return isSet ? handleDISASSOCIATE() : kIOReturnUnsupported;
    case APPLE80211_IOC_OP_MODE: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_opmode_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->op_mode = APPLE80211_M_STA;
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_PHY_MODE:
        return handleRequestPHY_MODE(isSet, data);
    case APPLE80211_IOC_CARD_CAPABILITIES: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_capability_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;

        /* Follow the reference IO80211 driver's Ventura capability layout.
         * Keep the low feature bits truthful for rtw88, then use the exact
         * opaque high-byte pattern the reference IO80211 driver currently exposes. Do not
         * invent extra AWDL bits: IO80211 probes the virtual-interface path
         * separately. */
        const unsigned caps[] = {
            APPLE80211_CAP_TKIP, APPLE80211_CAP_AES_CCM,
            APPLE80211_CAP_WPA2, APPLE80211_CAP_TKIPMIC,
            APPLE80211_CAP_SHSLOT, APPLE80211_CAP_SHPREAMBLE
        };
        for (unsigned cap : caps)
            d->capabilities[cap / 8] |= 1U << (cap % 8);

        /* The reference IO80211 driver (Ventura legacy IO80211 path) publishes these
         * high bytes. Keep them byte-for-byte aligned with the reference; the
         * previous 1.0.1 draft had drifted to a different experimental mask. */
        d->capabilities[2] = 0xFF;
        d->capabilities[3] = 0x2B;
        d->capabilities[4] = 0xAD;
        d->capabilities[5] = 0x8C;
        d->capabilities[6] = 0x8C;
        d->capabilities[7] = 0x84;
        static bool capsLogged = false;
        if (!capsLogged) {
            capsLogged = true;
            IOLog("RTL88WiFi: CARD_CAPABILITIES AirportItlwm v2.2.0 profile advertised\n");
        }
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_RATE:
        return handleRequestRATE(isSet, data);

    case APPLE80211_IOC_RATE_SET:
        return handleRequestRATE_SET(isSet, data);

    case APPLE80211_IOC_MCS_INDEX_SET: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return 6;
        auto *d = static_cast<apple80211_mcs_index_set_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        const uint8_t nss = _ieee80211->txNSS();
        /* Advertise the standard HT MCS 0-7 block for each active spatial
         * stream; this mirrors the hardware NSS instead of inventing rates. */
        for (uint8_t mcs = 0; mcs < (uint8_t)(8U * nss) && mcs <= APPLE80211_MAX_MCS_INDEX; ++mcs)
            d->mcs_set_map[mcs / 8U] |= (uint8_t)(1U << (mcs % 8U));
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_VHT_MCS_INDEX_SET: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return kIOReturnError;
        auto *d = static_cast<RTW88VHTMCSIndexSetData *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        const uint8_t nss = _ieee80211->txNSS();
        /* IEEE VHT MCS map: 2 bits/stream, value 2 = MCS 0-9, 3 = not
         * supported.  rtw88 chips handled by this port are VHT capable. */
        uint16_t map = 0xffffU;
        for (uint8_t i = 0; i < nss && i < 8; ++i) {
            map &= (uint16_t)~(0x3U << (i * 2U));
            map |= (uint16_t)(0x2U << (i * 2U));
        }
        d->mcs_map = map;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_MCS_VHT: {
        if (!data) return kIOReturnBadArgument;
        if (isSet) return kIOReturnError;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return kIOReturnError;
        /* Live TX rate from the firmware RA report; unknown until the first
         * report, and not applicable while the firmware sends HT/legacy. */
        struct rtw88_tx_rate tx;
        if (!rtw88_get_tx_rate(&tx)) return kIOReturnNotReady;
        if (!tx.vht) return kIOReturnUnsupported;
        auto *d = static_cast<RTW88MCSVHTData *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->index = tx.mcs;
        d->nss = tx.nss;
        d->bw = tx.bw_mhz;
        d->guard_interval = tx.sgi ? APPLE80211_GI_SHORT : APPLE80211_GI_LONG;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_TX_ANTENNA:
    case APPLE80211_IOC_ANTENNA_DIVERSITY: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_antenna_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->num_radios = 1;
        d->antenna_index[0] = 1;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_MCS: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return 6;
        /* HT MCS 0-31 or VHT MCS 0-9 of the live TX rate; legacy rates and
         * a missing RA report have no MCS to report. */
        struct rtw88_tx_rate tx;
        if (!rtw88_get_tx_rate(&tx) || !(tx.ht || tx.vht)) return kIOReturnNotReady;
        auto *d = static_cast<apple80211_mcs_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->index = tx.mcs;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_ROAM_THRESH: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_roam_threshold_data *>(data);
        bzero(d, sizeof(*d));
        d->threshold = 100;
        d->count = 0;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_LINK_CHANGED_EVENT_DATA: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_link_changed_event_data *>(data);
        bzero(d, sizeof(*d));
        RTW88StateResult st = {};
        const IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret != kIOReturnSuccess) return ret;
        d->isLinkDown = st.state != RTW88_STATE_CONNECTED;
        if (d->isLinkDown) {
            d->voluntary = false;
            d->reason = APPLE80211_LINK_DOWN_REASON_DEAUTH;
        } else {
            d->rssi = (uint32_t)st.rssi;
            int nf = 0, snr = 0;
            rtw88LinkNoise(st.rssi, _ieee80211->channelWidthMHz(), &nf, &snr);
            d->nf = (uint16_t)(int16_t)nf;
            d->snr = (uint16_t)snr;
        }
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_TX_NSS: {
        auto *d = static_cast<apple80211_tx_nss_data *>(data);
        if (isSet) return kIOReturnError;
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->nss = _ieee80211->txNSS();
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_NSS: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_nss_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->nss = _ieee80211->txNSS();
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_ROAM:
        /* The reference IO80211 driver recognizes the selector but declines the roam
         * command.  Returning an explicit error is better than an unknown
         * selector because CoreWiFi now knows the controller understood it. */
        return isSet ? kIOReturnError : kIOReturnUnsupported;

    case APPLE80211_IOC_WOW_PARAMETERS:
        return kIOReturnError;

    case APPLE80211_IOC_IE:
        /* Reserved for frame-IE injection.  Keep selector parity with the
         * Ventura reference without pretending that rtw88 has implemented it. */
        return kIOReturnError;

    case APPLE80211_IOC_BSSID: {
        if (isSet) return kIOReturnSuccess;
        RTW88StateResult st = {}; IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        // The reference IO80211 driver returns BSD ENXIO (6) until associated. Success with
        // an empty BSSID can make airportd treat an idle interface as joined.
        if (st.state != RTW88_STATE_CONNECTED) return 6;
        auto *d = static_cast<apple80211_bssid_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        memcpy(d->bssid.octet, st.bssid, 6);
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_DEAUTH: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_deauth_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        d->deauth_reason = _ieee80211->deauthReason();
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_ASSOCIATION_STATUS: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {}; IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        auto *d = static_cast<apple80211_assoc_status_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        // Query success is distinct from successful association (the reference IO80211 driver).
        d->status = st.state == RTW88_STATE_CONNECTED ?
            APPLE80211_STATUS_SUCCESS : APPLE80211_STATUS_UNAVAILABLE;
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_ASSOCIATE_RESULT: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {}; IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        if (st.state != RTW88_STATE_CONNECTED) return kIOReturnNotReady;
        auto *d = static_cast<apple80211_assoc_result_data *>(data);
        d->version = APPLE80211_VERSION; d->result = APPLE80211_RESULT_SUCCESS;
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_CHANNELS_INFO:
        return handleRequestCHANNELS_INFO(isSet, data);
    case APPLE80211_IOC_ROAM_PROFILE: {
        if (!data) return kIOReturnBadArgument;
        auto *d = static_cast<RTW88RoamProfileBandData *>(data);
        if (isSet) {
            memcpy(&_roamProfile, d, sizeof(_roamProfile));
            _roamProfileValid = true;
            setProperty("STA_ROAM_PROFILE_SET", kOSBooleanTrue);
            return kIOReturnSuccess;
        }
        if (!_roamProfileValid)
            return kIOReturnError;
        memcpy(d, &_roamProfile, sizeof(_roamProfile));
        setProperty("STA_ROAM_PROFILE_GET", kOSBooleanTrue);
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_SUPPORTED_CHANNELS:
    case APPLE80211_IOC_HW_SUPPORTED_CHANNELS:
        return handleRequestHW_SUPPORTED_CHANNELS(isSet, data);
    case APPLE80211_IOC_DRIVER_VERSION:
    case APPLE80211_IOC_HARDWARE_VERSION: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_version_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        const char *chip = rtw88AirportChipName(_compatPciDev);
        if (request_number == APPLE80211_IOC_DRIVER_VERSION) {
            char label[sizeof(d->string)] = {};
            strlcpy(label, chip, sizeof(label));
            strlcat(label, " (RTL88WiFi 1.0.11)", sizeof(label));
            d->string_len = (uint16_t)strlcpy(d->string, label, sizeof(d->string));
        } else {
            d->string_len = (uint16_t)strlcpy(d->string, chip, sizeof(d->string));
        }
        return kIOReturnSuccess;
    }

    /* System Information queries AirDrop capability/channel from the primary
     * controller, not only through awdl0's virtual IOCTL path.  Returning
     * unsupported (or channel 0) makes the UI omit the "AirDrop Channel"
     * field even though awdl0 exists.  Mirror the manager's effective social
     * channel here, while keeping SET ownership with IO80211's virtual path. */
    case APPLE80211_IOC_AWDL_MASTER_CHANNEL: {
        if (isSet || !data || !_awdlManager) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_awdl_master_channel *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->master_channel = _awdlManager->reportedChannel();
        return d->master_channel ? kIOReturnSuccess : kIOReturnNotReady;
    }
    case APPLE80211_IOC_AWDL_SECONDARY_MASTER_CHANNEL: {
        if (isSet || !data || !_awdlManager) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_awdl_secondary_master_channel *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->secondary_master_channel = _awdlManager->secondaryMasterChannel();
        return kIOReturnSuccess;
    }
    case APPLE80211_IOC_AWDL_SYNC_ENABLED: {
        if (isSet || !data || !_awdlManager) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_awdl_sync_enabled *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->enabled = _awdlManager->syncEnabled() ? 1 : 0;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_VIRTUAL_IF_CREATE:
        return isSet ? handleVIRTUAL_IF_CREATE((struct apple80211_virt_if_create_data *)data)
                     : kIOReturnUnsupported;

    case APPLE80211_IOC_VIRTUAL_IF_DELETE:
        return isSet ? handleVIRTUAL_IF_DELETE((struct apple80211_virt_if_delete_data *)data)
                     : kIOReturnUnsupported;

    case APPLE80211_IOC_CURRENT_NETWORK:
        if (isSet) return kIOReturnUnsupported;
        kprintf("RTL88WiFi: CURRENT_NETWORK dispatcher entry\n");
        return handleCURRENT_NETWORK(static_cast<apple80211_scan_result *>(data));

    case APPLE80211_IOC_STATE:
        return isSet ? kIOReturnUnsupported : handleSTATE((struct apple80211_state_data *)data);

    case APPLE80211_IOC_CHANNEL:
        return isSet ? kIOReturnUnsupported : handleCHANNEL((struct apple80211_channel_data *)data);

    case APPLE80211_IOC_RADIO_INFO: {
        if (isSet) return kIOReturnUnsupported;
        if (!data) return kIOReturnBadArgument;
        auto *radio = static_cast<apple80211_radio_info_data *>(data);
        bzero(radio, sizeof(*radio));
        radio->version = APPLE80211_VERSION;
        radio->count = 1;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_POWER:
        return handlePOWER(isSet, (struct apple80211_power_data *)data);

    case APPLE80211_IOC_NOISE: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        if (st.state != RTW88_STATE_CONNECTED) return 6;
        int nf = 0, snr = 0;
        bool measured = false;
        rtw88LinkNoise(st.rssi, _ieee80211->channelWidthMHz(), &nf, &snr, &measured);
        /* Publish where the number comes from, but only when it changes:
         * CoreWiFi polls this selector often. */
        static int8_t sLastNoiseSource = -1;
        if (sLastNoiseSource != (int8_t)measured) {
            sLastNoiseSource = (int8_t)measured;
            setProperty("RADIO_NOISE_SOURCE", measured ? "measured" : "estimated");
        }
        auto *d = static_cast<apple80211_noise_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->num_radios = 1;
        d->noise_unit = APPLE80211_UNIT_DBM;
        d->noise[0] = d->aggregate_noise = nf;
        d->noise_ext[0] = d->aggregate_noise_ext = nf;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_INT_MIT: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_intmit_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->int_mit = APPLE80211_INT_MIT_AUTO;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_PROTMODE: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        if (st.state != RTW88_STATE_CONNECTED) return 6;
        auto *d = static_cast<apple80211_protmode_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->protmode = APPLE80211_PROTMODE_OFF;
        d->threshold = 0;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_TXPOWER: {
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        IOReturn ret = _ieee80211->cmdGetState(&st);
        if (ret) return ret;
        if (st.state != RTW88_STATE_CONNECTED) return 6;
        auto *d = static_cast<apple80211_txpower_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->txpower_unit = APPLE80211_UNIT_PERCENT;
        d->txpower = 100;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_POWERSAVE: {
        auto *d = static_cast<apple80211_powersave_data *>(data);
        if (!d) return kIOReturnBadArgument;
        if (isSet) {
            if (d->version != APPLE80211_VERSION ||
                d->powersave_level > APPLE80211_POWERSAVE_MODE_MAX_POWERSAVE)
                return kIOReturnBadArgument;
            _powerSaveLevel = d->powersave_level;
            setProperty("STA_V20_POWERSAVE_SET", kOSBooleanTrue);
            setProperty("STA_V20_POWERSAVE_VALUE", (uint64_t)_powerSaveLevel, 32);
            return kIOReturnSuccess;
        }
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->powersave_level = _powerSaveLevel;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_LOCALE: {
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_locale_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->locale = APPLE80211_LOCALE_ROW;
        return kIOReturnSuccess;
    }

    case APPLE80211_IOC_PRIVATE_MAC:
        return handleRequestPRIVATE_MAC(isSet, data);

    default:
        return kIOReturnUnsupported;
    }
}

/* Private Wi-Fi address selector 238.  On modern hosts it is explicitly
 * bridged around IO80211FamilyLegacy's unsupported selector path.  SET stores
 * Off/Fixed/Rotating mode, accepts the host-selected address or generates a
 * locally-administered one, then schedules safe programming on the controller
 * workloop.  Rotation is deferred while an association or scan is active. */
__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestPRIVATE_MAC(bool isSet, void *data)
{
    if (!data) return kIOReturnBadArgument;
    auto *d = static_cast<rtw88_private_mac_data *>(data);
    if (isSet) {
        if (d->interval_s > kRTW88PrivateMacMaxIntervalS)
            return kIOReturnBadArgument;

        const bool enabled = d->enabled != 0;
        const bool supplied = rtw88MacIsUnicast(d->mac);
        _privMacEnabled = enabled;
        _privMacFlags = d->flags;
        _privMacIntervalS = enabled ? d->interval_s : 0;
        _privMacRotatePending = false;

        if (enabled) {
            if (supplied) {
                /* Match Apple's privateMACConfig: trust an explicit non-zero
                 * host-selected unicast address; only generated addresses are
                 * locally administered by this driver. */
                memcpy(_privMacAddress, d->mac, sizeof(_privMacAddress));
            } else if (!_privMacAddressValid) {
                rtw88GeneratePrivateMAC(_privMacAddress);
            }
            _privMacAddressValid = true;
        } else {
            bzero(_privMacAddress, sizeof(_privMacAddress));
            _privMacAddressValid = false;
        }
        _privMacApplyPending = true;

        /* Apply on the controller workloop.  If a link or scan is active the
         * timer retries after teardown; it never changes the MAC mid-link. */
        if (_privateMacTimer)
            _privateMacTimer->setTimeoutMS(1);
        IOLog("RTL88WiFi: PRIVATE_MAC set mode=%s flags=0x%x interval=%us address=%s apply=pending\n",
              !enabled ? "off" : (_privMacIntervalS ? "rotating" : "fixed"),
              (unsigned)_privMacFlags, (unsigned)_privMacIntervalS,
              supplied ? "host-supplied" : (enabled ? "generated" : "factory"));
        if (enabled && _privMacIntervalS && !_privateMacTimer)
            IOLog("RTL88WiFi: PRIVATE_MAC rotating requested but timer unavailable; address remains fixed\n");
        return kIOReturnSuccess;
    }

    bzero(d, sizeof(*d));
    d->enabled    = _privMacEnabled ? 1U : 0U;
    d->flags      = _privMacFlags;
    d->interval_s = _privMacIntervalS;
    if (_privMacEnabled && _privMacAddressValid)
        memcpy(d->mac, _privMacAddress, sizeof(d->mac));
    else if (_ieee80211)
        _ieee80211->getMACAddress(d->mac);
    if (_privMacGets++ < 3)
        IOLog("RTL88WiFi: PRIVATE_MAC get mode=%s interval=%us pending=%u\n",
              !_privMacEnabled ? "off" : (_privMacIntervalS ? "rotating" : "fixed"),
              (unsigned)_privMacIntervalS, _privMacApplyPending ? 1U : 0U);
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::applyPrivateMACAddress(bool rotate)
{
    if (!_ieee80211) return kIOReturnNotReady;
    const RTW88State state = _ieee80211->rawState();
    if (state == RTW88_STATE_CONNECTED || state == RTW88_STATE_ASSOCIATING ||
        state == RTW88_STATE_AUTHENTICATING || state == RTW88_STATE_HANDSHAKING ||
        state == RTW88_STATE_DISCONNECTING || state == RTW88_STATE_SCANNING)
        return kIOReturnBusy;

    uint8_t desired[6] = {};
    if (!_privMacEnabled) {
        _ieee80211->getPermanentMACAddress(desired);
    } else if (rotate || !_privMacAddressValid) {
        rtw88GeneratePrivateMAC(desired);
    } else {
        memcpy(desired, _privMacAddress, sizeof(desired));
    }
    if (!rtw88MacIsUnicast(desired)) {
        bzero(desired, sizeof(desired));
        return kIOReturnBadArgument;
    }

    const IOReturn ret = _ieee80211->setMACAddress(desired);
    if (ret == kIOReturnSuccess) {
        memcpy(_macAddr.bytes, desired, sizeof(_macAddr.bytes));
        if (_privMacEnabled) {
            memcpy(_privMacAddress, desired, sizeof(_privMacAddress));
            _privMacAddressValid = true;
        } else {
            bzero(_privMacAddress, sizeof(_privMacAddress));
            _privMacAddressValid = false;
        }
        _privMacApplyPending = false;
        _privMacRotatePending = false;
        IOLog("RTL88WiFi: PRIVATE_MAC applied mode=%s\n",
              !_privMacEnabled ? "off" : (_privMacIntervalS ? "rotating" : "fixed"));
    }
    bzero(desired, sizeof(desired));
    return ret;
}

void RTL88WiFi::armPrivateMACTimer(UInt32 milliseconds)
{
    if (_privateMacTimer && !_shutdown && milliseconds)
        _privateMacTimer->setTimeoutMS(milliseconds);
}

void RTL88WiFi::privateMacTimerFired(OSObject *owner, IOTimerEventSource *timer)
{
    RTL88WiFi *self = OSDynamicCast(RTL88WiFi, owner);
    if (!self || !timer || self->_shutdown || !self->_ieee80211) return;

    /* A timer tick with no pending SET means the requested rotation interval
     * expired.  Do nothing for a settled Off/Fixed mode.  Defer a live-link
     * rotation and retry after disassociation. */
    if (!self->_privMacApplyPending && !self->_privMacRotatePending &&
        (!self->_privMacEnabled || self->_privMacIntervalS == 0))
        return;
    const bool rotate = self->_privMacEnabled &&
        (self->_privMacRotatePending ||
         (!self->_privMacApplyPending && self->_privMacIntervalS != 0));
    if (rotate) self->_privMacRotatePending = true;

    const IOReturn ret = self->applyPrivateMACAddress(rotate);
    if (ret == kIOReturnBusy) {
        self->armPrivateMACTimer(kRTW88PrivateMacRetryMs);
        return;
    }
    if (ret != kIOReturnSuccess) {
        IOLog("RTL88WiFi: PRIVATE_MAC apply failed ret=0x%x; retrying\n", ret);
        self->armPrivateMACTimer(kRTW88PrivateMacRetryMs);
        return;
    }

    if (self->_privMacEnabled && self->_privMacIntervalS)
        self->armPrivateMACTimer(self->_privMacIntervalS * 1000U);
}


/* IO80211FamilyLegacy re-enters the dispatcher while posting COUNTRY_CODE
 * changes. v24 reserved 0x1210 bytes on EVERY call, exhausting the kernel
 * stack on that nested path. Keep large scratch buffers in non-inlined
 * handlers so unrelated requests, including country GET/SET, stay small.
 */
__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestPHY_MODE(bool isSet, void *data)
{
        if (isSet) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_phymode_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->phy_mode = APPLE80211_MODE_11A | APPLE80211_MODE_11B |
            APPLE80211_MODE_11G | APPLE80211_MODE_11N | APPLE80211_MODE_11AC;

        /* The reference IO80211 driver reports the current negotiated PHY instead of AUTO
         * once a BSS is selected.  rtw88 already keeps the target BSS IEs, so
         * infer the same legacy/HT/VHT distinction without depending on a
         * host-version-specific Skywalk API. */
        d->active_phy_mode = APPLE80211_MODE_AUTO;
        RTW88StateResult st = {};
        RTW88BSS b = {};
        if (_ieee80211->cmdGetState(&st) == kIOReturnSuccess &&
            (st.state == RTW88_STATE_CONNECTED ||
             st.state == RTW88_STATE_HANDSHAKING ||
             st.state == RTW88_STATE_ASSOCIATING ||
             st.state == RTW88_STATE_AUTHENTICATING) &&
            _ieee80211->copyCurrentBSS(&b) == kIOReturnSuccess) {
            bool hasHT = false, hasVHT = false;
            for (uint16_t off = 0; off + 2 <= b.ies_len; ) {
                const uint8_t id = b.ies[off];
                const uint8_t ieLen = b.ies[off + 1];
                if ((uint32_t)off + 2U + ieLen > b.ies_len) break;
                if (id == WLAN_EID_VHT_CAPABILITY || id == WLAN_EID_VHT_OPERATION)
                    hasVHT = true;
                else if (id == WLAN_EID_HT_CAPABILITY || id == WLAN_EID_HT_OPERATION)
                    hasHT = true;
                off = (uint16_t)(off + 2U + ieLen);
            }
            if (hasVHT)
                d->active_phy_mode = APPLE80211_MODE_11AC;
            else if (hasHT)
                d->active_phy_mode = APPLE80211_MODE_11N;
            else if (b.channel > 14)
                d->active_phy_mode = APPLE80211_MODE_11A;
            else
                d->active_phy_mode = APPLE80211_MODE_11G;
        }
        return kIOReturnSuccess;
    }

__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestRATE(bool isSet, void *data)
{
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return 6;
        /* Current TX PHY rate in Mbit/s from the firmware RA report (not the
         * AP's advertised rates).  Unknown until the first report arrives. */
        struct rtw88_tx_rate tx;
        if (!rtw88_get_tx_rate(&tx)) return kIOReturnNotReady;
        auto *d = static_cast<apple80211_rate_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->num_radios = 1;
        d->rate[0] = tx.kbps / 1000U;
        return kIOReturnSuccess;
    }

__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestRATE_SET(bool isSet, void *data)
{
        if (isSet) return kIOReturnUnsupported;
        RTW88StateResult st = {};
        if (_ieee80211->cmdGetState(&st) != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED)
            return 6;
        RTW88BSS b = {};
        if (_ieee80211->copyCurrentBSS(&b) != kIOReturnSuccess) return 6;
        auto *d = static_cast<apple80211_rate_set_data *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        for (uint16_t pos = 0; pos + 2 <= b.ies_len && d->num_rates < APPLE80211_MAX_RATES;) {
            const uint8_t id = b.ies[pos];
            const uint8_t n = b.ies[pos + 1];
            if ((uint32_t)pos + 2U + n > b.ies_len) break;
            if (id == 1 || id == 50) {
                for (uint8_t i = 0; i < n && d->num_rates < APPLE80211_MAX_RATES; ++i) {
                    apple80211_rate &r = d->rates[d->num_rates++];
                    r.version = APPLE80211_VERSION;
                    r.rate = b.ies[pos + 2 + i] & 0x7fU;
                    r.flags = (b.ies[pos + 2 + i] & 0x80U) ? APPLE80211_RATE_FLAG_BASIC : APPLE80211_RATE_FLAG_NONE;
                }
            }
            pos = (uint16_t)(pos + 2U + n);
        }
        return kIOReturnSuccess;
    }

__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestCHANNELS_INFO(bool isSet, void *data)
{
        if (isSet || !data) return kIOReturnUnsupported;
        auto *d = static_cast<apple80211_channels_info *>(data);
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        RTW88Channel channels[APPLE80211_MAX_CHANNELS] = {};
        uint32_t count = 0;
        IOReturn ret = _ieee80211->copyChannels(channels, APPLE80211_MAX_CHANNELS, &count);
        if (ret != kIOReturnSuccess && ret != kIOReturnNoSpace) return ret;
        if (count > APPLE80211_MAX_CHANNELS) count = APPLE80211_MAX_CHANNELS;
        uint32_t n = 0;
        for (uint32_t i = 0; i < count; ++i) {
            const uint16_t ch = channels[i].number;
            if (!rtw88ChannelAllowedInCountry(_countryCode, ch)) continue;
            d->chan_num[n] = (uint8_t)ch;
            d->passive[n] = channels[i].passive ? 1 : 0;
            d->radar_dfs[n] = channels[i].radar ? 1 : 0;
            d->support_40Mhz[n] = (ch != 14) ? 1 : 0;
            d->support_80Mhz[n] = (ch > 14) ? 1 : 0;
            d->chan_spec[n] = ch;
            n++;
        }
        count = n;
        d->num_chan_specs = (uint16_t)count;
        setProperty("STA_CHANNELS_INFO_OK", kOSBooleanTrue);
        setProperty("STA_CHANNELS_INFO_COUNT", (uint64_t)count, 32);
        return kIOReturnSuccess;
    }

__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestHW_SUPPORTED_CHANNELS(bool isSet, void *data)
{
        if (isSet) return kIOReturnUnsupported;
        RTW88Channel channels[APPLE80211_MAX_CHANNELS] = {};
        uint32_t count = 0;
        IOReturn ret = _ieee80211->copyChannels(channels, APPLE80211_MAX_CHANNELS, &count);
        if (ret) return ret;
        auto *d = static_cast<apple80211_sup_channel_data *>(data);
        bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
        uint32_t n = 0;
        for (uint32_t i = 0; i < count; i++) {
            if (!rtw88ChannelAllowedInCountry(_countryCode, channels[i].number)) continue;
            d->supported_channels[n].version = APPLE80211_VERSION;
            d->supported_channels[n].channel = channels[i].number;
            d->supported_channels[n].flags = APPLE80211_C_FLAG_ACTIVE |
                APPLE80211_C_FLAG_20MHZ |
                (channels[i].number <= 14 ? APPLE80211_C_FLAG_2GHZ : APPLE80211_C_FLAG_5GHZ);
            n++;
        }
        d->num_channels = n;
        return kIOReturnSuccess;
    }

__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestCOUNTRY_CODE(bool isSet, void *data)
{
        auto *d = static_cast<apple80211_country_code_data *>(data);
        if (isSet) {
            if (d->version != APPLE80211_VERSION) return kIOReturnBadArgument;
            /* Keep Apple's special x/X requests from replacing the usable code. */
            if (d->cc[0] != 'x' && d->cc[0] != 'X') {
                memcpy(_countryCode, d->cc, sizeof(_countryCode));
                _countryCode[APPLE80211_MAX_CC_LEN - 1] = 0;
                IOLog("RTL88WiFi: active regulatory country supplied by Apple80211: %.2s\n",
                      _countryCode);
                char alpha2[2] = {(char)_countryCode[0], (char)_countryCode[1]};
                for (unsigned i = 0; i < 2; ++i) {
                    if (alpha2[i] >= 'a' && alpha2[i] <= 'z')
                        alpha2[i] = (char)(alpha2[i] - 'a' + 'A');
                }
                if (alpha2[0] >= 'A' && alpha2[0] <= 'Z' &&
                    alpha2[1] >= 'A' && alpha2[1] <= 'Z' && _ieee80211) {
                    IOReturn regRet = _ieee80211->setRegulatoryCountry(alpha2);
                    if (regRet != kIOReturnSuccess)
                        IOLog("RTL88WiFi: host country update failed ret=0x%x\n", regRet);
                }
                if (_netif) _netif->postMessage(APPLE80211_M_COUNTRY_CODE_CHANGED);
            }
            return kIOReturnSuccess;
        }
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        memcpy(d->cc, _countryCode, sizeof(d->cc));
        return kIOReturnSuccess;
    }

bool RTL88WiFi::ensureAWDLVirtualInterface()
{
    if (!_awdlManager || !_netif)
        return false;
    if (_awdlManager->awdlInterface())
        return true;

    ether_addr addr = {};
    // The controller cache is only populated by SET hardware address;
    // normal startup can leave it zero. Read the initialized backend instead.
    IOEthernetAddress physical = {};
    if (getHardwareAddress(&physical) != kIOReturnSuccess ||
        !RTW88AWDL::unicast(physical.bytes)) return false;
    memcpy(addr.octet, physical.bytes, sizeof(addr.octet));
    /* AWDL uses a distinct locally administered unicast address. Keep it
     * deterministic for this boot and distinct from en0. */
    addr.octet[0] = (uint8_t)((addr.octet[0] | 0x02u) & 0xFEu);
    addr.octet[5] ^= 0x80u;

    IO80211VirtualInterface *created = nullptr;
    IOLog("RTL88WiFi: proactively attaching AWDL VIF mac=%02x:%02x:%02x:%02x:%02x:%02x\n",
          addr.octet[0], addr.octet[1], addr.octet[2], addr.octet[3], addr.octet[4], addr.octet[5]);
    bool ok = attachVirtualInterface(&created, &addr, APPLE80211_VIF_AWDL, true);
    if (!ok || !created) {
        IOLog("RTL88WiFi: proactive attachVirtualInterface(AWDL) failed\n");
        return false;
    }
    IOLog("RTL88WiFi: proactive AWDL VIF attached bsd=%s role=%u\n",
          created->getBSDName() ? created->getBSDName() : "?",
          (unsigned)created->getInterfaceRole());

    /* Ventura can publish the BSD awdl0 object without driving the legacy
     * enableVirtualInterface callback.  In that state ifconfig shows awdl0
     * with mtu 0 / inactive and CoreWLAN still reports no usable VIF.  Drive
     * the controller's normal enable path once, explicitly, after attach.
     * This is intentionally non-fatal: STA must remain usable even if the
     * private IO80211 VIF lifecycle rejects the transition. */
    SInt32 enableRet = enableVirtualInterface(created);
    IOLog("RTL88WiFi: proactive AWDL enable result=0x%x bsd=%s\n",
          (unsigned)enableRet, created->getBSDName() ? created->getBSDName() : "?");
    if (enableRet != kIOReturnSuccess) {
        // An attached BSD object is not an enabled AWDL transport.
        _awdlManager->clearVirtualInterface(created);
        return false;
    }

    return true;
}

IOReturn RTL88WiFi::handleVIRTUAL_IF_CREATE(struct apple80211_virt_if_create_data *d)
{
    if (!d || d->version != APPLE80211_VERSION)
        return kIOReturnBadArgument;
    if (d->role < APPLE80211_VIF_P2P_DEVICE || d->role > APPLE80211_VIF_AWDL)
        return kIOReturnUnsupported;

    ether_addr addr = {};
    memcpy(addr.octet, d->mac, APPLE80211_ADDR_LEN);

    if (!_awdlManager)
        return kIOReturnNotReady;

    IO80211VirtualInterface *existing =
        d->role == APPLE80211_VIF_AWDL ? _awdlManager->awdlInterface()
                                        : _awdlManager->p2pInterface();

    if (existing) {
        const char *name = existing->getBSDName();
        bzero(d->bsd_name, sizeof(d->bsd_name));
        if (name) strlcpy((char *)d->bsd_name, name, sizeof(d->bsd_name));
        IOLog("RTL88WiFi: VIRTUAL_IF_CREATE role=%u already exists bsd=%s\n",
              d->role, name ? name : "?");
        return kIOReturnSuccess;
    }

    IOLog("RTL88WiFi: VIRTUAL_IF_CREATE role=%u mac=%02x:%02x:%02x:%02x:%02x:%02x\n",
          d->role, d->mac[0], d->mac[1], d->mac[2], d->mac[3], d->mac[4], d->mac[5]);

    /* Match the reference IO80211 driver's lifecycle: let IO80211 perform the full
     * attach/configure/name sequence. This calls createVirtualInterface(),
     * then enableVirtualInterface(), and eventually yields p2p0/awdl0. */
    IO80211VirtualInterface *created = nullptr;
    if (!attachVirtualInterface(&created, &addr, d->role, true) || !created) {
        IOLog("RTL88WiFi: attachVirtualInterface failed role=%u\n", d->role);
        return kIOReturnError;
    }
    _awdlManager->setVirtualInterface(d->role, created);

    const char *name = created->getBSDName();
    bzero(d->bsd_name, sizeof(d->bsd_name));
    if (name) strlcpy((char *)d->bsd_name, name, sizeof(d->bsd_name));

    IOLog("RTL88WiFi: VIRTUAL_IF_CREATE success role=%u bsd=%s\n",
          d->role, name ? name : "?");
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleVIRTUAL_IF_DELETE(struct apple80211_virt_if_delete_data *d)
{
    if (!d || d->version != APPLE80211_VERSION)
        return kIOReturnBadArgument;

    char requested[sizeof(d->bsd_name) + 1] = {};
    memcpy(requested, d->bsd_name, sizeof(d->bsd_name));

    IO80211VirtualInterface *target = nullptr;
    IO80211VirtualInterface *awdl = _awdlManager ? _awdlManager->awdlInterface() : nullptr;
    IO80211VirtualInterface *p2p  = _awdlManager ? _awdlManager->p2pInterface() : nullptr;
    if (awdl && awdl->getBSDName() &&
        strncmp(awdl->getBSDName(), requested, sizeof(d->bsd_name)) == 0)
        target = awdl;
    else if (p2p && p2p->getBSDName() &&
             strncmp(p2p->getBSDName(), requested, sizeof(d->bsd_name)) == 0)
        target = p2p;

    if (!target) {
        IOLog("RTL88WiFi: VIRTUAL_IF_DELETE bsd=%s not found\n", requested);
        return kIOReturnNotFound;
    }

    UInt role = (UInt)target->getInterfaceRole();
    IOLog("RTL88WiFi: VIRTUAL_IF_DELETE role=%u bsd=%s\n", role, requested);
    bool ok = detachVirtualInterface(target, true);
    if (ok) {
        if (_awdlManager) _awdlManager->clearVirtualInterface(target);
        return kIOReturnSuccess;
    }
    return kIOReturnError;
}

IOReturn RTL88WiFi::handleSSID(bool set, struct apple80211_ssid_data *d)
{
    if (!d) return kIOReturnBadArgument;
    if (set) return kIOReturnSuccess; // The reference IO80211 driver accepts this; ASSOCIATE carries the target.
    RTW88StateResult st = {}; IOReturn r = _ieee80211->cmdGetState(&st);
    setProperty("STA_LAST_RAW_STATE", (uint64_t)_ieee80211->rawState(), 32);
    setProperty("STA_LAST_REPORTED_STATE", (uint64_t)st.state, 32);
    setProperty("STA_ASSOC_VISIBLE", _ieee80211->associatedVisible() ? kOSBooleanTrue : kOSBooleanFalse);
    if (r) return r;
    // Match the classic IO80211 contract: no current SSID before RUN.
    if (st.state != RTW88_STATE_CONNECTED) return 6;
    bzero(d, sizeof(*d)); d->version = APPLE80211_VERSION;
    d->ssid_len = (uint32_t)strnlen(st.ssid, sizeof(d->ssid_bytes));
    memcpy(d->ssid_bytes, st.ssid, d->ssid_len);
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleAUTH_TYPE(bool set, struct apple80211_authtype_data *d)
{
    if (!d) return kIOReturnBadArgument;
    if (set) {
        if (d->version != APPLE80211_VERSION) return kIOReturnBadArgument;
        /* The reference IO80211 driver stores the Apple auth request verbatim.  Do not reject
         * mixed WPA/WPA2 masks before the actual ASSOCIATE request arrives. */
        _authLower = d->authtype_lower;
        _authUpper = d->authtype_upper;
    } else {
        bzero(d, sizeof(*d));
        d->version = APPLE80211_VERSION;
        d->authtype_lower = _authLower;
        d->authtype_upper = _authUpper;
    }
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleASSOCIATE(struct apple80211_assoc_data *d)
{
    setProperty("STA_INTERNAL_RSN_MODE", kOSBooleanTrue);
    setProperty("STA_ASSOCIATE_RESULT_VALID", kOSBooleanFalse);
    auto finish = [this](IOReturn result) -> IOReturn {
        setProperty("STA_ASSOCIATE_CMD_RET", (uint64_t)(uint32_t)result, 32);
        setProperty("STA_ASSOCIATE_RESULT_VALID", kOSBooleanTrue);
        return result;
    };
    kprintf("RTL88WiFi: handleASSOCIATE ENTER data=%p (internal RSN)\n", d);
    // Metadata only: never publish SSID, BSSID, PMK or password bytes.
    if (d) {
        setProperty("STA_ASSOC_INPUT_VERSION", (uint64_t)d->version, 32);
        setProperty("STA_ASSOC_INPUT_MODE", (uint64_t)d->ad_mode, 32);
        setProperty("STA_ASSOC_INPUT_AUTH_LOWER", (uint64_t)d->ad_auth_lower, 32);
        setProperty("STA_ASSOC_INPUT_AUTH_UPPER", (uint64_t)d->ad_auth_upper, 32);
        setProperty("STA_ASSOC_INPUT_SSID_LEN", (uint64_t)d->ad_ssid_len, 32);
        setProperty("STA_ASSOC_INPUT_KEY_LEN", (uint64_t)d->ad_key.key_len, 32);
    }

    if (!d) {
        IOLog("RTL88WiFi: ASSOCIATE invalid payload: null data pointer\n");
        return finish(kIOReturnBadArgument);
    }
    if (d->version != APPLE80211_VERSION ||
        !d->ad_ssid_len || d->ad_ssid_len > APPLE80211_MAX_SSID_LEN) {
        IOLog("RTL88WiFi: ASSOCIATE invalid payload header version=%u mode=%u lower=%u upper=0x%x ssidLen=%u keyLen=%u; check host ABI translation\n",
              (unsigned)d->version, (unsigned)d->ad_mode,
              (unsigned)d->ad_auth_lower, (unsigned)d->ad_auth_upper,
              (unsigned)d->ad_ssid_len, (unsigned)d->ad_key.key_len);
        return finish(kIOReturnBadArgument);
    }

    char ssid[APPLE80211_MAX_SSID_LEN + 1] = {};
    memcpy(ssid, d->ad_ssid, d->ad_ssid_len);
    if (strnlen(ssid, sizeof(ssid)) != d->ad_ssid_len)
        return finish(kIOReturnUnsupported);

    const uint8_t emptyBssid[APPLE80211_ADDR_LEN] = {};
    const uint8_t *bssid = memcmp(d->ad_bssid.octet, emptyBssid,
                                  APPLE80211_ADDR_LEN) ? d->ad_bssid.octet : nullptr;

    /* 1.0.4: every request is logged (lengths and flags only, no key bytes), and
     * so is the reason for every early refusal below, so a failed join leaves
     * evidence in the kernel log even if macOS then reconnects elsewhere.
     * upper bits: 2 WPA-PSK, 8 WPA2-PSK, 0x80 PSK-SHA256, 0x200 WPA3-SAE. */
    IOLog("RTL88WiFi: ASSOCIATE request lower=%u upper=0x%x keylen=%u ssidLen=%u pinned=%d\n",
          (unsigned)d->ad_auth_lower, (unsigned)d->ad_auth_upper,
          (unsigned)d->ad_key.key_len, (unsigned)d->ad_ssid_len, bssid != nullptr);

    const uint32_t personalMask =
        APPLE80211_AUTHTYPE_WPA_PSK |
        APPLE80211_AUTHTYPE_WPA2_PSK |
        APPLE80211_AUTHTYPE_SHA256_PSK;
    constexpr uint32_t saeMask = 0x00000200U;
    const bool saeRequested = (d->ad_auth_upper & saeMask) != 0;
    const bool hasWpa2 = (d->ad_auth_upper & APPLE80211_AUTHTYPE_WPA2_PSK) != 0;
    const bool knownUpper = (d->ad_auth_upper & ~(personalMask | saeMask)) == 0;
    const bool secure = (d->ad_auth_upper & personalMask) != 0 && knownUpper &&
                        (!saeRequested || hasWpa2);

    if (d->ad_auth_lower != APPLE80211_AUTHTYPE_OPEN ||
        (d->ad_auth_upper != APPLE80211_AUTHTYPE_NONE && !secure)) {
        IOLog("RTL88WiFi: ASSOCIATE refused: auth lower=%u upper=0x%x is not open/PSK "
              "(WPA3-SAE or another unsupported type)\n",
              (unsigned)d->ad_auth_lower, (unsigned)d->ad_auth_upper);
        return finish(kIOReturnUnsupported);
    }

    /* Proven Ventura path (0.4.0 -> 1.0.0): IO80211 supplies the 32-byte
     * association PMK in ad_key.  Keep the 4-way handshake inside rtw88.
     * Do not enable Apple RSN here: that experimental path changed the join
     * transport and was never the known-good RTL8822BE path. */
    const uint8_t *pmk = nullptr;
    if (secure) {
        if (d->ad_key.key_len != 32) {
            setProperty("STA_ASSOCIATE_BAD_PMK_LEN", (uint64_t)d->ad_key.key_len, 32);
            IOLog("RTL88WiFi: ASSOCIATE refused: key length %u, a 32-byte PMK is required\n",
                  (unsigned)d->ad_key.key_len);
            return finish(kIOReturnUnsupported);
        }
        pmk = d->ad_key.key;

    }

    // Validate the open-network key before tearing down an existing link.
    if (!secure && d->ad_key.key_len != 0)
        return finish(kIOReturnUnsupported);

    RTW88StateResult current = {};
    if (_ieee80211->cmdGetState(&current) == kIOReturnSuccess &&
        (current.state == RTW88_STATE_AUTHENTICATING ||
         current.state == RTW88_STATE_ASSOCIATING ||
         current.state == RTW88_STATE_HANDSHAKING ||
         current.state == RTW88_STATE_CONNECTED)) {
        bool same = _ieee80211->matchesPendingJoin(ssid, bssid, pmk);
        setProperty("ASSOCIATE_COALESCED", same ? kOSBooleanTrue : kOSBooleanFalse);
        if (same) return finish(kIOReturnSuccess);
        // A valid new ASSOCIATE supersedes the old attempt/link. Drain its
        // authentication worker and remove old keys/STA before setting the
        // new request's RSN IE (doDisconnect clears the previous IE).
        IOReturn disconnectRet = _ieee80211->cmdDisconnect();
        if (disconnectRet != kIOReturnSuccess) return finish(disconnectRet);
    }

    _authLower = d->ad_auth_lower;
    /* Keep WPA3-SAE disabled.  On transition BSSes retain only the WPA2-PSK
     * selection; SAE-only and unknown AKMs have already been rejected. */
    _authUpper = d->ad_auth_upper & ~saeMask;
    if (saeRequested)
        IOLog("RTL88WiFi: WPA3-SAE disabled; using WPA2-PSK transition fallback\n");
    _ieee80211->clearAssocRsnIE();
    if (secure) {
        /* Ventura's legacy struct names the 16-bit RSN length slot `pad`.
         * Prefer the TLV's own length because that is what the proven audit
         * path used and it is stable across the older/newer header naming. */
        uint16_t rsnLen = 0;
        if (d->ad_rsn_ie[0] == 48)
            rsnLen = (uint16_t)d->ad_rsn_ie[1] + 2;
        if (rsnLen >= 2 && rsnLen <= APPLE80211_MAX_RSN_IE_LEN) {
            IOReturn rsnRet = _ieee80211->cmdSetAssocRsnIE(d->ad_rsn_ie, rsnLen);
            if (rsnRet != kIOReturnSuccess) return finish(rsnRet);
        }
    } else {
        if (d->ad_key.key_len != 0)
            return finish(kIOReturnUnsupported);
        _ieee80211->clearAssocRsnIE();
    }

    _assocDoneReported = false;
    _rsnHandshakeReported = false;
    setProperty("STA_ASSOCIATE_BEFORE_RAW_STATE", (uint64_t)_ieee80211->rawState(), 32);
    IOReturn ret = _ieee80211->cmdConnect(ssid, nullptr, pmk, bssid, false);
    setProperty("STA_ASSOCIATE_AFTER_RAW_STATE", (uint64_t)_ieee80211->rawState(), 32);
    if (ret == kIOReturnSuccess)
        setProperty("STA_ASSOCIATE_ACCEPTED", kOSBooleanTrue);

    IOLog("RTL88WiFi: ASSOCIATE internal-RSN ssid=%s secure=%d keylen=%u ret=0x%x\n",
          ssid, secure, d->ad_key.key_len, ret);
    return finish(ret);
}

IOReturn RTL88WiFi::handleRSN_IE(bool set, struct apple80211_rsn_ie_data *d)
{
    if (!d) return kIOReturnBadArgument;
    if (set) {
        if (d->version != APPLE80211_VERSION || d->len < 2 ||
            d->len > APPLE80211_MAX_RSN_IE_LEN)
            return kIOReturnBadArgument;
        return _ieee80211->cmdSetAssocRsnIE(d->ie, d->len);
    }
    uint16_t len = 0;
    IOReturn ret = _ieee80211->copyTargetRsnIE(d->ie, sizeof(d->ie), &len);
    if (ret) return ret;
    d->version = APPLE80211_VERSION;
    d->len = len;
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleAP_IE_LIST(struct apple80211_ap_ie_data *d)
{
    /* Ventura+ airportd passes an inline ie_data[1024] buffer (1032 bytes
     * total) and expects the associated AP's beacon/probe-response IE list,
     * as the reference IO80211 driver returns ni_rsnie_tlv.  Returning only our own RSN IE
     * (no SSID element) makes airportd classify the network as hidden. */
    static_assert(sizeof(struct apple80211_ap_ie_data) == 8 + APPLE80211_NETWORK_DATA_MAX_IE_LEN,
                  "AP_IE_LIST ABI changed");
    if (!d) return kIOReturnBadArgument;
    RTW88BSS b = {};
    IOReturn ret = _ieee80211->copyCurrentBSS(&b);
    if (ret != kIOReturnSuccess) return ret;
    size_t n = b.ies_len;
    if (n > sizeof(b.ies)) n = sizeof(b.ies);
    if (n == 0) return kIOReturnNotFound;
    size_t cap = sizeof(d->ie_data);
    if (d->len != 0 && d->len < cap) cap = d->len;
    if (n > cap) return kIOReturnNoSpace;
    memcpy(d->ie_data, b.ies, n);
    d->version = APPLE80211_VERSION;
    d->len = (u_int32_t)n;
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleCIPHER_KEY(struct apple80211_key *key)
{
    if (!key || key->version != APPLE80211_VERSION || key->key_len > APPLE80211_KEY_BUFF_LEN)
        return kIOReturnBadArgument;

    if (key->key_cipher_type == APPLE80211_CIPHER_NONE)
        return kIOReturnSuccess;

    uint32_t cipher = 0;
    switch (key->key_cipher_type) {
    case APPLE80211_CIPHER_AES_CCM:
        cipher = WLAN_CIPHER_SUITE_CCMP;
        break;
    case APPLE80211_CIPHER_TKIP:
        cipher = WLAN_CIPHER_SUITE_TKIP;
        break;
    default:
        return kIOReturnUnsupported;
    }

    /* Match the reference IO80211 driver semantics strictly:
     * key_flags == 4 -> PTK
     * key_flags == 0 -> GTK
     */
    bool pairwise;
    if (key->key_flags == 4) {
        pairwise = true;
    } else if (key->key_flags == 0) {
        pairwise = false;
    } else {
        IOLog("RTL88WiFi: unexpected CIPHER_KEY flags=%u\n",
              key->key_flags);
        return kIOReturnUnsupported;
    }
    IOReturn ret = _ieee80211->cmdInstallExternalKey(pairwise,
                    (uint8_t)key->key_index, cipher, key->key, (uint8_t)key->key_len);
    IOLog("RTL88WiFi: CIPHER_KEY %s cipher=%u idx=%u len=%u ret=0x%x\n",
          pairwise ? "PTK" : "GTK", key->key_cipher_type, key->key_index,
          key->key_len, ret);
    setProperty("STA_KEY_RAW_STATE", (uint64_t)_ieee80211->rawState(), 32);
    setProperty("STA_KEY_ASSOC_VISIBLE", _ieee80211->associatedVisible() ? kOSBooleanTrue : kOSBooleanFalse);
    /* The reference IO80211 driver v2.3 posts APPLE80211_M_RSN_HANDSHAKE_DONE after each
     * successful PTK/GTK callback.  Do the same.  Waiting for *both* keys
     * before posting this event can deadlock Apple's supplicant if it expects
     * the PTK notification before it submits the GTK.  The Realtek backend
     * still gates ordinary data until both keys are installed. */
    if (!ret && _netif) {
        _netif->postMessage(APPLE80211_M_RSN_HANDSHAKE_DONE);
        _rsnHandshakeReported = true;
        setProperty(pairwise ? "APPLE_RSN_PTK_EVENT" : "APPLE_RSN_GTK_EVENT",
                    kOSBooleanTrue);
        IOLog("RTL88WiFi: Apple RSN key event posted type=%s ready=%d\n",
              pairwise ? "PTK" : "GTK", _ieee80211->externalKeysReady());
    }
    return ret;
}

IOReturn RTL88WiFi::handleDISASSOCIATE()
{
    /* The reference IO80211 driver acknowledges DISASSOCIATE without tearing down AUTH/ASSOC.
     * Its SCAN state also remains a scan rather than becoming a fake link-down
     * event.  Our raw SCANNING state is an implementation detail, so when no
     * infrastructure RUN latch exists, acknowledge the cleanup request without
     * destroying the scan transaction. */
    const RTW88State raw = _ieee80211->rawState();
    const bool visible = _ieee80211->associatedVisible();
    setProperty("STA_DISASSOC_RAW_STATE", (uint64_t)raw, 32);
    setProperty("STA_DISASSOC_ASSOC_VISIBLE", visible ? kOSBooleanTrue : kOSBooleanFalse);

    if (raw == RTW88_STATE_AUTHENTICATING || raw == RTW88_STATE_ASSOCIATING) {
        setProperty("STA_DISASSOC_IGNORED_DURING_JOIN", kOSBooleanTrue);
        IOLog("RTL88WiFi: DISASSOCIATE ignored during join raw_state=%u\n", raw);
        return kIOReturnSuccess;
    }

    if (raw == RTW88_STATE_SCANNING && !visible) {
        setProperty("STA_DISASSOC_ACK_SCAN_ONLY", kOSBooleanTrue);
        setProperty("STA_DISASSOC_EXECUTED", kOSBooleanFalse);
        IOLog("RTL88WiFi: DISASSOCIATE acknowledged during disconnected scan (no teardown)\n");
        /* v9 accidentally called cmdDisconnect() here, which generated a real
         * disconnected event and collapsed SCANNING to IDLE.  The reference IO80211 driver's
         * join path treats this cleanup as non-destructive while association
         * is being prepared. */
        return kIOReturnSuccess;
    }

    _rsnHandshakeReported = false;
    _ieee80211->clearAssocRsnIE();
    setProperty("STA_DISASSOC_EXECUTED", kOSBooleanTrue);
    return _ieee80211->cmdDisconnect();
}

IOReturn RTL88WiFi::handleSCAN_REQ(void *data)
{
    if (!data) return kIOReturnBadArgument;
    auto *d = static_cast<apple80211_scan_data *>(data);
    if (d->version != APPLE80211_VERSION || d->ssid_len > APPLE80211_MAX_SSID_LEN ||
        d->num_channels > APPLE80211_MAX_CHANNELS) return kIOReturnBadArgument;
    if (_scanInProgress) {
        IOLog("RTL88WiFi: SCAN_REQ coalesced with active scan\n");
        return kIOReturnSuccess;
    }

    uint16_t requested[APPLE80211_MAX_CHANNELS] = {};
    for (uint32_t i = 0; i < d->num_channels; ++i) {
        if (d->channels[i].channel > 255) return kIOReturnBadArgument;
        requested[i] = (uint16_t)d->channels[i].channel;
    }

    RTW88StateResult st = {};
    const bool connected =
        _ieee80211->cmdGetState(&st) == kIOReturnSuccess &&
        st.state == RTW88_STATE_CONNECTED;
    _scanInProgress = true;
    _scanCursor = 0;
    IOReturn ret = _ieee80211->cmdScan(requested, d->num_channels);
    if (ret == kIOReturnNotReady && connected) {
        _scanInProgress = false;
        UInt32 result = 0;
        kprintf("RTL88WiFi: SCAN_REQ connected cache-only completion (no candidate channels)\n");
        _netif->postMessage(APPLE80211_M_SCAN_DONE, &result, sizeof(result));
        return kIOReturnSuccess;
    }
    if (ret) _scanInProgress = false;
    return ret;
}

void RTL88WiFi::fillScanResultFromBSS(const RTW88BSS &b, struct apple80211_scan_result *d, bool fullIEs)
{
    if (!d) return;
    bzero(d, sizeof(*d));
    d->version = APPLE80211_VERSION;
    d->asr_channel.version = APPLE80211_VERSION;
    d->asr_channel.channel = b.channel;
    /* Match the reference IO80211 driver's Ventura behavior: keep scan/current-network
     * channel flags deliberately conservative so CoreWiFi accepts them. */
    d->asr_channel.flags = APPLE80211_C_FLAG_ACTIVE |
                           APPLE80211_C_FLAG_20MHZ |
        (b.channel <= 14 ? APPLE80211_C_FLAG_2GHZ : APPLE80211_C_FLAG_5GHZ);

    /* No per-BSS noise measurement exists for scanned networks.  Report the
     * thermal-noise estimate for the BSS's width (never 0) so System
     * Information's other-networks list is not full of "0 dBm" noise.
     * CURRENT_NETWORK overwrites this with the link's own value. */
    {
        const RTW88Metrics::LinkNoise nz =
            RTW88Metrics::linkNoise(b.rssi, false, 0, rtw88BssWidthMHz(b));
        d->asr_noise = (int16_t)nz.noise;
        d->asr_snr = (int16_t)nz.snr;
    }
    d->asr_rssi = b.rssi;
    d->asr_beacon_int = (int16_t)b.beacon_interval;
    d->asr_cap = (int16_t)b.capabilities;
    d->asr_age = 0;
    memcpy(d->asr_bssid, b.bssid, APPLE80211_ADDR_LEN);
    d->asr_ssid_len = b.ssid_len > APPLE80211_MAX_SSID_LEN ?
                      APPLE80211_MAX_SSID_LEN : b.ssid_len;
    if (d->asr_ssid_len)
        memcpy(d->asr_ssid, b.ssid, d->asr_ssid_len);

    const size_t ieLength = b.ies_len > sizeof(b.ies) ? sizeof(b.ies) : b.ies_len;
    d->asr_ie_len = 0;
    if (fullIEs) {
        /* The reference IO80211 driver's CURRENT_NETWORK is a scan-result-style object. Give
         * CoreWiFi/locationd the complete BSS IE blob for the associated AP. */
        const size_t ieCopy = ieLength > sizeof(d->asr_ie_data) ? sizeof(d->asr_ie_data) : ieLength;
        if (ieCopy) {
            memcpy(d->asr_ie_data, b.ies, ieCopy);
            d->asr_ie_len = (int16_t)ieCopy;
        }
    } else {
        /* Preserve the already-working Ventura SCAN_RESULT contract: expose
         * only the first RSN TLV, matching the audited the reference IO80211 driver behavior. */
        for (size_t pos = 0; pos + 2 <= ieLength;) {
            const size_t n = (size_t)b.ies[pos + 1] + 2;
            if (n > ieLength - pos) break;
            if (b.ies[pos] == 48) { /* RSN TLV */
                const size_t copyLen = n > sizeof(d->asr_ie_data) ? sizeof(d->asr_ie_data) : n;
                memcpy(d->asr_ie_data, b.ies + pos, copyLen);
                d->asr_ie_len = (int16_t)copyLen;
                break;
            }
            pos += n;
        }
    }

    /* Populate real supported rates from beacon/probe IEs. */
    for (size_t pos = 0; pos + 2 <= ieLength;) {
        const size_t n = (size_t)b.ies[pos + 1] + 2;
        if (n > ieLength - pos) break;
        if (b.ies[pos] == 1 || b.ies[pos] == 50) {
            for (size_t j = 0; j < n - 2 && d->asr_nrates < APPLE80211_MAX_RATES; j++)
                d->asr_rates[d->asr_nrates++] = b.ies[pos + 2 + j];
        }
        pos += n;
    }
}

static bool bssIsNameless(const RTW88BSS &b)
{
    uint8_t n = b.ssid_len < sizeof(b.ssid) ? b.ssid_len : (uint8_t)(sizeof(b.ssid) - 1);
    for (uint8_t i = 0; i < n; i++)
        if (b.ssid[i] != 0) return false;
    return true;
}

IOReturn RTL88WiFi::handleSCAN_RESULT(struct apple80211_scan_result **out)
{
    if (!out) return kIOReturnBadArgument;
    *out = nullptr;

    /* Keep the Ventura/the reference IO80211 driver pointer-to-pointer SCAN_RESULT ABI.
     * On Sonoma with the OCLP legacy wireless stack, CoreWiFi can skip
     * SCAN_REQ/SCAN_REQ_MULTIPLE entirely and query only the family cache.
     * If that cache is empty, perform exactly one demand-driven physical scan
     * while unassociated.  The normal kRTW88EventScanDone path posts
     * APPLE80211_M_SCAN_DONE; a later GET then enumerates the populated cache.
     *
     * Do not do this on Ventura: its existing explicit scan request path is
     * known-good and must remain untouched. */
    if (_scanInProgress && version_major < 23)
        return kIOReturnBusy;

    RTW88BSS b = {};
    IOReturn ret = _ieee80211->copyScanBSS(_scanCursor, &b);
    /* Sonoma: CoreWiFi lists a BSS with an empty or all-zero SSID as a
     * separate "Hidden Network..." row. Hidden-network joining through that
     * row is not supported here (no directed probe), so skip such entries,
     * except the BSS we are currently associated with. */
    if (version_major >= 23) {
        RTW88BSS cur = {};
        bool haveCur = _ieee80211->copyCurrentBSS(&cur) == kIOReturnSuccess;
        while (ret == kIOReturnSuccess && bssIsNameless(b) &&
               !(haveCur && memcmp(cur.bssid, b.bssid, 6) == 0)) {
            _scanCursor++;
            b = {};
            ret = _ieee80211->copyScanBSS(_scanCursor, &b);
        }
    }
    setProperty("STA_V24_SCAN_CACHE_RET", (uint64_t)(uint32_t)ret, 32);
    if (ret == kIOReturnNotFound) {
        /* Newer hosts poll the cache while a physical scan is running. A
         * blanket EBUSY hides even existing BSS entries during repeated
         * scans. copyScanBSS returns a locked copy, safe to publish here.
         * An empty cache still reports busy; a partial list ends normally.
         */
        if (_scanInProgress && _scanCursor == 0)
            return kIOReturnBusy;
        if (_scanCursor == 0 && version_major >= 23 &&
            !_scanCacheBootstrapAttempted) {
            RTW88StateResult st = {};
            if (_ieee80211->cmdGetState(&st) == kIOReturnSuccess &&
                st.state == RTW88_STATE_IDLE) {
                _scanCacheBootstrapAttempted = true;
                _scanInProgress = true;
                IOReturn scanRet = _ieee80211->cmdScan();
                if (scanRet != kIOReturnSuccess) {
                    _scanInProgress = false;
                    IOLog("RTL88WiFi: Sonoma cache bootstrap scan failed 0x%x\n", scanRet);
                    return scanRet;
                }
                IOLog("RTL88WiFi: Sonoma cache-only SCAN_RESULT triggered bootstrap scan\n");
                return kIOReturnBusy;
            }
        }
        _scanCursor = 0;
        return 5; /* The reference IO80211 driver end-of-list ABI */
    }
    if (ret) return ret;

    /* Sonoma's CoreWiFi derives the network name from the IE blob; with
     * only the RSN TLV it lists the associated AP as a "Hidden Network".
     * The reference IO80211 driver actually hands over the full beacon/probe IE blob
     * (ni_rsnie_tlv holds every IE), so do the same on Sonoma and keep the
     * RSN-only Ventura contract unchanged. */
    fillScanResultFromBSS(b, &_scanResult, version_major >= 23);
    /* Report the BSS's advertised operating width (HT/VHT Operation IEs),
     * using the same parse as the connection chandef.  CURRENT_NETWORK keeps
     * its conservative flags; the live width is in APPLE80211_IOC_CHANNEL. */
    RTW88BssOperation op;
    RTW88IEEE80211::parseBssOperation(b.ies, b.ies_len, &op);
    uint32_t width = APPLE80211_C_FLAG_20MHZ;
    if (b.channel > 14 && op.vhtWidth == 1 && op.vhtSeg0 != 0)
        width = APPLE80211_C_FLAG_80MHZ;
    else if (op.htStaWidth && (op.sco == 1 || op.sco == 3))
        width = APPLE80211_C_FLAG_40MHZ | (op.sco == 1 ? APPLE80211_C_FLAG_EXT_ABV : 0);
    _scanResult.asr_channel.flags = (_scanResult.asr_channel.flags & ~APPLE80211_C_FLAG_20MHZ) | width;
    _scanCursor++;
    setProperty("STA_V24_SCAN_RESULT_CURSOR", (uint64_t)_scanCursor, 32);
    setProperty("STA_V24_SCAN_RESULT_DURING_SCAN", _scanInProgress ? kOSBooleanTrue : kOSBooleanFalse);
    *out = &_scanResult;
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleCURRENT_NETWORK(struct apple80211_scan_result *out)
{
    static_assert(sizeof(apple80211_scan_result) == 1164, "Ventura CURRENT_NETWORK ABI changed");
    if (!out) return kIOReturnBadArgument;

    RTW88BSS current = {};
    IOReturn ret = _ieee80211->copyCurrentBSS(&current);
    if (ret != kIOReturnSuccess) {
        /* CoreWiFi/locationd asks selector 103 aggressively.  Do not turn a
         * valid RUN state into -3903 merely because the scan-cache copy was
         * evicted.  Reconstruct the minimum current BSS from the authoritative
         * connection state exposed by the Realtek backend. */
        RTW88StateResult st = {};
        IOReturn sr = _ieee80211->cmdGetState(&st);
        if (sr != kIOReturnSuccess || st.state != RTW88_STATE_CONNECTED ||
            st.channel == 0 || st.ssid[0] == '\0') {
            kprintf("RTL88WiFi: CURRENT_NETWORK unavailable bss=0x%x state=0x%x run=%u ch=%u ssid0=%u\n",
                  ret, sr, st.state, st.channel, (unsigned)(uint8_t)st.ssid[0]);
            return ret != kIOReturnSuccess ? ret : kIOReturnNotReady;
        }

        current.ssid_len = (uint8_t)strnlen(st.ssid, 32);
        memcpy(current.ssid, st.ssid, current.ssid_len);
        current.ssid[current.ssid_len] = '\0';
        memcpy(current.bssid, st.bssid, sizeof(current.bssid));
        current.channel = (uint8_t)st.channel;
        current.rssi = (int16_t)st.rssi;
        current.beacon_interval = 100;
        kprintf("RTL88WiFi: CURRENT_NETWORK reconstructed from connected state\n");
    }

    fillScanResultFromBSS(current, out, true);
    int nf = 0, snr = 0;
    rtw88LinkNoise(out->asr_rssi, _ieee80211->channelWidthMHz(), &nf, &snr);
    out->asr_noise = (int16_t)nf;
    out->asr_snr = (int16_t)snr;
    kprintf("RTL88WiFi: CURRENT_NETWORK ssid_len=%u channel=%u rssi=%d ies=%d\n",
          out->asr_ssid_len, out->asr_channel.channel,
          out->asr_rssi, out->asr_ie_len);
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleSTATE(struct apple80211_state_data *out)
{
    if (!out) return kIOReturnBadArgument;
    struct RTW88StateResult st;
    IOReturn r = _ieee80211->cmdGetState(&st);
    if (r != kIOReturnSuccess) return r;
    bzero(out, sizeof(*out));
    out->version = APPLE80211_VERSION;
    switch (st.state) {
    case RTW88_STATE_SCANNING: out->state = APPLE80211_S_SCAN; break;
    case RTW88_STATE_AUTHENTICATING: out->state = APPLE80211_S_AUTH; break;
    case RTW88_STATE_ASSOCIATING:
    case RTW88_STATE_HANDSHAKING: out->state = APPLE80211_S_ASSOC; break;
    case RTW88_STATE_CONNECTED: out->state = APPLE80211_S_RUN; break;
    default: out->state = APPLE80211_S_INIT; break;
    }
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handleCHANNEL(struct apple80211_channel_data *out)
{
    if (!out) return kIOReturnBadArgument;
    RTW88StateResult st = {};
    IOReturn r = _ieee80211->cmdGetState(&st);
    if (r != kIOReturnSuccess) return r;
    if (st.state != RTW88_STATE_CONNECTED || st.channel == 0) return 6;
    bzero(out, sizeof(*out));
    out->version = APPLE80211_VERSION;
    out->channel.version = APPLE80211_VERSION;
    out->channel.channel = st.channel;
    const uint8_t width = _ieee80211->channelWidthMHz();
    out->channel.flags = APPLE80211_C_FLAG_ACTIVE |
        (width == 80 ? APPLE80211_C_FLAG_80MHZ :
         width == 40 ? APPLE80211_C_FLAG_40MHZ : APPLE80211_C_FLAG_20MHZ) |
        (st.channel <= 14 ? APPLE80211_C_FLAG_2GHZ : APPLE80211_C_FLAG_5GHZ);
    return kIOReturnSuccess;
}

IOReturn RTL88WiFi::handlePOWER(bool set, struct apple80211_power_data *d)
{
    if (!d) return kIOReturnBadArgument;
    if (set && __atomic_load_n(&_shutdown, __ATOMIC_ACQUIRE))
        return kIOReturnNotReady;
    if (set) {
        if (d->version != APPLE80211_VERSION || !d->num_radios ||
            d->num_radios > APPLE80211_MAX_RADIO)
            return kIOReturnBadArgument;
        UInt32 requested = d->power_state[0];
        if (requested != APPLE80211_POWER_ON && requested != APPLE80211_POWER_OFF)
            return kIOReturnUnsupported;
        // The device has one PHY. Never silently apply only the first of
        // contradictory radio states received from the family.
        for (UInt32 i = 1; i < d->num_radios; ++i)
            if (d->power_state[i] != requested) return kIOReturnUnsupported;
        IOReturn ret = requested == APPLE80211_POWER_ON ?
            _ieee80211->cmdPowerOn() : _ieee80211->cmdPowerOff();
        if (ret == kIOReturnSuccess && _netif)
            _netif->postMessage(APPLE80211_M_POWER_CHANGED);
        return ret;
    }
    RTW88StateResult st = {};
    IOReturn ret = _ieee80211->cmdGetState(&st);
    if (ret != kIOReturnSuccess) return ret;
    bzero(d, sizeof(*d));
    d->version = APPLE80211_VERSION;
    d->num_radios = 1;
    d->power_state[0] = st.powered ? APPLE80211_POWER_ON : APPLE80211_POWER_OFF;
    return kIOReturnSuccess;
}

SInt32 RTL88WiFi::stopDMA()
{
    /* This callback can run with the IO80211 command gate held. Do not join
     * workers or recursively disable the interface here: they may need that
     * same gate. Fence device DMA before acknowledging the request. Rings stay
     * allocated; enable() restores bus mastering for a reversible stop. */
    __atomic_store_n(&_dmaStopped, true, __ATOMIC_RELEASE);
    if (_intrSrc) _intrSrc->disable();
    if (_pciDev) {
        _pciDev->setBusMasterEnable(false);
        if (_pciDev->configRead16(kIOPCIConfigCommand) & 0x0004)
            return kIOReturnError;
    }
    return kIOReturnSuccess;
}

void RTL88WiFi::systemWillShutdown(IOOptionBits specifier)
{
    if (specifier == kIOMessageSystemWillPowerOff ||
        specifier == kIOMessageSystemWillRestart) {
        __atomic_store_n(&_shutdown, true, __ATOMIC_RELEASE);
        const SInt32 result = stopDMA();
        IOLog("RTL88WiFi: shutdown DMA fence result=0x%x\n", result);
    }
    super::systemWillShutdown(specifier);
}

UInt32 RTL88WiFi::hardwareOutputQueueDepth(IO80211Interface *interface)
{
    /* The reference IO80211 driver reports 0 here; IO80211 owns the queueing policy. */
    return 0;
}

UInt32 RTL88WiFi::getDataQueueDepth(OSObject *)
{
    /* Read once by IO80211Interface::init() as its per-AC dequeue limit. */
    return kRTW88DataQueueDepth;
}

IOReturn RTL88WiFi::outputStart(IONetworkInterface *interface, IOOptionBits options)
{
    if (interface && interface == _netif && txGateWanted()) {
        __atomic_store_n(&_txGated, true, __ATOMIC_SEQ_CST);
        _txGateCount++;
        /* Re-check after publishing the flag so a drain that ran in
         * between cannot be missed; kickGatedOutput() signals otherwise. */
        if (txGateWanted())
            return kIOReturnNoResources;
        __atomic_store_n(&_txGated, false, __ATOMIC_SEQ_CST);
    }
    return super::outputStart(interface, options);
}

bool RTL88WiFi::txGateWanted()
{
    /* A stalled queue cannot drain, so anything pulled now only waits in
     * (or tail-drops from) the 256-entry family queue. Open again only once
     * resumeTxIfStalled()/releaseTxStall() has cleared the stall at
     * kRTW88TxResumeAvail, which gives the gate the stall's hysteresis. */
    if (__atomic_load_n(&_txStalled, __ATOMIC_SEQ_CST) ||
        rtw88_be_tx_avail() < kRTW88TxStallAvail)
        return true;
    IOOutputQueue *q = getOutputQueue();
    return q && q->getSize() >= kRTW88TxQueueHigh;
}

void RTL88WiFi::kickGatedOutput()
{
    if (!__atomic_load_n(&_txGated, __ATOMIC_SEQ_CST) || !_netif)
        return;
    if (__atomic_load_n(&_txStalled, __ATOMIC_SEQ_CST) ||
        rtw88_be_tx_avail() < kRTW88TxStallAvail)
        return;
    IOOutputQueue *q = getOutputQueue();
    if (q && q->getSize() > kRTW88TxQueueLow)
        return;
    if (__atomic_exchange_n(&_txGated, false, __ATOMIC_SEQ_CST))
        _netif->signalOutputThread();
}

SInt32 RTL88WiFi::performCountryCodeOperation(IO80211Interface *interface, IO80211CountryCodeOp op)
{
    /* Match the reference IO80211 driver: acknowledge IO80211's country-code operation. */
    return kIOReturnSuccess;
}

SInt32 RTL88WiFi::enableFeature(IO80211FeatureCode feature, void *data)
{
    /* Match the reference IO80211 driver: AWDL service initialization does not depend on
     * acknowledging undocumented feature codes. Keep this truthful and
     * conservative now that the diagnostic feature-gate test is complete. */
    if (feature == kIO80211Feature80211n)
        return kIOReturnSuccess;
    return 102;
}

SInt32 RTL88WiFi::monitorModeSetEnabled(IO80211Interface *interface,
                                            bool enabled,
                                            UInt32 mode)
{
    /* No monitor backend yet, but the reference IO80211 driver returns success for this SPI. */
    return kIOReturnSuccess;
}

mbuf_t RTL88WiFi::allocateInputPacket(uint32_t len)
{
    return allocatePacket(len);  /* helper heredado de IONetworkController */
}

void RTL88WiFi::injectRxFrame(mbuf_t m)
{
    if (!m)
        return;

    if (!_netif) {
        mbuf_freem(m);
        return;
    }

    /* Submit each completed Ethernet packet directly. The former queue/flush
     * pair exposes packets to BPF before the later queue drain reaches IP.
     * Avoid retaining packets in the interface queue across link transitions.
     * A zero options mask means immediate input, not a zero-length packet. */
    size_t plen = mbuf_pkthdr_len(m);
    size_t mlen = mbuf_len(m);

    if (plen < 14 || plen > 4096 || mlen < 14 || mlen > 4096) {
        IOLog("RTL88WiFi: dropping bogus RX mbuf pkthdr=%zu mlen=%zu\n",
              plen, mlen);
        mbuf_freem(m);
        return;
    }

    /* Direct immediate input is not counted by the stack; account it here
     * (plen is read before inputPacket consumes the mbuf). */
    if (ifnet_t ifp = _netif->getIfnet())
        ifnet_stat_increment_in(ifp, 1, (u_int32_t)plen, 0);
    _netif->inputPacket(m, (UInt32)plen, 0);

    /* RX progress is an independent proof that the PCI datapath worker is
     * alive. If a TX-completion interrupt was coalesced after the BE ring
     * drained, re-check the watermark here so the macOS output queue cannot
     * remain parked indefinitely. */
    if (_txStalled)
        resumeTxIfStalled();
}

namespace {
/* AWDL management frames use an IEEE 802.11 Action header followed by the
 * Apple vendor header.  Do not feed arbitrary infrastructure action frames
 * (BlockAck, SA Query, etc.) to the AWDL peer manager. */
static bool rtw88IsAWDLActionFrame(const uint8_t *frame, uint32_t len,
                                   uint8_t *subtypeOut)
{
    static const uint8_t kAWDLBSSID[6] = {0x00, 0x25, 0x00, 0xff, 0x94, 0x73};
    static const uint8_t kAppleOUI[3] = {0x00, 0x17, 0xf2};
    constexpr uint32_t kHdrLen = 24;
    constexpr uint32_t kFixedAWDLActionLen = 16; /* category+OUI+12-byte fixed body */

    if (!frame || len < kHdrLen + kFixedAWDLActionLen)
        return false;

    /* Management/Action subtype (little-endian frame-control low byte). */
    if ((frame[0] & 0xfcU) != 0xd0U)
        return false;

    /* addr3/BSSID must be Apple's well-known AWDL BSSID. */
    if (memcmp(frame + 16, kAWDLBSSID, sizeof(kAWDLBSSID)) != 0)
        return false;

    const uint8_t *a = frame + kHdrLen;
    if (a[0] != 0x7f || memcmp(a + 1, kAppleOUI, sizeof(kAppleOUI)) != 0 ||
        a[4] != 8)
        return false;

    /* byte 5 is the AWDL version; byte 6 is PSF(0) or MIF(3). */
    const uint8_t subtype = a[6];
    if (subtype != 0 && subtype != 3)
        return false;

    /* Reject impossible source addresses before creating peer state. */
    const uint8_t *sa = frame + 10;
    bool any = false;
    for (unsigned i = 0; i < 6; ++i) any |= sa[i] != 0;
    if (!any || (sa[0] & 0x01U))
        return false;

    if (subtypeOut)
        *subtypeOut = subtype;
    return true;
}

/* The kernel SDK only carries an opaque/empty declaration for packet_info_tag.
 * Reserve a reasonably sized, zeroed backing store so IO80211 never reads
 * beyond a one-byte empty C++ placeholder if Ventura consults private fields. */
static packet_info_tag *rtw88ZeroPacketInfo(uint8_t (&storage)[64])
{
    bzero(storage, sizeof(storage));
    return reinterpret_cast<packet_info_tag *>(storage);
}
}

void RTL88WiFi::injectRxActionFrame(const uint8_t *frame, uint32_t len,
                                       int8_t rssi, uint16_t channel)
{
    IO80211VirtualInterface *awdl =
        _awdlManager ? _awdlManager->awdlInterface() : nullptr;
    if (!awdl || !frame || len > 4096)
        return;

    uint8_t subtype = 0xff;
    if (!rtw88IsAWDLActionFrame(frame, len, &subtype))
        return;
    bool presenceDue = false;
    const bool validatedPeer = _awdlManager->observeAction(frame, len, &presenceDue);

    /* Only publish peers after the AWDL parser has seen enough state to mark
     * them usable (MIF + Version/device class). Earlier builds posted every
     * PSF/MIF candidate, which could leave IO80211 with transient/stale peers
     * that never had a working data plane. */
    IO80211P2PInterface *p2p = OSDynamicCast(IO80211P2PInterface, awdl);
    const uint8_t *sa = frame + 10;
    if (p2p && validatedPeer && presenceDue) {
        ether_addr peer = {};
        memcpy(peer.octet, sa, sizeof(peer.octet));
        (void)p2p->postPeerPresence(&peer, (int)rssi,
                                    (int)channel,
                                    (int)subtype, nullptr);
        ++_awdlPeerPresencePosts;
        setProperty("AWDL_PEER_PRESENCE_POSTS", (uint64_t)_awdlPeerPresencePosts, 32);
        /* A newly usable peer may unblock queued mDNS/IPv6 traffic on awdl0. */
        p2p->signalOutputThread();

#if __IO80211_TARGET >= __MAC_10_15
        /* The Ventura P2P interface exposes a peer IPv6 notification hook.
         * Keep the EUI-64 address as diagnostic data, but do not interpret the
         * method's return register as an IOReturn: the legacy private ABI has
         * no trustworthy parameter/return contract in the public SDK. */
        unsigned char ipv6[16] = { 0xfe, 0x80 };
        ipv6[8]  = sa[0] ^ 0x02;
        ipv6[9]  = sa[1];
        ipv6[10] = sa[2];
        ipv6[11] = 0xff;
        ipv6[12] = 0xfe;
        ipv6[13] = sa[3];
        ipv6[14] = sa[4];
        ipv6[15] = sa[5];
        (void)p2p->postPeerPresenceIPv6(&peer, (int)rssi,
                                        (int)channel,
                                        (int)subtype, nullptr,
                                        ipv6);
        ++_awdlPeerIPv6Posts;
        setProperty("AWDL_PEER_IPV6_POSTED", kOSBooleanTrue);
        setProperty("AWDL_PEER_IPV6_POSTS", (uint64_t)_awdlPeerIPv6Posts, 32);
        setProperty("AWDL_PEER_IPV6", ipv6, sizeof(ipv6));
#endif
    }

    mbuf_t m = allocatePacket(len);
    if (!m)
        return;
    if (mbuf_copyback(m, 0, len, frame, MBUF_DONTWAIT) != 0) {
        mbuf_freem(m);
        return;
    }
    mbuf_pkthdr_setlen(m, len);

    alignas(8) uint8_t tagStorage[64];
    UInt32 ret = awdl->inputPacket(m, rtw88ZeroPacketInfo(tagStorage));
    setProperty("AWDL_LAST_ACTION_INPUT_RESULT", (uint64_t)ret, 32);
    if (ret != kIOReturnSuccess && ret != kIOReturnOutputSuccess) {
        /* IO80211VirtualInterface owns the mbuf on accepted paths. On a
         * failure return it is safer not to double-free an ambiguously
         * consumed packet; the trace above records the Ventura result. */
    }
}

void RTL88WiFi::injectRxAWDLFrame(mbuf_t m)
{
    if (!m) return;
    IO80211VirtualInterface *awdl = _awdlManager ? _awdlManager->awdlInterface() : nullptr;
    if (!awdl) {
        mbuf_freem(m);
        return;
    }
    const unsigned long packetLen = (unsigned long)mbuf_pkthdr_len(m);
    alignas(8) uint8_t tagStorage[64];
    UInt32 ret = awdl->inputPacket(m, rtw88ZeroPacketInfo(tagStorage));
    if (_awdlManager) _awdlManager->noteDataRX(ret);
    /* IO80211P2PInterface::inputPacket is a private ABI. Keep the raw value
     * as bounded telemetry only; do not flood the shutdown console. */
    setProperty("AWDL_LAST_DATA_INPUT_RAW", (uint64_t)ret, 32);
    (void)packetLen;
}

IOWorkLoop *RTL88WiFi::getRxWorkLoop()
{
    return _workLoop;   /* miembro ya declarado en RTL88WiFi.hpp */
}

bool RTL88WiFi::setLinkStatus(UInt32 status, const IONetworkMedium *activeMedium,
                                  UInt64 speed, OSData *data)
{
    if (__atomic_load_n(&_shutdown, __ATOMIC_ACQUIRE)) return false;
    const bool ret = IO80211Controller::setLinkStatus(status, activeMedium, speed, data);
    const bool up = (status & kIONetworkLinkActive) != 0;

    if (_netif && (_linkUp != up || !(status & kIONetworkLinkNoNetworkChange))) {
        _linkUp = up;
        if (getCommandGate()) {
            getCommandGate()->runAction(
                [](OSObject *owner, void *value, void *reason, void *, void *) -> IOReturn {
                    auto *self = static_cast<RTL88WiFi *>(owner);
                    if (!self->_netif) return kIOReturnNotReady;
                    const bool linkUp = (uintptr_t)value != 0;
                    const unsigned int why = (unsigned int)(uintptr_t)reason;
                    IOReturn lr = self->_netif->setLinkState(
                        linkUp ? kIO80211NetworkLinkUp : kIO80211NetworkLinkDown,
                        linkUp ? 0U : why);
                    IOLog("RTL88WiFi: link %s reason=%u ret=0x%x\n",
                          linkUp ? "up" : "down", linkUp ? 0U : why, (unsigned)lr);
                    if (linkUp) {
                        self->_netif->setLinkQualityMetric(100);
                        /* Proven 1.0.0 STA sequencing: with the internal rtw88
                         * supplicant, ASSOCIATION is complete for CoreWiFi only
                         * when the controlled port is actually usable (open
                         * network immediately, WPA2 after M3/PTK+GTK). */
                        if (!self->_assocDoneReported) {
                            self->_assocDoneReported = true;
                            self->setProperty("STA_ASSOC_DONE_AT_LINK_UP", kOSBooleanTrue);
                            self->_netif->postMessage(APPLE80211_M_ASSOC_DONE);
                        }
                    } else {
                        self->_assocDoneReported = false;
                    }
                    return lr;
                },
                (void *)(uintptr_t)(up ? 1U : 0U),
                (void *)(uintptr_t)(up ? 0U : _ieee80211->deauthReason()));
        }
    }
    return ret;
}

void RTL88WiFi::setLinkStatus(UInt32 status)
{
    /* RTW88RxDelegate entry point.  Route it through the full controller
     * override so registry link properties and IO80211 interface state change
     * together, as in the reference IO80211 driver. */
    (void)setLinkStatus(status, nullptr, 0, nullptr);
}

void RTL88WiFi::rtw88Event(RTW88Event ev, void *data)
{
    if (__atomic_load_n(&_shutdown, __ATOMIC_ACQUIRE) || !_netif) return;
    switch (ev) {
    case kRTW88EventScanDone: {
        setProperty("STA_V24_SCAN_COMPLETED", kOSBooleanTrue);
        _scanInProgress = false; _scanCursor = 0; UInt32 result = data ? *(UInt32 *)data : 0;
        if (_ieee80211) {
            setProperty("RADIO_SCAN_ENGINE", _ieee80211->scanEngine());
            setProperty("RADIO_SCAN_CHANNELS", (uint64_t)_ieee80211->scanChannelCount(), 32);
            setProperty("RADIO_SCAN_SW_VISITED_2GHZ", (uint64_t)_ieee80211->scanVisited2GHz(), 32);
            setProperty("RADIO_SCAN_SW_VISITED_5GHZ", (uint64_t)_ieee80211->scanVisited5GHz(), 32);
            setProperty("RADIO_SCAN_CACHE_COUNT", (uint64_t)_ieee80211->scanCacheCount(), 32);
            setProperty("RADIO_SCAN_COMPLETED_GENERATION", (uint64_t)_ieee80211->scanGeneration(), 32);
            setProperty("RADIO_SCAN_ABORTED", result != 0);
        }
        _netif->postMessage(APPLE80211_M_SCAN_DONE, &result, sizeof(result)); break;
    }
    case kRTW88EventAssocDone:
        setProperty("STA_ASSOC_DONE_EVENT", kOSBooleanTrue);
        setProperty("STA_ASSOC_DONE_RAW_STATE", (uint64_t)_ieee80211->rawState(), 32);
        setProperty("STA_ASSOC_DONE_VISIBLE", _ieee80211->associatedVisible() ? kOSBooleanTrue : kOSBooleanFalse);
        _netif->postMessage(APPLE80211_M_ASSOC_DONE);
        break;
    case kRTW88EventDeauth:
        setProperty("STA_DEAUTH_EVENT", kOSBooleanTrue);
        if (data) setProperty("STA_DEAUTH_REASON", (uint64_t)*(uint32_t *)data, 32);
        _netif->postMessage(APPLE80211_M_DEAUTH_RECEIVED);
        break;
    case kRTW88EventDisconnected:
        setProperty("STA_DISCONNECTED_EVENT", kOSBooleanTrue);
        _netif->postMessage(APPLE80211_M_LINK_CHANGED);
        break;
    case kRTW88EventConnected:
        // The legacy frontend already publishes connection readiness through
        // setLinkStatus(). This backend event is consumed by the native WCL
        // frontend, so deliberately do not post a duplicate legacy message.
        break;
    case kRTW88EventRSSIChanged:   _netif->postMessage(APPLE80211_M_LINK_QUALITY); break;
    default: break;
    }
}
