/* SPDX-License-Identifier: GPL-2.0-only
 * Freestanding MPSC intrusive stack for deferred TX completion-token retire.
 *
 * Producers only push fully initialized nodes with atomic compare/exchange.
 * A single deferred consumer detaches the whole list with one atomic exchange.
 * Nodes are not reclaimed until after detachment; there is no pop/reuse path
 * and producers never dereference a previously observed head pointer.
 */
#pragma once

template <typename Node>
class RTW88WCLCompletionTokenRetireList {
public:
    void push(Node *node)
    {
        if (!node)
            return;

        Node *head = __atomic_load_n(&_head, __ATOMIC_ACQUIRE);
        do {
            node->deferred_next = head;
        } while (!__atomic_compare_exchange_n(
            &_head, &head, node, false,
            __ATOMIC_RELEASE, __ATOMIC_ACQUIRE));
    }

    /* Exactly one deferred consumer may detach/reclaim nodes at a time. */
    Node *takeAll()
    {
        return __atomic_exchange_n(&_head, static_cast<Node *>(nullptr),
                                   __ATOMIC_ACQ_REL);
    }

    bool empty() const
    {
        return __atomic_load_n(&_head, __ATOMIC_ACQUIRE) == nullptr;
    }

private:
    Node * volatile _head = nullptr;
};
