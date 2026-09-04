#include "nri_rendered_frame_budget.h"

#include <cstdlib>
#include <iostream>
#include <limits>

namespace
{
void Require(bool condition, const char* message)
{
	if (!condition)
	{
		std::cerr << "FAILED: " << message << '\n';
		std::exit(1);
	}
}
}

int main()
{
	using namespace nri_frame_budget;
	static_assert(MinimumLimit == 1u);
	static_assert(MaximumLimit == 3u);
	static_assert(DefaultLimit == 3u);
	static_assert(ClampLimit(-100) == 1u);
	static_assert(ClampLimit(0) == 1u);
	static_assert(ClampLimit(1) == 1u);
	static_assert(ClampLimit(2) == 2u);
	static_assert(ClampLimit(3) == 3u);
	static_assert(ClampLimit(4) == 3u);
	static_assert(ClampLimit((std::numeric_limits<int>::max)()) == 3u);

	const uint64_t empty[] = { 0u, 0u, 0u };
	Require(CountOutstanding(empty, 3u, 0u) == 0u, "empty slots must not be outstanding");
	Require(SelectAdmissionFence(empty, 3u, 0u, 1) == 0u, "empty slots must not block admission");
	Require(CountOutstanding(nullptr, 3u, 0u) == 0u, "null storage must be empty");
	Require(SelectAdmissionFence(nullptr, 3u, 0u, 1) == 0u, "null storage must not select a fence");

	const uint64_t ordered[] = { 8u, 9u, 10u };
	Require(CountOutstanding(ordered, 3u, 7u) == 3u, "all successful unretired fences must count");
	Require(SelectAdmissionFence(ordered, 3u, 7u, 1) == 10u, "limit one must drain every older rendered submit");
	Require(SelectAdmissionFence(ordered, 3u, 7u, 2) == 9u, "limit two must leave one older rendered submit");
	Require(SelectAdmissionFence(ordered, 3u, 7u, 3) == 8u, "limit three must leave two older rendered submits");
	Require(SelectAdmissionFence(ordered, 3u, 8u, 3) == 0u, "depth below the limit must not wait");
	Require(SelectAdmissionFence(ordered, 3u, 9u, 1) == 10u, "limit one must wait for the sole unretired submit");
	Require(SelectAdmissionFence(ordered, 3u, 10u, 1) == 0u, "fully retired submits must not wait");

	const uint64_t unsortedWithGap[] = { 40u, 0u, 38u, 39u };
	Require(CountOutstanding(unsortedWithGap, 4u, 37u) == 3u, "failed/empty submissions must not inflate depth");
	Require(SelectAdmissionFence(unsortedWithGap, 4u, 37u, 1) == 40u, "selection must not depend on slot order");
	Require(SelectAdmissionFence(unsortedWithGap, 4u, 37u, 2) == 39u, "selection must use successful fence rank, not frame arithmetic");
	Require(SelectAdmissionFence(unsortedWithGap, 4u, 37u, 3) == 38u, "oldest successful fence should admit the throughput limit");
	Require(SelectAdmissionFence(unsortedWithGap, 4u, 38u, 3) == 0u, "retired gaps must reduce outstanding depth");

	const uint64_t partiallyRetired[] = { 101u, 104u, 0u, 103u };
	Require(CountOutstanding(partiallyRetired, 4u, 101u) == 2u, "completed fences must be filtered before selection");
	Require(SelectAdmissionFence(partiallyRetired, 4u, 101u, 1) == 104u, "responsive admission must wait through every outstanding success");
	Require(SelectAdmissionFence(partiallyRetired, 4u, 101u, 2) == 103u, "balanced admission must retire only the oldest outstanding success");
	Require(SelectAdmissionFence(partiallyRetired, 4u, 101u, 3) == 0u, "throughput admission must not wait below depth three");

	// Duplicate values are not expected from the renderer, but inclusive-rank
	// selection remains conservative if malformed telemetry supplies them.
	const uint64_t duplicates[] = { 55u, 55u, 56u };
	Require(SelectAdmissionFence(duplicates, 3u, 54u, 2) == 55u, "duplicate fences must not defeat conservative selection");

	// Live policy transitions never resize storage. Tightening drains existing
	// successful submissions immediately; relaxing admits new work gradually.
	uint64_t liveSlots[] = { 200u, 201u, 202u };
	Require(SelectAdmissionFence(liveSlots, 3u, 199u, 3) == 200u, "depth three should recycle only the oldest saturated submit");
	Require(SelectAdmissionFence(liveSlots, 3u, 199u, 1) == 202u, "a live 3-to-1 transition must drain through the newest submit");
	uint64_t liveCompleted = 202u;
	liveSlots[0] = 203u;
	Require(SelectAdmissionFence(liveSlots, 3u, liveCompleted, 2) == 0u, "a live 1-to-2 transition must admit one additional submit");
	liveSlots[1] = 204u;
	Require(SelectAdmissionFence(liveSlots, 3u, liveCompleted, 2) == 203u, "depth two must then retain one older submit");
	Require(SelectAdmissionFence(liveSlots, 3u, liveCompleted, 3) == 0u, "a live 2-to-3 transition must restore overlap without rebuilding slots");

	std::cout << "NRI rendered-frame budget policy tests passed.\n";
	return 0;
}
