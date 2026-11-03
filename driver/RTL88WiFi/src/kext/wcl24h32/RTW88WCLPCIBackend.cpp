/* SPDX-License-Identifier: GPL-2.0-only
 * ABI-neutral PCI/MMIO/DMA owner for the native Sequoia WCL frontend.
 */
#include "RTW88WCLPCIBackend.hpp"

#include <IOKit/IOLib.h>
#include <libkern/c++/OSMetaClass.h>
#include <kern/thread.h>
#include <string.h>

extern "C" {
#include "../../compat/rtw88_compat.h"
void rtw88_trigger_interrupt(void);
boolean_t preemption_enabled(void);
}

#define super OSObject
OSDefineMetaClassAndStructors(RTW88WCLPCIBackend, OSObject)

bool RTW88WCLPCIBackend::init()
{
    if (!super::init())
        return false;
    _pciDev = nullptr;
    _mmioMap = nullptr;
    _mmioBase = nullptr;
    _interruptSource = nullptr;
    _workLoop = nullptr;
    _compatPciDev = nullptr;
    _client = nullptr;
    _dmaLock = nullptr;
    _pendingFreeLock = nullptr;
    _dmaList = nullptr;
    _dmaPendingFree = nullptr;
    _compatLeaseHeld = false;
    _compatInitialized = false;
    _opened = false;
    _radioRunning = false;
    return true;
}

IOReturn RTW88WCLPCIBackend::open(IOPCIDevice *provider,
                                  IOWorkLoop *workLoop,
                                  RTW88WCLPCIBackendClient *client)
{
    if (!provider || !workLoop)
        return kIOReturnBadArgument;
    if (_opened || _pciDev || _compatLeaseHeld)
        return kIOReturnBusy;

    _pciDev = provider;
    _pciDev->retain();
    _workLoop = workLoop;
    _workLoop->retain();
    _client = client;

    _dmaLock = IOSimpleLockAlloc();
    _pendingFreeLock = IOSimpleLockAlloc();
    if (!_dmaLock || !_pendingFreeLock) {
        closeResources();
        return kIOReturnNoMemory;
    }

    _pciDev->setMemoryEnable(true);
    _pciDev->setBusMasterEnable(true);
    const UInt16 enabledCommand = _pciDev->configRead16(kIOPCIConfigCommand);
    if ((enabledCommand & 0x0006U) != 0x0006U) {
        IOLog("rtl88wifi-wcl: PCI memory/bus-master enable failed (command=0x%04x)\n",
              enabledCommand);
        closeResources();
        return kIOReturnNotReady;
    }

    /* rtw88's PCI backend maps BAR2 (the Linux driver uses bar_id=2). */
    _mmioMap = _pciDev->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress2);
    if (!_mmioMap || !_mmioMap->getVirtualAddress() || !_mmioMap->getLength()) {
        IOLog("rtl88wifi-wcl: unable to map a usable BAR2\n");
        closeResources();
        return kIOReturnNoResources;
    }
    _mmioBase = reinterpret_cast<volatile void *>(_mmioMap->getVirtualAddress());

    _compatPciDev = static_cast<struct pci_dev *>(IOMallocZero(sizeof(*_compatPciDev)));
    if (!_compatPciDev) {
        closeResources();
        return kIOReturnNoMemory;
    }
    _compatPciDev->vendor = _pciDev->configRead16(0x00);
    _compatPciDev->device = _pciDev->configRead16(0x02);
    _compatPciDev->kext_dev = this;
    _compatPciDev->resource[2] = reinterpret_cast<resource_size_t>(_mmioBase);
    _compatPciDev->resource_len[2] = static_cast<resource_size_t>(_mmioMap->getLength());

    /* The compat layer has process-global callbacks, so acquire this lease
     * before publishing the function tables or starting its workqueues. */
    RTW88HwOps *expectedOwner = nullptr;
    if (!__atomic_compare_exchange_n(&g_pci_dev_instance, &expectedOwner,
                                     static_cast<RTW88HwOps *>(this), false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        IOLog("rtl88wifi-wcl: RTW88 compat hardware lease is already owned\n");
        closeResources();
        return kIOReturnBusy;
    }
    _compatLeaseHeld = true;
    rtw88_pci_io_ops = &_pci_io_ops;
    rtw88_dma_ops = &_dma_ops;

    const int compatStatus = rtw88_compat_init();
    if (compatStatus != 0) {
        IOLog("rtl88wifi-wcl: compat runtime initialization failed (%d)\n",
              compatStatus);
        closeResources();
        return kIOReturnNoResources;
    }
    _compatInitialized = true;

    _interruptSource = IOInterruptEventSource::interruptEventSource(
        this,
        OSMemberFunctionCast(IOInterruptEventSource::Action, this,
                             &RTW88WCLPCIBackend::handleInterrupt),
        _pciDev, 0);
    if (!_interruptSource ||
        _workLoop->addEventSource(_interruptSource) != kIOReturnSuccess) {
        IOLog("rtl88wifi-wcl: unable to register PCI interrupt event source\n");
        closeResources();
        return kIOReturnNoResources;
    }
    _interruptSource->disable();

    _opened = true;
    IOLog("rtl88wifi-wcl: PCI backend acquired %04x:%04x, BAR2=%p length=0x%llx\n",
          _compatPciDev->vendor, _compatPciDev->device, (void *)_mmioBase,
          static_cast<unsigned long long>(_mmioMap->getLength()));
    return kIOReturnSuccess;
}

