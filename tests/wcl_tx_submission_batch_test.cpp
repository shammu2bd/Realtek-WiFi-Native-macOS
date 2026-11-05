/* SPDX-License-Identifier: GPL-2.0-only */
#include "../driver/RTL88WiFi/src/kext/wcl24h32/RTW88WCLTxSubmissionBatch.hpp"

#include <cassert>
#include <cstdint>

struct Packet {
    uint32_t id;
};

struct SubmitState {
    int failAt;
    uint32_t calls;
    uint32_t accepted[32];
};

static int submit(void *context, void *rawPacket)
{
    auto *state = static_cast<SubmitState *>(context);
    auto *packet = static_cast<Packet *>(rawPacket);
    const uint32_t index = state->calls++;
    if (static_cast<int>(index) == state->failAt)
        return -1;
    state->accepted[index] = packet->id;
    return 0;
}

static void testAcceptedPrefixStopsAtFirstFailure()
{
    Packet packets[5] = {{0}, {1}, {2}, {3}, {4}};
    Packet * const list[] = {
        &packets[0], &packets[1], &packets[2], &packets[3], &packets[4]
    };
    SubmitState state = {-1, 0, {}};
    state.failAt = 2;
    const uint32_t accepted =
        RTW88WCLTxSubmissionBatch::submitPrefix(list, 5, submit, &state);
    assert(accepted == 2);
    assert(state.calls == 3);
    assert(state.accepted[0] == 0 && state.accepted[1] == 1);
}

static void testBoundsCallbackWork()
{
    Packet packets[24] = {};
    Packet * const list[24] = {
        &packets[0], &packets[1], &packets[2], &packets[3],
        &packets[4], &packets[5], &packets[6], &packets[7],
        &packets[8], &packets[9], &packets[10], &packets[11],
        &packets[12], &packets[13], &packets[14], &packets[15],
        &packets[16], &packets[17], &packets[18], &packets[19],
        &packets[20], &packets[21], &packets[22], &packets[23]
    };
    SubmitState state = {-1, 0, {}};
    const uint32_t accepted =
        RTW88WCLTxSubmissionBatch::submitPrefix(list, 24, submit, &state);
    assert(accepted == RTW88WCLTxSubmissionBatch::kMaximumPacketsPerCallback);
    assert(state.calls == RTW88WCLTxSubmissionBatch::kMaximumPacketsPerCallback);
}

static void testMalformedAndNullInputsRemainUnaccepted()
{
    Packet first = {1};
    Packet third = {3};
    Packet * const list[] = {&first, nullptr, &third};
    SubmitState state = {-1, 0, {}};
    const uint32_t accepted =
        RTW88WCLTxSubmissionBatch::submitPrefix(list, 3, submit, &state);
    assert(accepted == 1);
    /* Only the first packet reaches submit(). The null second slot must stop
     * the contiguous prefix; the third packet must never be visited. */
    assert(state.calls == 1);
    assert(state.accepted[0] == 1);

    SubmitState invalidState = {-1, 0, {}};
    assert(RTW88WCLTxSubmissionBatch::submitPrefix<Packet>(
        nullptr, 3, submit, &invalidState) == 0);
    assert(RTW88WCLTxSubmissionBatch::submitPrefix<Packet>(
        list, 0, submit, &invalidState) == 0);
    assert(RTW88WCLTxSubmissionBatch::submitPrefix<Packet>(
        list, 3, nullptr, &invalidState) == 0);
    assert(invalidState.calls == 0);
}

int main()
{
    testAcceptedPrefixStopsAtFirstFailure();
    testBoundsCallbackWork();
    testMalformedAndNullInputsRemainUnaccepted();
    return 0;
}
