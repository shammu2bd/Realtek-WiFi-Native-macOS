/* Modified by X1REN41L on 2026-10-14 for RTL88WiFi 1.0.1; see the repository NOTICE.md. */
/* Modified on 2026-10-23 for RTL88WiFi 1.0.2 (AWDL radio policy, mesh join selection); see NOTICE.md. */
/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * RTW88IEEE80211.hpp — 802.11 state machine for rtw88 macOS port.
 *
 * Responsibilities:
 *  - Drives the Linux rtw88 driver (rtw_core_start/stop, rtw_tx, etc.)
 *  - Manages scan, authenticate, associate, 4-way handshake
 *  - Converts between mbuf_t and sk_buff for the driver
 *  - Delivers decrypted data frames as Ethernet to RTW88PCIDevice
 *  - Accepts Ethernet output frames and wraps them as 802.11 data frames
 */
#pragma once

#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOLocks.h>
#include <sys/mbuf.h>
#include <net/ethernet.h>
#include <kern/thread_call.h>
#include "RTW88JoinPolicy.hpp"
#include "RTW88RoamScanPolicy.hpp"
#include "RTW88BaPolicy.hpp"
#include "RTW88TxSequenceNumbers.hpp"
#include "RTW88TxStateGate.hpp"
#include "RTW88TxBAState.hpp"
#include "RTW88TxFrameProtection.hpp"

/* Opaque C driver handle */
struct rtw_dev;
struct pci_dev;
struct ieee80211_hw;
struct ieee80211_vif;
struct ieee80211_sta;
struct ieee80211_channel;
struct ieee80211_scan_request;
struct sk_buff;

/* Eventos async para integracion nativa (RTL88WiFi) */
enum RTW88Event {
    kRTW88EventScanDone,
    kRTW88EventAssocDone,
    kRTW88EventDeauth,
    kRTW88EventDisconnected,
    kRTW88EventRSSIChanged,
    /* Complete controlled-port transition (open association or WPA2 M3). */
    kRTW88EventConnected,
};

class RTW88EventDelegate {
public:
    virtual void rtw88Event(RTW88Event ev, void *data) = 0;
    virtual ~RTW88EventDelegate() {}
};

class RTW88PCIDevice;

/* Interfaz de acceso a hardware compartida -- antes _pci_io_ops llamaba
 * directo a metodos de RTW88PCIDevice via g_pci_dev_instance (tipado a
 * esa clase). Ahora cualquiera de los dos kexts (RTW88PCIDevice o
 * RTL88WiFi) puede implementarla, y g_pci_dev_instance pasa a ser
 * de este tipo generico. */
/* Struct compartida para tracking de buffers DMA -- antes vivia solo
 * adentro de RTW88PCIDevice; ahora la comparten ambas clases. */
struct RTW88DMAEntry {
    IOBufferMemoryDescriptor *desc;
    void    *virt;
    IOPhysicalAddress phys;
    size_t   size;
    void    *orig_va;
    RTW88DMAEntry *next;
};

class RTW88HwOps;
extern RTW88HwOps *g_pci_dev_instance;
struct pci_ops_rtw88;
struct rtw88_dma_alloc_ops;
extern struct pci_ops_rtw88 _pci_io_ops;
extern struct rtw88_dma_alloc_ops _dma_ops;

class RTW88HwOps {
public:
    virtual UInt8  pciReadByte(int offset) = 0;
    virtual UInt16 pciReadWord(int offset) = 0;
    virtual UInt32 pciReadDword(int offset) = 0;
    virtual void   pciWriteByte(int offset, UInt8 val) = 0;
    virtual void   pciWriteWord(int offset, UInt16 val) = 0;
    virtual void   pciWriteDword(int offset, UInt32 val) = 0;
    virtual int    pciFindCapability(int cap) = 0;
    virtual volatile void *mmioBase() const = 0;
    virtual void  *allocCoherent(size_t size, IOPhysicalAddress *phys) = 0;
    virtual void   freeCoherent(size_t size, void *virt, IOPhysicalAddress phys) = 0;
    virtual void   freeCoherentByPhys(IOPhysicalAddress phys) = 0;
    virtual void   setBounceOrigVA(IOPhysicalAddress phys, void *orig_va) = 0;
    virtual void   syncBounceForCpu(IOPhysicalAddress dma, size_t size) = 0;
    virtual void   resumeTxIfStalled() = 0;
    virtual ~RTW88HwOps() {}
};


