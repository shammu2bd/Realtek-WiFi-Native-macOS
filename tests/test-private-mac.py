"""Exercise PRIVATE_MAC Off/Fixed/Rotating state and source integration."""
from pathlib import Path
import shutil
import subprocess
import tempfile

kext = Path(__file__).resolve().parents[1] / 'driver/RTL88WiFi/src/kext'
s = (kext / 'RTL88WiFi.cpp').read_text()

def block(start_marker, end_marker):
    a = s.index(start_marker)
    b = s.index(end_marker, a) + len(end_marker)
    return s[a:b]

def fn(signature):
    start = s.index(signature)
    i = s.index('{', start) + 1
    depth = 1
    while depth:
        depth += (s[i] == '{') - (s[i] == '}')
        i += 1
    return s[start:i]

struct_src = block('struct rtw88_private_mac_data {', '};') + '\n' + \
    block('static_assert(sizeof(rtw88_private_mac_data) == 28', ');')
handler_src = fn('__attribute__((__noinline__)) IOReturn RTL88WiFi::handleRequestPRIVATE_MAC(')
h = (kext / 'RTL88WiFi.hpp').read_text()
assert 'case APPLE80211_IOC_PRIVATE_MAC:\n        return handleRequestPRIVATE_MAC(isSet, data);' in s
assert 'const bool privateMacBridge' in s
assert 'handlePrivateMACBSDRequest(cmd, req, "legacy-ioctl")' in s
assert 'apple80211_ioctl_get(IO80211Interface *interface' in h
assert 'apple80211_ioctl_get(IO80211SkywalkInterface *skywalkInterface' in h
assert 'RTL88WiFi::apple80211_ioctl_get(IO80211SkywalkInterface *skywalkInterface' in s
assert 'RTL88WiFi::apple80211_ioctl_get(IO80211Interface *interface' in s
assert 'legacy-split-set' in s and 'skywalk-split-set' in s
assert 'skywalk-split-get' in s and 'STA_PRIVATE_MAC_GET_SEEN' in s
assert 'privateMacTimerFired' in s and 'armPrivateMACTimer(self->_privMacIntervalS * 1000U)' in s
assert 'getPermanentMACAddress(desired)' in s

prefix = r'''
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cassert>
#include <cstddef>
#include <strings.h>
typedef int IOReturn;
#define kIOReturnSuccess 0
#define kIOReturnBadArgument (-1)
static int logs = 0;
#define IOLog(...) (logs++)
static constexpr uint32_t kRTW88PrivateMacMaxIntervalS = UINT32_MAX / 1000U;
static void read_random(void *p, unsigned n) { static uint8_t seed=0x31; auto *b=(uint8_t*)p; while(n--) *b++=++seed; }
static bool rtw88MacIsZero(const uint8_t m[6]) { return !(m[0]|m[1]|m[2]|m[3]|m[4]|m[5]); }
static bool rtw88MacIsUnicast(const uint8_t m[6]) { return !rtw88MacIsZero(m) && !(m[0]&1); }
static void rtw88MakeLocallyAdministered(uint8_t m[6]) { m[0]=(uint8_t)((m[0]&0xfcU)|0x02U); }
static void rtw88GeneratePrivateMAC(uint8_t m[6]) { read_random(m,6); rtw88MakeLocallyAdministered(m); }
struct FakeTimer { uint32_t timeout=0; void setTimeoutMS(uint32_t n) { timeout=n; } };
''' + struct_src + r'''
struct FakeIEEE { uint8_t mac[6]={}; void getMACAddress(uint8_t *out) { memcpy(out,mac,6); } };
class RTL88WiFi {
public:
    FakeIEEE *_ieee80211=nullptr;
    FakeTimer *_privateMacTimer=nullptr;
    bool _privMacEnabled=true;
    uint32_t _privMacFlags=0, _privMacIntervalS=0, _privMacGets=0;
    uint8_t _privMacAddress[6]={};
    bool _privMacAddressValid=false, _privMacApplyPending=false, _privMacRotatePending=false;
    IOReturn handleRequestPRIVATE_MAC(bool isSet, void *data);
};
'''

