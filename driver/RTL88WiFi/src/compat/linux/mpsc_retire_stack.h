/* SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
 * Minimal intrusive MPSC stack for deferred kernel-object reclamation.
 */
#ifndef _RTW88_MPSC_RETIRE_STACK_H
#define _RTW88_MPSC_RETIRE_STACK_H
struct rtw88_mpsc_retire_node { struct rtw88_mpsc_retire_node *next; };
struct rtw88_mpsc_retire_stack { struct rtw88_mpsc_retire_node *volatile head; };
static inline void rtw88_mpsc_retire_stack_init(struct rtw88_mpsc_retire_stack *stack)
{
    __atomic_store_n(&stack->head, (struct rtw88_mpsc_retire_node *)0, __ATOMIC_RELAXED);
}
static inline void rtw88_mpsc_retire_stack_push(struct rtw88_mpsc_retire_stack *stack,
                                                struct rtw88_mpsc_retire_node *node)
{
    struct rtw88_mpsc_retire_node *head = __atomic_load_n(&stack->head, __ATOMIC_RELAXED);
    do { node->next = head; }
    while (!__atomic_compare_exchange_n(&stack->head, &head, node, false,
                                         __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}
static inline struct rtw88_mpsc_retire_node *
rtw88_mpsc_retire_stack_take_all(struct rtw88_mpsc_retire_stack *stack)
{
    return __atomic_exchange_n(&stack->head, (struct rtw88_mpsc_retire_node *)0,
                               __ATOMIC_ACQ_REL);
}
static inline int rtw88_mpsc_retire_stack_empty(const struct rtw88_mpsc_retire_stack *stack)
{
    return __atomic_load_n(&stack->head, __ATOMIC_ACQUIRE) == 0;
}
#endif
