/* SPDX-License-Identifier: GPL-2.0-only
 * RTL88WiFi Sequoia 15.8.1 (24H32) WCL interface ABI declarations.
 *
 * This file declares the 24H32 IOSkywalk/IO80211 inheritance and vtable
 * surface needed by the private native WCL frontend. It must only be included
 * by wcl24h32 translation units. Do NOT include legacy IO80211Interface.h,
 * IO80211SkywalkInterface.h or Apple80211.h in the same translation unit.
 *
 * ABI sizes reviewed against the 24H32 x86_64 kernel collection:
 * IOSkywalkInterface 0xb0, IOSkywalkNetworkInterface 0xd0,
 * IOSkywalkEthernetInterface 0x110, IO80211SkywalkInterface 0x118,
 * IO80211InfraInterface/IO80211InfraProtocol 0x120.
 */
#pragma once

#if !defined(KERNEL) || !defined(__cplusplus)
#error "24H32 WCL ABI declarations require kernel C++"
#endif
#ifndef __IO80211_TARGET
#error "Define __IO80211_TARGET for the native WCL target"
#endif
#if __IO80211_TARGET != __MAC_15_2
#error "This ABI header is pinned to macOS 15.2+ / Sequoia Darwin 24"
#endif

#include <stdint.h>
#include <stddef.h>
#include <sys/kpi_mbuf.h>
#include <net/if.h>
#include <net/if_var.h>
#include <net/if_dl.h>
#include <net/ethernet.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/network/IOEthernetController.h>
#include <IOKit/80211/apple80211_ioctl.h>
#include <libkern/c++/OSMetaClass.h>

class IO80211Controller;
class IO80211Peer;
class IO80211APIUserClient;
class IO80211NetworkPacket;
class IO80211FlowQueue;
class IO80211FlowQueueLegacy;
class IO80211ScanManager;
class CCLogStream;
class CCPipe;
class OSString;
class OSSymbol;
class IOSkywalkPacketQueue;
class IOSkywalkLogicalLink;
class IOSkywalkPacketBufferPool;
class TxSubmissionDequeueStats;
class TxCompletionEnqueueStats;
class PacketSkywalkScratch;
class FlowIdMetadata;
struct nicproxy_info_s;
struct nicproxy_limits_info_s;
struct if_link_status;
struct ifnet_init_eparams;
struct sockaddr_dl;
struct ifdrv;
struct packet_info_tag;
struct userPrintCtx;
struct ether_addr;
struct apple80211_wme_ac;
typedef struct apple80211_wme_ac apple80211_wme_ac;
struct apple80211_interface_availability;
struct apple80211_cca_report;
struct apple80211_stat_report;
struct apple80211_chip_counters_tx;
struct apple80211_chip_counters_rx;
struct apple80211_chip_error_counters_tx;
struct apple80211_ManagementInformationBasedot11_counters;
struct apple80211_frame_counters;
struct apple80211_infra_specific_stats;
struct apple80211_lqm_summary;
struct apple80211_wcl_advisory_info;
struct apple80211_wcl_tx_rx_latency;
struct apple80211_wcl_update_link_state;
struct apple80211_power_debug_info;
struct apple80211_bgscan_cached_network_data_list;
struct apple80211_private_mac_data;
struct apple80211_dbg_guard_time_params;
struct apple80211_ranging_enable_request_t;
struct apple80211_gas_result_t;
struct apple80211_ranging_start_request_t;
struct apple80211_leaky_ap_setting;
struct apple80211_rsdb_capability;
struct apple80211_tko_params;
struct apple80211_tko_dump;
struct apple80211_thermal_index_t;
struct apple80211_btcoex_max_nss_for_ap_data;
struct apple80211_btcoex_2g_chain_disable;
struct apple80211_power_budget_t;
struct apple80211_ranging_capabilities_t;
struct apple80211_suppress_scans_t;
struct apple80211_host_ap_mode_hidden_t;
struct apple80211_lqm_config_t;
struct apple80211_trap_mini_dump_data;
struct apple80211_beacon_info_t;
struct apple80211_softap_params;
struct apple80211_chip_power_limit;
struct apple80211_softap_stats;
struct apple80211_nss_data;
struct apple80211_hw_mac_address;
struct appl80211_chip_diags_data;
struct apple80211_hp2p_ctrl;
struct apple80211_assoc_ready;
struct apple80211_txrx_chain_info;
struct apple80211_mimo_status;
struct apple80211_dynsar_detail;
struct apple80211_mac_randomisation_status;
struct apple80211_slow_wifi_feature_enabled;
struct apple80211_interface_cca_data;
struct apple80211_timesync_info;
struct apple80211_sensing_data_t;
struct apple80211_country_band_support;
struct apple80211_fw_hot_channels;
struct apple80211_low_latency_info;
struct apple80211_beacon_msg;
struct apple80211_wcl_traffic_counters;
struct apple80211_ssid_transition_feature_enabled;
struct apple80211ChannelInfo;
struct apple80211_p2p_steering_metrics;
struct apple80211_rsn_xe_data;
struct apple80211_sib_coex_status;
struct apple80211_extended_bss_info;
struct apple80211_wcl_low_latency_stats;
struct apple80211_noise_per_ant_t;
struct apple80211_blocked_bands;
struct apple80211_disassoc_data;
struct apple80211_bgscan_data;
struct apple80211_sta_authorize_data;
struct apple80211_sta_disassoc_data;
struct apple80211_rsn_conf_data;
struct apple80211_country_channel_data;
struct apple80211_awdl_forced_roam_config;
struct apple80211_offload_arp_data;
struct apple80211_offload_ndp_data;
struct apple80211_offload_scan_data;
struct apple80211_gas_query_t;
struct apple80211_gas_peer_t;
struct apple80211_btcoex_profile;
struct apple80211_btcoex_profile_active_data;
struct apple80211_trap_info_data;
struct apple80211_he_capability;
struct apple80211_pmk;
struct apple80211_wow_test_data;
struct apple80211_reset_command;
struct apple80211_crash_command;
struct apple80211_ranging_authenticate_request_t;
struct apple80211_softap_csa_params;
struct apple80211_softap_wifi_network_info;
struct apple80211_scan_control_params;
struct apple80211_usb_host_notification_data;
struct apple80211_set_mac_address;
struct apple80211_abort_scan;
struct apple80211_set_property_unserialized_data;
struct apple80211_roam_cache_data;
struct apple80211_pm_mode;
struct apple80211_wifi_assertion_data;
struct apple80211_capture_debug_info_t;
struct apple80211_linkdown_debounce_status;
struct apple80211_softap_extended_capabilities_info;
struct apple80211_sensing_enable_t;
struct apple80211_sensing_disable_t;
struct apple80211_nan_link_association_info;
struct apple80211_6G_mode;
struct apple80211_leave_network;
struct apple80211_reassoc;
struct apple80211_set_roam_lock;
struct apple80211_roam_profile_config;
struct apple80211_roam_profile_configV1;
struct apple80211_user_roam_cache;
struct apple80211_wcl_real_time_mode;
struct apple80211_wcl_garp_mode;
struct triggerCC;
struct apple80211ScanRequest;
struct apple80211_assoc_candidates;
struct apple80211AssocCandidates;
struct scanHomeAndAwayTime;
struct apple80211_wcl_protect_ip_mode;
struct apple80211_wcl_voluntary_network_disconnect;
struct apple80211_wcl_action_frame;
struct apple80211_wcl_real_time_policy;
struct apple80211_feature_flags;
struct apple80211_dhcp_renewal_data;
struct apple80211_network_flags;
struct apple80211_battery_ps_config;
struct apple80211_mimo_config;
struct apple80211_bg_motion_profile;
struct apple80211_bg_network;
struct apple80211_bg_scan;
struct apple80211_bg_params;
struct apple80211_offload_tcpka_enable_t;
struct apple80211_dynamic_rssi_window_config;
struct apple80211_legacy_roam_profile_config;
struct apple80211_sensing_data_t;
struct apple80211_btcoex_ext_profile;
struct apple80211_device_orientation;
struct apple80211_device_accessory_info;
struct apple80211_os_eligibility;
struct apple80211_tx_mode_config;
struct apple80211_mitigate_interference;
struct apple80211_mws_accessory_power_limit;
struct apple80211_facetime_wificalling_params;
struct apple80211_ipv4_params;
struct apple80211_wcl_wnm_config_t;
struct apple80211_wcl_wnm_offload_t;
struct apple80211_limited_aggregation_config;
struct apple80211_bcn_mute_config;
struct apple80211_eap_filter_config;
struct apple80211_wow_low_power_mode;
struct apple80211_dual_power_mode_params;
struct apple80211_fastlane;
struct apple80211_associated_sleep_config;
struct apple80211_congestion_control_indication;
struct apple80211_standalone_state;
struct apple80211_ipv6_params;
struct apple80211_infra_enumerated;
struct apple80211_lmtpc_config;
struct apple80211_traffic_eng_params;
struct apple80211_le_scan_params;
struct apple80211_timesync_gpio;
struct apple80211_host_clock_info;
struct apple80211_fw_clock_source;
struct apple80211_timesync_tx_policy;
struct apple80211_timesync_rx_policy;
struct apple80211_timestamping_en;
struct appl80211_sleep_on_inactivity_config;
struct apple80211_mws_time_sharing;
struct apple80211_mws_wifi_channel_bitmap;
struct apple80211_mws_rfem_config;
struct apple80211_mws_scan_freq;
struct apple80211_mws_scan_freq_mode;
struct apple80211_mws_condition_id_config;
struct apple80211_mws_antenna_selection;
struct apple80211_ndd_data;
struct apple80211_drbg_entropy;
struct apple80211_sdb_enable;
struct apple80211_chip_stats;
struct apple80211_bypass_tx_power_cap;
struct apple80211_fw_clock_info;
struct apple80211_he_counters_ctl;
struct apple80211_ie_data;
struct apple80211_interface_setting;
struct apple80211_mcs_vht_data;
struct apple80211_power_profile;
struct apple80211_roam_profile_all_bands;
struct apple80211_system_sleep_config;
struct apple80211_timesync_stats;
struct apple80211_wcl_arp_mode;
struct apple80211_wcl_qos_params;
struct bss_blacklist;
struct apple80211_voice_ind_state;
struct apple80211_wcl_ulofdma_state;
struct apple80211_apmode_data;
struct apple80211_wifi_bt_5g_policy_t;
struct apple80211_smartcca_opmode;
struct apple80211_lqm_statistics;
struct apple80211_p2p_device_capability;
struct apple80211_powertable_version_data;

