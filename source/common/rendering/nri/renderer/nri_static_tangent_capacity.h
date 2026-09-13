#pragma once
#include <cstdint>
#include "nri_smoke_descriptor_budget.h"

// Fixed owners only; UI/texture-set allocations have an independent lifetime cap.
constexpr uint32_t NRIStaticTangentStructuredPoolCapacity(uint32_t queuedFrames)
{
    const uint32_t snapshots = queuedFrames * 4u > 8u ? queuedFrames * 4u : 8u;
    // 29 scene SRVs; four voxel input sets each contain four SRVs;
    // smoke publishes the complete current SRV layouts per queued frame;
    // optional grid owns six. Root-descriptor tangent producer owns NO sets.
    const uint32_t known = 29u * (snapshots + queuedFrames) + 16u +
        nri_smoke_descriptors::StructuredPerQueuedFrame * queuedFrames + 6u;
    // Preserve smoke's established non-smoke reserve while also covering
    // the expanded scene snapshots if their count exceeds that reserve.
    const uint32_t smokeReserve = nri_smoke_descriptors::SharedStructuredPoolCapacity(queuedFrames);
    return known + 32u > smokeReserve ? known + 32u : smokeReserve;
}
static_assert(NRIStaticTangentStructuredPoolCapacity(2) == 570);
static_assert(NRIStaticTangentStructuredPoolCapacity(3) == 599);
static_assert(NRIStaticTangentStructuredPoolCapacity(4) == 750);
