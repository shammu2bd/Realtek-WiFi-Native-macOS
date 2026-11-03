/* SPDX-License-Identifier: GPL-2.0-only
 * Exactly-once completion token for the macOS sk_buff compatibility layer.
 *
 * The token is separately allocated from the skb. A racing kfree_skb() may
 * reclaim the skb immediately after another thread claims the token, so no
 * callback state may remain embedded in the skb after the atomic claim.
 * Callbacks may run from TX completion or arbitrary free/teardown context;
 * they must be non-blocking and must not call Skywalk directly.
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

struct rtw88_skb_tx_completion_token {
    rtw88_skb_tx_completion_fn callback;
    rtw88_skb_tx_completion_release_fn release;
    void *context;
    void *cookie;
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

    if (callback)
        callback(context, cookie, transmitted);
    if (release)
        release(token);
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
