/* SPDX-License-Identifier: GPL-2.0-only
 * ABI-neutral PCI/MMIO/DMA owner for the native Sequoia WCL frontend.
 *
 * This class intentionally knows nothing about IO80211Controller or any
 * IO80211Family ABI. It owns the IOKit PCI resources consumed by the common
 * RTW88 core and exposes them through RTW88HwOps. The native controller owns
 * this object and must stop RTW88IEEE80211 before setRadioRunning(false) and
 * close().
 */
#pragma once

#include "../RTW88IEEE80211.hpp"

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOInterruptEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOLocks.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSObject.h>

class RTW88WCLPCIBackendClient {
public:
    virtual void rtw88WCLResumeTransmit() = 0;
    virtual ~RTW88WCLPCIBackendClient() {}
};

class RTW88WCLPCIBackend final : public OSObject, public RTW88HwOps {
    OSDeclareDefaultStructors(RTW88WCLPCIBackend)

public:
    bool init() override;
    void free() override;

    /* Acquires one process-wide RTW88 compat-hardware lease. This is
     * deliberately exclusive: the legacy controller and a native WCL
     * controller must never drive the same global rtw88 compat callbacks. */
    IOReturn open(IOPCIDevice *provider, IOWorkLoop *workLoop,
                  RTW88WCLPCIBackendClient *client = nullptr);

    /* The caller must first stop RTW88IEEE80211 so it can no longer issue
     * MMIO/DMA operations. close() refuses to tear down a running radio. */
    IOReturn close();
    IOReturn setRadioRunning(bool running);

    bool isOpen() const { return _opened; }
    bool isRadioRunning() const { return _radioRunning; }
    IOPCIDevice *pciDevice() const { return _pciDev; } // borrowed
    struct pci_dev *compatPCIDevice() const { return _compatPciDev; } // borrowed
    uint64_t mmioLength() const;

    UInt8 pciReadByte(int offset) override;
    UInt16 pciReadWord(int offset) override;
    UInt32 pciReadDword(int offset) override;
    void pciWriteByte(int offset, UInt8 value) override;
    void pciWriteWord(int offset, UInt16 value) override;
    void pciWriteDword(int offset, UInt32 value) override;
    int pciFindCapability(int capability) override;
    volatile void *mmioBase() const override { return _mmioBase; }
    void *allocCoherent(size_t size, IOPhysicalAddress *physical) override;
    void freeCoherent(size_t size, void *virtualAddress,
                      IOPhysicalAddress physical) override;
    void freeCoherentByPhys(IOPhysicalAddress physical) override;
    void setBounceOrigVA(IOPhysicalAddress physical, void *originalAddress) override;
    void syncBounceForCpu(IOPhysicalAddress dmaAddress, size_t size) override;
    void resumeTxIfStalled() override;

private:
    static void freeDMAList(RTW88DMAEntry *list);
    void drainPendingFree();
    void releaseDMAEntries();
    void handleInterrupt(IOInterruptEventSource *source, int count);
    void clearCompatLease();
    bool closeResources();

    IOPCIDevice *_pciDev = nullptr;                // retained
    IOMemoryMap *_mmioMap = nullptr;               // retained
    volatile void *_mmioBase = nullptr;
    IOInterruptEventSource *_interruptSource = nullptr;
    IOWorkLoop *_workLoop = nullptr;               // retained
    struct pci_dev *_compatPciDev = nullptr;
    RTW88WCLPCIBackendClient *_client = nullptr;   // non-owning

    IOSimpleLock *_dmaLock = nullptr;
    IOSimpleLock *_pendingFreeLock = nullptr;
    RTW88DMAEntry *_dmaList = nullptr;
    RTW88DMAEntry *_dmaPendingFree = nullptr;

    bool _compatLeaseHeld = false;
    bool _compatInitialized = false;
    bool _opened = false;
    bool _radioRunning = false;
};