/* Native Sequoia link-state values. */
enum IO80211LinkState {
    kIO80211NetworkLinkUndefined = 0,
    kIO80211NetworkLinkDown = 1,
    kIO80211NetworkLinkUp = 2
};
/* The 24H32 WCL header uses this four-byte traffic-class scalar. */
/* apple80211_wme_ac is an opaque four-byte-by-value ABI token. */

class IOSkywalkInterface : public IOService {
    OSDeclareAbstractStructors(IOSkywalkInterface)
public:
    virtual void free() override;
    virtual bool init(OSDictionary *) override;
    virtual bool willTerminate(IOService *, unsigned int) override;
    virtual bool didTerminate(IOService *, unsigned int, bool *) override;
    virtual bool handleOpen(IOService *, unsigned int, void *) override;
    virtual void handleClose(IOService *, unsigned int) override;
    virtual bool handleIsOpen(IOService const *) const override;
    virtual IOReturn enable(unsigned int) = 0;
    virtual IOReturn disable(unsigned int) = 0;
    virtual IOReturn clientConnectWithTask(task *, IOService *, unsigned int);
    virtual void clientDisconnect(IOService *, unsigned int);
    virtual bool isTerminating();
    virtual void _RESERVEDIOSkywalkInterface0();
    virtual void _RESERVEDIOSkywalkInterface1();
    virtual void _RESERVEDIOSkywalkInterface2();
    virtual void _RESERVEDIOSkywalkInterface3();
    virtual void _RESERVEDIOSkywalkInterface4();
    virtual void _RESERVEDIOSkywalkInterface5();
    virtual void _RESERVEDIOSkywalkInterface6();
    virtual void _RESERVEDIOSkywalkInterface7();
    virtual void _RESERVEDIOSkywalkInterface8();
    virtual void _RESERVEDIOSkywalkInterface9();
    virtual void _RESERVEDIOSkywalkInterface10();
private:
    uint8_t _layout[0xb0 - sizeof(IOService)];
};
static_assert(sizeof(IOSkywalkInterface) == 0xb0, "24H32 IOSkywalkInterface ABI");

class IOSkywalkNetworkInterface : public IOSkywalkInterface {
    OSDeclareAbstractStructors(IOSkywalkNetworkInterface)
    /* Private registration payload; its fields are not part of the SDK. */
    struct RegistrationInfo;
public:
    struct IOSkywalkTSOOptions;
    virtual void free() override;
    virtual bool init(OSDictionary *) override;
    virtual void stop(IOService *) override;
    virtual void joinPMtree(IOService *) override;
    virtual IOReturn setAggressiveness(unsigned long, unsigned long) override;
    virtual IOReturn enable(unsigned int) override;
    virtual IOReturn disable(unsigned int) override;
    virtual IOReturn registerNetworkInterfaceWithLogicalLink(RegistrationInfo const *, IOSkywalkLogicalLink *, IOSkywalkPacketBufferPool *, IOSkywalkPacketBufferPool *, unsigned int);
    /* 24H32 non-virtual registration entry points. Their IOReturn convention
     * is confirmed by the target function bodies and Apple caller's EAX test.
     * These declarations do not add vtable slots. */
    IOReturn registerNetworkInterface(RegistrationInfo const *, IOSkywalkPacketQueue **,
                                      unsigned int, IOSkywalkPacketBufferPool *,
                                      IOSkywalkPacketBufferPool *, unsigned int);
    IOReturn registerNetworkInterface(RegistrationInfo const *, IOSkywalkLogicalLink *,
                                      IOSkywalkPacketBufferPool *,
                                      IOSkywalkPacketBufferPool *, unsigned int);
    IOReturn deregisterNetworkInterface(unsigned int);
    virtual IOReturn deregisterLogicalLink();
    virtual SInt32 initBSDInterfaceParameters(ifnet_init_eparams *, sockaddr_dl **) = 0;
    virtual IOReturn prepareBSDInterface(struct __ifnet *, unsigned int);
    virtual void finalizeBSDInterface(struct __ifnet *, unsigned int);
    virtual ifnet_t getBSDInterface() const;
    virtual void setBSDName(char const *);
    virtual const char *getBSDName() const;
    virtual IOReturn processBSDCommand(struct __ifnet *, unsigned int, void *);
    virtual IOReturn processInterfaceCommand(ifdrv *);
    virtual IOReturn interfaceAdvisoryEnable(bool);
    virtual SInt32 setInterfaceEnable(bool);
    virtual SInt32 setRunningState(bool);
    virtual IOReturn handleChosenMedia(unsigned int);
    virtual void *getSupportedMediaArray(unsigned int *, unsigned int *);
    virtual void *getPacketTapInfo(unsigned int *, unsigned int *);
    virtual UInt getUnsentDataByteCount(unsigned int *, unsigned int *, unsigned int) const;
    virtual UInt32 getSupportedWakeFlags(unsigned int *);
    virtual void enableNetworkWake(unsigned int);
    virtual void calculateRingSizeForQueue(IOSkywalkPacketQueue const *, unsigned int *) const;
    virtual UInt getMaxTransferUnit();
    virtual void setMaxTransferUnit(unsigned int);
    virtual UInt getMinPacketSize();
    virtual UInt getHardwareAssists();
    virtual void setHardwareAssists(unsigned int, unsigned int);
    virtual void *getInterfaceFamily();
    virtual void *getInterfaceSubFamily();
    virtual UInt getInitialMedia();
    virtual UInt32 getFeatureFlags();
    virtual UInt getTxDataOffset();
    virtual UInt captureInterfaceState(unsigned int);
    virtual void restoreInterfaceState(unsigned int);
    virtual void setMTU(unsigned int);
    virtual bool bpfTap(unsigned int, unsigned int);
    virtual const char *getBSDNamePrefix();
    virtual UInt getBSDUnitNumber();
    virtual const char *classNameOverride();
    virtual void deferBSDAttach(bool);
    virtual void reportDetailedLinkStatus(if_link_status const *);
    virtual UInt getTSOOptions(IOSkywalkNetworkInterface::IOSkywalkTSOOptions *);
    virtual void _RESERVEDIOSkywalkNetworkInterface0();
    virtual void _RESERVEDIOSkywalkNetworkInterface1();
    virtual void _RESERVEDIOSkywalkNetworkInterface2();
    virtual void _RESERVEDIOSkywalkNetworkInterface3();
    virtual void _RESERVEDIOSkywalkNetworkInterface4();
    virtual void _RESERVEDIOSkywalkNetworkInterface5();
    virtual void _RESERVEDIOSkywalkNetworkInterface6();
    virtual void _RESERVEDIOSkywalkNetworkInterface7();
    virtual void _RESERVEDIOSkywalkNetworkInterface8();
    virtual void _RESERVEDIOSkywalkNetworkInterface9();
    void reportLinkStatus(unsigned int, unsigned int);
protected:
    /* Kernel-owned expansion allocation: keep its 24H32 extent opaque. */
    struct ExpansionData;
private:
    uint8_t _layout0[0x8];
protected:
    ExpansionData *mExpansionData;
private:
    uint8_t _layout1[0x10];
};
static_assert(sizeof(IOSkywalkNetworkInterface) == 0xd0, "24H32 IOSkywalkNetworkInterface ABI");