main = r'''
int main() {
    static_assert(offsetof(rtw88_private_mac_data, enabled)==0x04,"enabled");
    static_assert(offsetof(rtw88_private_mac_data, flags)==0x08,"flags");
    static_assert(offsetof(rtw88_private_mac_data, interval_s)==0x0c,"interval");
    static_assert(offsetof(rtw88_private_mac_data, mac)==0x10,"mac");
    static_assert(sizeof(rtw88_private_mac_data)==0x1c,"size");
    FakeIEEE ieee; const uint8_t factory[6]={0x00,0x11,0x22,0x33,0x44,0x55}; memcpy(ieee.mac,factory,6);
    FakeTimer timer; RTL88WiFi c; c._ieee80211=&ieee; c._privateMacTimer=&timer;
    uint8_t raw[28];
    auto get=[&](RTL88WiFi &ctl) { memset(raw,0xAA,sizeof(raw)); return ctl.handleRequestPRIVATE_MAC(false,raw); };
    assert(get(c)==kIOReturnSuccess);
    auto *d=reinterpret_cast<rtw88_private_mac_data *>(raw);
    assert(d->version==0 && d->pad[0]==0 && d->pad[1]==0 && d->reserved==0);
    assert(d->enabled==1 && d->flags==0 && d->interval_s==0 && memcmp(d->mac,factory,6)==0);

    /* Fixed: provided MAC becomes locally administered unicast and is queued. */
    rtw88_private_mac_data in{}; in.enabled=1; in.flags=0x5;
    const uint8_t host[6]={0x80,0x11,0x22,0x33,0x44,0x55}; memcpy(in.mac,host,6);
    assert(c.handleRequestPRIVATE_MAC(true,&in)==kIOReturnSuccess);
    const uint8_t fixed[6]={0x80,0x11,0x22,0x33,0x44,0x55};
    assert(c._privMacEnabled && c._privMacAddressValid && c._privMacApplyPending);
    assert(memcmp(c._privMacAddress,fixed,6)==0 && timer.timeout==1);
    assert(get(c)==kIOReturnSuccess && d->enabled==1 && d->flags==0x5 && d->interval_s==0 && memcmp(d->mac,fixed,6)==0);

    /* Rotating: interval is retained and the first apply is queued. */
    in.flags=0; in.interval_s=14*24*3600;
    assert(c.handleRequestPRIVATE_MAC(true,&in)==kIOReturnSuccess);
    assert(get(c)==kIOReturnSuccess && d->enabled==1 && d->interval_s==14u*24*3600 && timer.timeout==1);

    /* Off: clear private address and queue restoration of EFuse MAC. */
    in.enabled=0; in.flags=0x9; in.interval_s=0;
    assert(c.handleRequestPRIVATE_MAC(true,&in)==kIOReturnSuccess);
    assert(!c._privMacEnabled && !c._privMacAddressValid && c._privMacApplyPending);
    assert(get(c)==kIOReturnSuccess && d->enabled==0 && d->flags==0x9 && d->interval_s==0 && memcmp(d->mac,factory,6)==0);

    /* Fixed with no host-supplied address generates a private local unicast. */
    RTL88WiFi generated; generated._privateMacTimer=&timer;
    rtw88_private_mac_data noMac{}; noMac.enabled=1;
    assert(generated.handleRequestPRIVATE_MAC(true,&noMac)==kIOReturnSuccess);
    assert(generated._privMacAddressValid && (generated._privMacAddress[0]&0x03)==0x02);
    noMac.interval_s=kRTW88PrivateMacMaxIntervalS+1;
    assert(generated.handleRequestPRIVATE_MAC(true,&noMac)==kIOReturnBadArgument);

    /* Works before backend attach; GET is bounded and null-safe. */
    RTL88WiFi early; assert(get(early)==kIOReturnSuccess); for(unsigned i=0;i<6;i++) assert(d->mac[i]==0);
    RTL88WiFi poll; poll._ieee80211=&ieee; poll._privateMacTimer=&timer; logs=0;
    for(int i=0;i<1000;i++) get(poll); assert(logs==3);
    noMac.interval_s=0;
    for(int i=0;i<5;i++) poll.handleRequestPRIVATE_MAC(true,&noMac); assert(logs==8);
    puts("PASS: PRIVATE_MAC Off/Fixed/Rotating, 28-byte ABI, LAA unicast normalization, workloop apply queue, overflow guard, bounded GET logs");
}
'''
with tempfile.TemporaryDirectory(prefix='rtw88-privmac-') as td:
    td=Path(td); (td/'test.cpp').write_text(prefix+'\n'+handler_src+'\n'+main)
    compiler=['xcrun','clang++'] if shutil.which('xcrun') else ['clang++']
    subprocess.run(compiler+['-std=c++17','-fsanitize=address,undefined','-fno-sanitize-recover=all','-g',str(td/'test.cpp'),'-o',str(td/'test')],check=True)
    r=subprocess.run([str(td/'test')],capture_output=True,text=True)
    print(r.stdout.strip())
    if r.returncode: print(r.stderr[-3000:]); raise SystemExit(r.returncode)