/* Interfaz minima que necesita RTW88IEEE80211 de su "padre" -- antes
 * asumia directamente RTW88PCIDevice, lo cual rompia el link en
 * RTL88WiFi (que no compila esa clase). Ahora cualquiera de los dos
 * kexts puede ser el padre con tal de implementar esto. */
class RTW88RxDelegate {
public:
    virtual mbuf_t allocateInputPacket(uint32_t len) = 0;
    virtual void injectRxFrame(mbuf_t m) = 0;
    /* Optional native 802.11 action-frame sink for AWDL/P2P controllers. */
    virtual void injectRxActionFrame(const uint8_t *frame, uint32_t len, int8_t rssi, uint16_t channel) {
        (void)frame; (void)len; (void)rssi; (void)channel;
    }
    /* Optional AWDL Ethernet sink. Default consumes the packet so legacy
     * IOEthernet parents that do not expose an AWDL VIF cannot leak it. */
    virtual void injectRxAWDLFrame(mbuf_t m) { if (m) mbuf_freem(m); }
    virtual IOWorkLoop *getRxWorkLoop() = 0;
    virtual void setLinkStatus(UInt32 status) = 0;
    virtual ~RTW88RxDelegate() {}
};

/* ------------------------------------------------------------------ */
/*  BSS descriptor (scan result)                                        */
/* ------------------------------------------------------------------ */
struct RTW88Channel { uint16_t number; bool passive; bool radar; };

struct RTW88BSS {
    char   ssid[33];
    uint8_t ssid_len;
    uint8_t bssid[6];
    int16_t rssi;
    uint16_t freq;
    uint8_t  channel;
    uint32_t capabilities;
    uint16_t beacon_interval;
    uint32_t cipher;       /* selected pairwise WLAN_CIPHER_SUITE_* */
    uint32_t group_cipher; /* selected group WLAN_CIPHER_SUITE_* */
    uint32_t akm;
    /* RSN capabilities we must not silently ignore: SAE is recorded so a
     * transition BSS can explicitly use WPA2-PSK fallback; MFPR requires
     * protected management frames, which this port does not yet implement. */
    uint8_t  rsn_has_sae;
    uint8_t  rsn_pmf_required;
    uint32_t last_seen_scan;
    /* Final: a beacon from this BSSID carried a non-empty, non-zero SSID, so
     * the AP is not hidden even if a later frame has a blank SSID element. */
    uint8_t  beacon_named;
    /* Raw IE data for association */
    uint8_t  ies[512];
    uint16_t ies_len;
    RTW88BSS *next;
};

/* BSS operating width advertised by the HT Operation (61) and VHT
 * Operation (192) IEs.  Shared by the connection chandef and scan results. */
struct RTW88BssOperation {
    int     sco;         /* HT secondary-channel offset: 1=above 3=below */
    bool    htStaWidth;  /* HT "STA Channel Width" (40 MHz allowed)      */
    int     vhtWidth;    /* VHT op channel width: >=1 means 80 MHz        */
    uint8_t vhtSeg0;     /* VHT center-frequency segment 0 (center chan)  */
};

/* ------------------------------------------------------------------ */
/*  Connection state                                                     */
/* ------------------------------------------------------------------ */
enum RTW88State {
    RTW88_STATE_IDLE = 0,
    RTW88_STATE_SCANNING,
    RTW88_STATE_AUTHENTICATING,
    RTW88_STATE_ASSOCIATING,
    RTW88_STATE_HANDSHAKING,
    RTW88_STATE_CONNECTED,
    RTW88_STATE_DISCONNECTING,
};

