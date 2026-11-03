#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLRequestDecoder.hpp"

static void put16(uint8_t *p, uint16_t v)
{
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = static_cast<uint8_t>(v);
    p[1] = static_cast<uint8_t>(v >> 8);
    p[2] = static_cast<uint8_t>(v >> 16);
    p[3] = static_cast<uint8_t>(v >> 24);
}

static std::vector<uint8_t> makeScan()
{
    std::vector<uint8_t> data(0x58 + 12, 0);
    put32(data.data() + 0x00, 7);       // request identifier
    const uint8_t bssid[] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
    memcpy(data.data() + 0x14, bssid, sizeof(bssid));
    put32(data.data() + 0x1c, 3);
    memcpy(data.data() + 0x20, "lab", 3);
    put32(data.data() + 0x40, 1);       // active scan
    put32(data.data() + 0x54, 1);
    put32(data.data() + 0x58 + 4, 36);
    put32(data.data() + 0x58 + 8, 0x10); // 5 GHz
    return data;
}

static std::vector<uint8_t> makeOpenJoin()
{
    std::vector<uint8_t> data(0x218 + 18, 0);
    put32(data.data() + 0x10, 1);       // open-system lower auth
    put32(data.data() + 0x14, 0);       // no upper auth
    put32(data.data() + 0x1c, 3);
    memcpy(data.data() + 0x20, "lab", 3);
    const uint8_t bssid[] = {0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee};
    memcpy(data.data() + 0x21c, bssid, sizeof(bssid));
    put32(data.data() + 0x214, 1);      // one candidate
    return data;
}

static std::vector<uint8_t> makeWpa2PmkJoin()
{
    std::vector<uint8_t> data = makeOpenJoin();
    put32(data.data() + 0x14, 1U << 3); // WPA2-PSK
    put32(data.data() + 0x44, 32);
    put32(data.data() + 0x48, 6);       // PMK
    for (unsigned i = 0; i < 32; ++i) data[0x50 + i] = static_cast<uint8_t>(i + 1);
    put16(data.data() + 0xd4, 4);
    data[0xd6] = 48; data[0xd7] = 2; data[0xd8] = 1; data[0xd9] = 0;
    return data;
}

int main()
{
    using namespace RTW88WCLRequest;

    Scan scan = {};
    std::vector<uint8_t> scanBytes = makeScan();
    assert(decodeScan(scanBytes.data(), scanBytes.size(), scan));
    assert(scan.identifier == 7 && scan.type == 1 && scan.ssidLength == 3);
    assert(memcmp(scan.ssid, "lab", 3) == 0);
    assert(scan.channelBitmap[36 / 8] & (1U << (36 % 8)));
    assert(!decodeScan(scanBytes.data(), 0x57, scan));

    auto badScan = scanBytes;
    put32(badScan.data() + 0x54, 401);
    assert(!decodeScan(badScan.data(), badScan.size(), scan));
    badScan = scanBytes;
    put32(badScan.data() + 0x40, 0);
    assert(!decodeScan(badScan.data(), badScan.size(), scan));

    Join join = {};
    auto open = makeOpenJoin();
    assert(decodeJoin(open.data(), open.size(), join));
    assert(join.upperAuth == 0 && join.keyLength == 0 && join.ssidLength == 3);

    auto wpa2 = makeWpa2PmkJoin();
    assert(decodeJoin(wpa2.data(), wpa2.size(), join));
    assert(join.upperAuth == (1U << 3) && join.keyLength == 32);
    assert(join.rsnLength == 4 && join.rsn[0] == 48);

    auto tooShort = wpa2;
    assert(!decodeJoin(tooShort.data(), 0x217, join));
    auto manyCandidates = wpa2;
    put32(manyCandidates.data() + 0x214, 11);
    assert(!decodeJoin(manyCandidates.data(), manyCandidates.size(), join));
    auto multicastBssid = open;
    multicastBssid[0x21c] = 0x03;
    assert(!decodeJoin(multicastBssid.data(), multicastBssid.size(), join));
    auto passphrase = wpa2;
    put32(passphrase.data() + 0x44, 12);
    put32(passphrase.data() + 0x48, 10);
    assert(!decodeJoin(passphrase.data(), passphrase.size(), join));
    auto wep = open;
    put32(wep.data() + 0x14, 0);
    put32(wep.data() + 0x44, 5);
    put32(wep.data() + 0x48, 1);
    assert(!decodeJoin(wep.data(), wep.size(), join));

    auto enterprise = wpa2;
    put32(enterprise.data() + 0x14, 1U << 2); // WPA2-802.1X is not implemented
    assert(!decodeJoin(enterprise.data(), enterprise.size(), join));
    auto sha256Psk = wpa2;
    put32(sha256Psk.data() + 0x14, 1U << 7); // SHA256-PSK not implemented
    assert(!decodeJoin(sha256Psk.data(), sha256Psk.size(), join));
    auto noPmk = wpa2;
    put32(noPmk.data() + 0x44, 0);
    assert(!decodeJoin(noPmk.data(), noPmk.size(), join));
    auto badPmkCipher = wpa2;
    put32(badPmkCipher.data() + 0x48, 5); // TKIP/AES key material is not a PMK
    assert(!decodeJoin(badPmkCipher.data(), badPmkCipher.size(), join));
    auto openWithRsn = open;
    put16(openWithRsn.data() + 0xd4, 4);
    openWithRsn[0xd6] = 48; openWithRsn[0xd7] = 2;
    openWithRsn[0xd8] = 1; openWithRsn[0xd9] = 0;
    assert(!decodeJoin(openWithRsn.data(), openWithRsn.size(), join));

    puts("WCL request decoder: all tests passed");
    return 0;
}
