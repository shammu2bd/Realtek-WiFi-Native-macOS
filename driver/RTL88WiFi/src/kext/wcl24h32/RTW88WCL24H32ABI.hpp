/* SPDX-License-Identifier: GPL-2.0-only
 * RTL88WiFi private Sequoia 24H32 WCL ABI declaration layer.
 *
 * This is an ABI declaration, not an implementation of Apple's classes.
 * It is isolated under src/kext/wcl24h32 and must only be included by the
 * native WCL translation units. Never include this together with the legacy
 * IOKit/80211/IO80211Controller.h declaration in one translation unit.
 *
 * Target reviewed: macOS 15.8.1 (24H32), x86_64.
 * IO80211Controller size: 0x128; vtable entries: 466 (24H32 ABI archive).
 */
#pragma once

#if !defined(KERNEL) || !defined(__cplusplus)
#error "RTW88WCL24H32ABI.hpp is for kernel C++ translation units only"
#endif

#ifndef __IO80211_TARGET
#error "Define __IO80211_TARGET for the native WCL target"
#endif

#include <stdint.h>
#include <sys/kpi_mbuf.h>
#include <net/ethernet.h>
#include <IOKit/network/IOEthernetController.h>
#include <libkern/c++/OSMetaClass.h>
#include <IOKit/80211/apple80211_ioctl.h>

class IO80211SkywalkInterface;
class IO80211Interface;
class IO80211VirtualInterface;
class IO80211FlowQueue;
class IO80211FlowQueueLegacy;
class IO80211WorkQueue;
class IO80211InterfaceAVCAdvisory;
class IOCommandGate;
class CCLogStream;
class CCPipe;
class CommonFaultReporter;
class IOService;
class IOWorkLoop;
class OSObject;
class OSString;
class OSDictionary;
class FlowIdMetadata;
struct apple80211_platform_config;
struct apple80211_debug_command;

/* The values and signatures below match the Sequoia V2 controller surface.
 * Types not consumed by the controller shell are intentionally forward-declared;
 * pointer ABI and virtual declaration order remain explicit here. */
enum IO80211CountryCodeOp {
    kIO80211CountryCodeReset
};
enum IO80211FeatureCode {
    kIO80211Feature80211n = 1
};

