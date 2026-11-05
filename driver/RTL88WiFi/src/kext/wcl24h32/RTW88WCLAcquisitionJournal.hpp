/* SPDX-License-Identifier: GPL-2.0-only
 * Fixed-capacity acquisition journal for the 24H32 Skywalk queue owner.
 *
 * This header is freestanding so its state machine can be fault-injection
 * tested on the host. It records successful acquisitions only; rollback
 * returns those resources in strict reverse order.
 */
#pragma once

#include <stdint.h>

namespace RTW88WCLAcquisitionJournal {

enum class Resource : uint8_t {
    kTXPool = 0,
    kRXPool,
    kTXSubmission0,
    kTXSubmission1,
    kTXSubmission2,
    kTXSubmission3,
    kTXCompletion,
    kRXSubmission,
    kRXCompletion,
    kInvalid
};

enum class Phase : uint8_t {
    kIdle = 0,
    kAcquiring,
    kCommitted,
    kRollingBack
};

static constexpr uint32_t kResourceCount = 9;
static constexpr Resource kAcquisitionOrder[kResourceCount] = {
    Resource::kTXPool,
    Resource::kRXPool,
    Resource::kTXSubmission0,
    Resource::kTXSubmission1,
    Resource::kTXSubmission2,
    Resource::kTXSubmission3,
    Resource::kTXCompletion,
    Resource::kRXSubmission,
    Resource::kRXCompletion,
};

inline bool txSubmissionResource(uint32_t index, Resource *resource)
{
    if (!resource || index >= 4)
        return false;
    *resource = static_cast<Resource>(
        static_cast<uint8_t>(Resource::kTXSubmission0) + index);
    return true;
}

class Journal final {
public:
    bool begin()
    {
        if (_phase != Phase::kIdle || _count != 0)
            return false;
        _phase = Phase::kAcquiring;
        return true;
    }

    /* A resource is recorded only after its factory returned a live object.
     * Requiring the exact next token rejects duplicate and out-of-order writes.
     */
    bool record(Resource resource)
    {
        if (_phase != Phase::kAcquiring || _count >= kResourceCount ||
            resource != kAcquisitionOrder[_count])
            return false;
        _entries[_count++] = resource;
        return true;
    }

    bool commit()
    {
        if (_phase != Phase::kAcquiring || _count != kResourceCount)
            return false;
        _phase = Phase::kCommitted;
        return true;
    }

    bool beginRollback()
    {
        if (_phase == Phase::kRollingBack)
            return true;
        if (_phase == Phase::kIdle)
            return _count == 0;
        if (_phase != Phase::kAcquiring && _phase != Phase::kCommitted)
            return false;
        _phase = Phase::kRollingBack;
        return true;
    }

    bool popRollback(Resource *resource)
    {
        if (!resource || _phase != Phase::kRollingBack || _count == 0)
            return false;
        *resource = _entries[--_count];
        _entries[_count] = Resource::kInvalid;
        return true;
    }

    /* Idempotent after a completed rollback, but never discards live entries. */
    bool finishRollback()
    {
        if (_phase == Phase::kIdle)
            return _count == 0;
        if (_phase != Phase::kRollingBack || _count != 0)
            return false;
        _phase = Phase::kIdle;
        return true;
    }

    bool isCommitted() const { return _phase == Phase::kCommitted; }
    bool isEmpty() const { return _phase == Phase::kIdle && _count == 0; }
    uint32_t count() const { return _count; }
    Phase phase() const { return _phase; }

private:
    Resource _entries[kResourceCount] = {};
    uint32_t _count = 0;
    Phase _phase = Phase::kIdle;
};

} // namespace RTW88WCLAcquisitionJournal