/* ------------------------------------------------------------------ */
/*  RTW88IEEE80211                                                       */
/* ------------------------------------------------------------------ */
typedef void (*RTW88TxCompletionCallback)(void *context, void *cookie,
                                           bool transmitted);

class RTW88IEEE80211 : public OSObject {
public:
    RTW88EventDelegate *_delegate = nullptr;
    OSDeclareDefaultStructors(RTW88IEEE80211)

public:
    static RTW88IEEE80211 *create(RTW88PCIDevice *dev, struct pci_dev *pci);
    static RTW88IEEE80211 *createAirport(RTW88RxDelegate *delegate, struct pci_dev *pci);

    bool      init(RTW88PCIDevice *dev, struct pci_dev *pci);
    bool      init(RTW88RxDelegate *delegate, struct pci_dev *pci);
    void      free() override;

    /* Called by RTW88PCIDevice */
    IOReturn  start();       /* probe: chip info, efuse, register hw */
    void      stop();        /* full teardown */
    IOReturn setReceiveMulticast(bool active);
    IOReturn setAWDLReceiveMode(bool active);
    IOReturn setAWDLChannel(uint16_t channel);
    /* RTL88WiFi 1.0.2 policy.  AWDL (AirDrop/Continuity) has never completed a
     * peer exchange on this driver, yet while the awdl0 interface exists the
     * scheduler (a) puts the NIC in near-promiscuous receive mode and (b)
     * parks the radio on channels 6/44/149 and stalls en0 transmit, which is
     * what overflowed the 256-packet output queue under upload.  Default:
     * the AWDL virtual interface exists but never takes the radio.  Set the
     * Info.plist property RTL88WiFiAWDLRadio to true to restore the old
     * behaviour for experiments. */
    /* 1.0.4 band policy (Info.plist key RTL88WiFiPrefer5GHz, default true): when
     * macOS asks for a 2.4 GHz node but a usable 5 GHz node of the same SSID is
     * known, join the 5 GHz node.  False honours the requested BSSID exactly. */
    void setPrefer5GHzUpgrade(bool on) { _prefer5GHzUpgrade = on; }
    void setAWDLRadioAllowed(bool allowed) { _awdlRadioAllowed = allowed; }
    bool awdlRadioAllowed() const { return _awdlRadioAllowed; }
    bool canTransmitAWDL() const;
    bool staAssociatedForAWDL() const { return __atomic_load_n(&_associatedVisible, __ATOMIC_ACQUIRE) && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED; }
    uint16_t infrastructureChannel() const { return _targetBSS.channel; }
    bool staTxBlockedByAWDL() const { return _awdlOffChannel; }
    void restoreSTAChannelAfterAWDL();
    void setAWDLAddress(const uint8_t *mac);
    IOReturn  powerOn();     /* enable: rtw_core_start */
    void      powerOff();    /* disable: rtw_core_stop */
    void      handleInterrupt();
    UInt32    outputPacket(mbuf_t m);
    /* Optional hardware completion hook for native packet adapters. The
     * callback may run in interrupt/teardown context and must only enqueue a
     * bounded completion record; it must not call Skywalk directly. */
    UInt32    outputPacketWithCompletion(
                                         mbuf_t m,
                                         RTW88TxCompletionCallback callback,
                                         void *context, void *cookie,
                                         uint8_t accessCategory = 2,
                                         uint8_t tid = 0);
    bool      txRawManagementFrame(const uint8_t *frame, uint32_t len);
    /* Native AWDL Ethernet -> 802.11 direct data encapsulation. Consumes m. */
    bool      txAWDLDataFrame(mbuf_t m);
    void      getMACAddress(uint8_t *mac);
    void      getPermanentMACAddress(uint8_t *mac);
    IOReturn  setMACAddress(const uint8_t *mac);
    IOReturn  setRegulatoryCountry(const char alpha2[2]);

