/* SPDX-License-Identifier: GPL-2.0-only
 * Sequoia 24H32 native IO80211Controller with staged backend ownership.
 */
#include "RTW88WCLController.hpp"
#include "RTW88WCL24H32InterfaceABI.hpp"
#include "RTW88WCLSkywalkQueues.hpp"
#include "RTW88WCLSkywalkRxAdapter.hpp"
#include "RTW88WCLSkywalkTxAdapter.hpp"
#include "RTW88WCLTxCompletionWorkQueue.hpp"
#include "RTW88WCLInfraInterface.hpp"
#include "../RTW88IEEE80211.hpp"

extern "C" {
#include "../../compat/rtw88_compat.h"
}

#include <IOKit/pci/IOPCIDevice.h>

#include <IOKit/IOLib.h>
#include <IOKit/network/IOOutputQueue.h>
#include <libkern/c++/OSMetaClass.h>

/* Exact macOS 15.8.1 (24H32) IO80211WorkQueue factory exported by
 * com.apple.iokit.IO80211Family. The returned object derives from
 * IOWorkLoop; the asm label preserves Apple's exact C++ symbol ABI while
 * avoiding a locally invented IO80211WorkQueue class/vtable declaration. */
extern "C" IOWorkLoop *rtw88wclCreateIO80211WorkQueue(void)
    __asm__("__ZN16IO80211WorkQueue9workQueueEv");

#define super IO80211Controller
OSDefineMetaClassAndStructors(RTW88WCLController, IO80211Controller)

bool RTW88WCLController::init(OSDictionary *properties)
{
    if (!super::init(properties))
        return false;
    _workQueue = nullptr;
    _workLoop = nullptr;
    _packetPathInterface = nullptr;
    _packetPathState = kPacketPathDisabled;
    _packetPathInFlight = 0;
    _pciBackend = nullptr;
    _skywalkQueues = nullptr;
    _infraInterface = nullptr;
    _rxAdapter = nullptr;
    _txAdapter = nullptr;
    _txCompletionWorker = nullptr;
    _txAdapterBoundToQueues = false;
    _stagedRxPackets.reset();
    _radio = nullptr;
    _baseStarted = false;
    _radioStarted = false;
    return true;
}

bool RTW88WCLController::createWorkQueue()
{
    if (_workQueue)
        return true;

    IOWorkLoop *queue = rtw88wclCreateIO80211WorkQueue();
    if (!queue)
        return false;

    /* The factory returns an IO80211WorkQueue, a single-inheritance
     * IOWorkLoop subclass. This controller owns the factory's initial
     * reference; getWorkQueue() lends it to IO80211Controller. */
    _workQueue = reinterpret_cast<IO80211WorkQueue *>(queue);
    return true;
}

IO80211WorkQueue *RTW88WCLController::getWorkQueue() const
{
    return _workQueue;
}

bool RTW88WCLController::createWorkLoop()
{
    if (_workLoop)
        return true;
    _workLoop = IOWorkLoop::workLoop();
    return _workLoop != nullptr;
}

IOWorkLoop *RTW88WCLController::getWorkLoop() const
{
    return _workLoop;
}

