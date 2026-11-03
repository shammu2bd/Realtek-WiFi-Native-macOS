#include <cassert>
#include <cstdint>
#include <limits>

#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPacketSpanValidation.hpp"

static void test_resolves_valid_rx_span()
{
    uintptr_t address = 0;
    const RTW88WCLPacketSpan span{65536, 4096, 4096, 0, 1514};
    assert(RTW88WCLResolvePacketBufferAddress(0x100000, span, &address));
    assert(address == 0x101000);
}

static void test_resolves_data_offset()
{
    uintptr_t address = 0;
    const RTW88WCLPacketSpan span{8192, 1024, 4096, 128, 1500};
    assert(RTW88WCLResolvePacketBufferAddress(0x200000, span, &address));
    assert(address == 0x200480);
}

static void test_rejects_invalid_or_overflowing_address()
{
    uintptr_t address = 0;
    const RTW88WCLPacketSpan valid{8192, 0, 4096, 0, 64};
    assert(!RTW88WCLResolvePacketBufferAddress(0, valid, &address));
    assert(!RTW88WCLResolvePacketBufferAddress(
        static_cast<uint64_t>(UINTPTR_MAX) - 8, valid, &address));
    const RTW88WCLPacketSpan invalid{4096, 4090, 16, 0, 64};
    assert(!RTW88WCLResolvePacketBufferAddress(0x100000, invalid, &address));
    assert(!RTW88WCLResolvePacketBufferAddress(0x100000, valid, nullptr));
}

int main()
{
    test_resolves_valid_rx_span();
    test_resolves_data_offset();
    test_rejects_invalid_or_overflowing_address();
    return 0;
}