    /* Called from compat layer (ieee80211_rx_irqsafe) */
    void      rxFrame(struct sk_buff *skb);
    void      txStatus(struct sk_buff *skb);
    void      scanDone(bool aborted);

    /* Control interface — called from RTW88UserClient */
    uint32_t deauthReason() const { return _deauthReason; }
    RTW88State rawState() const { return __atomic_load_n(&_state, __ATOMIC_ACQUIRE); }
    bool associatedVisible() const { return __atomic_load_n(&_associatedVisible, __ATOMIC_ACQUIRE); }
    /* Connected scans are bounded to candidate channels for the current ESS.
     * Disconnected scans retain the normal full-channel discovery behavior. */
    IOReturn  cmdScan(const uint16_t *requestedChannels = nullptr,
                      uint32_t requestedCount = 0);
    /* Native WCL scan-abort entry point. Uses the existing bounded abort
     * primitive so scan and join state remain owned by the RTW88 backend. */
    IOReturn  cmdAbortScan();
    IOReturn  cmdConnect(const char *ssid, const char *password, const uint8_t *pmk = nullptr,
                         const uint8_t *bssid = nullptr, bool externalSupplicant = false);
    IOReturn  cmdInstallExternalKey(bool pairwise, uint8_t keyidx, uint32_t cipher,
                                    const uint8_t *key, uint8_t key_len);
    bool      externalKeysReady() const { return __atomic_load_n(&_externalPTKInstalled, __ATOMIC_ACQUIRE) && __atomic_load_n(&_externalGTKInstalled, __ATOMIC_ACQUIRE); }
    IOReturn  cmdSetAssocRsnIE(const uint8_t *ie, uint16_t len);
    void      clearAssocRsnIE();
    bool      matchesPendingJoin(const char *ssid, const uint8_t *bssid, const uint8_t *pmk) const;
    void      failJoin(const char *stage);
    IOReturn  copyTargetIEs(uint8_t *out, uint32_t capacity, uint32_t *len) const;
    IOReturn  copyTargetRsnIE(uint8_t *out, uint16_t capacity, uint16_t *len) const;
    IOReturn copyScanBSS(uint32_t index, RTW88BSS *out);
    IOReturn copyCurrentBSS(RTW88BSS *out);
    IOReturn copyChannels(RTW88Channel *out, uint32_t capacity, uint32_t *count);
    IOReturn  cmdDisconnect();
    IOReturn  cmdPowerOn();
    IOReturn  cmdPowerOff();
    IOReturn  suspendForSystemSleep();
    bool      isPowered() const { return __atomic_load_n(&_powered, __ATOMIC_ACQUIRE); }
    IOReturn  cmdGetState(struct RTW88StateResult *result);
    uint8_t   txNSS() const;
    uint8_t channelWidthMHz() const { return _connChanWidth; }
    static void parseBssOperation(const uint8_t *ies, uint16_t ielen, RTW88BssOperation *op);
    bool txAggregationActive() const { return _txBaState.active(); }
    /* 1.0.6: periodic upkeep of a connected link (currently: re-negotiating a lost
     * or declined uplink Block Ack agreement).  Called about every 5 s by the
     * controller's diagnostic timer, inside its hardware-safe window. */
    void housekeeping();
    uint32_t receivedFrameCount() const { return _rxFrameCount; }
    const char *scanEngine() const { return _scanEngine; }
    uint32_t scanChannelCount() const { return _lastScanChannelCount; }
    uint32_t scanVisited2GHz() const { return _scanVisited2GHz; }
    uint32_t scanVisited5GHz() const { return _scanVisited5GHz; }
    uint32_t scanCacheCount() const { return _lastScanCacheCount; }
    uint32_t scanGeneration() const { return _scanGeneration; }

