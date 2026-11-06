/* SPDX-License-Identifier: GPL-2.0-only
 * First concrete Sequoia 24H32 infrastructure protocol slice.
 *
 * ABI surface is kept separate from the legacy Airport frontend. Optional
 * selectors fail closed until the RTW88 backend has a truthful implementation.
 */
#pragma once

#include "RTW88WCL24H32InterfaceABI.hpp"
#include "RTW88WCLRegistrationInfo.hpp"
#include "RTW88WCLRequestDecoder.hpp"
#include "../RTW88WCLRadioBridge.hpp"
#include "../RTW88WCLWorkQueue.hpp"

class RTW88WCLController;

#define RTW88_WCL_UNSUPPORTED(name, type) \
    IOReturn name(type *data) override { \
        return data ? kIOReturnUnsupported : kIOReturnBadArgument; \
    }

class RTW88WCLInfraInterface final : public IO80211InfraProtocol,
                                     public RTW88WCLRadioEventHandler {
    OSDeclareDefaultStructors(RTW88WCLInfraInterface)
public:
    bool init() override;
    bool init(IOService *provider, ether_addr *address) override;
    void free() override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;

    /* Controller-owned stop transaction. Returns an error rather than
     * releasing queue/pool owners if Skywalk deregistration cannot complete. */
    IOReturn shutdownForController();
    bool isRegistered() const { return _registered; }
    bool isBaseStarted() const { return _baseStarted; }

    IOReturn enable(unsigned int options) override;
    IOReturn disable(unsigned int options) override;
    SInt32 initBSDInterfaceParameters(ifnet_init_eparams *params,
                                      sockaddr_dl **address) override;
    IOReturn setMacAddress(ether_addr &address) override;
    IOReturn getHardwareAddress(ether_addr *address) override;
    IOReturn setHardwareAddress(ether_addr *address) override;
    IO80211Controller *getController() override;
    bool isChipInterfaceReady() override;
    bool isDebounceOnGoing() override;
    IO80211LinkState linkState() override;
    bool setLinkState(IO80211LinkState state, unsigned int reason,
                      bool debounce, unsigned int duration) override;
    int getAssocState() override;
    UInt getHardwareAssists() override;
    bool bpfTap(unsigned int direction, unsigned int flags) override;
    void hwConfigNicProxyData(nicproxy_info_s *info) override;

    IOReturn getCHANNEL(apple80211_channel_data *data) override;
    IOReturn getRSSI(apple80211_rssi_data *data) override;
    IOReturn getSUPPORTED_CHANNELS(apple80211_sup_channel_data *data) override;
    IOReturn setCIPHER_KEY(apple80211_key *data) override;
    IOReturn setCLEAR_PMKSA_CACHE(void *data) override;
    IOReturn setWCL_LEAVE_NETWORK(apple80211_leave_network *data) override;
    IOReturn setWCL_SCAN_ABORT(void *data) override;
    IOReturn setWCL_JOIN_ABORT(void *data) override;
    IOReturn setWCL_SCAN_REQ(apple80211ScanRequest *data) override;
    IOReturn setWCL_ASSOCIATE(apple80211AssocCandidates *data) override;
    IOReturn setWCL_LINK_UP_DONE(void *data) override;
    IOReturn setWCL_LINK_STATE_UPDATE(apple80211_wcl_update_link_state *data) override;

    RTW88_WCL_UNSUPPORTED(getPOWERSAVE, apple80211_powersave_data)
    RTW88_WCL_UNSUPPORTED(getTXPOWER, apple80211_txpower_data)
    RTW88_WCL_UNSUPPORTED(getRATE, apple80211_rate_data)
    RTW88_WCL_UNSUPPORTED(getOP_MODE, apple80211_opmode_data)
    RTW88_WCL_UNSUPPORTED(getGUARD_INTERVAL, apple80211_guard_interval_data)
    RTW88_WCL_UNSUPPORTED(getMCS, apple80211_mcs_data)
    RTW88_WCL_UNSUPPORTED(getPOWER_DEBUG_INFO, apple80211_power_debug_info)
    RTW88_WCL_UNSUPPORTED(getHT_CAPABILITY, apple80211_ht_capability)
    RTW88_WCL_UNSUPPORTED(getMCS_VHT, apple80211_mcs_vht_data)
    RTW88_WCL_UNSUPPORTED(getCHANNELS_INFO, apple80211_channels_info)
    RTW88_WCL_UNSUPPORTED(getVHT_CAPABILITY, apple80211_vht_capability)
    RTW88_WCL_UNSUPPORTED(getROAM_PROFILE, apple80211_roam_profile_all_bands)
    RTW88_WCL_UNSUPPORTED(getCHIP_COUNTER_STATS, apple80211_chip_stats)
    RTW88_WCL_UNSUPPORTED(getDBG_GUARD_TIME_PARAMS, apple80211_dbg_guard_time_params)
    RTW88_WCL_UNSUPPORTED(getLEAKY_AP_STATS_MODE, apple80211_leaky_ap_setting)
    RTW88_WCL_UNSUPPORTED(getCOUNTRY_CHANNELS, apple80211_country_channel_data)
    RTW88_WCL_UNSUPPORTED(getPRIVATE_MAC, apple80211_private_mac_data)
    RTW88_WCL_UNSUPPORTED(getRANGING_ENABLE, apple80211_ranging_enable_request_t)
    RTW88_WCL_UNSUPPORTED(getRANGING_START, apple80211_ranging_start_request_t)
    RTW88_WCL_UNSUPPORTED(getAWDL_RSDB_CAPS, apple80211_rsdb_capability)
    RTW88_WCL_UNSUPPORTED(getTKO_PARAMS, apple80211_tko_params)
    RTW88_WCL_UNSUPPORTED(getTKO_DUMP, apple80211_tko_dump)
    RTW88_WCL_UNSUPPORTED(getHW_SUPPORTED_CHANNELS, apple80211_sup_channel_data)
    RTW88_WCL_UNSUPPORTED(getBTCOEX_PROFILE, apple80211_btcoex_profile)
    RTW88_WCL_UNSUPPORTED(getBTCOEX_PROFILE_ACTIVE, apple80211_btcoex_profile_active_data)
    RTW88_WCL_UNSUPPORTED(getTRAP_INFO, apple80211_trap_info_data)
    RTW88_WCL_UNSUPPORTED(getTHERMAL_INDEX, apple80211_thermal_index_t)
    RTW88_WCL_UNSUPPORTED(getMAX_NSS_FOR_AP, apple80211_btcoex_max_nss_for_ap_data)
    RTW88_WCL_UNSUPPORTED(getBTCOEX_2G_CHAIN_DISABLE, apple80211_btcoex_2g_chain_disable)
    RTW88_WCL_UNSUPPORTED(getPOWER_BUDGET, apple80211_power_budget_t)
    RTW88_WCL_UNSUPPORTED(getOFFLOAD_TCPKA_ENABLE, apple80211_offload_tcpka_enable_t)
    RTW88_WCL_UNSUPPORTED(getRANGING_CAPS, apple80211_ranging_capabilities_t)
    RTW88_WCL_UNSUPPORTED(getLQM_CONFIG, apple80211_lqm_config_t)
    RTW88_WCL_UNSUPPORTED(getTRAP_CRASHTRACER_MINI_DUMP, apple80211_trap_mini_dump_data)
    RTW88_WCL_UNSUPPORTED(getBEACON_INFO, apple80211_beacon_info_t)
    RTW88_WCL_UNSUPPORTED(getCHIP_POWER_RANGE, apple80211_chip_power_limit)
    RTW88_WCL_UNSUPPORTED(getNSS, apple80211_nss_data)
    RTW88_WCL_UNSUPPORTED(getHW_ADDR, apple80211_hw_mac_address)
    RTW88_WCL_UNSUPPORTED(getCHIP_DIAGS, appl80211_chip_diags_data)
    RTW88_WCL_UNSUPPORTED(getHP2P_CTRL, apple80211_hp2p_ctrl)
    RTW88_WCL_UNSUPPORTED(getBSS_BLACKLIST, bss_blacklist)
    RTW88_WCL_UNSUPPORTED(getTXRX_CHAIN_INFO, apple80211_txrx_chain_info)
    RTW88_WCL_UNSUPPORTED(getMIMO_STATUS, apple80211_mimo_status)
    RTW88_WCL_UNSUPPORTED(getCUR_PMK, apple80211_pmk)
    RTW88_WCL_UNSUPPORTED(getDYNSAR_DETAIL, apple80211_dynsar_detail)
    RTW88_WCL_UNSUPPORTED(getCOUNTRY_CHANNELS_INFO, apple80211_channels_info)
    RTW88_WCL_UNSUPPORTED(getLQM_SUMMARY, apple80211_lqm_summary)
    RTW88_WCL_UNSUPPORTED(getSLOW_WIFI_FEATURE_ENABLED, apple80211_slow_wifi_feature_enabled)
    RTW88_WCL_UNSUPPORTED(getTIMESYNC_INFO, apple80211_timesync_info)
    RTW88_WCL_UNSUPPORTED(getSENSING_DATA, apple80211_sensing_data_t)
    RTW88_WCL_UNSUPPORTED(getWCL_FW_HOT_CHANNELS, apple80211_fw_hot_channels)
    RTW88_WCL_UNSUPPORTED(getWCL_LOW_LATENCY_INFO, apple80211_low_latency_info)
    RTW88_WCL_UNSUPPORTED(getWCL_BSS_INFO, apple80211_beacon_msg)
    RTW88_WCL_UNSUPPORTED(getWCL_TRAFFIC_COUNTERS, apple80211_wcl_traffic_counters)
    RTW88_WCL_UNSUPPORTED(getHE_COUNTERS, apple80211_he_counters_ctl)
    RTW88_WCL_UNSUPPORTED(getWCL_CHANNELS_INFO, apple80211ChannelInfo)
    RTW88_WCL_UNSUPPORTED(getRSN_XE, apple80211_rsn_xe_data)
    RTW88_WCL_UNSUPPORTED(getSIB_COEX_STATUS, apple80211_sib_coex_status)
    RTW88_WCL_UNSUPPORTED(getWIFI_BT_5G_POLICY, apple80211_wifi_bt_5g_policy_t)
    RTW88_WCL_UNSUPPORTED(getWCL_EXTENDED_BSS_INFO, apple80211_extended_bss_info)
    RTW88_WCL_UNSUPPORTED(getWCL_LOW_LATENCY_INFO_STATS, apple80211_wcl_low_latency_stats)
    RTW88_WCL_UNSUPPORTED(getWCL_BGSCAN_CACHE_RESULT, apple80211_bgscan_cached_network_data_list)
    RTW88_WCL_UNSUPPORTED(getWCL_WNM_OFFLOAD, apple80211_wcl_wnm_offload_t)
    RTW88_WCL_UNSUPPORTED(getWIFI_NOISE_PER_ANT, apple80211_noise_per_ant_t)
    RTW88_WCL_UNSUPPORTED(getFW_CLOCK_INFO, apple80211_fw_clock_info)
    RTW88_WCL_UNSUPPORTED(getTIMESYNC_STATS, apple80211_timesync_stats)
    RTW88_WCL_UNSUPPORTED(getSYSTEM_SLEEP_CONFIG, apple80211_system_sleep_config)
    RTW88_WCL_UNSUPPORTED(setCHANNEL, apple80211_channel_data)
    RTW88_WCL_UNSUPPORTED(setPOWERSAVE, apple80211_powersave_data)
    RTW88_WCL_UNSUPPORTED(setTXPOWER, apple80211_txpower_data)
    RTW88_WCL_UNSUPPORTED(setRATE, apple80211_rate_data)
    RTW88_WCL_UNSUPPORTED(setIBSS_MODE, apple80211_network_data)
    RTW88_WCL_UNSUPPORTED(setAP_MODE, apple80211_apmode_data)
    RTW88_WCL_UNSUPPORTED(setIE, apple80211_ie_data)
    RTW88_WCL_UNSUPPORTED(setWOW_TEST, apple80211_wow_test_data)
    RTW88_WCL_UNSUPPORTED(setVIRTUAL_IF_CREATE, apple80211_virt_if_create_data)
    RTW88_WCL_UNSUPPORTED(setHT_CAPABILITY, apple80211_ht_capability)
    RTW88_WCL_UNSUPPORTED(setOFFLOAD_ARP, apple80211_offload_arp_data)
    RTW88_WCL_UNSUPPORTED(setOFFLOAD_NDP, apple80211_offload_ndp_data)
    RTW88_WCL_UNSUPPORTED(setGAS_REQ, apple80211_gas_query_t)
    RTW88_WCL_UNSUPPORTED(setVHT_CAPABILITY, apple80211_vht_capability)
    RTW88_WCL_UNSUPPORTED(setROAM_PROFILE, apple80211_roam_profile_all_bands)
    RTW88_WCL_UNSUPPORTED(setDBG_GUARD_TIME_PARAMS, apple80211_dbg_guard_time_params)
    RTW88_WCL_UNSUPPORTED(setLEAKY_AP_STATS_MODE, apple80211_leaky_ap_setting)
    RTW88_WCL_UNSUPPORTED(setPRIVATE_MAC, apple80211_private_mac_data)
    RTW88_WCL_UNSUPPORTED(setRESET_CHIP, apple80211_reset_command)
    RTW88_WCL_UNSUPPORTED(setCRASH, apple80211_crash_command)
    RTW88_WCL_UNSUPPORTED(setRANGING_ENABLE, apple80211_ranging_enable_request_t)
    RTW88_WCL_UNSUPPORTED(setRANGING_START, apple80211_ranging_start_request_t)
    RTW88_WCL_UNSUPPORTED(setRANGING_AUTHENTICATE, apple80211_ranging_authenticate_request_t)
    RTW88_WCL_UNSUPPORTED(setTKO_PARAMS, apple80211_tko_params)
    RTW88_WCL_UNSUPPORTED(setBTCOEX_PROFILE, apple80211_btcoex_profile)
    RTW88_WCL_UNSUPPORTED(setBTCOEX_PROFILE_ACTIVE, apple80211_btcoex_profile_active_data)
    RTW88_WCL_UNSUPPORTED(setTHERMAL_INDEX, apple80211_thermal_index_t)
    RTW88_WCL_UNSUPPORTED(setBTCOEX_2G_CHAIN_DISABLE, apple80211_btcoex_2g_chain_disable)
    RTW88_WCL_UNSUPPORTED(setPOWER_BUDGET, apple80211_power_budget_t)
    RTW88_WCL_UNSUPPORTED(setOFFLOAD_TCPKA_ENABLE, apple80211_offload_tcpka_enable_t)
    RTW88_WCL_UNSUPPORTED(setLQM_CONFIG, apple80211_lqm_config_t)
    RTW88_WCL_UNSUPPORTED(setDYNAMIC_RSSI_WINDOW_CONFIG, apple80211_dynamic_rssi_window_config)
    RTW88_WCL_UNSUPPORTED(setUSB_HOST_NOTIFICATION, apple80211_usb_host_notification_data)
    RTW88_WCL_UNSUPPORTED(setHP2P_CTRL, apple80211_hp2p_ctrl)
    RTW88_WCL_UNSUPPORTED(setBSS_BLACKLIST, bss_blacklist)
    RTW88_WCL_UNSUPPORTED(setSET_PROPERTY, apple80211_set_property_unserialized_data)
    RTW88_WCL_UNSUPPORTED(setROAM_CACHE_UPDATE, apple80211_roam_cache_data)
    RTW88_WCL_UNSUPPORTED(setPM_MODE, apple80211_pm_mode)
    RTW88_WCL_UNSUPPORTED(setSET_WIFI_ASSERTION_STATE, apple80211_wifi_assertion_data)
    RTW88_WCL_UNSUPPORTED(setREALTIME_QOS_MSCS, apple80211_state_data)
    RTW88_WCL_UNSUPPORTED(setSENSING_ENABLE, apple80211_sensing_enable_t)
    RTW88_WCL_UNSUPPORTED(setSENSING_DISABLE, apple80211_sensing_disable_t)
    RTW88_WCL_UNSUPPORTED(set6G_MODE, apple80211_6G_mode)
    RTW88_WCL_UNSUPPORTED(setWCL_REASSOC, apple80211_reassoc)
    RTW88_WCL_UNSUPPORTED(setWCL_SET_ROAM_LOCK, apple80211_set_roam_lock)
    RTW88_WCL_UNSUPPORTED(setWCL_LEGACY_ROAM_PROFILE_CONFIG, apple80211_legacy_roam_profile_config)
    RTW88_WCL_UNSUPPORTED(setWCL_ROAM_PROFILE_CONFIG, apple80211_roam_profile_config)
    RTW88_WCL_UNSUPPORTED(setWCL_ROAM_USER_CACHE, apple80211_user_roam_cache)
    RTW88_WCL_UNSUPPORTED(setWCL_REAL_TIME_MODE, apple80211_wcl_real_time_mode)
    RTW88_WCL_UNSUPPORTED(setWCL_ARP_MODE, apple80211_wcl_arp_mode)
    RTW88_WCL_UNSUPPORTED(setWCL_TRIGGER_CC, triggerCC)
    RTW88_WCL_UNSUPPORTED(setWCL_QOS_PARAMS, apple80211_wcl_qos_params)
    RTW88_WCL_UNSUPPORTED(setWCL_SET_SCAN_HOME_AWAY_TIME, scanHomeAndAwayTime)
    RTW88_WCL_UNSUPPORTED(setVOICE_IND_STATE, apple80211_voice_ind_state)
    RTW88_WCL_UNSUPPORTED(setRSN_XE, apple80211_rsn_xe_data)
    RTW88_WCL_UNSUPPORTED(setWIFI_BT_5G_POLICY, apple80211_wifi_bt_5g_policy_t)
    RTW88_WCL_UNSUPPORTED(setWCL_ULOFDMA_STATE, apple80211_wcl_ulofdma_state)
    RTW88_WCL_UNSUPPORTED(setWCL_ACTION_FRAME, apple80211_wcl_action_frame)
    RTW88_WCL_UNSUPPORTED(setOS_FEATURE_FLAGS, apple80211_feature_flags)
    RTW88_WCL_UNSUPPORTED(setDHCP_RENEWAL_DATA, apple80211_dhcp_renewal_data)
    RTW88_WCL_UNSUPPORTED(setBATTERY_POWERSAVE_CONFIG, apple80211_battery_ps_config)
    RTW88_WCL_UNSUPPORTED(setMIMO_CONFIG, apple80211_mimo_config)
    RTW88_WCL_UNSUPPORTED(setWCL_CONFIG_BG_MOTIONPROFILE, apple80211_bg_motion_profile)
    RTW88_WCL_UNSUPPORTED(setWCL_CONFIG_BG_NETWORK, apple80211_bg_network)
    RTW88_WCL_UNSUPPORTED(setWCL_CONFIG_BGSCAN, apple80211_bg_scan)
    RTW88_WCL_UNSUPPORTED(setWCL_CONFIG_BG_PARAMS, apple80211_bg_params)
    RTW88_WCL_UNSUPPORTED(setPOWER_PROFILE, apple80211_power_profile)
    RTW88_WCL_UNSUPPORTED(setINTERFACE_SETTING, apple80211_interface_setting)
    RTW88_WCL_UNSUPPORTED(setBYPASS_TX_POWER_CAP, apple80211_bypass_tx_power_cap)
    RTW88_WCL_UNSUPPORTED(setFACETIME_WIFICALLING_PARAMS, apple80211_facetime_wificalling_params)
    RTW88_WCL_UNSUPPORTED(setIPV4_PARAMS, apple80211_ipv4_params)
    RTW88_WCL_UNSUPPORTED(setWCL_WNM_OPS, apple80211_wcl_wnm_config_t)
    RTW88_WCL_UNSUPPORTED(setWCL_WNM_OFFLOAD, apple80211_wcl_wnm_offload_t)
    RTW88_WCL_UNSUPPORTED(setWCL_LIMITED_AGGREGATION, apple80211_limited_aggregation_config)
    RTW88_WCL_UNSUPPORTED(setWCL_BCN_MUTE_CONFIG, apple80211_bcn_mute_config)
    RTW88_WCL_UNSUPPORTED(setEAP_FILTER_CONFIG, apple80211_eap_filter_config)
    RTW88_WCL_UNSUPPORTED(setWOW_LOW_POWER_MODE, apple80211_wow_low_power_mode)
    RTW88_WCL_UNSUPPORTED(setDUAL_POWER_MODE, apple80211_dual_power_mode_params)
    RTW88_WCL_UNSUPPORTED(setWCL_UPDATE_FAST_LANE, apple80211_fastlane)
    RTW88_WCL_UNSUPPORTED(setWCL_ASSOCIATED_SLEEP, apple80211_associated_sleep_config)
    RTW88_WCL_UNSUPPORTED(setCONGESTION_CTRL_IND, apple80211_congestion_control_indication)
    RTW88_WCL_UNSUPPORTED(setSTAND_ALONE_MODE_STATE, apple80211_standalone_state)
    RTW88_WCL_UNSUPPORTED(setIPV6_PARAMS, apple80211_ipv6_params)
    RTW88_WCL_UNSUPPORTED(setINFRA_ENUMERATED, apple80211_infra_enumerated)
    RTW88_WCL_UNSUPPORTED(setLMTPC_CONFIG, apple80211_lmtpc_config)
    RTW88_WCL_UNSUPPORTED(setTRAFFIC_ENG_PARAMS, apple80211_traffic_eng_params)
    RTW88_WCL_UNSUPPORTED(setLE_SCAN_PARAM, apple80211_le_scan_params)
    RTW88_WCL_UNSUPPORTED(setTIMESYNC_GPIO, apple80211_timesync_gpio)
    RTW88_WCL_UNSUPPORTED(setHOST_CLOCK_INFO, apple80211_host_clock_info)
    RTW88_WCL_UNSUPPORTED(setFW_CLOCK_SOURCE, apple80211_fw_clock_source)
    RTW88_WCL_UNSUPPORTED(setTIMESYNC_TX_POLICY, apple80211_timesync_tx_policy)
    RTW88_WCL_UNSUPPORTED(setTIMESYNC_RX_POLICY, apple80211_timesync_rx_policy)
    RTW88_WCL_UNSUPPORTED(setTIMESTAMPING_EN, apple80211_timestamping_en)
    RTW88_WCL_UNSUPPORTED(setWCL_SOI_CONFIG, appl80211_sleep_on_inactivity_config)
    RTW88_WCL_UNSUPPORTED(setMWS_TIME_SHARING_WIFI_ENH, apple80211_mws_time_sharing)
    RTW88_WCL_UNSUPPORTED(setMWS_WIFI_TYPE_7_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_UNSUPPORTED(setMWS_COEX_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_UNSUPPORTED(setMWS_DISABLE_OCL_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_UNSUPPORTED(setMWS_RFEM_CONFIG_WIFI_ENH, apple80211_mws_rfem_config)
    RTW88_WCL_UNSUPPORTED(setMWS_ASSOC_PROTECTION_BITMAP_WIFI_ENH, apple80211_mws_wifi_channel_bitmap)
    RTW88_WCL_UNSUPPORTED(setMWS_SCAN_FREQ_WIFI_ENH, apple80211_mws_scan_freq)
    RTW88_WCL_UNSUPPORTED(setMWS_SCAN_FREQ_MODE_WIFI_ENH, apple80211_mws_scan_freq_mode)
    RTW88_WCL_UNSUPPORTED(setMWS_CONDITION_ID_BITMAP_WIFI_ENH, apple80211_mws_condition_id_config)
    RTW88_WCL_UNSUPPORTED(setMWS_ANTENNA_SELECTION_WIFI_ENH, apple80211_mws_antenna_selection)
    RTW88_WCL_UNSUPPORTED(setNDD_REQ, apple80211_ndd_data)
    RTW88_WCL_UNSUPPORTED(setDBRG_ENTROPY, apple80211_drbg_entropy)
    RTW88_WCL_UNSUPPORTED(setSDB_ENABLE, apple80211_sdb_enable)
    RTW88_WCL_UNSUPPORTED(setMWS_ACCESSORY_POWER_LIMIT_WIFI_ENH, apple80211_mws_accessory_power_limit)
        RTW88_WCL_UNSUPPORTED(getWCL_GET_TX_BLANKING_STATUS, unsigned int)
    RTW88_WCL_UNSUPPORTED(setGAS_ABORT, void)
    RTW88_WCL_UNSUPPORTED(setHEARTBEAT, void)

    void handleRTW88WCLRadioEvent(const RTW88WCLRadioEvent &event) override;

    IOReturn attachRadio(RTW88IEEE80211 *radio);
    void detachRadio();
    RTW88WCLRadioBridge *radioBridge() { return &_bridge; }

private:
    struct ScanFilter {
        uint32_t identifier;
        uint8_t ssid[32];
        uint8_t ssidLength;
        uint8_t bssid[6];
        uint8_t channelBitmap[32];
        bool filterBSSID;
        bool filterChannels;
    };
    bool scanResultMatches(const RTW88BSS &bss) const;
    void publishScanResults(IOReturn status);
    bool prepareRegistrationInfo(const ether_addr &address);
    IOReturn attachControllerInterface();
    IOReturn detachControllerInterface();
    void clearRegistrationInfo();
    void postConnectionComplete(uint16_t status, uint16_t reason,
                                IOReturn driverStatus);
    void maybePublishConnected();
    IOReturn postWCLMessage(unsigned int message, void *payload,
                            unsigned long length);

    RTW88WCLController *_controller = nullptr; // provider-owned
    RTW88WCLRadioBridge _bridge;
    RTW88WCLWorkQueue *_workQueue = nullptr;   // interface-owned
    ScanFilter _scanFilter = {};
    uint8_t _targetBSSID[6] = {0};
    bool _scanActive = false;
    uint32_t _activeScanGeneration = 0;
    uint32_t _activeJoinGeneration = 0;
    bool _assocNotified = false;
    bool _connectNotified = false;
    bool _stopping = false;
    bool _baseStarted = false;
    bool _controllerAttached = false;
    bool _registered = false;

    /* Opaque 24H32 payload storage remains resident until the interface has
     * successfully deregistered from the Skywalk QueueSet. */
    RTW88WCLRegistrationInfo24H32::Storage _registrationInfo = {};
    bool _registrationInfoPrepared = false;
};

#undef RTW88_WCL_UNSUPPORTED
