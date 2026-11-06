#include "../driver/RTL88WiFi/src/compat/linux/mpsc_retire_stack.h"
#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>
#include <sched.h>
struct TestNode {
    rtw88_mpsc_retire_node retire;
    uint32_t id;
    std::atomic<uint32_t> reclaimed;
};
static TestNode *fromRetire(rtw88_mpsc_retire_node *node) {
    return reinterpret_cast<TestNode *>(reinterpret_cast<char *>(node) -
                                        offsetof(TestNode, retire));
}
int main() {
    constexpr uint32_t producerCount = 12, perProducer = 3000;
    constexpr uint32_t total = producerCount * perProducer;
    rtw88_mpsc_retire_stack stack;
    rtw88_mpsc_retire_stack_init(&stack);
    std::vector<TestNode> nodes(total);
    for (uint32_t i=0;i<total;++i) {
        nodes[i].retire.next=nullptr; nodes[i].id=i;
        nodes[i].reclaimed.store(0,std::memory_order_relaxed);
    }
    std::atomic<uint32_t> produced{0}, consumed{0};
    std::vector<std::thread> producers;
    for (uint32_t p=0;p<producerCount;++p) producers.emplace_back([&,p] {
        const uint32_t begin=p*perProducer;
        for(uint32_t n=0;n<perProducer;++n) {
            rtw88_mpsc_retire_stack_push(&stack,&nodes[begin+n].retire);
            produced.fetch_add(1,std::memory_order_release);
        }
    });
    while(consumed.load(std::memory_order_acquire)<total) {
        auto *node=rtw88_mpsc_retire_stack_take_all(&stack);
        if(!node){sched_yield();continue;}
        while(node) {
            auto *next=node->next; TestNode *entry=fromRetire(node);
            node->next=nullptr; uint32_t expected=0;
            assert(entry->reclaimed.compare_exchange_strong(expected,1,
                    std::memory_order_acq_rel));
            consumed.fetch_add(1,std::memory_order_release); node=next;
        }
    }
    for(auto &t:producers)t.join();
    assert(produced.load(std::memory_order_acquire)==total);
    assert(consumed.load(std::memory_order_acquire)==total);
    assert(rtw88_mpsc_retire_stack_empty(&stack));
    for(const auto &n:nodes) assert(n.reclaimed.load(std::memory_order_acquire)==1);
}