class IO80211Controller : public IOEthernetController {
    OSDeclareAbstractStructors(IO80211Controller)
public:
    IOReturn postMessage(IO80211SkywalkInterface *, unsigned int, void *, unsigned long, bool);
    virtual void _RESERVEDIONetworkController6() __asm__("__ZN19IONetworkController20allocatePacketNoWaitEj") override;
    virtual void _RESERVEDIONetworkController7() __asm__("__ZN19IONetworkController18setHardwareAssistsEjj") override;
    virtual void free() override;
    virtual bool init(OSDictionary *) override;
    virtual IOReturn configureReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual IOReturn updateReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual bool start(IOService *) override;
    virtual void stop(IOService *) override;
    virtual IOWorkLoop *getWorkLoop() const override;
    virtual const char *stringFromReturn(int) override;
    virtual int errnoFromReturn(int) override;
    virtual UInt32 getFeatures() const override;
    virtual const OSString *newVendorString() const override;
    virtual const OSString *newModelString() const override;
    virtual bool createWorkLoop() override;
    virtual IOReturn getHardwareAddress(IOEthernetAddress *) override;
    virtual IOReturn setMulticastMode(bool) override;
    virtual IOReturn setPromiscuousMode(bool) override;
    virtual bool isCommandProhibited(int) = 0;
    virtual bool createWorkQueue();
private:
    virtual void _abi_0c60() __asm__("__ZN17IO80211Controller14debugStateInitEv");
public:
    virtual IO80211WorkQueue *getWorkQueue() const;
    virtual void requestPacketTx(void *, unsigned int);
    virtual IOCommandGate *getIO80211CommandGate() const;
    virtual IO80211SkywalkInterface *getPrimarySkywalkInterface();
    virtual int bpfOutputPacket(OSObject *, unsigned int, struct __mbuf *);
    virtual SInt32 monitorModeSetEnabled(bool, unsigned int);
    virtual SInt32 handleCardSpecific(IO80211SkywalkInterface *, unsigned long, void *, bool) = 0;
    virtual UInt32 hardwareOutputQueueDepth();
    virtual SInt32 performCountryCodeOperation(IO80211CountryCodeOp);
    virtual void dataLinkLayerAttachComplete();
    virtual SInt32 enableFeature(IO80211FeatureCode, void *);
    virtual IOReturn getDRIVER_VERSION(IO80211SkywalkInterface *, apple80211_version_data *) = 0;
    virtual IOReturn getHARDWARE_VERSION(IO80211SkywalkInterface *, apple80211_version_data *) = 0;
    virtual IOReturn getCARD_CAPABILITIES(IO80211SkywalkInterface *, apple80211_capability_data *) = 0;
    virtual IOReturn getPOWER(IO80211SkywalkInterface *, apple80211_power_data *) = 0;
    virtual IOReturn setPOWER(IO80211SkywalkInterface *, apple80211_power_data *) = 0;
    virtual IOReturn getCOUNTRY_CODE(IO80211SkywalkInterface *, apple80211_country_code_data *) = 0;
    virtual IOReturn setCOUNTRY_CODE(IO80211SkywalkInterface *, apple80211_country_code_data *) = 0;
    virtual IOReturn setGET_DEBUG_INFO(IO80211SkywalkInterface *, apple80211_debug_command *) = 0;
private:
    virtual void _abi_0d00() __asm__("__ZN17IO80211Controller18getPLATFORM_CONFIGEP23IO80211SkywalkInterfaceP26apple80211_platform_config");
public:
    virtual SInt32 enableVirtualInterface(IO80211VirtualInterface *);
    virtual SInt32 disableVirtualInterface(IO80211VirtualInterface *);
    virtual bool requiresExplicitMBufRelease();
    virtual bool flowIdSupported();
    virtual IO80211FlowQueueLegacy *requestFlowQueue(FlowIdMetadata const *);
    virtual void releaseFlowQueue(IO80211FlowQueue *);
    virtual bool getLogPipes(CCPipe **, CCPipe **, CCPipe **);
    virtual CCLogStream *getLogger() const = 0;
    virtual void enableFeatureForLoggingFlags(unsigned long long);
    virtual IOReturn requestQueueSizeAndTimeout(unsigned short *, unsigned short *);
    virtual IOReturn enablePacketTimestamping();
    virtual IOReturn disablePacketTimestamping();
    virtual UInt getPacketTSCounter();
    virtual void *getDriverTextLog();
    virtual UInt32 selfDiagnosticsReport(int, char const *, unsigned int);
    virtual CommonFaultReporter *getFaultReporterFromDriver() = 0;
private:
    virtual void _abi_0d88() __asm__("__ZN17IO80211Controller25allocIO80211RecursiveLockEv");
public:
    virtual UInt32 getDataQueueDepth(OSObject *);
    virtual bool wasDynSARInFailSafeMode();
    virtual void updateAdvisoryScoresIfNeed();
    virtual UInt64 getAVCAdvisoryInfo(IO80211InterfaceAVCAdvisory *);
private:
    virtual void _abi_0db0() __asm__("__ZN17IO80211Controller26getActionFramePoolCapacityEv");
    virtual void _abi_0db8() __asm__("__ZN17IO80211Controller13getPostOfficeEv");
    virtual void _abi_0dc0() __asm__("__ZN17IO80211Controller16CreatePostOfficeEv");
public:
    virtual bool attachInterface(OSObject *, IOService *);
    virtual void detachInterface(OSObject *, bool);
    virtual IO80211VirtualInterface *createVirtualInterface(ether_addr *, unsigned int);
    virtual bool attachVirtualInterface(IO80211VirtualInterface **, ether_addr *, unsigned int, bool);
    virtual bool detachVirtualInterface(IO80211VirtualInterface *, bool);
    virtual void _RESERVEDIO80211Controller0();
    virtual void _RESERVEDIO80211Controller1();
    virtual void _RESERVEDIO80211Controller2();
    virtual void _RESERVEDIO80211Controller3();
    virtual void _RESERVEDIO80211Controller4();
    virtual void _RESERVEDIO80211Controller5();
    virtual void _RESERVEDIO80211Controller6();
    virtual void _RESERVEDIO80211Controller7();
    virtual void _RESERVEDIO80211Controller8();
    virtual void _RESERVEDIO80211Controller9();
    virtual void _RESERVEDIO80211Controller10();
    virtual void _RESERVEDIO80211Controller11();
    virtual void _RESERVEDIO80211Controller12();
    virtual void _RESERVEDIO80211Controller13();
    virtual void _RESERVEDIO80211Controller14();
    virtual void _RESERVEDIO80211Controller15();
    /* Sequoia adds this IO80211Controller slot with ether_addr ABI; it is
     * distinct from IOEthernetController::setMulticastList(IOEthernetAddress*, UInt32). */
    virtual IOReturn setMulticastList(ether_addr const *, unsigned int);
private:
    uint8_t _layout[0x128 - sizeof(IOEthernetController)];
};

static_assert(sizeof(IO80211Controller) == 0x128,
              "IO80211Controller does not match the reviewed Sequoia ABI");