class IOSkywalkEthernetInterface : public IOSkywalkNetworkInterface {
    OSDeclareAbstractStructors(IOSkywalkEthernetInterface)
public:
    /* Opaque nested type: public here only so the 24H32 infra shim can spell
     * the exact parameter type. This does not expose or change its layout. */
    struct RegistrationInfo;
    virtual void free() override;
    virtual bool init(OSDictionary *) override;
    virtual IOReturn newUserClient(task *, void *, unsigned int, OSDictionary *, IOUserClient **) override;
    virtual IOReturn setPowerState(unsigned long, IOService *) override;
    virtual IOReturn enable(unsigned int) override;
    virtual SInt32 initBSDInterfaceParameters(ifnet_init_eparams *, sockaddr_dl **) override;
    virtual IOReturn prepareBSDInterface(struct __ifnet *, unsigned int) override;
    virtual IOReturn processBSDCommand(struct __ifnet *, unsigned int, void *) override;
    virtual void *getPacketTapInfo(unsigned int *, unsigned int *) override;
    virtual void enableNetworkWake(unsigned int) override;
    virtual UInt getMaxTransferUnit() override;
    virtual UInt getMinPacketSize() override;
    virtual void *getInterfaceFamily() override;
    virtual void *getInterfaceSubFamily() override;
    virtual UInt getInitialMedia() override;
    virtual const char *getBSDNamePrefix() override;
    virtual IOReturn getHardwareAddress(ether_addr *);
    virtual IOReturn setHardwareAddress(ether_addr *);
    virtual void setLinkLayerAddress(ether_addr *);
    virtual bool configureMulticastFilter(unsigned int, ether_addr const *, unsigned int);
    virtual bool setMulticastAddresses(ether_addr const *, unsigned int);
    virtual void setAllMulticastModeEnable(bool);
    virtual IOReturn setPromiscuousModeEnable(bool, unsigned int);
    virtual void reportNicProxyLimits(nicproxy_limits_info_s);
    virtual void hwConfigNicProxyData(nicproxy_info_s *);
    virtual void _RESERVEDIOSkywalkEthernetInterface0();
    virtual void _RESERVEDIOSkywalkEthernetInterface1();
    virtual void _RESERVEDIOSkywalkEthernetInterface2();
    virtual void _RESERVEDIOSkywalkEthernetInterface3();
    virtual void _RESERVEDIOSkywalkEthernetInterface4();
    virtual void _RESERVEDIOSkywalkEthernetInterface5();
    virtual void _RESERVEDIOSkywalkEthernetInterface6();
    virtual void _RESERVEDIOSkywalkEthernetInterface7();
    virtual void _RESERVEDIOSkywalkEthernetInterface8();
    virtual void _RESERVEDIOSkywalkEthernetInterface9();
    virtual void _RESERVEDIOSkywalkEthernetInterface10();

    /* Non-virtual 24H32 entry points. The complete kernel bodies propagate
     * IOReturn values; Apple callers treat EAX==0 as success. */
    bool initRegistrationInfo(RegistrationInfo *, unsigned int, size_t);
    IOReturn registerEthernetInterface(RegistrationInfo const *, IOSkywalkPacketQueue **,
                                       unsigned int, IOSkywalkPacketBufferPool *,
                                       IOSkywalkPacketBufferPool *, unsigned int);
    IOReturn registerEthernetInterface(RegistrationInfo const *, IOSkywalkLogicalLink *,
                                       IOSkywalkPacketBufferPool *,
                                       IOSkywalkPacketBufferPool *, unsigned int);
    IOReturn deregisterEthernetInterface(unsigned int);
protected:
    struct ExpansionData;
private:
    uint8_t _layout0[0x38];
public:
    /* Pointer is visible for layout assertions; its pointed-to layout is not. */
    ExpansionData *mExpansionData2;
};
static_assert(sizeof(IOSkywalkEthernetInterface) == 0x110, "24H32 IOSkywalkEthernetInterface ABI");
static_assert(__offsetof(IOSkywalkEthernetInterface, mExpansionData2) == 0x108, "24H32 Ethernet expansion offset");

struct TxPacketRequest {
    uint16_t unk1, t, mU, mM, pkt_cnt, unk2, unk3, unk4;
    uint32_t pad;
    mbuf_t bufs[8];
    uint32_t reqTx;
};
static_assert(sizeof(TxPacketRequest) == 0x60, "24H32 TxPacketRequest ABI");

