/* SPDX-License-Identifier: GPL-2.0-only
 * Exactly-once completion token for the macOS sk_buff compatibility layer.
 *
 * The token is separately allocated from the skb. A racing kfree_skb() may
 * reclaim the skb immediately after another thread claims the token, so no
 * callback state may remain embedded in the skb after the atomic claim.
 * The release hook and callback may run from TX completion or arbitrary
 * free/teardown context. Both must be non-blocking and must not call Skywalk;
 * the release hook may only enqueue the detached token for deferred freeing.
 */
#ifndef _RTW88_COMPAT_SKBUFF_TX_COMPLETION_H
#define _RTW88_COMPAT_SKBUFF_TX_COMPLETION_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*rtw88_skb_tx_completion_fn)(void *context, void *cookie,
                                           bool transmitted);
typedef void (*rtw88_skb_tx_completion_release_fn)(void *token);

/* Optional native adapter hook, registered before completion tokens can exist.
 * Keeping this indirection here lets the shared radio object also link into
 * the legacy Airport kext without a direct WCL adapter symbol dependency. */
typedef void (*rtw88_skb_tx_completion_retire_hook)(void *context, void *token);
void rtw88_set_skb_tx_completion_token_releaser(
    rtw88_skb_tx_completion_retire_hook hook);

struct rtw88_skb_tx_completion_token {
    rtw88_skb_tx_completion_fn callback;
    rtw88_skb_tx_completion_release_fn release;
    void *context;
    void *cookie;

    /* Intrusive link used by the native WCL deferred token reaper. The
     * release hook may only enqueue this node; it must not free it. */
    struct rtw88_skb_tx_completion_token *deferred_next;
};

/* This one pointer is the only completion state stored inside struct sk_buff. */
struct rtw88_skb_tx_completion {
    struct rtw88_skb_tx_completion_token *token;
};

static inline bool
rtw88_skb_tx_completion_bind(
    struct rtw88_skb_tx_completion *completion,
    struct rtw88_skb_tx_completion_token *token)
{
    if (!completion || !token || !token->callback || !token->release)
        return false;

    struct rtw88_skb_tx_completion_token *expected = 0;
    /* Publish a fully initialized, independently allocated token atomically. */
    return __atomic_compare_exchange_n(&completion->token, &expected, token,
                                       false, __ATOMIC_RELEASE,
                                       __ATOMIC_RELAXED);
}

/*
 * Claim the token with one atomic exchange. After this returns, callers must
 * not touch completion again: the skb may be freed by the losing free path.
 */
static inline struct rtw88_skb_tx_completion_token *
rtw88_skb_tx_completion_claim(struct rtw88_skb_tx_completion *completion)
{
    if (!completion)
        return 0;
    return __atomic_exchange_n(&completion->token,
                               (struct rtw88_skb_tx_completion_token *)0,
                               __ATOMIC_ACQ_REL);
}

/* Dispatch uses only the detached token, never memory owned by the skb. */
static inline bool
rtw88_skb_tx_completion_dispatch(
    struct rtw88_skb_tx_completion_token *token, bool transmitted)
{
    if (!token)
        return false;

    rtw88_skb_tx_completion_fn callback = token->callback;
    rtw88_skb_tx_completion_release_fn release = token->release;
    void *context = token->context;
    void *cookie = token->cookie;

    /*
     * Retire the token before notifying the backend. The callback may publish
     * the final ticket and wake teardown concurrently; moving the token onto
     * its deferred-reclamation list first ensures that a completed ticket
     * cannot make its context appear quiescent while this token still refers
     * to it. The release hook must be bounded/nonblocking and must not free.
     */
    if (release)
        release(token);
    if (callback)
        callback(context, cookie, transmitted);
    return callback != 0;
}

static inline bool
rtw88_skb_tx_completion_report(struct rtw88_skb_tx_completion *completion,
                               bool transmitted)
{
    struct rtw88_skb_tx_completion_token *token =
        rtw88_skb_tx_completion_claim(completion);
    return rtw88_skb_tx_completion_dispatch(token, transmitted);
}

#ifdef __cplusplus
}
#endif

#endif /* _RTW88_COMPAT_SKBUFF_TX_COMPLETION_H */
