#include "nri_smoke_transient_trail_chunks.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

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

void RequireCompletePartition(uint32_t crossings, uint32_t chunks)
{
	uint32_t next = 0u;
	for (uint32_t index = 0u; index < chunks; ++index)
	{
		const auto range = NRIGetSmokeTransientTrailChunkRange(crossings, chunks, index);
		Require(range.firstLogical == next, "trail chunk partition left a gap or overlap");
		Require(range.lastLogical >= range.firstLogical, "trail chunk range is empty");
		next = range.lastLogical + 1u;
	}
	Require(next == crossings, "trail chunk partition omitted its newest crossing");
}
}

int main()
{
	constexpr float RpgUnitsPerTick = 40.25f;
	constexpr float TickRate = 30.0f;
	constexpr float Spacing = 4.0f;
	constexpr float Radius = 10.0f;
	constexpr float MinimumRadiusScale = 0.75f;
	constexpr uint32_t AuthoredLobes = 8u;
	constexpr uint32_t MaximumChunks = 8u;

	float spacingRemainder = 0.0f;
	uint32_t admittedGroups = 0u;
	for (uint32_t tick = 0u; tick < static_cast<uint32_t>(TickRate); ++tick)
	{
		const float total = spacingRemainder + RpgUnitsPerTick;
		const uint32_t crossings = static_cast<uint32_t>(std::floor(total / Spacing));
		spacingRemainder = std::fmod(total, Spacing);
		const uint32_t chunks = NRIPlanSmokeTransientTrailChunkCount(crossings,
			MaximumChunks, Spacing, Radius, MinimumRadiusScale, AuthoredLobes);
		Require(chunks == 1u, "normal Duke RPG game-tick motion must form one group");
		RequireCompletePartition(crossings, chunks);
		admittedGroups += chunks;
	}
	Require(admittedGroups == 30u, "one second of normal RPG motion must form 30 groups");

	// At a 0.75-second production lifetime, the inclusive worst-case live set is
	// 23 groups. It fits both the fixed 64/256 pool at eight lobes and Low's
	// 24/96 profile even at its pressure fallback of two lobes. The group/lobe
	// builder test separately proves those two endpoint supports cover the span.
	constexpr uint32_t MaximumLiveGroups = 23u;
	Require(MaximumLiveGroups <= 64u && MaximumLiveGroups * AuthoredLobes <= 256u,
		"normal trail must fit the fixed group/lobe pools");
	Require(MaximumLiveGroups <= 24u && MaximumLiveGroups * 2u <= 96u,
		"normal trail must fit the Low profile at worst-case two-lobe reduction");

	const uint32_t quarterSecondCrossings = static_cast<uint32_t>(
		std::floor((RpgUnitsPerTick * TickRate * 0.25f) / Spacing));
	const uint32_t quarterSecondChunks = NRIPlanSmokeTransientTrailChunkCount(
		quarterSecondCrossings, MaximumChunks, Spacing, Radius,
		MinimumRadiusScale, AuthoredLobes);
	Require(quarterSecondChunks > 1u && quarterSecondChunks <= MaximumChunks,
		"a quarter-second hitch must split into bounded support chunks");
	RequireCompletePartition(quarterSecondCrossings, quarterSecondChunks);

	const uint32_t extremeHitchCrossings = 257u;
	const uint32_t extremeHitchChunks = NRIPlanSmokeTransientTrailChunkCount(
		extremeHitchCrossings, MaximumChunks, Spacing, Radius,
		MinimumRadiusScale, AuthoredLobes);
	Require(extremeHitchChunks == MaximumChunks,
		"an extreme hitch must respect the authored chunk ceiling");
	RequireCompletePartition(extremeHitchCrossings, extremeHitchChunks);

	std::cout << "Smoke transient trail chunk tests passed.\n";
	return 0;
}