bool RTW88WCLController::start(IOService *provider)
{
    if (!provider || _baseStarted || _pciBackend || _radio)
        return false;

    /* The Apple base start path immediately asks getWorkQueue() while
     * creating its command gate and PostOffice. Acquire the exact 24H32
     * queue before entering that base start path. */
    if (!createWorkQueue()) {
        IOLog("rtl88wifi-wcl: IO80211WorkQueue factory failed\n");
        return false;
    }
    if (!super::start(provider))
        return false;
    _baseStarted = true;

    /* Stage A: the controller workloop must exist before acquiring a PCI
     * backend or registering any interrupt source. */
    if (!createWorkLoop()) {
        IOLog("rtl88wifi-wcl: controller workloop creation failed\n");
        goto fail;
    }

    /* Stage B: this native personality must be matched directly to a PCI
     * provider. The backend retains it and owns BAR2/MMIO/DMA resources. */
    {
        IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
        if (!pci) {
            IOLog("rtl88wifi-wcl: provider is not an IOPCIDevice\n");
            goto fail;
        }

        _pciBackend = new RTW88WCLPCIBackend;
        if (!_pciBackend) {
            IOLog("rtl88wifi-wcl: PCI backend allocation failed\n");
            goto fail;
        }
        if (!_pciBackend->init()) {
            _pciBackend->release();
            _pciBackend = nullptr;
            IOLog("rtl88wifi-wcl: PCI backend initialization failed\n");
            goto fail;
        }

        const IOReturn openStatus = _pciBackend->open(pci, _workLoop, this);
        if (openStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: PCI backend open failed: 0x%08x\n",
                  openStatus);
            goto fail;
        }

        /* Stage C: instantiate the RTW88 state machine against the backend's
         * compat pci_dev. This installs callback context and allocates its
         * private timers/workloop only; it does not probe or power the chip. */
        struct pci_dev *compatPCI = _pciBackend->compatPCIDevice();
        if (!compatPCI) {
            IOLog("rtl88wifi-wcl: backend did not provide a compat PCI device\n");
            goto fail;
        }
        RTW88IEEE80211 *radio = RTW88IEEE80211::createAirport(this, compatPCI);
        if (!radio) {
            IOLog("rtl88wifi-wcl: RTW88 state-machine allocation failed\n");
            goto fail;
        }
        /* The interface's workloop bridge takes radio-event ownership after
         * the native WCL event queue is initialized. */
        const IOReturn bindStatus = bindRadioBackend(radio);
        radio->release();
        if (bindStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: RTW88 state-machine bind failed: 0x%08x\n",
                  bindStatus);
            goto fail;
        }
    }

    /* Stage D: reserve native Skywalk queue/pool objects while the PCI and
     * RTW88 owners are still available for orderly unwind. Queue scheduling
     * remains owned by Apple's 24H32 registration helper until the infra
     * interface commits its queue transaction. */
    _skywalkQueues = new RTW88WCLSkywalkQueues;
    if (!_skywalkQueues || !_skywalkQueues->init()) {
        if (_skywalkQueues) {
            _skywalkQueues->release();
            _skywalkQueues = nullptr;
        }
        IOLog("rtl88wifi-wcl: Skywalk queue owner allocation failed\n");
        goto fail;
    }
    {
        const IOReturn queueStatus = _skywalkQueues->createQueues();
        if (queueStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: Skywalk queue/pool allocation failed: 0x%08x\n",
                  queueStatus);
            goto fail;
        }
    }

    /* Stage91: bind the TX adapter to the controller's RTW88 owner and the
     * exact TX pool that backs all four WMM submission queues, then retain it
     * in the queue owner as callback context. No queue registration, enable,
     * event-source attachment, or radio start occurs in this stage. */
    _txAdapter = new RTW88WCLSkywalkTxAdapter;
    if (!_txAdapter || !_txAdapter->init()) {
        if (_txAdapter) {
            _txAdapter->release();
            _txAdapter = nullptr;
        }
        IOLog("rtl88wifi-wcl: TX adapter allocation failed\n");
        goto fail;
    }
    {
        const IOReturn adapterStatus =
            _txAdapter->bind(_radio, _skywalkQueues->txPacketPool());
        if (adapterStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: TX adapter bind failed: 0x%08x\n",
                  adapterStatus);
            goto fail;
        }
        const IOReturn queueBindStatus =
            _skywalkQueues->bindTXAdapter(_txAdapter);
        if (queueBindStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: TX callback-owner bind failed: 0x%08x\n",
                  queueBindStatus);
            goto fail;
        }
        _txAdapterBoundToQueues = true;
    }

    /* Stage92: RTW88 completion callbacks only publish ticket state and signal
     * this controller-workloop consumer. The serialized consumer uses the
     * target 24H32 synchronous TX-completion queue API; no Skywalk packet method
     * is invoked in the backend callback context. */
    _txCompletionWorker = new RTW88WCLTxCompletionWorkQueue;
    if (!_txCompletionWorker ||
        !_txCompletionWorker->init(this, _workLoop, _txAdapter,
                                   _skywalkQueues->txCompletionQueue())) {
        if (_txCompletionWorker) {
            const IOReturn workerStopStatus = _txCompletionWorker->stop();
            if (workerStopStatus == kIOReturnSuccess) {
                _txCompletionWorker->release();
                _txCompletionWorker = nullptr;
            } else {
                IOLog("rtl88wifi-wcl: partial TX completion worker cleanup deferred: 0x%08x\n",
                      workerStopStatus);
            }
        }
        IOLog("rtl88wifi-wcl: TX completion worker initialization failed\n");
        goto fail;
    }

    /* Stage E: bind the RX workloop consumer to the now-owned 4 KiB RX pool.
     * It copies received Ethernet frames into pool-backed Skywalk packets;
     * the sink accepts ownership only after native interface registration. */
    _rxAdapter = new RTW88WCLSkywalkRxAdapter;
    if (!_rxAdapter || !_rxAdapter->init(
            this, _workLoop, _skywalkQueues->rxPacketPool(),
            &RTW88WCLController::stagedRxFrame, this)) {
        if (_rxAdapter) {
            _rxAdapter->release();
            _rxAdapter = nullptr;
        }
        IOLog("rtl88wifi-wcl: RX packet adapter initialization failed\n");
        goto fail;
    }

    {
    /* Probe the RTW88 core before constructing the interface so the real
     * eFuse MAC and PHY capabilities are available to 24H32 RegistrationInfo.
     * PCI interrupts remain masked until all Skywalk queues are registered. */
    const IOReturn radioStatus = _radio->start();
    if (radioStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: RTW88 probe/start failed: 0x%08x\n", radioStatus);
        goto fail;
    }
    _radioStarted = true;

    ether_addr address = {};
    _radio->getMACAddress(address.octet);
    uint8_t addressBits = 0;
    for (unsigned i = 0; i < sizeof(address.octet); ++i)
        addressBits |= address.octet[i];
    if (addressBits == 0 || (address.octet[0] & 0x01)) {
        IOLog("rtl88wifi-wcl: probed RTW88 MAC is not a valid unicast address\n");
        goto fail;
    }

    _infraInterface = new RTW88WCLInfraInterface;
    if (!_infraInterface || !_infraInterface->init(this, &address)) {
        if (_infraInterface) {
            _infraInterface->release();
            _infraInterface = nullptr;
        }
        IOLog("rtl88wifi-wcl: native IO80211InfraProtocol allocation/init failed\n");
        goto fail;
    }
    if (!_infraInterface->attach(this)) {
        _infraInterface->release();
        _infraInterface = nullptr;
        IOLog("rtl88wifi-wcl: failed to attach native infra protocol to controller\n");
        goto fail;
    }
    if (!_infraInterface->start(this)) {
        IOLog("rtl88wifi-wcl: native 24H32 Skywalk interface registration failed\n");
        goto fail;
    }

    _infraInterface->registerService();

    const IOReturn interruptStatus = _pciBackend->setRadioRunning(true);
    if (interruptStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: PCI interrupt activation failed: 0x%08x\n",
              interruptStatus);
        goto fail;
    }

    }

    provider->setProperty("RTW88WCLControllerStage",
                          "24H32 native infrastructure interface registered; Skywalk queues active");
    IOLog("rtl88wifi-wcl: native 24H32 infrastructure interface published\n");
    return true;