class IO80211SkywalkInterface : public IOSkywalkEthernetInterface {
    OSDeclareAbstractStructors(IO80211SkywalkInterface)
public:
    virtual bool init() override;
    virtual void free() override;
    virtual IOReturn configureReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual IOReturn updateReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual bool start(IOService *) override;
    virtual void stop(IOService *) override;
    virtual IOReturn newUserClient(task *, void *, unsigned int, OSDictionary *, IOUserClient **) override;
    virtual const char *stringFromReturn(int) override;
    virtual int errnoFromReturn(int) override;
    virtual IOReturn setPowerState(unsigned long, IOService *) override;
    virtual unsigned long maxCapabilityForDomainState(unsigned long) override;
    virtual unsigned long initialPowerStateForDomainState(unsigned long) override;
    virtual IOReturn enable(unsigned int) override;
    virtual IOReturn disable(unsigned int) override;
    virtual SInt32 initBSDInterfaceParameters(ifnet_init_eparams *, sockaddr_dl **) override;
    virtual IOReturn prepareBSDInterface(struct __ifnet *, unsigned int) override;
    virtual IOReturn processBSDCommand(struct __ifnet *, unsigned int, void *) override;
    virtual SInt32 setInterfaceEnable(bool) override;
    virtual SInt32 setRunningState(bool) override;
    virtual IOReturn handleChosenMedia(unsigned int) override;
    virtual void *getSupportedMediaArray(unsigned int *, unsigned int *) override;
    virtual UInt32 getFeatureFlags() override;
    virtual const char *classNameOverride() override;
    virtual IOReturn getHardwareAddress(ether_addr *) override;
    virtual IOReturn setHardwareAddress(ether_addr *) override;
    virtual IOReturn setPromiscuousModeEnable(bool, unsigned int) override;
    virtual void *createPeerManager();
private:
    virtual void _abi_0b10() __asm__("__ZN23IO80211SkywalkInterface10createPeerEPKhP18IO80211PeerManager");
public:
    virtual void postMessage(unsigned int, void *, unsigned long, bool);
    virtual IOReturn reportDataPathEvents(unsigned int, void *, unsigned long, bool);
    virtual IOReturn recordOutputPackets(TxSubmissionDequeueStats *, TxSubmissionDequeueStats *);
    virtual IOReturn recordOutputPacket(apple80211_wme_ac, int, int);
    virtual void logTxPacket(IO80211NetworkPacket *, PacketSkywalkScratch *, apple80211_wme_ac, bool);
    virtual void logTxCompletionPacket(IO80211NetworkPacket *, PacketSkywalkScratch *, unsigned char *, apple80211_wme_ac, int, unsigned int, bool, bool);
    virtual IOReturn recordCompletionPackets(TxCompletionEnqueueStats *, TxCompletionEnqueueStats *);
    virtual IOReturn inputPacket(IO80211NetworkPacket *, packet_info_tag *, ether_header *, bool *, bool);
    virtual IOReturn forwardInfraRelayPackets(IO80211NetworkPacket *, ether_header *);
    virtual void logSkywalkTxReqPacket(IO80211NetworkPacket *, PacketSkywalkScratch *, unsigned char *, apple80211_wme_ac, bool);
    virtual SInt64 pendingPackets(unsigned char);
    virtual SInt64 packetSpace(unsigned char);
    virtual bool isChipInterfaceReady();
    virtual bool isDebounceOnGoing();
    virtual bool setLinkState(IO80211LinkState, unsigned int, bool, unsigned int);
    virtual IO80211LinkState linkState();
    virtual void setScanningState(unsigned int, bool, apple80211_scan_data *, int);
    virtual void setDataPathState(bool);
    virtual void *getScanManager();
    virtual IO80211Controller *getController();
    virtual void updateLinkParameters(apple80211_interface_availability *);
    virtual void updateInterfaceCoexRiskPct(unsigned long long);
    virtual void setLQM(unsigned long long);
    virtual void updateLinkStatus();
    virtual void updateLinkStatusGated();
    virtual void setInterfaceExtendedCCA(apple80211_channel, apple80211_cca_report *);
    virtual void setInterfaceCCA(apple80211_channel, int);
    virtual void setInterfaceNF(apple80211_channel, long long);
    virtual void setInterfaceOFDMDesense(apple80211_channel, long long);
private:
    virtual void _abi_0bf8() __asm__("__ZN23IO80211SkywalkInterface17removePacketQueueEP20IO80211FlowQueueHash");
public:
    virtual void setDebugFlags(unsigned long long, unsigned int);
    virtual SInt64 debugFlags();
    virtual void setInterfaceChipCounters(apple80211_stat_report *, apple80211_chip_counters_tx *, apple80211_chip_error_counters_tx *, apple80211_chip_counters_rx *);
    virtual void setInterfaceMIBdot11(apple80211_stat_report *, apple80211_ManagementInformationBasedot11_counters *);
    virtual void setFrameStats(apple80211_stat_report *, apple80211_frame_counters *);
    virtual void setInfraSpecificFrameStats(apple80211_stat_report *, apple80211_infra_specific_stats *);
    virtual SInt64 getWmeTxCounters(unsigned long long *);
    virtual void setPeerManagerLogFlag(unsigned int, unsigned int, unsigned int);
    virtual void setWoWEnabled(bool);
    virtual bool wowEnabled();
    virtual void printDataPath(userPrintCtx *);
    virtual UInt32 getDataQueueDepth();
private:
    virtual void _abi_0c68() __asm__("__ZN23IO80211SkywalkInterface21findOrCreateFlowQueueE20IO80211FlowQueueHash");
    virtual void _abi_0c70() __asm__("__ZN23IO80211SkywalkInterface30findOrCreateFlowQueueWithCacheE20IO80211FlowQueueHashPb");
    virtual void _abi_0c78() __asm__("__ZN23IO80211SkywalkInterface21findExistingFlowQueueE20IO80211FlowQueueHash");
    virtual void _abi_0c80() __asm__("__ZN23IO80211SkywalkInterface17removePacketQueueEPK20IO80211FlowQueueHash");
public:
    virtual void flushPacketQueues();
    virtual void cachePeer(ether_addr *, unsigned int *);
    virtual bool shouldLog(unsigned long long);
    virtual void vlogDebug(unsigned long long, char const *, va_list);
    virtual void vlogDebugBPF(unsigned long long, char const *, va_list);
    virtual UInt64 createLinkQualityMonitor(IO80211Peer *, IOService *);
    virtual void releaseLinkQualityMonitor(IO80211Peer *);
    virtual void *getP2PSkywalkPeerMgr();
    virtual bool isCommandProhibited(int);
private:
    virtual void _abi_0cd0() __asm__("__ZN23IO80211SkywalkInterface8findPeerER10ether_addr");
public:
    virtual void setNotificationProperty(OSSymbol const *, OSObject const *);
    virtual void *getWorkerMatchingDict(OSString *);
    virtual bool init(IOService *, ether_addr *);
    virtual bool isInterfaceEnabled();
    virtual ether_addr *getSelfMacAddr();
    virtual IOReturn setMacAddress(ether_addr &) = 0;
    virtual void *getPacketPool(OSString *);
    virtual CCLogStream *getLogger() const;
    virtual IOReturn handleSIOCSIFADDR();
    virtual IOReturn debugHandler(apple80211_debug_command *);
    virtual void statsDump();
    virtual void powerOnNotification();
    virtual void powerOffNotification();
    virtual UInt64 getTxQueueDepth();
    virtual UInt64 getRxQueueCapacity();
    virtual void updateRxCounter(unsigned long long);
    virtual void *getMultiCastQueue();
    virtual int getAssocState();
    virtual void notifyQueueState(apple80211_wme_ac, unsigned short);
    virtual int getTxHeadroom();
    virtual void *getRxCompQueue();
    virtual void *getTxCompQueue();
    virtual void *getTxSubQueue(apple80211_wme_ac);
    virtual void *getTxPacketPool();
    virtual void *getRxPacketPool();
    virtual void enableDatapath();
    virtual void disableDatapath();
    virtual int getNumTxQueues();
    virtual void *getLQMSummary(apple80211_lqm_summary *);
    virtual int getEventPipeSize();
    virtual UInt64 createEventPipe(IO80211APIUserClient *);
    virtual void destroyEventPipe(IO80211APIUserClient *);
private:
    virtual void _abi_0dd0() __asm__("__ZN23IO80211SkywalkInterface17setUserBufferInfoEP18IOMemoryDescriptory");
public:
    virtual void postMessageIOUC(char const *, unsigned int, void *, unsigned long);
    virtual bool isIOUCPipeOpened();
    virtual void *getRingMD(IO80211APIUserClient *, unsigned long long);
private:
    virtual void _abi_0df0() __asm__("__ZN23IO80211SkywalkInterface10attachPeerEP10ether_addr");
    virtual void _abi_0df8() __asm__("__ZN23IO80211SkywalkInterface10detachPeerEP10ether_addr");
    virtual void _abi_0e00() __asm__("__ZN23IO80211SkywalkInterface21setDebugTrafficReportEb");
    virtual void _abi_0e08() __asm__("__ZN23IO80211SkywalkInterface25getDataPathInterfaceStatsEP36apple80211_data_path_interface_stats");
    virtual void _abi_0e10() __asm__("__ZN23IO80211SkywalkInterface20getDataPathPeerStatsEP31apple80211_data_path_peer_stats");
    virtual void _abi_0e18() __asm__("__ZN23IO80211SkywalkInterface22getLastQueuePacketTimeEP10ether_addr");
    virtual void _abi_0e20() __asm__("__ZN23IO80211SkywalkInterface32getLastRxUnicastLinkActivityTimeEP10ether_addr");
    virtual void _abi_0e28() __asm__("__ZN23IO80211SkywalkInterface24updateInterfaceDataStatsEP36apple80211_data_path_interface_stats");
    virtual void _abi_0e30() __asm__("__ZN23IO80211SkywalkInterface19updatePeerDataStatsEP31apple80211_data_path_peer_stats");
    virtual void _abi_0e38() __asm__("__ZN23IO80211SkywalkInterface12logTxLatencyEPhjy");
    virtual void _abi_0e40() __asm__("__ZN23IO80211SkywalkInterface12logRxLatencyEjy");
    virtual void _abi_0e48() __asm__("__ZN23IO80211SkywalkInterface20getNClearTxRxLatencyEP25apple80211_latency_all_acS1_");
    virtual void _abi_0e50() __asm__("__ZN23IO80211SkywalkInterface18getLastTxTimeStampERy");
    virtual void _abi_0e58() __asm__("__ZN23IO80211SkywalkInterface18getLastRxTimeStampERy");
private:
    uint8_t _layout[0x118 - sizeof(IOSkywalkEthernetInterface)];
public:
    OSString *setInterfaceRole(unsigned int);
    void *setInterfaceId(unsigned int);
    int getInterfaceRole();
};
static_assert(sizeof(IO80211SkywalkInterface) == 0x118, "24H32 IO80211SkywalkInterface ABI");

