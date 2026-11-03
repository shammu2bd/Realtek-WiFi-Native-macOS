"""Validate the host 32-bit ASSOCIATE prefix for open and WPA2 joins.
Open requests legitimately have an empty key object (key-version 0).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1] / 'driver/RTL88WiFi'
header = root / 'src/kext/RTW88AssocWire.hpp'
source = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include "RTW88AssocWire.hpp"
using namespace RTW88AssocWire;
static void le32put(uint8_t *p, uint32_t v) { p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static void base(uint8_t p[PrefixSize], uint32_t upper, uint32_t keyLen,
                 uint32_t keyVersion=1, const char *ssid="Net") {
  const size_t ssidLen = strlen(ssid); assert(ssidLen <= 32);
  memset(p,0,PrefixSize); le32put(p,1); le32put(p+4,2); le32put(p+8,1);
  le32put(p+12,upper); le32put(p+16,(uint32_t)ssidLen); memcpy(p+20,ssid,ssidLen);
  le32put(p+60,keyVersion); le32put(p+64,keyLen);
}
int main() {
  uint8_t p[PrefixSize]; Personal out{};
  base(p,0,0,0,"MERCUSYS_Guest_E760_5G");
  assert(decode(p,sizeof p,out) && out.mode==2 && out.lower==1 && out.upper==0 &&
         out.keyLength==0 && out.ssidLength==22 &&
         memcmp(out.ssid,"MERCUSYS_Guest_E760_5G",22)==0);
  base(p,0,0,1); assert(decode(p,sizeof p,out) && out.upper==0 && out.keyLength==0);
  base(p,1U<<3,32); assert(decode(p,sizeof p,out) && out.upper==(1U<<3));
  base(p,(1U<<3)|(1U<<9),32); assert(decode(p,sizeof p,out) && out.upper==(1U<<3));
  base(p,1U<<9,32); assert(!decode(p,sizeof p,out));
  base(p,(1U<<3)|(1U<<9),0); assert(!decode(p,sizeof p,out));
  base(p,1U<<3,32,0); assert(!decode(p,sizeof p,out));

  /* Reproduce the exact old-ABI misread from the Mac diagnostic. */
  base(p,0,0,0,"MERCUSYS_Guest_E760_5G");
  struct __attribute__((packed)) LegacyView { uint32_t version; uint16_t mode, lower, upper, pad; uint32_t ssidLength; };
  const auto *legacy = reinterpret_cast<const LegacyView *>(p);
  assert(legacy->version==1 && legacy->mode==2 && legacy->lower==0 &&
         legacy->upper==1 && legacy->ssidLength==0);
  assert(decode(p,sizeof p,out) && out.lower==1 && out.upper==0 && out.ssidLength==22);

  uint8_t old[PrefixSize]{};
  le32put(old,1); old[4]=2; old[6]=1; old[12]=3; memcpy(old+16,"Net",3);
  assert(!decode(old,sizeof old,out));
  puts("PASS: empty-key open request with key-version 0; 22-byte SSID normalized; old-ABI misread prevented; WPA2 and transition fallback retained; SAE-only rejected");
}
'''
with tempfile.TemporaryDirectory(prefix='rtw88-assoc-wire-') as td:
    td = Path(td)
    (td / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-I', str(header.parent),
                    str(td / 'test.cpp'), '-o', str(td / 'test')], check=True)
    run = subprocess.run([str(td / 'test')], text=True, capture_output=True)
    if run.returncode:
        raise SystemExit(run.stdout + run.stderr)
    print(run.stdout.strip())

cpp = (root / 'src/kext/RTL88WiFi.cpp').read_text()
assert 'RTW88AssocWire::decode(' in cpp
assert 'normalized.ad_auth_lower = (uint16_t)fields.lower' in cpp
assert 'const bool keyHeaderValid = open ? (keyVersion == 0 || keyVersion == 1)' in header.read_text()
assert 'RTW88AssocWire::supportedRequestSize(req->req_len)' in cpp and 'rtw88TryHostAssociation(this, interface, req, &ret)' in cpp
print('PASS: native host32 ASSOCIATE decoder accepts open/no-key v0 and normalizes before Ventura struct parsing')