fail:
    {
        const IOReturn cleanupStatus = releaseNativeResources();
        if (cleanupStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: start-failure cleanup incomplete (0x%08x); retaining native resources\n",
                  cleanupStatus);
            return false;
        }
    }
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
    return false;
}

void RTW88WCLController::stop(IOService *provider)
{
    const IOReturn cleanupStatus = releaseNativeResources();
    if (cleanupStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: stop cleanup incomplete (0x%08x); deferring superclass stop and retaining resources\n",
              cleanupStatus);
        return;
    }
    if (_baseStarted) {
        super::stop(provider);
        _baseStarted = false;
    }
}

IOReturn RTW88WCLController::releaseNativeResources()
{
    const IOReturn packetPathStatus = quiescePacketPath();
    if (packetPathStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: packet path quiesce deferred: 0x%08x\n",
              packetPathStatus);
        return packetPathStatus; // Keep the radio, interface and PCI callbacks alive.
    }

    /* Close TX callback admission before stopping RTW88. If a Skywalk
     * submission callback is still copying/reserving a completion ticket,
     * keep the radio and PCI callback context alive and retry teardown after
     * that bounded callback leaves. */
    if (_txAdapter) {
        const IOReturn txQuiesceStatus = _txAdapter->quiesceSubmissions();
        if (txQuiesceStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: TX submission callback quiesce deferred: 0x%08x\n",
                  txQuiesceStatus);
            return txQuiesceStatus;
        }
    }

    /* Stop the RTW88 RX/TX producer before removing its deferred consumers or
     * disabling PCI interrupts. The radio has been probed and started only
     * after its native interface's complete queue-registration preflight. */
    if (_radio && _radioStarted) {
        _radio->stop();
        _radioStarted = false;
    }

    if (_pciBackend && _pciBackend->isRadioRunning()) {
        const IOReturn fenceStatus = _pciBackend->setRadioRunning(false);
        if (fenceStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: PCI interrupt/bus-master fence failed: 0x%08x\n",
                  fenceStatus);
            return fenceStatus; // Keep callbacks, mappings and DMA owner alive on failure.
        }
    }

    /* RTW88 and the PCI interrupt/DMA producer are stopped. Close and join
     * the entire TX-status callback before draining its deferred skb frees;
     * kfree_skb may itself retire a WCL completion token, so the completion
     * worker must remain alive during this final generic skb drain.
     */
    if (_pciBackend) {
        rtw88_compat_quiesce_tx_status();
        if (!rtw88_compat_quiesce_skb_free_reaper()) {
            IOLog("rtl88wifi-wcl: generic deferred skb reaper did not drain; retaining owners\n");
            return kIOReturnBusy;
        }
    }

    /* The generic skb drain may publish final WCL tokens/completions. Only
     * now can adapter unbind prove every ticket and backend callback returned.
     */
    if (_txAdapter) {
        const IOReturn txUnbindStatus = _txAdapter->unbind();
        if (txUnbindStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: TX adapter completion drain deferred: 0x%08x\n",
                  txUnbindStatus);
            return txUnbindStatus;
        }
    }

    /* Remove the notifier/event source only after the callback quiescence
     * proof, while the completion queue owner is still retained. */
    if (_txCompletionWorker) {
        const IOReturn workerStopStatus = _txCompletionWorker->stop();
        if (workerStopStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: completion worker stop deferred: 0x%08x\n",
                  workerStopStatus);
            return workerStopStatus;
        }
        _txCompletionWorker->release();
        _txCompletionWorker = nullptr;
    }

    if (_txAdapter) {
        if (_txAdapterBoundToQueues) {
            if (!_skywalkQueues) {
                IOLog("rtl88wifi-wcl: TX adapter queue owner missing during detach\n");
                return kIOReturnNotReady;
            }
            const IOReturn detachStatus =
                _skywalkQueues->unbindTXAdapter(_txAdapter);
            if (detachStatus != kIOReturnSuccess) {
                IOLog("rtl88wifi-wcl: TX adapter callback detach deferred: 0x%08x\n",
                      detachStatus);
                return detachStatus;
            }
            _txAdapterBoundToQueues = false;
        }
        _txAdapter->release();
        _txAdapter = nullptr;
    }

    /* Remove the RX workloop source only after the RTW88 producer is stopped.
     * stop() waits out an active checkForWork() and releases all staged mbufs. */
    if (_rxAdapter) {
        _rxAdapter->stop();
        _rxAdapter->release();
        _rxAdapter = nullptr;
    }

    /* Return any packets retained by an earlier partial RX handoff while the
     * pool still exists. On a pool error, retain the queue owner and PCI/backend
     * context so a later stop/free attempt can retry safely. */
    const IOReturn recycleStatus = recycleStagedRxPackets();
    if (recycleStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: staged RX packet recycle deferred: 0x%08x\n",
              recycleStatus);
        return recycleStatus;
    }

    /* RX staging and RTW88 producers are drained. Deregister the interface
     * before destroying any queue/pool that Apple now owns through its
     * QueueSet/LogicalLink. On failure retain the child and queue owner. */
    if (_infraInterface) {
        const IOReturn interfaceStatus =
            _infraInterface->shutdownForController();
        if (interfaceStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: native interface deregistration deferred: 0x%08x\n",
                  interfaceStatus);
            return interfaceStatus;
        }
        _infraInterface->detach(this);
        _infraInterface->release();
        _infraInterface = nullptr;
    }

    /* Skywalk packet pools/queues are released only after both the mbuf staging
     * adapter and the prepared-packet ownership ring have been drained. */
    if (_skywalkQueues) {
        _skywalkQueues->destroyQueues();
        if (!_skywalkQueues->resourcesReleased()) {
            IOLog("rtl88wifi-wcl: Skywalk queue/pool rollback incomplete; retaining radio and owner\n");
            return kIOReturnBusy;
        }
        _skywalkQueues->release();
        _skywalkQueues = nullptr;
    }

    

    /* RTW88IEEE80211 owns the compat callback context; destroy it before
     * rtw88_compat_exit() and before relinquishing the global hardware lease. */
    unbindRadioBackend();

    if (_pciBackend) {
        const IOReturn closeStatus = _pciBackend->close();
        if (closeStatus != kIOReturnSuccess) {
            IOLog("rtl88wifi-wcl: PCI backend close deferred: 0x%08x\n",
                  closeStatus);
            return closeStatus;
        }
        _pciBackend->release();
        _pciBackend = nullptr;
    }
    return kIOReturnSuccess;
}

