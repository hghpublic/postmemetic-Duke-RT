#pragma once

#include <cstdint>

// Shared with the layouts: smoke initializes lazily after the scene snapshot
// and voxel-compute sets have consumed their portion of the device pool.
namespace nri_smoke_descriptors
{
constexpr uint32_t InputCount = 5u;
constexpr uint32_t LightCount = 3u;
constexpr uint32_t FilteredSceneCount = 8u;
constexpr uint32_t ExtendedSceneCount = 10u;
constexpr uint32_t GridInputCount = 2u;
constexpr uint32_t StructuredPerQueuedFrame = InputCount + LightCount +
	FilteredSceneCount + ExtendedSceneCount + GridInputCount;

constexpr uint32_t SharedStructuredPoolCapacity(uint32_t queuedFrames)
{
	// Preserve the established non-smoke reserve and explicitly budget the
	// complete smoke SRV layouts, not merely the newest two transient inputs.
	return 512u + StructuredPerQueuedFrame * queuedFrames;
}
}
