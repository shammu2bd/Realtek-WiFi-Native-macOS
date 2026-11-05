#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTXQueueArrayContract.hpp"

#include <cassert>
#include <cstdint>

using RTW88WCLTXQueueContract::Entry;
using RTW88WCLTXQueueContract::kRequiredCount;
using RTW88WCLTXQueueContract::kServiceClasses;
using RTW88WCLTXQueueContract::validate;

int main()
{
    int q0, q1, q2, q3;
    Entry good[kRequiredCount] = {
        {&q0, kServiceClasses[0]},
        {&q1, kServiceClasses[1]},
        {&q2, kServiceClasses[2]},
        {&q3, kServiceClasses[3]},
    };
    assert(validate(good, kRequiredCount));

    // Exact 24H32 Skywalk service classes retain their WMM AC and TID.
    RTW88WCLTXQueueContract::Route route = {};
    assert(RTW88WCLTXQueueContract::routeForServiceClass(kServiceClasses[0], &route));
    assert(route.accessCategory == 3 && route.tid == 1); // BK
    assert(RTW88WCLTXQueueContract::routeForServiceClass(kServiceClasses[1], &route));
    assert(route.accessCategory == 2 && route.tid == 0); // BE
    assert(RTW88WCLTXQueueContract::routeForServiceClass(kServiceClasses[2], &route));
    assert(route.accessCategory == 1 && route.tid == 5); // VI
    assert(RTW88WCLTXQueueContract::routeForServiceClass(kServiceClasses[3], &route));
    assert(route.accessCategory == 0 && route.tid == 6); // VO
    assert(!RTW88WCLTXQueueContract::routeForServiceClass(0xdeadbeefU, &route));
    assert(!RTW88WCLTXQueueContract::routeForServiceClass(kServiceClasses[0], nullptr));

    Entry test[kRequiredCount];

    // Empty slot must fail.
    for (uint32_t i = 0; i < kRequiredCount; ++i) test[i] = good[i];
    test[2].identity = nullptr;
    assert(!validate(test, kRequiredCount));

    // Aliased pointers must fail even if their classes differ.
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

    assert(!validate(nullptr, kRequiredCount));
    assert(!validate(good, kRequiredCount - 1));
    assert(!validate(good, kRequiredCount + 1));
    return 0;
}