void RTW88WCLController::free()
{
    const IOReturn cleanupStatus = releaseNativeResources();
    if (cleanupStatus != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: controller shutdown incomplete (0x%08x); quarantining controller and retaining workloop/resources\n",
              cleanupStatus);
        /* Do not release the workloop or call super::free() while any child,
         * packet pool, or PCI/DMA resource may still reference this controller.
         * This deliberately leaks the object rather than risking a UAF/DMA UAF. */
        return;
    }
    if (_workLoop) {
        _workLoop->release();
        _workLoop = nullptr;
    }
    /* The Apple base free path dismantles the PostOffice and timer sources.
     * Keep their borrowed work-queue pointer valid until that teardown has
     * completed, then release the factory-owned reference exactly once. */
    super::free();
    if (_workQueue) {
        reinterpret_cast<IOWorkLoop *>(_workQueue)->release();
        _workQueue = nullptr;
    }
}

bool RTW88WCLController::isCommandProhibited(int command)
{
    (void)command;
    /* Do not dispatch WCL commands into a partially constructed controller.
     * Once the 24H32 infra child has registered, the protocol adapter handles
     * the implemented selectors and explicitly rejects the remaining ones. */
    return !_infraInterface || !_infraInterface->isRegistered();
}

SInt32 RTW88WCLController::handleCardSpecific(IO80211SkywalkInterface *interface,
                                               unsigned long command,
                                               void *data, bool set)
{
    (void)interface; (void)command; (void)data; (void)set;
    return kIOReturnUnsupported;
}

