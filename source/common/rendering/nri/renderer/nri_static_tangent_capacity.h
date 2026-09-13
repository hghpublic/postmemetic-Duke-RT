#pragma once
#include <cstdint>

// Fixed owners only; UI/texture-set allocations have an independent lifetime cap.
constexpr uint32_t NRIStaticTangentStructuredPoolCapacity(uint32_t queuedFrames)
{
    const uint32_t snapshots = queuedFrames * 4u > 8u ? queuedFrames * 4u : 8u;
    // 29 scene SRVs; four voxel input sets each contain four SRVs;
    // smoke's three input/light/filter sets total24 SRVs per queued frame;
    // optional grid owns six. Root-descriptor tangent producer owns NO sets.
    const uint32_t known = 29u * (snapshots + queuedFrames) + 16u + 24u * queuedFrames + 6u;
    return known + 32u > 512u ? known + 32u : 512u;
}
static_assert(NRIStaticTangentStructuredPoolCapacity(3) == 561);