class IO80211InfraInterface : public IO80211SkywalkInterface {
    OSDeclareAbstractStructors(IO80211InfraInterface)
public:
    virtual bool init() override;
    virtual void free() override;
    virtual IOReturn configureReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual IOReturn updateReport(IOReportChannelList *, unsigned int, void *, void *) override;
    virtual bool start(IOService *) override;
    virtual void stop(IOService *) override;
    virtual IOReturn setPowerState(unsigned long, IOService *) override;
    virtual SInt32 initBSDInterfaceParameters(ifnet_init_eparams *, sockaddr_dl **) override;
    virtual IOReturn prepareBSDInterface(struct __ifnet *, unsigned int) override;
    virtual IOReturn processBSDCommand(struct __ifnet *, unsigned int, void *) override;
    virtual SInt32 setInterfaceEnable(bool) override;
    virtual UInt getHardwareAssists() override;
    virtual bool bpfTap(unsigned int, unsigned int) override;
    virtual void hwConfigNicProxyData(nicproxy_info_s *) override;
    virtual void postMessage(unsigned int, void *, unsigned long, bool) override;
    virtual IOReturn recordOutputPackets(TxSubmissionDequeueStats *, TxSubmissionDequeueStats *) override;
    virtual void logTxPacket(IO80211NetworkPacket *, PacketSkywalkScratch *, apple80211_wme_ac, bool) override;
    virtual void logTxCompletionPacket(IO80211NetworkPacket *, PacketSkywalkScratch *, unsigned char *, apple80211_wme_ac, int, unsigned int, bool, bool) override;
    virtual IOReturn recordCompletionPackets(TxCompletionEnqueueStats *, TxCompletionEnqueueStats *) override;
    virtual IOReturn inputPacket(IO80211NetworkPacket *, packet_info_tag *, ether_header *, bool *, bool) override;
    virtual SInt64 pendingPackets(unsigned char) override;
    virtual SInt64 packetSpace(unsigned char) override;
    virtual bool isDebounceOnGoing() override;
    virtual IO80211LinkState linkState() override;
    virtual void setScanningState(unsigned int, bool, apple80211_scan_data *, int) override;
    virtual void setDataPathState(bool) override;
    virtual void *getScanManager() override;
    virtual void updateLinkParameters(apple80211_interface_availability *) override;
    virtual void updateInterfaceCoexRiskPct(unsigned long long) override;
    virtual void setLQM(unsigned long long) override;
    virtual void updateLinkStatus() override;
    virtual void updateLinkStatusGated() override;
    virtual void setInterfaceExtendedCCA(apple80211_channel, apple80211_cca_report *) override;
    virtual void setInterfaceCCA(apple80211_channel, int) override;
    virtual void setInterfaceNF(apple80211_channel, long long) override;
    virtual void setInterfaceOFDMDesense(apple80211_channel, long long) override;
    virtual void setDebugFlags(unsigned long long, unsigned int) override;
    virtual SInt64 debugFlags() override;
    virtual void setInterfaceChipCounters(apple80211_stat_report *, apple80211_chip_counters_tx *, apple80211_chip_error_counters_tx *, apple80211_chip_counters_rx *) override;
    virtual void setInterfaceMIBdot11(apple80211_stat_report *, apple80211_ManagementInformationBasedot11_counters *) override;
    virtual void setFrameStats(apple80211_stat_report *, apple80211_frame_counters *) override;
    virtual void setInfraSpecificFrameStats(apple80211_stat_report *, apple80211_infra_specific_stats *) override;
    virtual SInt64 getWmeTxCounters(unsigned long long *) override;
    virtual void setPeerManagerLogFlag(unsigned int, unsigned int, unsigned int) override;
    virtual void setWoWEnabled(bool) override;
    virtual bool wowEnabled() override;
    virtual UInt64 createLinkQualityMonitor(IO80211Peer *, IOService *) override;
    virtual void releaseLinkQualityMonitor(IO80211Peer *) override;
    virtual int getAssocState() override;
    virtual void *getLQMSummary(apple80211_lqm_summary *) override;
    virtual bool setLinkState(IO80211LinkState, unsigned int, bool, unsigned int) override;
    virtual IOReturn setLinkStateInternal(IO80211LinkState, unsigned int, bool, unsigned int);
    virtual void setCurrentApAddress(ether_addr *);
    virtual void setWCL_ADVISORTY_INFO(apple80211_wcl_advisory_info *);
    virtual void *getWCL_TX_RX_LATENCY(apple80211_wcl_tx_rx_latency *);

    /* Non-virtual helper called directly by AppleBCMWLANSkywalkInterface::start
     * on 24H32. Return is an IOReturn (zero means success), not bool. */
    IOReturn registerInfraEthernetInterface(
        IOSkywalkEthernetInterface::RegistrationInfo *, IOSkywalkPacketQueue **,
        unsigned int, IOSkywalkPacketBufferPool *, IOSkywalkPacketBufferPool *);
private:
    virtual void _abi_0e98() __asm__("__ZN21IO80211InfraInterface13createLQMDataEv");
    uint8_t _layout[0x120 - sizeof(IO80211SkywalkInterface)];
};
static_assert(sizeof(IO80211InfraInterface) == 0x120, "24H32 IO80211InfraInterface ABI");