IOReturn RTW88WCLController::getDRIVER_VERSION(IO80211SkywalkInterface *interface,
                                                apple80211_version_data *data)
{
    (void)interface;
    if (!data)
        return kIOReturnBadArgument;
    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    static const char version[] = "RTL88WiFi WCL 24H32 (development)";
    data->string_len = static_cast<uint16_t>(sizeof(version) - 1);
    memcpy(data->string, version, sizeof(version));
    return kIOReturnSuccess;
}

IOReturn RTW88WCLController::getHARDWARE_VERSION(IO80211SkywalkInterface *interface,
                                                  apple80211_version_data *data)
{
    (void)interface;
    if (data)
        bzero(data, sizeof(*data));
    return data ? kIOReturnNotReady : kIOReturnBadArgument;
}

IOReturn RTW88WCLController::getCARD_CAPABILITIES(IO80211SkywalkInterface *interface,
                                                   apple80211_capability_data *data)
{
    if (!data)
        return kIOReturnBadArgument;
    if (!_infraInterface || !_infraInterface->isRegistered() ||
        interface != _infraInterface)
        return kIOReturnNotReady;

    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    auto advertise = [data](apple80211_card_capability capability) {
        const unsigned bit = static_cast<unsigned>(capability);
        if (bit < sizeof(data->capabilities) * 8U)
            data->capabilities[bit / 8U] |=
                static_cast<uint8_t>(1U << (bit % 8U));
    };
    /* Conservative station-mode capabilities backed by the current RTW88
     * WCL implementation: WPA2/CCMP, power management and WMM. Do not expose
     * WEP, TKIP, IBSS, host-AP, monitor, or unimplemented offloads. */
    advertise(APPLE80211_CAP_AES_CCM);
    advertise(APPLE80211_CAP_PMGT);
    advertise(APPLE80211_CAP_WPA2);
    advertise(APPLE80211_CAP_WME);
    return kIOReturnSuccess;
}