IOReturn RTW88WCLPCIBackend::setRadioRunning(bool running)
{
    if (!_opened || !_pciDev || !_interruptSource)
        return kIOReturnNotReady;
    if (_radioRunning == running)
        return kIOReturnSuccess;

    if (running) {
        _pciDev->setMemoryEnable(true);
        _pciDev->setBusMasterEnable(true);
        const UInt16 command = _pciDev->configRead16(kIOPCIConfigCommand);
        if ((command & 0x0006U) != 0x0006U) {
            _interruptSource->disable();
            _pciDev->setBusMasterEnable(false);
            const UInt16 rollbackCommand = _pciDev->configRead16(kIOPCIConfigCommand);
            if (rollbackCommand & 0x0004U) {
                /* Bus mastering may still be active. Keep the backend marked
                 * running so close/free cannot reclaim DMA mappings. */
                _radioRunning = true;
                IOLog("rtl88wifi-wcl: partial PCI enable rollback failed (command=0x%04x); DMA resources quarantined\n",
                      rollbackCommand);
            } else {
                _radioRunning = false;
                _pciDev->setMemoryEnable(false);
            }
            return kIOReturnNotReady;
        }
        _radioRunning = true;
        _interruptSource->enable();
        return kIOReturnSuccess;
    }

    /* Caller contract: RTW88IEEE80211::stop() must already have synchronized
     * its interrupt/NAPI workers and stopped device DMA before this call. */
    _interruptSource->disable();
    _pciDev->setBusMasterEnable(false);
    const UInt16 command = _pciDev->configRead16(kIOPCIConfigCommand);
    if (command & 0x0004U) {
        IOLog("rtl88wifi-wcl: PCI bus-master fence did not stick (command=0x%04x)\n",
              command);
        return kIOReturnNotReady;
    }
    _radioRunning = false;
    if (preemption_enabled())
        drainPendingFree();
    return kIOReturnSuccess;
}

IOReturn RTW88WCLPCIBackend::close()
{
    if (_radioRunning)
        return kIOReturnBusy;
    closeResources();
    return kIOReturnSuccess;
}