    void setEventDelegate(RTW88EventDelegate *d) { _delegate = d; }
    void setRxDelegate(RTW88RxDelegate *d) { _parent = d; }
    IOReturn  cmdGetBSSList(uint8_t *buf, uint32_t *len);
    IOReturn  cmdGetRSSI(int *rssi);

private:
    /* State machine internals */
    void      processRxMgmt(struct sk_buff *skb);
    void      processRxData(struct sk_buff *skb);
    void      processScanResult(struct sk_buff *skb);
    void      processAssocResponse(struct sk_buff *skb);

    void      doAuthenticate();
    void      cancelAuthentication();
    void      clearDeferredJoin();
    bool authenticationCancelled() const { return __atomic_load_n(&_connectCancelled, __ATOMIC_ACQUIRE); }
    void      doAssociate();
    void      setConnectedChandef(struct ieee80211_channel *chan,
                                  RTW88TxStateGate::MutationLease *existingMutation = nullptr);
    void      doHandshake(const uint8_t *eapol, uint32_t len);
    void      doDisconnect();
    RTW88TxStateGate::MutationLease beginTxStateMutation();
    void      setRadioState(RTW88State state);
    void      clearKeys();
    void      releaseSta();
    bool      abortActiveScan(bool waitForIdle);
    void      restoreConnectedChannel();
    bool      installKey(struct ieee80211_key_conf **slot, bool pairwise,
                         uint8_t keyidx, uint32_t cipher,
                         const uint8_t *tk, uint8_t tk_len);
    bool      installKeyUnderMutation(struct ieee80211_key_conf **slot, bool pairwise,
                         uint8_t keyidx, uint32_t cipher, const uint8_t *tk,
                         uint8_t tk_len, RTW88TxStateGate::MutationLease *mutation);

    bool      buildAssocReq(uint8_t *buf, uint32_t *len);
    bool      buildAuthReq(uint8_t *buf, uint32_t *len);

    /* 1.0.2 multi-BSS (mesh) join.  *Locked helpers need _bssLock held. */
    RTW88BSS *selectBssLocked(const char *ssid, size_t ssidLen, const uint8_t *pinned,
                              bool skipTried, int privacyMatch);
    /* The BSS to join for a request: the pinned BSSID when macOS named a known
     * one, else the best node.  1.0.4: a pinned 2.4 GHz node is upgraded to a
     * fresh, usable 5 GHz node of the same SSID (see _prefer5GHzUpgrade). */
    RTW88BSS *selectBssForJoinLocked(const char *ssid, size_t ssidLen, const uint8_t *pinned,
                                     bool *upgraded);
    bool      hasUntriedAlternativeLocked();
    void      applyAssocRsnOverride(bool externalSupplicant, bool havePmk, bool havePassword);
    bool      retryOtherBss(const char *stage);     /* true: now joining another BSS */
    void      joinAttemptFailed(const char *stage); /* retry elsewhere, else failJoin() */

    /* WPA2 4-way handshake */
    void      handleEAPOL(const uint8_t *data, uint32_t len);
    bool      deriveKeys(const uint8_t *anonce, const uint8_t *snonce);
    bool      sendEAPOLKey(int step, const uint8_t *replay_counter,
                            bool install, bool ack, bool mic,
                            RTW88TxStateGate::TransmitLease *existingLease = nullptr);

    /* A-MPDU BlockAck (aggregation) negotiation */
    bool      htAllowed() const;   /* HT/VHT/A-MPDU usable on this link? */
    void      startTxAggregation();
    void      sendAddbaRequest(uint8_t tid,
                               RTW88TxStateGate::TransmitLease *existingLease = nullptr);
    void      sendAddbaResponse(uint8_t tid, uint8_t dialog,
                                uint16_t req_param, uint16_t ba_timeout,
                                uint16_t status = 0);
    void      handleBackAction(const uint8_t *b, uint32_t len);

