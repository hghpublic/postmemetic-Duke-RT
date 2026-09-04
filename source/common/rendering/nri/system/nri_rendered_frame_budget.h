#pragma once

#include <cstddef>
#include <cstdint>

// Pure policy helpers for limiting successful rendered submissions that have
// not retired. Resource-slot and swapchain sizing are deliberately separate.
namespace nri_frame_budget
{
	constexpr uint32_t MinimumLimit = 1u;
	constexpr uint32_t MaximumLimit = 3u;
	constexpr uint32_t DefaultLimit = 3u;

	constexpr uint32_t ClampLimit(int requested) noexcept
	{
		return requested < (int)MinimumLimit ? MinimumLimit :
			(requested > (int)MaximumLimit ? MaximumLimit : (uint32_t)requested);
	}

	inline uint32_t CountOutstanding(
		const uint64_t* submittedFenceValues,
		size_t count,
		uint64_t completedFence) noexcept
	{
		if (submittedFenceValues == nullptr)
		{
			return 0u;
		}

		uint32_t outstanding = 0u;
		for (size_t index = 0; index < count; ++index)
		{
			if (submittedFenceValues[index] != 0u && submittedFenceValues[index] > completedFence)
			{
				++outstanding;
			}
		}
		return outstanding;
	}

	// Returns the successful submission fence that must retire before another
	// rendered frame may be admitted. Zero means the current depth is below the
	// limit. The input may be unsorted and may contain empty/retired slots.
	inline uint64_t SelectAdmissionFence(
		const uint64_t* submittedFenceValues,
		size_t count,
		uint64_t completedFence,
		int requestedLimit) noexcept
	{
		const uint32_t limit = ClampLimit(requestedLimit);
		const uint32_t outstanding = CountOutstanding(submittedFenceValues, count, completedFence);
		if (outstanding < limit || submittedFenceValues == nullptr)
		{
			return 0u;
		}

		// Retire enough of the oldest outstanding submissions to leave at most
		// limit-1 before the next submit. Selecting the smallest fence whose
		// inclusive rank reaches retireCount avoids sorting or allocation.
		const uint32_t retireCount = outstanding - limit + 1u;
		uint64_t selected = 0u;
		for (size_t candidateIndex = 0; candidateIndex < count; ++candidateIndex)
		{
			const uint64_t candidate = submittedFenceValues[candidateIndex];
			if (candidate == 0u || candidate <= completedFence)
			{
				continue;
			}

			uint32_t inclusiveRank = 0u;
			for (size_t compareIndex = 0; compareIndex < count; ++compareIndex)
			{
				const uint64_t value = submittedFenceValues[compareIndex];
				if (value != 0u && value > completedFence && value <= candidate)
				{
					++inclusiveRank;
				}
			}

			if (inclusiveRank >= retireCount && (selected == 0u || candidate < selected))
			{
				selected = candidate;
			}
		}
		return selected;
	}
}
