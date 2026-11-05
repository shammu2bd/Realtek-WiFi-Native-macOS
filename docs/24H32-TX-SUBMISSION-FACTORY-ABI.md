# Sequoia 15.8.1 / 24H32 TX submission factory ABI

## Result

The target kernel exports a service-class-capable IOSkywalkTxSubmissionQueue::withPool overload. It is not named withPoolAndServiceClass, and the bundled SDK header did not declare it. The matching overload was identified by its exact target symbol and call-site dataflow, then declared without changing the existing SDK declarations.

Target evidence retained in the repository:

- Development/Logs/stage89/run-20261103-211403-2ef027376f6e/evidence/queue-methods/IOSkywalkTxSubmissionQueue_withPool_0xffffff8002983ff0.txt
- Development/Logs/stage89/run-20261103-211403-2ef027376f6e/evidence/queue-methods/IOSkywalkTxSubmissionQueue_withPool_0xffffff800298409e.txt
- Development/Logs/stage89/run-20261103-211403-2ef027376f6e/evidence/queue-methods/IOSkywalkTxSubmissionQueue_withPool_0xffffff80029840c2.txt
- Development/Logs/stage89/run-20261103-211403-2ef027376f6e/evidence/queue-methods/IOSkywalkTxSubmissionQueue_initWithPool_0xffffff80029840e8.txt
- Development/Logs/stage89/run-20261103-211403-2ef027376f6e/evidence/queue-methods/IOSkywalkPacketQueue_getServiceClass_0xffffff8002980bb0.txt

## Exact target mapping

The exported target symbol at 0xffffff8002983ff0 demangles to:

IOSkywalkTxSubmissionQueue::withPool(IOSkywalkPacketBufferPool*, UInt32, UInt32, OSObject*, IOSkywalkQueryFreeSpaceHandler, IOSkywalkTxSubmissionQueueAction, void*, UInt32, UInt32)

The two trailing integers after refCon are options, then serviceClass. The wrapper passes pool in RSI, capacity in ESI, queue ID in EDX, owner in RCX, query handler in R8, action in R9, and refCon/options/serviceClass in the stack argument slots.

The mangled callback parameter types are also target-specific: both callback return types are UInt32, and the action receives IOSkywalkPacket **. The generic SDK typedefs instead use IOReturn and const IOSkywalkPacket **; reusing them would produce a different C++ symbol. The header therefore defines separate 24H32 callback typedefs for this overload. The action-only wrapper proves a null query handler is an accepted path.

The wrapper reads the final stack argument at [RBP+0x20] into EDX before dispatching to initWithPool. It passes capacity in ECX and queue ID in R8D. The target initializer stores the service-class value at object offset 0xb8. The target IOSkywalkPacketQueue::getServiceClass implementation at 0xffffff8002980bb0 reads the same offset [RDI+0xb8].

The action-only target wrapper at 0xffffff80029840c2 pushes 0xffffffff as the service class. That explains why the old source factory path could not create WMM-specific role-1 queues.

## Source change

The bundled header now declares the additional target-backed overload:

withPool(pool, capacity, queueId, owner, handler, action, refCon, options, serviceClass)

The queue owner calls that factory with a null optional query handler and the existing packet action callback. It does not call initWithPool directly, write private fields, or use the absent withPoolAndServiceClass symbol.

Four TX submission queues are constructed in this order:

1. 0x00100080
2. 0x00000000
3. 0x00380100
4. 0x00400180

The four pointers live in a fixed array within RTW88WCLSkywalkQueues; validation checks non-null pointers, pairwise identity uniqueness, and exact service-class order through the target getter.

## Safety boundary

This change only constructs and validates queue objects. It does not register queues, create a live QueueSet, enable queues, accept TX packets, complete packets, refill RX buffers, publish a BSD interface, build/sign/install/load the kext, run hardware tests, or change OpenCore/SIP/NVRAM. Those remain separate gates.
