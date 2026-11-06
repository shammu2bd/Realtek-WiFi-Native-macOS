/* SPDX-License-Identifier: GPL-2.0-only
 * First native WCL controller slice for Sequoia 24H32.
 *
 * This controller remains isolated from the active legacy Kext. It owns the
 * native PCI backend and RTW88 state-machine object, but deliberately does
 * not start the radio or publish an interface until the Skywalk datapath is
 * complete.
 */
#pragma once

#include "RTW88WCL24H32ABI.hpp"
#include "RTW88WCLPCIBackend.hpp"
#include "RTW88WCLMbufRing.hpp"
#include <IOKit/IOWorkLoop.h>

class RTW88IEEE80211;
class RTW88WCLSkywalkQueues;
class RTW88WCLSkywalkRxAdapter;
class RTW88WCLSkywalkTxAdapter;
class RTW88WCLTxCompletionWorkQueue;
class RTW88WCLInfraInterface;
class IOSkywalkPacket;

class RTW88WCLController final : public IO80211Controller,
                                 public RTW88WCLPCIBackendClient,
                                 public RTW88EventDelegate,
                                 public RTW88RxDelegate {
    OSDeclareDefaultStructors(RTW88WCLController)

public:
    bool init(OSDictionary *properties) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;
    bool createWorkLoop() override;
    IOWorkLoop *getWorkLoop() const override;

    /* Native Ethernet mbuf handoff seam. Skywalk queue callbacks must call these
     * only after their packet rings are registered and the radio is started. */
    UInt32 outputPacket(mbuf_t packet, void *param) override;
    IOReturn activatePacketPath(IO80211SkywalkInterface *interface);
    IOReturn quiescePacketPath();

    /* Required pure virtuals in the 24H32 IO80211Controller ABI. Command and
     * power operations remain closed until the native infra interface and its
     * Skywalk registration transaction have committed. */
    bool isCommandProhibited(int command) override;
    SInt32 handleCardSpecific(IO80211SkywalkInterface *interface,
                              unsigned long command, void *data,
                              bool set) override;
    IOReturn getDRIVER_VERSION(IO80211SkywalkInterface *interface,
                               apple80211_version_data *data) override;
    IOReturn getHARDWARE_VERSION(IO80211SkywalkInterface *interface,
                                 apple80211_version_data *data) override;
    IOReturn getCARD_CAPABILITIES(IO80211SkywalkInterface *interface,
                                  apple80211_capability_data *data) override;
    IOReturn getPOWER(IO80211SkywalkInterface *interface,
                      apple80211_power_data *data) override;
    IOReturn setPOWER(IO80211SkywalkInterface *interface,
                      apple80211_power_data *data) override;
    IOReturn getCOUNTRY_CODE(IO80211SkywalkInterface *interface,
                             apple80211_country_code_data *data) override;
    IOReturn setCOUNTRY_CODE(IO80211SkywalkInterface *interface,
                             apple80211_country_code_data *data) override;
    IOReturn setGET_DEBUG_INFO(IO80211SkywalkInterface *interface,
                               apple80211_debug_command *data) override;
    CCLogStream *getLogger() const override;
    CommonFaultReporter *getFaultReporterFromDriver() override;

    IOReturn bindRadioBackend(RTW88IEEE80211 *radio);
    void unbindRadioBackend();
    RTW88IEEE80211 *radioBackend() const { return _radio; }
    RTW88WCLPCIBackend *pciBackend() const { return _pciBackend; }
    RTW88WCLSkywalkQueues *skywalkQueues() const { return _skywalkQueues; }

    /* RTW88WCLPCIBackendClient: resume the registered native WMM submission path
     * when RTW88 reopens its software TX queues. */
    void rtw88WCLResumeTransmit() override;

    /* Legacy controller delegate surface. The active native path installs
     * RTW88WCLRadioBridge as the radio event delegate and posts events from the
     * interface-owned workloop. */
    void rtw88Event(RTW88Event event, void *data) override;

    /* RTW88RxDelegate: receive mbufs enter the native RX workloop adapter,
     * become RX-pool Skywalk packets, and transfer to the network receive path
     * only after interface registration is committed. */
    mbuf_t allocateInputPacket(uint32_t length) override;
    void injectRxFrame(mbuf_t packet) override;
    IOWorkLoop *getRxWorkLoop() override;
    void setLinkStatus(UInt32 status) override;

private:
    IOReturn releaseNativeResources();
    IOReturn recycleStagedRxPackets();
    static bool stagedRxFrame(IOSkywalkPacket *preparedPacket, void *context);

    enum : uint32_t {
        kPacketPathDisabled = 0,
        kPacketPathActive = 1,
        kPacketPathQuiescing = 2,
        kPacketPathReleasing = 3,
        kPacketPathBinding = 4
    };

    bool enterPacketPath();
    void leavePacketPath();

    static constexpr uint32_t kStagedRxPacketCapacity = 128;

    IOWorkLoop *_workLoop = nullptr;
    IO80211SkywalkInterface *_packetPathInterface = nullptr; // retained while active
    volatile uint32_t _packetPathState = kPacketPathDisabled;
    volatile uint32_t _packetPathInFlight = 0;
    RTW88WCLPCIBackend *_pciBackend = nullptr; // retained
    RTW88WCLSkywalkQueues *_skywalkQueues = nullptr; // retained by controller
    RTW88WCLInfraInterface *_infraInterface = nullptr; // retained child service
    RTW88WCLSkywalkRxAdapter *_rxAdapter = nullptr; // retained, workloop-bound
    RTW88WCLSkywalkTxAdapter *_txAdapter = nullptr; // retained, queue-owner-bound
    RTW88WCLTxCompletionWorkQueue *_txCompletionWorker = nullptr; // retained, workloop-bound
    bool _txAdapterBoundToQueues = false;
    /* Accepted RX packets remain pool-owned here until a verified completion
     * queue can consume them. This ring is bounded to the RX pool packet count. */
    RTW88WCLMbufRing<IOSkywalkPacket *, kStagedRxPacketCapacity> _stagedRxPackets;
    RTW88IEEE80211 *_radio = nullptr;          // retained via bindRadioBackend
    bool _baseStarted = false;
    bool _radioStarted = false;
};