/* IO80211InfraProtocol's pure virtual selector order is part of the WCL ABI.
 * Unsupported optional selectors are implemented by the concrete adapter as
 * kIOReturnUnsupported. Do not reorder this list. */
class IO80211InfraProtocol : public IO80211InfraInterface {
    OSDeclareAbstractStructors(IO80211InfraProtocol)
public:
#define RTW88_WCL_ABI_METHOD(name, type) virtual IOReturn name(type *) = 0;
    RTW88_WCL_ABI_METHOD(getCHANNEL, apple80211_channel_data)
    RTW88_WCL_ABI_METHOD(getPOWERSAVE, apple80211_powersave_data)
    RTW88_WCL_ABI_METHOD(getTXPOWER, apple80211_txpower_data)
    RTW88_WCL_ABI_METHOD(getRATE, apple80211_rate_data)
    RTW88_WCL_ABI_METHOD(getOP_MODE, apple80211_opmode_data)
    RTW88_WCL_ABI_METHOD(getRSSI, apple80211_rssi_data)
    RTW88_WCL_ABI_METHOD(getSUPPORTED_CHANNELS, apple80211_sup_channel_data)
    RTW88_WCL_ABI_METHOD(getGUARD_INTERVAL, apple80211_guard_interval_data)
    RTW88_WCL_ABI_METHOD(getMCS, apple80211_mcs_data)
    RTW88_WCL_ABI_METHOD(getPOWER_DEBUG_INFO, apple80211_power_debug_info)
    RTW88_WCL_ABI_METHOD(getHT_CAPABILITY, apple80211_ht_capability)
    RTW88_WCL_ABI_METHOD(getMCS_VHT, apple80211_mcs_vht_data)
    RTW88_WCL_ABI_METHOD(getCHANNELS_INFO, apple80211_channels_info)
    RTW88_WCL_ABI_METHOD(getVHT_CAPABILITY, apple80211_vht_capability)
    RTW88_WCL_ABI_METHOD(getROAM_PROFILE, apple80211_roam_profile_all_bands)
    RTW88_WCL_ABI_METHOD(getCHIP_COUNTER_STATS, apple80211_chip_stats)
    RTW88_WCL_ABI_METHOD(getDBG_GUARD_TIME_PARAMS, apple80211_dbg_guard_time_params)
    RTW88_WCL_ABI_METHOD(getLEAKY_AP_STATS_MODE, apple80211_leaky_ap_setting)
    RTW88_WCL_ABI_METHOD(getCOUNTRY_CHANNELS, apple80211_country_channel_data)
    RTW88_WCL_ABI_METHOD(getPRIVATE_MAC, apple80211_private_mac_data)
    RTW88_WCL_ABI_METHOD(getRANGING_ENABLE, apple80211_ranging_enable_request_t)
    RTW88_WCL_ABI_METHOD(getRANGING_START, apple80211_ranging_start_request_t)
    RTW88_WCL_ABI_METHOD(getAWDL_RSDB_CAPS, apple80211_rsdb_capability)
    RTW88_WCL_ABI_METHOD(getTKO_PARAMS, apple80211_tko_params)
    RTW88_WCL_ABI_METHOD(getTKO_DUMP, apple80211_tko_dump)
    RTW88_WCL_ABI_METHOD(getHW_SUPPORTED_CHANNELS, apple80211_sup_channel_data)
    RTW88_WCL_ABI_METHOD(getBTCOEX_PROFILE, apple80211_btcoex_profile)
    RTW88_WCL_ABI_METHOD(getBTCOEX_PROFILE_ACTIVE, apple80211_btcoex_profile_active_data)
    RTW88_WCL_ABI_METHOD(getTRAP_INFO, apple80211_trap_info_data)
    RTW88_WCL_ABI_METHOD(getTHERMAL_INDEX, apple80211_thermal_index_t)
    RTW88_WCL_ABI_METHOD(getMAX_NSS_FOR_AP, apple80211_btcoex_max_nss_for_ap_data)
    RTW88_WCL_ABI_METHOD(getBTCOEX_2G_CHAIN_DISABLE, apple80211_btcoex_2g_chain_disable)
    RTW88_WCL_ABI_METHOD(getPOWER_BUDGET, apple80211_power_budget_t)
    RTW88_WCL_ABI_METHOD(getOFFLOAD_TCPKA_ENABLE, apple80211_offload_tcpka_enable_t)
    RTW88_WCL_ABI_METHOD(getRANGING_CAPS, apple80211_ranging_capabilities_t)
    RTW88_WCL_ABI_METHOD(getLQM_CONFIG, apple80211_lqm_config_t)
    RTW88_WCL_ABI_METHOD(getTRAP_CRASHTRACER_MINI_DUMP, apple80211_trap_mini_dump_data)
    RTW88_WCL_ABI_METHOD(getBEACON_INFO, apple80211_beacon_info_t)
    RTW88_WCL_ABI_METHOD(getCHIP_POWER_RANGE, apple80211_chip_power_limit)
    RTW88_WCL_ABI_METHOD(getNSS, apple80211_nss_data)
    RTW88_WCL_ABI_METHOD(getHW_ADDR, apple80211_hw_mac_address)
    RTW88_WCL_ABI_METHOD(getCHIP_DIAGS, appl80211_chip_diags_data)
    RTW88_WCL_ABI_METHOD(getHP2P_CTRL, apple80211_hp2p_ctrl)
    RTW88_WCL_ABI_METHOD(getBSS_BLACKLIST, bss_blacklist)
    RTW88_WCL_ABI_METHOD(getTXRX_CHAIN_INFO, apple80211_txrx_chain_info)
    RTW88_WCL_ABI_METHOD(getMIMO_STATUS, apple80211_mimo_status)
    RTW88_WCL_ABI_METHOD(getCUR_PMK, apple80211_pmk)
    RTW88_WCL_ABI_METHOD(getDYNSAR_DETAIL, apple80211_dynsar_detail)
    RTW88_WCL_ABI_METHOD(getCOUNTRY_CHANNELS_INFO, apple80211_channels_info)
    RTW88_WCL_ABI_METHOD(getLQM_SUMMARY, apple80211_lqm_summary)
    RTW88_WCL_ABI_METHOD(getSLOW_WIFI_FEATURE_ENABLED, apple80211_slow_wifi_feature_enabled)
    RTW88_WCL_ABI_METHOD(getTIMESYNC_INFO, apple80211_timesync_info)
    RTW88_WCL_ABI_METHOD(getSENSING_DATA, apple80211_sensing_data_t)
    RTW88_WCL_ABI_METHOD(getWCL_FW_HOT_CHANNELS, apple80211_fw_hot_channels)
    RTW88_WCL_ABI_METHOD(getWCL_LOW_LATENCY_INFO, apple80211_low_latency_info)
    RTW88_WCL_ABI_METHOD(getWCL_BSS_INFO, apple80211_beacon_msg)
    RTW88_WCL_ABI_METHOD(getWCL_TRAFFIC_COUNTERS, apple80211_wcl_traffic_counters)
    virtual IOReturn getWCL_GET_TX_BLANKING_STATUS(unsigned int *) = 0;
    RTW88_WCL_ABI_METHOD(getHE_COUNTERS, apple80211_he_counters_ctl)
    RTW88_WCL_ABI_METHOD(getWCL_CHANNELS_INFO, apple80211ChannelInfo)
    RTW88_WCL_ABI_METHOD(getRSN_XE, apple80211_rsn_xe_data)
    RTW88_WCL_ABI_METHOD(getSIB_COEX_STATUS, apple80211_sib_coex_status)
    RTW88_WCL_ABI_METHOD(getWIFI_BT_5G_POLICY, apple80211_wifi_bt_5g_policy_t)
    RTW88_WCL_ABI_METHOD(getWCL_EXTENDED_BSS_INFO, apple80211_extended_bss_info)
    RTW88_WCL_ABI_METHOD(getWCL_LOW_LATENCY_INFO_STATS, apple80211_wcl_low_latency_stats)
    RTW88_WCL_ABI_METHOD(getWCL_BGSCAN_CACHE_RESULT, apple80211_bgscan_cached_network_data_list)
    RTW88_WCL_ABI_METHOD(getWCL_WNM_OFFLOAD, apple80211_wcl_wnm_offload_t)
    RTW88_WCL_ABI_METHOD(getWIFI_NOISE_PER_ANT, apple80211_noise_per_ant_t)
    RTW88_WCL_ABI_METHOD(getFW_CLOCK_INFO, apple80211_fw_clock_info)
    RTW88_WCL_ABI_METHOD(getTIMESYNC_STATS, apple80211_timesync_stats)
    RTW88_WCL_ABI_METHOD(getSYSTEM_SLEEP_CONFIG, apple80211_system_sleep_config)
    RTW88_WCL_ABI_METHOD(setCIPHER_KEY, apple80211_key)
    RTW88_WCL_ABI_METHOD(setCHANNEL, apple80211_channel_data)
    RTW88_WCL_ABI_METHOD(setPOWERSAVE, apple80211_powersave_data)
    RTW88_WCL_ABI_METHOD(setTXPOWER, apple80211_txpower_data)
    RTW88_WCL_ABI_METHOD(setRATE, apple80211_rate_data)
    RTW88_WCL_ABI_METHOD(setIBSS_MODE, apple80211_network_data)
    RTW88_WCL_ABI_METHOD(setAP_MODE, apple80211_apmode_data)
    RTW88_WCL_ABI_METHOD(setIE, apple80211_ie_data)
    RTW88_WCL_ABI_METHOD(setWOW_TEST, apple80211_wow_test_data)
    virtual IOReturn setCLEAR_PMKSA_CACHE(void *) = 0;
    RTW88_WCL_ABI_METHOD(setVIRTUAL_IF_CREATE, apple80211_virt_if_create_data)
    RTW88_WCL_ABI_METHOD(setHT_CAPABILITY, apple80211_ht_capability)
    RTW88_WCL_ABI_METHOD(setOFFLOAD_ARP, apple80211_offload_arp_data)
    RTW88_WCL_ABI_METHOD(setOFFLOAD_NDP, apple80211_offload_ndp_data)
    RTW88_WCL_ABI_METHOD(setGAS_REQ, apple80211_gas_query_t)
    RTW88_WCL_ABI_METHOD(setVHT_CAPABILITY, apple80211_vht_capability)
    RTW88_WCL_ABI_METHOD(setROAM_PROFILE, apple80211_roam_profile_all_bands)
    RTW88_WCL_ABI_METHOD(setDBG_GUARD_TIME_PARAMS, apple80211_dbg_guard_time_params)
    RTW88_WCL_ABI_METHOD(setLEAKY_AP_STATS_MODE, apple80211_leaky_ap_setting)
    RTW88_WCL_ABI_METHOD(setPRIVATE_MAC, apple80211_private_mac_data)
    RTW88_WCL_ABI_METHOD(setRESET_CHIP, apple80211_reset_command)
    RTW88_WCL_ABI_METHOD(setCRASH, apple80211_crash_command)
    RTW88_WCL_ABI_METHOD(setRANGING_ENABLE, apple80211_ranging_enable_request_t)
    RTW88_WCL_ABI_METHOD(setRANGING_START, apple80211_ranging_start_request_t)
    RTW88_WCL_ABI_METHOD(setRANGING_AUTHENTICATE, apple80211_ranging_authenticate_request_t)
    RTW88_WCL_ABI_METHOD(setTKO_PARAMS, apple80211_tko_params)
    RTW88_WCL_ABI_METHOD(setBTCOEX_PROFILE, apple80211_btcoex_profile)
    RTW88_WCL_ABI_METHOD(setBTCOEX_PROFILE_ACTIVE, apple80211_btcoex_profile_active_data)
    RTW88_WCL_ABI_METHOD(setTHERMAL_INDEX, apple80211_thermal_index_t)
    RTW88_WCL_ABI_METHOD(setBTCOEX_2G_CHAIN_DISABLE, apple80211_btcoex_2g_chain_disable)
    RTW88_WCL_ABI_METHOD(setPOWER_BUDGET, apple80211_power_budget_t)
    RTW88_WCL_ABI_METHOD(setOFFLOAD_TCPKA_ENABLE, apple80211_offload_tcpka_enable_t)
    RTW88_WCL_ABI_METHOD(setLQM_CONFIG, apple80211_lqm_config_t)
    RTW88_WCL_ABI_METHOD(setDYNAMIC_RSSI_WINDOW_CONFIG, apple80211_dynamic_rssi_window_config)
    RTW88_WCL_ABI_METHOD(setUSB_HOST_NOTIFICATION, apple80211_usb_host_notification_data)
    RTW88_WCL_ABI_METHOD(setHP2P_CTRL, apple80211_hp2p_ctrl)
    RTW88_WCL_ABI_METHOD(setBSS_BLACKLIST, bss_blacklist)
    RTW88_WCL_ABI_METHOD(setSET_PROPERTY, apple80211_set_property_unserialized_data)
    RTW88_WCL_ABI_METHOD(setROAM_CACHE_UPDATE, apple80211_roam_cache_data)
    RTW88_WCL_ABI_METHOD(setPM_MODE, apple80211_pm_mode)
    RTW88_WCL_ABI_METHOD(setSET_WIFI_ASSERTION_STATE, apple80211_wifi_assertion_data)
    RTW88_WCL_ABI_METHOD(setREALTIME_QOS_MSCS, apple80211_state_data)
    RTW88_WCL_ABI_METHOD(setSENSING_ENABLE, apple80211_sensing_enable_t)
    RTW88_WCL_ABI_METHOD(setSENSING_DISABLE, apple80211_sensing_disable_t)
    RTW88_WCL_ABI_METHOD(set6G_MODE, apple80211_6G_mode)
    RTW88_WCL_ABI_METHOD(setWCL_LEAVE_NETWORK, apple80211_leave_network)
    RTW88_WCL_ABI_METHOD(setWCL_REASSOC, apple80211_reassoc)
    RTW88_WCL_ABI_METHOD(setWCL_SET_ROAM_LOCK, apple80211_set_roam_lock)
    RTW88_WCL_ABI_METHOD(setWCL_LEGACY_ROAM_PROFILE_CONFIG, apple80211_legacy_roam_profile_config)
    RTW88_WCL_ABI_METHOD(setWCL_ROAM_PROFILE_CONFIG, apple80211_roam_profile_config)
    RTW88_WCL_ABI_METHOD(setWCL_ROAM_USER_CACHE, apple80211_user_roam_cache)
    virtual IOReturn setWCL_SCAN_ABORT(void *) = 0;
    RTW88_WCL_ABI_METHOD(setWCL_REAL_TIME_MODE, apple80211_wcl_real_time_mode)
    RTW88_WCL_ABI_METHOD(setWCL_ARP_MODE, apple80211_wcl_arp_mode)
    virtual IOReturn setWCL_JOIN_ABORT(void *) = 0;
    RTW88_WCL_ABI_METHOD(setWCL_TRIGGER_CC, triggerCC)
    RTW88_WCL_ABI_METHOD(setWCL_SCAN_REQ, apple80211ScanRequest)
    RTW88_WCL_ABI_METHOD(setWCL_ASSOCIATE, apple80211AssocCandidates)
    RTW88_WCL_ABI_METHOD(setWCL_QOS_PARAMS, apple80211_wcl_qos_params)
    virtual IOReturn setWCL_LINK_UP_DONE(void *) = 0;
    RTW88_WCL_ABI_METHOD(setWCL_SET_SCAN_HOME_AWAY_TIME, scanHomeAndAwayTime)
    RTW88_WCL_ABI_METHOD(setVOICE_IND_STATE, apple80211_voice_ind_state)
    RTW88_WCL_ABI_METHOD(setWCL_LINK_STATE_UPDATE, apple80211_wcl_update_link_state)
    RTW88_WCL_ABI_METHOD(setRSN_XE, apple80211_rsn_xe_data)
    RTW88_WCL_ABI_METHOD(setWIFI_BT_5G_POLICY, apple80211_wifi_bt_5g_policy_t)
    RTW88_WCL_ABI_METHOD(setWCL_ULOFDMA_STATE, apple80211_wcl_ulofdma_state)
    RTW88_WCL_ABI_METHOD(setWCL_ACTION_FRAME, apple80211_wcl_action_frame)
    virtual IOReturn setGAS_ABORT(void *) = 0;
    RTW88_WCL_ABI_METHOD(setOS_FEATURE_FLAGS, apple80211_feature_flags)
    RTW88_WCL_ABI_METHOD(setDHCP_RENEWAL_DATA, apple80211_dhcp_renewal_data)
    RTW88_WCL_ABI_METHOD(setBATTERY_POWERSAVE_CONFIG, apple80211_battery_ps_config)
    RTW88_WCL_ABI_METHOD(setMIMO_CONFIG, apple80211_mimo_config)
    RTW88_WCL_ABI_METHOD(setWCL_CONFIG_BG_MOTIONPROFILE, apple80211_bg_motion_profile)
    RTW88_WCL_ABI_METHOD(setWCL_CONFIG_BG_NETWORK, apple80211_bg_network)
    RTW88_WCL_ABI_METHOD(setWCL_CONFIG_BGSCAN, apple80211_bg_scan)
    RTW88_WCL_ABI_METHOD(setWCL_CONFIG_BG_PARAMS, apple80211_bg_params)
    RTW88_WCL_ABI_METHOD(setPOWER_PROFILE, apple80211_power_profile)
    virtual IOReturn setHEARTBEAT(void *) = 0;
    RTW88_WCL_ABI_METHOD(setINTERFACE_SETTING, apple80211_interface_setting)
    RTW88_WCL_ABI_METHOD(setBYPASS_TX_POWER_CAP, apple80211_bypass_tx_power_cap)
    RTW88_WCL_ABI_METHOD(setFACETIME_WIFICALLING_PARAMS, apple80211_facetime_wificalling_params)
    RTW88_WCL_ABI_METHOD(setIPV4_PARAMS, apple80211_ipv4_params)
    RTW88_WCL_ABI_METHOD(setWCL_WNM_OPS, apple80211_wcl_wnm_config_t)
    RTW88_WCL_ABI_METHOD(setWCL_WNM_OFFLOAD, apple80211_wcl_wnm_offload_t)
    RTW88_WCL_ABI_METHOD(setWCL_LIMITED_AGGREGATION, apple80211_limited_aggregation_config)
    RTW88_WCL_ABI_METHOD(setWCL_BCN_MUTE_CONFIG, apple80211_bcn_mute_config)
    RTW88_WCL_ABI_METHOD(setEAP_FILTER_CONFIG, apple80211_eap_filter_config)
    RTW88_WCL_ABI_METHOD(setWOW_LOW_POWER_MODE, apple80211_wow_low_power_mode)
    RTW88_WCL_ABI_METHOD(setDUAL_POWER_MODE, apple80211_dual_power_mode_params)
    RTW88_WCL_ABI_METHOD(setWCL_UPDATE_FAST_LANE, apple80211_fastlane)
    RTW88_WCL_ABI_METHOD(setWCL_ASSOCIATED_SLEEP, apple80211_associated_sleep_config)
    RTW88_WCL_ABI_METHOD(setCONGESTION_CTRL_IND, apple80211_congestion_control_indication)
    RTW88_WCL_ABI_METHOD(setSTAND_ALONE_MODE_STATE, apple80211_standalone_state)
    RTW88_WCL_ABI_METHOD(setIPV6_PARAMS, apple80211_ipv6_params)
    RTW88_WCL_ABI_METHOD(setINFRA_ENUMERATED, apple80211_infra_enumerated)
    RTW88_WCL_ABI_METHOD(setLMTPC_CONFIG, apple80211_lmtpc_config)
    RTW88_WCL_ABI_METHOD(setTRAFFIC_ENG_PARAMS, apple80211_traffic_eng_params)
    RTW88_WCL_ABI_METHOD(setLE_SCAN_PARAM, apple80211_le_scan_params)
    RTW88_WCL_ABI_METHOD(setTIMESYNC_GPIO, apple80211_timesync_gpio)
    RTW88_WCL_ABI_METHOD(setHOST_CLOCK_INFO, apple80211_host_clock_info)
    RTW88_WCL_ABI_METHOD(setFW_CLOCK_SOURCE, apple80211_fw_clock_source)
    RTW88_WCL_ABI_METHOD(setTIMESYNC_TX_POLICY, apple80211_timesync_tx_policy)
    RTW88_WCL_ABI_METHOD(setTIMESYNC_RX_POLICY, apple80211_timesync_rx_policy)
    RTW88_WCL_ABI_METHOD(setTIMESTAMPING_EN, apple80211_timestamping_en)
    RTW88_WCL_ABI_METHOD(setWCL_SOI_CONFIG, appl80211_sleep_on_inactivity_config)
    RTW88_WCL_ABI_METHOD(setMWS_TIME_SHARING_WIFI_ENH, apple80211_mws_time_sharing)
    RTW88_WCL_ABI_METHOD(setMWS_WIFI_TYPE_7_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_ABI_METHOD(setMWS_COEX_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_ABI_METHOD(setMWS_DISABLE_OCL_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_ABI_METHOD(setMWS_RFEM_CONFIG_WIFI_ENH, apple80211_mws_rfem_config)
    RTW88_WCL_ABI_METHOD(setMWS_ASSOC_PROTECTION_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_ABI_METHOD(setMWS_SCAN_FREQ_WIFI_ENH, apple80211_mws_scan_freq)
    RTW88_WCL_ABI_METHOD(setMWS_SCAN_FREQ_MODE_WIFI_ENH, apple80211_mws_scan_freq_mode)
    RTW88_WCL_ABI_METHOD(setMWS_CONDITION_ID_BITMAP_WIFI_ENH, apple80211_mws_condition_id_config)
    RTW88_WCL_ABI_METHOD(setMWS_ANTENNA_SELECTION_WIFI_ENH, apple80211_mws_antenna_selection)
    RTW88_WCL_ABI_METHOD(setNDD_REQ, apple80211_ndd_data)
    RTW88_WCL_ABI_METHOD(setDBRG_ENTROPY, apple80211_drbg_entropy)
    RTW88_WCL_ABI_METHOD(setSDB_ENABLE, apple80211_sdb_enable)
    RTW88_WCL_ABI_METHOD(setMWS_ACCESSORY_POWER_LIMIT_WIFI_ENH, apple80211_mws_accessory_power_limit)
#undef RTW88_WCL_ABI_METHOD
};
static_assert(sizeof(IO80211InfraProtocol) == 0x120, "24H32 IO80211InfraProtocol ABI");
