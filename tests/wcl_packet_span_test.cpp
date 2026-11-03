#include <cassert>
#include <cstdint>

#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLPacketSpanValidation.hpp"

static void test_valid_packet()
{
    const RTW88WCLPacketSpan span{262144, 2048, 2048, 64, 1500};
    assert(RTW88WCLPacketSpanIsValid(span));
    assert(RTW88WCLIsValidEthernetFrameLength(1514, 1984));
}

static void test_exact_end_boundaries()
{
    const RTW88WCLPacketSpan span{4096, 2048, 2048, 2048, 0};
    assert(RTW88WCLPacketSpanIsValid(span)); // empty RX buffer at exact end
    assert(RTW88WCLRangeFits(2048, 2048, 0));
    assert(RTW88WCLIsValidEthernetFrameLength(2048, 2048));
}

static void test_rejects_invalid_offsets_and_lengths()
{
    assert(!RTW88WCLPacketSpanIsValid({4096, 4097, 2048, 0, 1}));
    assert(!RTW88WCLPacketSpanIsValid({4096, 2048, 2048, 2049, 0}));
    assert(!RTW88WCLPacketSpanIsValid({4096, 2048, 2048, 2000, 100}));
    assert(!RTW88WCLPacketSpanIsValid({4096, UINT64_MAX - 3, 2048, 0, 1}));
    assert(!RTW88WCLPacketSpanIsValid({4096, 0, 0, 0, 0}));
    assert(!RTW88WCLIsValidEthernetFrameLength(13, 2048));
    assert(!RTW88WCLIsValidEthernetFrameLength(2049, 4096));
    assert(!RTW88WCLIsValidEthernetFrameLength(1500, 1499));
}

static void test_range_arithmetic_does_not_overflow()
{
    assert(RTW88WCLRangeFits(UINT64_MAX, UINT64_MAX, 0));
    assert(!RTW88WCLRangeFits(UINT64_MAX, UINT64_MAX, 1));
    assert(!RTW88WCLRangeFits(10, 9, UINT64_MAX));
}

int main()
{
    test_valid_packet();
    test_exact_end_boundaries();
    test_rejects_invalid_offsets_and_lengths();
    test_range_arithmetic_does_not_overflow();
    return 0;
}