IOReturn RTW88WCLController::getPOWER(IO80211SkywalkInterface *interface,
                                       apple80211_power_data *data)
{
    if (!data)
        return kIOReturnBadArgument;
    if (!_infraInterface || !_infraInterface->isRegistered() ||
        interface != _infraInterface)
        return kIOReturnNotReady;

    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    data->num_radios = 1;
    data->power_state[0] = _infraInterface->isInterfaceEnabled()
        ? APPLE80211_POWER_ON : APPLE80211_POWER_OFF;
    return kIOReturnSuccess;
}

IOReturn RTW88WCLController::setPOWER(IO80211SkywalkInterface *interface,
                                       apple80211_power_data *data)
{
    if (!data)
        return kIOReturnBadArgument;
    if (!_infraInterface || !_infraInterface->isRegistered() ||
        interface != _infraInterface)
        return kIOReturnNotReady;
    if (data->num_radios != 1)
        return kIOReturnBadArgument;

    switch (data->power_state[0]) {
    case APPLE80211_POWER_ON:
        return _infraInterface->enable(0);
    case APPLE80211_POWER_OFF:
        return _infraInterface->disable(0);
    default:
        return kIOReturnBadArgument;
    }
}

IOReturn RTW88WCLController::getCOUNTRY_CODE(IO80211SkywalkInterface *interface,
                                              apple80211_country_code_data *data)
{
    (void)interface;
    if (!data)
        return kIOReturnBadArgument;
    bzero(data, sizeof(*data));
    data->version = APPLE80211_VERSION;
    return kIOReturnNotReady;
}

IOReturn RTW88WCLController::setCOUNTRY_CODE(IO80211SkywalkInterface *interface,
                                              apple80211_country_code_data *data)
{
    (void)interface;
    return data ? kIOReturnNotReady : kIOReturnBadArgument;
}

IOReturn RTW88WCLController::setGET_DEBUG_INFO(IO80211SkywalkInterface *interface,
                                                apple80211_debug_command *data)
{
    (void)interface;
    return data ? kIOReturnUnsupported : kIOReturnBadArgument;
}

CCLogStream *RTW88WCLController::getLogger() const
{
    return nullptr;
}

CommonFaultReporter *RTW88WCLController::getFaultReporterFromDriver()
{
    return nullptr;
}