    /* RX A-MPDU reorder + delivery */
    void      deliverDataFrame(struct sk_buff *skb);   /* strip 802.11, inject */
    void      deAmsdu(const uint8_t *data, uint32_t len);
    void      deliverEthernet(const uint8_t *da, const uint8_t *sa,
                              uint16_t ethertype,
                              const uint8_t *payload, uint32_t paylen);
    void      rxBaSetup(uint8_t tid, uint16_t ssn, uint16_t bufsize);
    void      rxBaTeardown(uint8_t tid);
    void      rxBaTeardownAll();
    void      rxReorderInput(uint8_t tid, struct sk_buff *skb, uint16_t sn);
    void      rxReorderArmTimer();
    void      rxReorderFlushStale();
    static void reorderTimerFired(OSObject *owner, IOTimerEventSource *t);

    /* Frame transmission helpers */
    bool      txMgmtFrame(const uint8_t *frame, uint32_t len,
                          RTW88TxStateGate::TransmitLease *existingLease = nullptr);
    bool      txNullFunc(bool powerSave,
                          RTW88TxStateGate::TransmitLease *existingLease = nullptr);
    bool      txProbeRequest();
    uint16_t  nextTxSequence();
    uint16_t  nextDataSequence(uint8_t tid);
    uint16_t  currentDataSequence(uint8_t tid) const;
    bool      txDataFrame(mbuf_t m,
                          RTW88TxCompletionCallback callback = nullptr,
                          void *completionContext = nullptr,
                          void *completionCookie = nullptr,
                          uint8_t accessCategory = 2,
                          uint8_t tid = 0,
                          bool protectEapol = false,
                          bool allowHandshakeEapol = false,
                          RTW88TxStateGate::TransmitLease *existingLease = nullptr);
    bool      tryDeliverAWDLDataFrame(struct sk_buff *skb);
    void      deliverAWDLEthernet(const uint8_t *da, const uint8_t *sa,
                                  uint16_t ethertype,
                                  const uint8_t *payload, uint32_t paylen);
    struct sk_buff *mbufToSkb(mbuf_t m);
    mbuf_t    skbToMbuf(struct sk_buff *skb);

    /* Driver callbacks installed in rtw_dev */
    static void compat_rx_frame(void *kext_hw, struct sk_buff *skb);
    static void compat_tx_status(void *kext_hw, struct sk_buff *skb);
    static void compat_scan_done(void *kext_hw, bool aborted);

    /* Timer callback for state machine timeouts */
    static void timerFired(OSObject *owner, IOTimerEventSource *timer);
    void        onTimer();

    /* Connect thread_call — runs doAuthenticate off the IOUserClient thread */
    static void connectTCFn(thread_call_param_t self, thread_call_param_t);
    thread_call_t _connectTC = nullptr;

    /* Manual passive scan fallback for chips/firmware without scan offload */
    static void manualScanTCFn(thread_call_param_t self, thread_call_param_t);
    void        runManualScan();
    thread_call_t _manualScanTC = nullptr;

    /* ---------------------------------------------------------------- */
    RTW88RxDelegate   *_parent        = nullptr;
    struct rtw_dev    *_rtwdev        = nullptr;
    struct ieee80211_hw *_hw          = nullptr;
    struct ieee80211_vif *_vif        = nullptr;
    struct ieee80211_sta *_sta        = nullptr;
    size_t              _staAllocSize = 0;
    size_t              _vifAllocSize = 0;
    struct pci_dev     *_pcidev       = nullptr;

    IOWorkLoop         *_wl           = nullptr;
    RTW88TxStateGate    _txStateGate;
    volatile bool       _dataTxBlocked = true;
    IOCommandGate      *_gate         = nullptr;
    IOTimerEventSource *_timer        = nullptr;
    IOLock             *_lock         = nullptr;

