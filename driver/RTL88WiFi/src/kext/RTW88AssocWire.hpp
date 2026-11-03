#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Sequoia 900-byte and Tahoe 908-byte ASSOCIATE envelopes.
// Validate the shared prefix independently; never interpret the unknown tail.
// Mode and both auth fields use 32 bits rather than the Ventura controller ABI.
// Never cast this wire prefix to apple80211_assoc_data.
// Accepts open, WPA2-PSK, and WPA2-PSK fallback from transition mode; the unknown tail is not interpreted as RSN.
namespace RTW88AssocWire {
constexpr size_t RequestSize = 900, TahoeRequestSize = 908, PrefixSize = 108;
inline bool supportedRequestSize(size_t n) {
    return n == RequestSize || n == TahoeRequestSize;
}
struct Personal {
    uint32_t mode, lower, upper, ssidLength, keyLength, cipher;
    uint8_t ssid[32], bssid[6], key[32];
};
inline uint32_t le32(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
}
inline bool decode(const uint8_t *p, size_t n, Personal &out) {
    if (!p || n != PrefixSize || le32(p)!=1 || le32(p+4)!=2 || le32(p+8)!=1)
        return false;
    const uint32_t upper=le32(p+12), ssidLength=le32(p+16), keyLength=le32(p+64);
    const uint32_t keyVersion=le32(p+60);
    /* WPA3-SAE is disabled.  A transition-mode request may be downgraded
     * only when WPA2-PSK is also explicitly present; SAE-only is rejected.
     * The decoded request is normalized to WPA2-PSK so the SAE bit never
     * reaches the association backend as a capability we do not implement. */
    constexpr uint32_t kWpa2Psk = 1U << 3;
    constexpr uint32_t kWpa3Sae = 1U << 9;
    const bool open = upper == 0;
    const bool psk = upper == kWpa2Psk || upper == (kWpa2Psk | kWpa3Sae);
    /* For an open network macOS supplies no key object; its embedded key
     * version is therefore zero.  WPA2 must still carry the version-1 key
     * object.  Requiring version 1 for an empty open request caused a valid
     * host32 request to fall through and be misread as Ventura's 16-bit ABI
     * (lower=0, upper=1, ssidLen=0). */
    const bool keyHeaderValid = open ? (keyVersion == 0 || keyVersion == 1)
                                     : (keyVersion == 1);
    if ((!open && !psk) || !ssidLength || ssidLength>32 || !keyHeaderValid ||
        (psk ? keyLength!=32 : keyLength!=0)) return false;
    for (uint32_t i=0;i<ssidLength;++i) if (!p[20+i]) return false;
    if (p[52]&1) return false; // A selected BSSID must be unicast (zero is allowed).
    out={};out.mode=2;out.lower=1;out.upper=psk ? kWpa2Psk : 0;out.ssidLength=ssidLength;
    out.keyLength=keyLength;out.cipher=le32(p+68);
    memcpy(out.ssid,p+20,ssidLength);memcpy(out.bssid,p+52,6);
    if (keyLength) memcpy(out.key,p+76,keyLength);
    return true;
}
inline void wipe(void *p,size_t n) {
    volatile uint8_t *q=static_cast<volatile uint8_t *>(p);while(n--) *q++=0;
}
}