bool RTW88WCLController::enterPacketPath()
{
    if (__atomic_load_n(&_packetPathState, __ATOMIC_ACQUIRE) !=
        kPacketPathActive)
        return false;

    __atomic_add_fetch(&_packetPathInFlight, 1U, __ATOMIC_ACQ_REL);
    if (__atomic_load_n(&_packetPathState, __ATOMIC_ACQUIRE) ==
        kPacketPathActive)
        return true;

    __atomic_sub_fetch(&_packetPathInFlight, 1U, __ATOMIC_ACQ_REL);
    return false;
}

void RTW88WCLController::leavePacketPath()
{
    __atomic_sub_fetch(&_packetPathInFlight, 1U, __ATOMIC_ACQ_REL);
}

IOReturn RTW88WCLController::activatePacketPath(
    IO80211SkywalkInterface *interface)
{
    if (!interface)
        return kIOReturnBadArgument;
    if (!_radio || !_radioStarted || !_pciBackend || !_pciBackend->isOpen())
        return kIOReturnNotReady;

    uint32_t expected = kPacketPathDisabled;
    if (!__atomic_compare_exchange_n(&_packetPathState, &expected,
                                     kPacketPathBinding, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        return kIOReturnBusy;

    interface->retain();
    _packetPathInterface = interface;
    __atomic_store_n(&_packetPathState, kPacketPathActive, __ATOMIC_RELEASE);
    IOLog("rtl88wifi-wcl: native mbuf packet handoff enabled\n");
    return kIOReturnSuccess;
}

IOReturn RTW88WCLController::quiescePacketPath()
{
    for (;;) {
        uint32_t state = __atomic_load_n(&_packetPathState, __ATOMIC_ACQUIRE);
        if (state == kPacketPathDisabled)
            return kIOReturnSuccess;
        if (state == kPacketPathBinding)
            return kIOReturnBusy;
        if (state == kPacketPathActive) {
            uint32_t expected = kPacketPathActive;
            if (!__atomic_compare_exchange_n(&_packetPathState, &expected,
                                             kPacketPathQuiescing, false,
                                             __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
                continue;
        } else if (state != kPacketPathQuiescing) {
            return kIOReturnBusy;
        }
        break;
    }

    if (__atomic_load_n(&_packetPathInFlight, __ATOMIC_ACQUIRE) != 0)
        return kIOReturnBusy;

    uint32_t expected = kPacketPathQuiescing;
    if (!__atomic_compare_exchange_n(&_packetPathState, &expected,
                                     kPacketPathReleasing, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        return kIOReturnBusy;

    IO80211SkywalkInterface *interface = _packetPathInterface;
    _packetPathInterface = nullptr;
    if (interface)
        interface->release();
    __atomic_store_n(&_packetPathState, kPacketPathDisabled, __ATOMIC_RELEASE);
    return kIOReturnSuccess;
}

UInt32 RTW88WCLController::outputPacket(mbuf_t packet, void *param)
{
    (void)param;
    if (!packet)
        return kIOReturnOutputDropped;

    if (!enterPacketPath()) {
        mbuf_freem(packet);
        return kIOReturnOutputDropped;
    }

    /* RTW88IEEE80211::outputPacket consumes the mbuf on every return path. */
    const UInt32 result = _radio ? _radio->outputPacket(packet)
                                 : kIOReturnOutputDropped;
    leavePacketPath();
    return result;
}

void RTW88WCLController::rtw88WCLResumeTransmit()
{
    if (!_skywalkQueues || !_skywalkQueues->isRegistered())
        return;

    /* RTW88 calls this when its hardware/software TX queues can accept more
     * work. Ask each registered WMM Skywalk queue to resume asynchronous
     * dequeue; a busy result means that queue already has a wake pending. */
    const IOReturn status = _skywalkQueues->requestTXSubmissionDequeue();
    if (status != kIOReturnSuccess && status != kIOReturnBusy &&
        status != kIOReturnNotReady)
        IOLog("rtl88wifi-wcl: WMM TX dequeue resume request failed: 0x%08x\n",
              status);
}

void RTW88WCLController::rtw88Event(RTW88Event event, void *data)
{
    (void)event;
    (void)data;
    /* WCL notifications are withheld until interface registration succeeds. */
}

mbuf_t RTW88WCLController::allocateInputPacket(uint32_t length)
{
    if (length < 14 || length > RTW88WCLSkywalkRxAdapter::kMaximumFrameLength ||
        !_radio || !_rxAdapter || !enterPacketPath())
        return nullptr;

    /* IO80211Controller inherits the IONetworkController packet allocator.
     * Keep its mbuf metadata initialization rather than hand-rolling m_len. */
    mbuf_t packet = allocatePacket(length);
    leavePacketPath();
    return packet;
}

void RTW88WCLController::injectRxFrame(mbuf_t packet)
{
    if (!packet)
        return;

    if (!_rxAdapter || !enterPacketPath()) {
        mbuf_freem(packet);
        return;
    }

    /* enqueueFrame consumes the mbuf on both success and failure. The
     * workloop sink rejects packets until both the queue-owner transaction
     * and InfraProtocol registration have committed; after that it transfers
     * accepted pool-backed packets into the 24H32 networking RX path. */
    (void)_rxAdapter->enqueueFrame(packet);
    leavePacketPath();
}

IOReturn RTW88WCLController::recycleStagedRxPackets()
{
    if (_stagedRxPackets.empty())
        return kIOReturnSuccess;
    if (!_skywalkQueues || !_skywalkQueues->rxPacketPool())
        return kIOReturnNotReady;

    IOSkywalkPacketBufferPool *pool = _skywalkQueues->rxPacketPool();
    IOSkywalkPacket *packet = nullptr;
    bool disposalRequired = false;
    while (_stagedRxPackets.pop(&packet)) {
        if (!packet)
            continue;

        const IOReturn status = pool->deallocatePacket(packet);
        if (status != kIOReturnSuccess) {
            /* The radio and RX event source are already quiesced, and these
             * queues were never registered. If a packet cannot be returned
             * individually, dispose the pool's packet set as one teardown
             * operation before its memory segments are released. */
            IOLog("rtl88wifi-wcl: RX packet recycle returned 0x%08x; pool disposal required\n",
                  status);
            disposalRequired = true;
        }
        packet = nullptr;
    }

    if (disposalRequired)
        pool->disposeAllPackets();
    return kIOReturnSuccess;
}

bool RTW88WCLController::stagedRxFrame(
    IOSkywalkPacket *preparedPacket, void *context)
{
    auto *self = static_cast<RTW88WCLController *>(context);
    if (!self || !preparedPacket)
        return false;

    if (!self->_skywalkQueues ||
        !self->_skywalkQueues->isRegistered() ||
        !self->_infraInterface ||
        !self->_infraInterface->isRegistered())
        return false;

    /* This helper's 24H32 return is a UInt32 accepted-buffer count, not an
     * IOReturn. RX pool packets are single-buffer by construction. A result
     * of one transfers the packet to the network-facing receive path; zero
     * leaves ownership with this adapter, which returns it to the RX pool. */
    const UInt32 accepted =
        self->_skywalkQueues->enqueueRXPacketForNetworking(preparedPacket);
    return accepted == 1;
}

IOWorkLoop *RTW88WCLController::getRxWorkLoop()
{
    return _workLoop;
}

void RTW88WCLController::setLinkStatus(UInt32 status)
{
    (void)status;
    /* Link state is owned by IO80211InfraProtocol after Skywalk attachment. */
}

IOReturn RTW88WCLController::bindRadioBackend(RTW88IEEE80211 *radio)
{
    if (!radio) return kIOReturnBadArgument;
    if (_radio) return kIOReturnBusy;
    radio->retain();
    _radio = radio;
    return kIOReturnSuccess;
}

void RTW88WCLController::unbindRadioBackend()
{
    if (_radio) {
        _radio->release();
        _radio = nullptr;
    }
}