    RTW88State          _state        = RTW88_STATE_IDLE;
    /* Persistent IO80211 RUN latch.  net80211 (the reference IO80211 driver) keeps its
     * infrastructure state at IEEE80211_S_RUN from association completion
     * until a real deauth/disconnect.  rtw88 has extra transient internal
     * states, so keep that externally-visible RUN fact separately instead of
     * making SSID/BSSID/CHANNEL queries depend on a momentary backend state. */
    bool                _associatedVisible = false;
    bool                _connectCancelled = true;
    uint32_t            _deauthReason = 0;
    RTW88State          _scanReturnState = RTW88_STATE_IDLE;
    bool                _powered      = false;
    bool                _pmkProvided = false;
    bool                _externalSupplicant = false;
    bool                _externalPTKInstalled = false;
    bool                _externalGTKInstalled = false;
    bool                _receiveMulticast = true;
    bool                _awdlReceiveMode = false;
    uint16_t            _awdlChannel = 0;
    uint16_t            _awdlPreparedChannel = 0;
    bool                _awdlOffChannel = false;
    bool                _awdlRadioAllowed = false;   /* see setAWDLRadioAllowed() */
    bool                _awdlPolicyLogged = false;
    uint8_t             _awdlAddress[6] = {};
    uint8_t             _macAddr[6]   = {};
    uint8_t             _permanentMacAddr[6] = {};
    uint32_t            _timeoutMs    = 0;

    /* Scan results */
    RTW88BSS           *_bssList      = nullptr;
    uint32_t            _bssCount     = 0;
    IOLock             *_bssLock      = nullptr;
    uint32_t            _scanGeneration = 0;
    bool                _scanPartial = false; /* connected, bounded scan: do not age/prune unscanned BSSs */
    const char *        _scanEngine = "not-started";
    uint32_t            _lastScanChannelCount = 0, _lastScanCacheCount = 0;
    uint32_t            _scanVisited2GHz = 0, _scanVisited5GHz = 0;
    struct ieee80211_scan_request *_scanRequest = nullptr;
    struct ieee80211_channel *_scanRequestChannels[256] = {};
    struct ieee80211_channel *_manualScanChannels[256] = {};
    uint32_t            _manualScanChannelCount = 0;
    volatile bool       _manualScanAbort = false;
    volatile bool       _manualScanOnHomeChannel = false;
    bool                _manualScanFallbackLogged = false;

    /* Association requested while the radio is still finishing a scan.
     * The reference IO80211 driver/net80211 accepts ASSOCIATE in SCAN and lets the state
     * machine continue into AUTH instead of returning EBUSY.  rtw88 has a
     * separate scan implementation, so preserve the request and start it as
     * soon as scanDone() returns the backend to IDLE. */
    bool                _deferredConnectPending = false;
    /* One full refresh is allowed when ASSOCIATE names a BSS missing from the
     * cache; the refreshed retry still honours the exact requested BSSID. */
    bool                _missingBssRescanAttempted = false;
    char                _deferredSSID[33] = {};
    char                _deferredPassword[64] = {};
    uint8_t             _deferredPMK[32] = {};
    bool                _deferredPMKValid = false;
    uint8_t             _deferredBSSID[6] = {};
    bool                _deferredBSSIDValid = false;
    bool                _deferredExternalSupplicant = false;

    /* Target BSS for connection */
    RTW88BSS            _targetBSS    = {};
    char                _password[64] = {};
    uint8_t             _authAttempts = 0;
    /* 1.0.2: nodes that recently failed and nodes already tried in this join. */
    RTW88Join::FailMemory _joinFail;
    RTW88Join::TriedSet   _joinTried;
    bool                  _prefer5GHzUpgrade = true;
    bool                  _joinHasRequested = false;   /* BSSID macOS named, when we joined another */
    uint8_t               _joinRequestedBssid[6] = {};

