#include <atomic>
#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>

extern "C" {
#include "../driver/RTL88WiFi/src/compat/linux/skbuff_tx_completion.h"
}

struct Capture {
    std::atomic<unsigned> calls{0};
    std::atomic<unsigned> sent{0};
    std::atomic<unsigned> dropped{0};
    std::atomic<unsigned> releases{0};
    void *expectedCookie = nullptr;
};

static void completion(void *context, void *cookie, bool transmitted)
{
    auto *capture = static_cast<Capture *>(context);
    assert(capture != nullptr);
    assert(cookie == capture->expectedCookie);
    capture->calls.fetch_add(1, std::memory_order_relaxed);
    (transmitted ? capture->sent : capture->dropped)
        .fetch_add(1, std::memory_order_relaxed);
}

static void releaseToken(void *opaque)
{
    auto *token = static_cast<rtw88_skb_tx_completion_token *>(opaque);
    auto *capture = static_cast<Capture *>(token->context);
    capture->releases.fetch_add(1, std::memory_order_relaxed);
    delete token;
}

static rtw88_skb_tx_completion_token *makeToken(Capture *capture, void *cookie)
{
    auto *token = new rtw88_skb_tx_completion_token{};
    token->callback = completion;
    token->release = releaseToken;
    token->context = capture;
    token->cookie = cookie;
    return token;
}

static void test_normal_completion_is_exactly_once()
{
    rtw88_skb_tx_completion state{};
    Capture capture;
    int cookie = 7;
    capture.expectedCookie = &cookie;
    assert(rtw88_skb_tx_completion_bind(&state, makeToken(&capture, &cookie)));
    assert(rtw88_skb_tx_completion_report(&state, true));
    assert(!rtw88_skb_tx_completion_report(&state, false));
    assert(capture.calls.load() == 1);
    assert(capture.sent.load() == 1);
    assert(capture.dropped.load() == 0);
    assert(capture.releases.load() == 1);
}

static void test_early_free_reports_drop()
{
    rtw88_skb_tx_completion state{};
    Capture capture;
    int cookie = 8;
    capture.expectedCookie = &cookie;
    assert(rtw88_skb_tx_completion_bind(&state, makeToken(&capture, &cookie)));
    assert(rtw88_skb_tx_completion_report(&state, false)); // kfree_skb path
    assert(capture.calls.load() == 1);
    assert(capture.sent.load() == 0);
    assert(capture.dropped.load() == 1);
    assert(capture.releases.load() == 1);
}

static void test_completion_free_race_has_one_winner()
{
    rtw88_skb_tx_completion state{};
    Capture capture;
    int cookie = 9;
    capture.expectedCookie = &cookie;
    assert(rtw88_skb_tx_completion_bind(&state, makeToken(&capture, &cookie)));

    std::vector<std::thread> racers;
    for (unsigned i = 0; i < 32; ++i) {
        racers.emplace_back([&state, i]() {
            (void)rtw88_skb_tx_completion_report(&state, (i & 1U) != 0);
        });
    }
    for (auto &thread : racers)
        thread.join();

    assert(capture.calls.load() == 1);
    assert(capture.sent.load() + capture.dropped.load() == 1);
    assert(capture.releases.load() == 1);
}

/*
 * Model the critical lifetime race: the TX-status path claims the detached
 * token, then the competing kfree path claims nothing and is free to reclaim
 * the skb's embedded state before callback dispatch. Dispatch must use only
 * the independent token, never dereference the deleted skb state.
 */
static void test_claimed_token_outlives_skb_state()
{
    auto *state = new rtw88_skb_tx_completion{};
    Capture capture;
    int cookie = 10;
    capture.expectedCookie = &cookie;
    assert(rtw88_skb_tx_completion_bind(state, makeToken(&capture, &cookie)));

    auto *claimed = rtw88_skb_tx_completion_claim(state);
    assert(claimed != nullptr);
    assert(rtw88_skb_tx_completion_claim(state) == nullptr); // concurrent free loses
    delete state; // equivalent to kfree_skb reclaiming the skb

    assert(rtw88_skb_tx_completion_dispatch(claimed, true));
    assert(capture.calls.load() == 1);
    assert(capture.sent.load() == 1);
    assert(capture.dropped.load() == 0);
    assert(capture.releases.load() == 1);
}

int main()
{
    test_normal_completion_is_exactly_once();
    test_early_free_reports_drop();
    test_completion_free_race_has_one_winner();
    test_claimed_token_outlives_skb_state();
    return 0;
}