void RTW88WCLPCIBackend::closeResources()
{
    if (_interruptSource) {
        _interruptSource->disable();
        if (_workLoop)
            _workLoop->removeEventSource(_interruptSource);
        _interruptSource->release();
        _interruptSource = nullptr;
    }

    /* Stop all compat work before reclaiming DMA buffers and releasing the
     * callbacks they may invoke. The RTW88 core must already be stopped. */
    if (_compatInitialized) {
        rtw88_compat_exit();
        _compatInitialized = false;
    }

    if (preemption_enabled())
        drainPendingFree();
    releaseDMAEntries();

    clearCompatLease();

    if (_pciDev) {
        _pciDev->setBusMasterEnable(false);
        _pciDev->setMemoryEnable(false);
    }
    if (_compatPciDev) {
        IOFree(_compatPciDev, sizeof(*_compatPciDev));
        _compatPciDev = nullptr;
    }
    if (_mmioMap) {
        _mmioMap->release();
        _mmioMap = nullptr;
    }
    _mmioBase = nullptr;

    if (_workLoop) {
        _workLoop->release();
        _workLoop = nullptr;
    }
    if (_pciDev) {
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

    _client = nullptr;
    _radioRunning = false;
    _opened = false;
}

void RTW88WCLPCIBackend::clearCompatLease()
{
    if (!_compatLeaseHeld)
        return;
    RTW88HwOps *expectedOwner = static_cast<RTW88HwOps *>(this);
    if (__atomic_compare_exchange_n(&g_pci_dev_instance, &expectedOwner,
                                    static_cast<RTW88HwOps *>(nullptr), false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        rtw88_pci_io_ops = nullptr;
        rtw88_dma_ops = nullptr;
    }
    _compatLeaseHeld = false;
}

void RTW88WCLPCIBackend::free()
{
    if (_pciDev) {
        if (_interruptSource)
            _interruptSource->disable();
        _pciDev->setBusMasterEnable(false);
        const UInt16 command = _pciDev->configRead16(kIOPCIConfigCommand);
        if (command & 0x0004U) {
            IOLog("rtl88wifi-wcl: PCI bus-master bit remains set (command=0x%04x); refusing to free DMA resources; backend quarantined\n",
                  command);
            /* Keep this object, DMA descriptors, MMIO map, locks, and PCI
             * reference alive until hardware bus mastering is demonstrably off. */
            return;
        }
    }
    _radioRunning = false;
    closeResources();
    super::free();
}

uint64_t RTW88WCLPCIBackend::mmioLength() const
{
    return _mmioMap ? static_cast<uint64_t>(_mmioMap->getLength()) : 0;
}

UInt8 RTW88WCLPCIBackend::pciReadByte(int offset)
{
    return _pciDev ? _pciDev->configRead8(static_cast<UInt8>(offset)) : 0xff;
}

UInt16 RTW88WCLPCIBackend::pciReadWord(int offset)
{
    return _pciDev ? _pciDev->configRead16(static_cast<UInt8>(offset)) : 0xffff;
}

UInt32 RTW88WCLPCIBackend::pciReadDword(int offset)
{
    return _pciDev ? _pciDev->configRead32(static_cast<UInt8>(offset)) : 0xffffffffU;
}

void RTW88WCLPCIBackend::pciWriteByte(int offset, UInt8 value)
{
    if (_pciDev) _pciDev->configWrite8(static_cast<UInt8>(offset), value);
}

void RTW88WCLPCIBackend::pciWriteWord(int offset, UInt16 value)
{
    if (_pciDev) _pciDev->configWrite16(static_cast<UInt8>(offset), value);
}

void RTW88WCLPCIBackend::pciWriteDword(int offset, UInt32 value)
{
    if (_pciDev) _pciDev->configWrite32(static_cast<UInt8>(offset), value);
}

int RTW88WCLPCIBackend::pciFindCapability(int capability)
{
    if (!_pciDev || capability < 0 || capability > 0xff)
        return 0;
    UInt8 offset = 0;
    return _pciDev->findPCICapability(static_cast<UInt8>(capability), &offset)
               ? static_cast<int>(offset) : 0;
}

void *RTW88WCLPCIBackend::allocCoherent(size_t size,
                                         IOPhysicalAddress *physical)
{
    if (physical) *physical = 0;
    if (!size || !_compatLeaseHeld || !_dmaLock || !_pendingFreeLock)
        return nullptr;
    if (preemption_enabled())
        drainPendingFree();

    IOBufferMemoryDescriptor *descriptor =
        IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task,
            kIOMemoryPhysicallyContiguous | kIODirectionInOut |
                kIOMemoryKernelUserShared,
            size, 0x00000000FFFFFFF0ULL);
    if (!descriptor)
        return nullptr;
    if (descriptor->prepare() != kIOReturnSuccess) {
        descriptor->release();
        return nullptr;
    }

    const IOPhysicalAddress address = descriptor->getPhysicalAddress();
    void *virtualAddress = descriptor->getBytesNoCopy();
    if (!virtualAddress || !address) {
        descriptor->complete();
        descriptor->release();
        return nullptr;
    }
    bzero(virtualAddress, size);

    RTW88DMAEntry *entry = static_cast<RTW88DMAEntry *>(IOMallocZero(sizeof(*entry)));
    if (!entry) {
        descriptor->complete();
        descriptor->release();
        return nullptr;
    }
    entry->desc = descriptor;
    entry->virt = virtualAddress;
    entry->phys = address;
    entry->size = size;

    IOSimpleLockLock(_dmaLock);
    entry->next = _dmaList;
    _dmaList = entry;
    IOSimpleLockUnlock(_dmaLock);
    if (physical) *physical = address;
    return virtualAddress;
}

void RTW88WCLPCIBackend::freeCoherent(size_t size, void *virtualAddress,
                                      IOPhysicalAddress physical)
{
    (void)size;
    (void)physical;
    if (!_dmaLock || !_pendingFreeLock || !virtualAddress)
        return;

    IOSimpleLockLock(_dmaLock);
    RTW88DMAEntry **previous = &_dmaList;
    RTW88DMAEntry *entry = _dmaList;
    while (entry && entry->virt != virtualAddress) {
        previous = &entry->next;
        entry = entry->next;
    }
    if (entry)
        *previous = entry->next;
    IOSimpleLockUnlock(_dmaLock);

    if (!entry) {
        IOLog("rtl88wifi-wcl: freeCoherent: unknown virtual address %p\n",
              virtualAddress);
        return;
    }
    if (preemption_enabled()) {
        freeDMAList(entry);
    } else {
        IOSimpleLockLock(_pendingFreeLock);
        entry->next = _dmaPendingFree;
        _dmaPendingFree = entry;
        IOSimpleLockUnlock(_pendingFreeLock);
    }
}

void RTW88WCLPCIBackend::freeCoherentByPhys(IOPhysicalAddress physical)
{
    if (!_dmaLock || !_pendingFreeLock || !physical)
        return;

    IOSimpleLockLock(_dmaLock);
    RTW88DMAEntry **previous = &_dmaList;
    RTW88DMAEntry *entry = _dmaList;
    while (entry && entry->phys != physical) {
        previous = &entry->next;
        entry = entry->next;
    }
    if (entry)
        *previous = entry->next;
    IOSimpleLockUnlock(_dmaLock);

    if (!entry)
        return;
    if (preemption_enabled()) {
        freeDMAList(entry);
    } else {
        IOSimpleLockLock(_pendingFreeLock);
        entry->next = _dmaPendingFree;
        _dmaPendingFree = entry;
        IOSimpleLockUnlock(_pendingFreeLock);
    }
}

void RTW88WCLPCIBackend::setBounceOrigVA(IOPhysicalAddress physical,
                                         void *originalAddress)
{
    if (!_dmaLock || !physical)
        return;
    IOSimpleLockLock(_dmaLock);
    for (RTW88DMAEntry *entry = _dmaList; entry; entry = entry->next) {
        if (entry->phys == physical) {
            entry->orig_va = originalAddress;
            break;
        }
    }
    IOSimpleLockUnlock(_dmaLock);
}

void RTW88WCLPCIBackend::syncBounceForCpu(IOPhysicalAddress dmaAddress,
                                          size_t size)
{
    if (!_dmaLock || !dmaAddress || !size)
        return;
    /* Keep the entry pinned by the list lock for the bounded copy; this avoids
     * racing a concurrent unmap/free against the original buffer pointer. */
    IOSimpleLockLock(_dmaLock);
    for (RTW88DMAEntry *entry = _dmaList; entry; entry = entry->next) {
        if (entry->phys == dmaAddress && entry->orig_va && entry->virt) {
            const size_t copyLength = size < entry->size ? size : entry->size;
            memcpy(entry->orig_va, entry->virt, copyLength);
            break;
        }
    }
    IOSimpleLockUnlock(_dmaLock);
}

void RTW88WCLPCIBackend::resumeTxIfStalled()
{
    if (_client)
        _client->rtw88WCLResumeTransmit();
}

void RTW88WCLPCIBackend::handleInterrupt(IOInterruptEventSource *source,
                                          int count)
{
    (void)source;
    (void)count;
    if (!_radioRunning || !g_pci_dev_instance ||
        __atomic_load_n(&g_pci_dev_instance, __ATOMIC_ACQUIRE) !=
            static_cast<RTW88HwOps *>(this))
        return;
    if (preemption_enabled())
        drainPendingFree();
    rtw88_trigger_interrupt();
}

void RTW88WCLPCIBackend::drainPendingFree()
{
    if (!_pendingFreeLock)
        return;
    IOSimpleLockLock(_pendingFreeLock);
    RTW88DMAEntry *list = _dmaPendingFree;
    _dmaPendingFree = nullptr;
    IOSimpleLockUnlock(_pendingFreeLock);
    freeDMAList(list);
}

void RTW88WCLPCIBackend::releaseDMAEntries()
{
    if (_dmaLock) {
        IOSimpleLockLock(_dmaLock);
        RTW88DMAEntry *list = _dmaList;
        _dmaList = nullptr;
        IOSimpleLockUnlock(_dmaLock);
        freeDMAList(list);
    }
    if (_pendingFreeLock) {
        IOSimpleLockLock(_pendingFreeLock);
        RTW88DMAEntry *pending = _dmaPendingFree;
        _dmaPendingFree = nullptr;
        IOSimpleLockUnlock(_pendingFreeLock);
        freeDMAList(pending);
    }
}

void RTW88WCLPCIBackend::freeDMAList(RTW88DMAEntry *list)
{
    while (list) {
        RTW88DMAEntry *next = list->next;
        if (list->desc) {
            list->desc->complete();
            list->desc->release();
        }
        IOFree(list, sizeof(*list));
        list = next;
    }
}

#undef super