    /* WPA2 key material */
    uint8_t  _pmk[32]  = {};
    uint8_t  _ptk[64]  = {};   /* PTK = KCK|KEK|TK */
    uint8_t  _gtk[32]  = {};
    struct ieee80211_key_conf *_ptkConf = nullptr;
    struct ieee80211_key_conf *_gtkConf = nullptr;
    uint8_t  _anonce[32] = {};
    uint8_t  _snonce[32] = {};
    uint8_t  _replayCtr[8] = {};
    uint8_t  _installedM3ReplayCtr[8] = {};
    bool     _snonceValid = false;
    bool     _m3KeysInstalled = false;
    bool     _handshakePending = false;
    RTW88TxSequenceNumbers _txSequenceNumbers;
    bool     _rxCcmpIvSkipLogged = false;
    /* r10: the scan-cache entry of the associated BSS has a TIM element
     * (beacon-derived). Until it does, beacons from that BSS refresh it while
     * connected, so CoreWLAN's AP_IE_LIST hidden/broadcast check passes. */
    volatile bool _curBssTim = false;
    uint32_t _rxUndecryptedProtected = 0;  /* protected data without HW decrypt */
    uint32_t _rxUnprotectedDropped = 0;    /* plaintext data after PTK install */
    uint32_t _rxNonSnapDropped = 0;        /* single MSDU without LLC/SNAP */
    uint32_t _rxAmsduSpoofDropped = 0;     /* A-MSDU whose first DA is LLC/SNAP */
    uint32_t _rxTrailerChecks = 0;         /* one-shot IPv4 length checks */
    bool     _wpa2     = false;
    uint8_t  _assocRsnIE[257] = {};
    uint16_t _assocRsnIELen = 0;

    /* Sequence number for TX frames */
    /* RTW88TxSequenceNumbers owns the atomic management, per-TID QoS and
     * 48-bit CCMP packet-number spaces shared by concurrent AC callbacks. */
    uint16_t _awdlDataSeq = 0;
    uint16_t _assocAID = 0;

    /* A-MPDU aggregation (BlockAck) state */
    RTW88TxBAState _txBaState;      /* atomic active+TID snapshot shared by four AC submitters */
    uint8_t  _baTid      = 0;      /* TID carrying aggregated data (BE)        */
    uint8_t  _connChanWidth = 20;  /* negotiated operating width: 20/40/80 MHz */
    uint8_t  _baDialog   = 0;      /* rolling ADDBA-request dialog token       */
    bool     _txBaPending = false;
    RTW88Ba::Recovery _baRecovery;      /* when to (re)send ADDBA; see RTW88BaPolicy.hpp */
    uint16_t _baBufSize  = 64;     /* advertised BlockAck buffer/window size   */

    /* RX A-MPDU reorder buffer — one per TID with an active downlink BA.
     * Touched from the RX workloop (frame input) and the IEEE80211 workloop
     * (flush timer, disconnect teardown), so guarded by _rxBaLock.  Frames are
     * always delivered with the lock dropped to avoid holding it across the
     * network-stack input path. */
    static const uint16_t kRxBaMaxBuf   = 64;
    static const uint8_t  kRxBaNumTid   = 8;   /* QoS data TIDs 0-7 */
    static const uint32_t kReorderTimeoutMs = 60;
    struct RxReorder {
        bool      active;
        uint16_t  headSn;          /* next expected SN (12-bit, mod 4096) */
        uint16_t  bufSize;         /* reorder window size */
        uint32_t  stored;          /* frames currently buffered */
        struct sk_buff *buf[kRxBaMaxBuf];   /* indexed by SN % bufSize */
    };
    RxReorder *_rxBa[kRxBaNumTid] = {};
    IOLock    *_rxBaLock      = nullptr;
    IOTimerEventSource *_reorderTimer = nullptr;
    bool _reorderTimerArmed = false; // accessed only on the RX workloop

    /* RSSI tracking */
    int      _rssi     = -100;

    /* Diagnostics: periodic logging of RX activity during scan */
    uint32_t _rxFrameCount = 0;
};
