#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTXQueueArrayContract.hpp"

#include <cassert>
#include <cstdint>

using RTW88WCLTXQueueContract::Entry;
using RTW88WCLTXQueueContract::kRequiredCount;
using RTW88WCLTXQueueContract::kServiceClasses;
using RTW88WCLTXQueueContract::validate;

static Entry validEntries(const void *a, const void *b,
                          const void *c, const void *d)
{
    return Entry{a, 0, 0};
}

int main()
{
    int q0, q1, q2, q3;
    Entry good[kRequiredCount] = {
        {&q0, kServiceClasses[0], 0},
        {&q1, kServiceClasses[1], 1},
        {&q2, kServiceClasses[2], 2},
        {&q3, kServiceClasses[3], 3},
    };
    assert(validate(good, kRequiredCount));

    Entry test[kRequiredCount];

    // Empty slot must fail.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[2].identity = nullptr;
    assert(!validate(test, kRequiredCount));

    // Aliased pointers must fail even if their classes and IDs differ.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[3].identity = test[1].identity;
    assert(!validate(test, kRequiredCount));

    // Wrong array order must fail.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    Entry tmp = test[0]; test[0] = test[1]; test[1] = tmp;
    assert(!validate(test, kRequiredCount));

    // Duplicate service class and unknown service class must fail.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[3].serviceClass = test[2].serviceClass;
    assert(!validate(test, kRequiredCount));
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[2].serviceClass = 0xdeadbeefU;
    assert(!validate(test, kRequiredCount));

    // Queue IDs are part of the deterministic four-entry mapping.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[1].queueId = 0;
    assert(!validate(test, kRequiredCount));

    assert(!validate(nullptr, kRequiredCount));
    assert(!validate(good, kRequiredCount - 1));
    assert(!validate(good, kRequiredCount + 1));
    return 0;
}
