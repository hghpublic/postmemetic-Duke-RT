#include "nri_smoke_transient_clouds.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

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

bool Near(float a, float b, float epsilon = 1.0e-5f)
{
	return std::abs(a - b) <= epsilon;
}

float Distance3(const float a[3], const float b[3])
{
	float squared = 0.0f;
	for (uint32_t axis = 0u; axis < 3u; ++axis)
	{
		const float delta = a[axis] - b[axis];
		squared += delta * delta;
	}
	return std::sqrt(squared);
}

float RadiusAt(const NRISmokeTransientLobeRequest& lobe, float age)
{
	const float localAge = std::max(age - lobe.lobeDelaySeconds, 0.0f);
	const float normalizedAge = std::clamp(localAge / lobe.lifetimeSeconds,
		0.0f, 1.0f);
	return std::max(lobe.initialRadius + lobe.expansionVelocity *
		(lobe.lifetimeSeconds * std::pow(normalizedAge, lobe.radiusExponent)), 0.001f);
}

bool RequestGraphConnected(const NRISmokeTransientLobeRequest* lobes,
	uint32_t count, float age)
{
	if (count == 0u) return false;
	std::array<bool, NRISmokeTransientClouds::FixedMaximumLobesPerGroup> reached = {};
	reached[0] = true;
	for (uint32_t pass = 0u; pass < count; ++pass)
	{
		for (uint32_t a = 0u; a < count; ++a)
		{
			if (!reached[a]) continue;
			float positionA[3] = {};
			for (uint32_t axis = 0u; axis < 3u; ++axis)
				positionA[axis] = lobes[a].position[axis] + lobes[a].velocity[axis] * age;
			for (uint32_t b = 0u; b < count; ++b)
			{
				float positionB[3] = {};
				for (uint32_t axis = 0u; axis < 3u; ++axis)
					positionB[axis] = lobes[b].position[axis] + lobes[b].velocity[axis] * age;
				if (Distance3(positionA, positionB) <=
					RadiusAt(lobes[a], age) + RadiusAt(lobes[b], age) + 1.0e-4f)
					reached[b] = true;
			}
		}
	}
	for (uint32_t index = 0u; index < count; ++index)
		if (!reached[index]) return false;
	return true;
}

bool GpuGraphConnected(const std::vector<NRISmokeTransientLobeGpu>& lobes)
{
	if (lobes.empty()) return false;
	std::vector<bool> reached(lobes.size(), false);
	reached[0] = true;
	for (size_t pass = 0u; pass < lobes.size(); ++pass)
	{
		for (size_t a = 0u; a < lobes.size(); ++a)
		{
			if (!reached[a]) continue;
			for (size_t b = 0u; b < lobes.size(); ++b)
				if (Distance3(lobes[a].position, lobes[b].position) <=
					lobes[a].radius + lobes[b].radius + 1.0e-4f)
					reached[b] = true;
		}
	}
	for (bool value : reached) if (!value) return false;
	return true;
}

NRISmokeTransientLobeRequest Lobe(uint32_t epoch, uint64_t event,
	double authoredSeconds, float x = 0.0f)
{
	NRISmokeTransientLobeRequest request = {};
	request.position[0] = x;
	request.velocity[0] = 1.0f;
	request.initialRadius = 2.0f;
	request.initialDensity = 2.0f;
	request.opticalWeight = 1.0f;
	request.expansionVelocity = 2.0f;
	request.densityHalfLife = 20.0f;
	request.lifetimeSeconds = 4.0f;
	request.groupLifetimeSeconds = 4.0f;
	request.styleIndex = 1u;
	request.sourceId = static_cast<uint32_t>(event);
	request.epoch = epoch;
	request.authoredGameplaySeconds = authoredSeconds;
	request.sourceEventSerial = event;
	request.densitySustainSeconds = 3.0f;
	request.densityReleaseSeconds = 1.0f;
	request.intrinsicEmission = 4.0f;
	request.emissionHalfLife = 0.5f;
	request.transientClass = NRISmokeTransientClass::Explosion;
	return request;
}

std::vector<NRISmokeTransientLobeRequest> Batch(uint32_t epoch, uint64_t event,
	double authoredSeconds, uint32_t count)
{
	std::vector<NRISmokeTransientLobeRequest> requests;
	requests.reserve(count);
	for (uint32_t index = 0u; index < count; ++index)
	{
		auto request = Lobe(epoch, event, authoredSeconds,
			static_cast<float>(index));
		request.batchIndex = index;
		request.batchCount = count;
		requests.push_back(request);
	}
	return requests;
}

const NRISmokeTransientGroupGpu& Group(const NRISmokeTransientClouds& owner,
	const NRISmokeTransientHandle& handle)
{
	Require(handle.slot < owner.GetGpuGroups().size(),
		"group handle slot must be represented in the indexed GPU snapshot");
	return owner.GetGpuGroups()[handle.slot];
}

void TestProfiles()
{
	const auto reference = NRISmokeTransientClouds::ProfileForQuality(0u);
	const auto high = NRISmokeTransientClouds::ProfileForQuality(1u);
	const auto medium = NRISmokeTransientClouds::ProfileForQuality(2u);
	const auto low = NRISmokeTransientClouds::ProfileForQuality(3u);
	Require(reference.maximumActiveGroups == 64u &&
		reference.maximumActiveLobes == 256u &&
		reference.maximumLobesPerGroup == 16u &&
		reference.maximumFullLightBuilds == 64u,
		"reference profile must expose full fixed-pool and light-build budgets");
	Require(high.maximumLobesPerGroup == 16u && high.samplesPerAnchor == 4u &&
		high.maximumFullLightBuilds == 16u,
		"high profile must retain bounded high-detail geometry and lighting");
	Require(medium.maximumLobesPerGroup == 12u && medium.anchorsPerGroup == 4u &&
		medium.samplesPerAnchor == 2u && medium.maximumFullLightBuilds == 8u,
		"medium profile must match the provisional plan table");
	Require(reference.samplesPerAnchor == 8u,
		"reference profile must retain its diagnostic eight-sample cache build");
	Require(low.maximumActiveGroups == 24u && low.maximumActiveLobes == 96u &&
		low.maximumLobesPerGroup == 4u && low.anchorsPerGroup == 2u &&
		!low.allowSlowFireRefresh,
		"low profile must reduce geometry, cache sampling, and maintenance");
	Require(NRISmokeTransientClouds::DefaultLobeCountForQuality(2u,
		NRISmokeTransientClass::Explosion) == 12u &&
		NRISmokeTransientClouds::DefaultLobeCountForQuality(3u,
			NRISmokeTransientClass::Muzzle) == 2u,
		"class lobe defaults must be deterministic per quality profile");

	NRISmokeTransientClouds owner;
	owner.Reset(1u);
	owner.BeginFrame(0.0, 256u, medium);
	const auto& budget = owner.GetLightBudgetMetadata();
	Require(budget.maximumFullBuildsPerFrame == 8u &&
		budget.maximumPointLightsPerAnchor == 4u &&
		budget.maximumDirectionalLightsPerAnchor == 1u &&
		budget.maximumVisibilityQueriesPerGroup == 28u &&
		budget.maximumVisibilityQueriesPerFrame == 224u &&
		budget.slowFireRefreshEnabled,
		"owner must expose an exact static light-query budget to renderer constants");
	Require(owner.GetSnapshot().allocatedGroupBytes > 0u &&
		owner.GetSnapshot().allocatedLobeBytes > 0u,
		"fixed pool allocation bytes must remain visible in diagnostics");
}

void TestSemanticBuilder()
{
	NRISmokeTransientGroupShapeInput input = {};
	input.position[0] = 1.0f;
	input.velocity[2] = 3.0f;
	input.up[1] = 1.0f;
	input.initialRadius = 2.0f;
	input.initialDensity = 1.5f;
	input.opticalAmount = 100.0f;
	input.expansionVelocity = 1.0f;
	input.densityHalfLife = 2.0f;
	input.lobeLifetimeSeconds = 4.0f;
	input.groupLifetimeSeconds = 5.0f;
	input.densityAttackSeconds = 0.1f;
	input.densitySustainSeconds = 3.0f;
	input.densityReleaseSeconds = 1.0f;
	input.intrinsicEmission = 2.0f;
	input.requestedLobeCount = 8u;
	input.styleIndex = 2u;
	input.sourceId = 7u;
	input.epoch = 3u;
	input.sourceEventSerial = 91u;
	input.deterministicSeed = 123u;
	input.transientClass = NRISmokeTransientClass::Explosion;
	NRISmokeTransientLobeRequest full[16] = {};
	Require(NRIBuildSmokeTransientLobes(input, full, 16u) == 8u,
		"semantic input must build its independently requested lobe count");
	float fullWeight = 0.0f;
	for (uint32_t index = 0u; index < 8u; ++index)
	{
		fullWeight += full[index].opticalWeight;
		Require(full[index].batchIndex == index && full[index].batchCount == 8u &&
			full[index].sourceEventSerial == input.sourceEventSerial,
			"builder must stamp one exact batch identity");
	}
	Require(Near(fullWeight, 100.0f),
		"source optical amount must be independent from lobe count");
	NRISmokeTransientLobeRequest reduced[4] = {};
	Require(NRIBuildSmokeTransientLobes(input, reduced, 4u) == 4u,
		"builder output capacity must deterministically reduce spatial complexity");
	float reducedWeight = 0.0f;
	for (const auto& request : reduced) reducedWeight += request.opticalWeight;
	Require(Near(reducedWeight, 100.0f),
		"builder reduction must retain complete source optical amount");
	NRISmokeTransientLobeRequest repeated[4] = {};
	NRIBuildSmokeTransientLobes(input, repeated, 4u);
	for (uint32_t index = 0u; index < 4u; ++index)
		Require(Near(reduced[index].position[0], repeated[index].position[0]) &&
			reduced[index].deterministicSeed == repeated[index].deterministicSeed,
			"class lobe shaping must be stable for a stable event seed");
	input.transientClass = NRISmokeTransientClass::FirePacket;
	NRISmokeTransientLobeRequest fire[8] = {};
	NRIBuildSmokeTransientLobes(input, fire, 8u);
	Require(!Near(full[1].position[1], fire[1].position[1]) ||
		!Near(full[1].position[2], fire[1].position[2]),
		"explosion and fire classes must not collapse to one placement pattern");
	input.noiseScale = std::numeric_limits<float>::quiet_NaN();
	Require(NRIBuildSmokeTransientLobes(input, fire, 8u) == 0u,
		"semantic builder must reject non-finite shaping fields");
}

void TestPositiveUpBuoyancy()
{
	NRISmokeTransientGroupShapeInput fire = {};
	fire.position[1] = 10.0f;
	fire.velocity[1] = 6.0f;
	fire.up[1] = 1.0f;
	fire.initialRadius = 10.0f;
	fire.initialDensity = 1.0f;
	fire.opticalAmount = 5.0f;
	fire.expansionVelocity = 2.0f;
	fire.densityHalfLife = 2.0f;
	fire.lobeLifetimeSeconds = 3.0f;
	fire.groupLifetimeSeconds = 3.0f;
	fire.clusterSpread = 0.45f;
	fire.lobeRadiusMinScale = 0.4f;
	fire.lobeRadiusMaxScale = 0.7f;
	fire.riseVelocity = 12.0f;
	fire.curlVelocity = 4.0f;
	fire.requestedLobeCount = 5u;
	fire.sourceId = 17u;
	fire.epoch = 4u;
	fire.sourceEventSerial = 1234u;
	fire.transientClass = NRISmokeTransientClass::FirePacket;
	NRISmokeTransientLobeRequest fireLobes[16] = {};
	Require(NRIBuildSmokeTransientLobes(fire, fireLobes, 16u) == 5u,
		"positive-up fire fixture must build its complete packet");
	float meanInitialY = 0.0f;
	float meanLaterY = 0.0f;
	for (uint32_t index = 0u; index < fire.requestedLobeCount; ++index)
	{
		const auto& lobe = fireLobes[index];
		const float unit = (static_cast<float>(index) + 0.5f) /
			static_cast<float>(fire.requestedLobeCount);
		const float expectedInitialY = fire.position[1] + fire.initialRadius *
			fire.clusterSpread * 1.6f * unit;
		Require(Near(lobe.position[1], expectedInitialY) &&
			Near(lobe.velocity[1], fire.velocity[1] + fire.riseVelocity),
			"fire axial placement and rise must follow explicit path-tracing +Y without vertical curl even when source velocity is vertical");
		meanInitialY += lobe.position[1];
		meanLaterY += lobe.position[1] + lobe.velocity[1];
	}
	meanInitialY /= static_cast<float>(fire.requestedLobeCount);
	meanLaterY /= static_cast<float>(fire.requestedLobeCount);
	Require(meanInitialY > fire.position[1] && meanLaterY > meanInitialY,
		"positive-up fire must form a rising packet instead of propagating below its source");

	NRISmokeTransientGroupShapeInput explosion = fire;
	explosion.transientClass = NRISmokeTransientClass::Explosion;
	explosion.requestedLobeCount = 8u;
	explosion.expansionVelocity = 10.0f;
	explosion.riseVelocity = 5.0f;
	NRISmokeTransientLobeRequest explosionLobes[16] = {};
	Require(NRIBuildSmokeTransientLobes(explosion, explosionLobes, 16u) == 8u,
		"vertical-velocity explosion fixture must build its complete billow");
	const float expectedBinderY = explosion.velocity[1] + explosion.riseVelocity +
		explosion.expansionVelocity * 0.08f;
	Require(Near(explosionLobes[0].velocity[1], expectedBinderY) &&
		Near(explosionLobes[1].velocity[1], expectedBinderY),
		"explosion binder buoyancy must follow authored +Y instead of a projected orientation basis");

	NRISmokeTransientGroupShapeInput fallback = fire;
	std::fill(fallback.up, fallback.up + 3, 0.0f);
	fallback.velocity[0] = 0.0f;
	fallback.velocity[1] = 0.0f;
	fallback.velocity[2] = 0.0f;
	NRISmokeTransientLobeRequest fallbackLobes[16] = {};
	Require(NRIBuildSmokeTransientLobes(fallback, fallbackLobes, 16u) == 5u,
		"zero-velocity fire must retain a deterministic horizontal ring basis");
	for (uint32_t index = 0u; index < fallback.requestedLobeCount; ++index)
	{
		const float unit = (static_cast<float>(index) + 0.5f) /
			static_cast<float>(fallback.requestedLobeCount);
		const float expectedInitialY = fallback.position[1] + fallback.initialRadius *
			fallback.clusterSpread * 1.6f * unit;
		Require(Near(fallbackLobes[index].position[1], expectedInitialY) &&
			Near(fallbackLobes[index].velocity[1], fallback.riseVelocity),
			"zero-velocity fire must use +Y fallback gravity while radial curl remains horizontal");
	}
}

void TestNonFirePositiveUpRise()
{
	const std::array<NRISmokeTransientClass, 4> classes = {
		NRISmokeTransientClass::TrailChunk,
		NRISmokeTransientClass::Muzzle,
		NRISmokeTransientClass::Impact,
		NRISmokeTransientClass::Diagnostic,
	};
	for (const NRISmokeTransientClass transientClass : classes)
	{
		NRISmokeTransientGroupShapeInput baseline = {};
		baseline.position[0] = 10.0f;
		baseline.position[1] = 20.0f;
		baseline.position[2] = -5.0f;
		baseline.velocity[0] = 2.0f;
		baseline.velocity[1] = -3.0f;
		baseline.velocity[2] = 4.0f;
		baseline.up[1] = 4.0f;
		baseline.trailAxis[0] = 1.0f;
		baseline.trailSpan = 12.0f;
		baseline.initialRadius = 2.0f;
		baseline.initialDensity = 1.0f;
		baseline.opticalAmount = 10.0f;
		baseline.expansionVelocity = 3.0f;
		baseline.densityHalfLife = 2.0f;
		baseline.lobeLifetimeSeconds = 3.0f;
		baseline.groupLifetimeSeconds = 3.0f;
		baseline.clusterSpread = 0.6f;
		baseline.lobeRadiusMinScale = 0.7f;
		baseline.lobeRadiusMaxScale = 1.2f;
		baseline.curlVelocity = 2.5f;
		baseline.lobeDelayStepSeconds = 0.07f;
		baseline.requestedLobeCount = 6u;
		baseline.sourceId = 29u;
		baseline.epoch = 7u;
		baseline.authoredGameplaySeconds = 41.0;
		baseline.sourceEventSerial = 7788u;
		baseline.deterministicSeed = 99u;
		baseline.transientClass = transientClass;
		NRISmokeTransientLobeRequest baselineLobes[16] = {};
		Require(NRIBuildSmokeTransientLobes(baseline, baselineLobes, 16u) ==
			baseline.requestedLobeCount,
			"non-fire rise baseline must build its complete deterministic batch");

		NRISmokeTransientGroupShapeInput rising = baseline;
		rising.riseVelocity = 7.25f;
		NRISmokeTransientLobeRequest risingLobes[16] = {};
		Require(NRIBuildSmokeTransientLobes(rising, risingLobes, 16u) ==
			rising.requestedLobeCount,
			"non-fire positive-up rise fixture must build its complete batch");
		for (uint32_t index = 0u; index < baseline.requestedLobeCount; ++index)
		{
			const auto& still = baselineLobes[index];
			const auto& raised = risingLobes[index];
			Require(Near(raised.velocity[0], still.velocity[0]) &&
				Near(raised.velocity[1], still.velocity[1] + rising.riseVelocity) &&
				Near(raised.velocity[2], still.velocity[2]),
				"non-fire authored rise must add exactly once to inherited +Y velocity");
			Require(Near(raised.position[0], still.position[0]) &&
				Near(raised.position[1], still.position[1]) &&
				Near(raised.position[2], still.position[2]) &&
				Near(raised.initialRadius, still.initialRadius) &&
				Near(RadiusAt(raised, 0.75f), RadiusAt(still, 0.75f)) &&
				Near(raised.lobeDelaySeconds, still.lobeDelaySeconds) &&
				raised.batchIndex == still.batchIndex &&
				raised.batchCount == still.batchCount &&
				raised.authoredGameplaySeconds == still.authoredGameplaySeconds,
				"non-fire authored rise must not alter initial support, growth, or cadence identity");
		}
	}
}

void TestExplosionBillowShaping()
{
	NRISmokeTransientGroupShapeInput input = {};
	input.position[0] = 10.0f;
	input.position[1] = 20.0f;
	input.position[2] = -5.0f;
	input.velocity[2] = 2.0f;
	input.up[1] = 1.0f;
	input.initialRadius = 45.0f;
	input.initialDensity = 2.4f;
	input.opticalAmount = 48.0f;
	input.expansionVelocity = 18.0f;
	input.densityHalfLife = 10.0f;
	input.lobeLifetimeSeconds = 4.0f;
	input.groupLifetimeSeconds = 4.0f;
	input.densityAttackSeconds = 0.04f;
	input.densitySustainSeconds = 2.5f;
	input.densityReleaseSeconds = 1.5f;
	input.radiusExponent = 0.72f;
	input.intrinsicEmission = 7.0f;
	input.emissionHalfLife = 0.24f;
	input.clusterSpread = 0.82f;
	input.lobeRadiusMinScale = 0.42f;
	input.lobeRadiusMaxScale = 0.68f;
	input.curlVelocity = 5.0f;
	input.requestedLobeCount = 12u;
	input.sourceId = 71u;
	input.epoch = 17u;
	input.sourceEventSerial = 1200u;
	input.deterministicSeed = 0x534d4f4bu;
	input.transientClass = NRISmokeTransientClass::Explosion;
	NRISmokeTransientLobeRequest lobes[16] = {};
	Require(NRIBuildSmokeTransientLobes(input, lobes, 16u) == 12u,
		"production-scale explosion fixture must build all requested billow lobes");
	NRISmokeTransientLobeRequest repeated[16] = {};
	Require(NRIBuildSmokeTransientLobes(input, repeated, 16u) == 12u,
		"stable explosion seed must rebuild its complete lobe batch");

	float minimumInitialRadius = std::numeric_limits<float>::max();
	float maximumInitialRadius = 0.0f;
	float minimumLateRadius = std::numeric_limits<float>::max();
	float maximumLateRadius = 0.0f;
	float totalOpticalWeight = 0.0f;
	float weightedInitialEmission = 0.0f;
	float minimumEmission = std::numeric_limits<float>::max();
	float maximumEmission = 0.0f;
	float minimumHalfLife = std::numeric_limits<float>::max();
	float maximumHalfLife = 0.0f;
	uint32_t satellitesOutsideOrigin = 0u;
	constexpr uint32_t binderCount = 3u;
	const float lateAge = 3.0f;
	const float shapedLateAge = input.lobeLifetimeSeconds * std::pow(
		lateAge / input.lobeLifetimeSeconds, input.radiusExponent);
	for (uint32_t index = 0u; index < input.requestedLobeCount; ++index)
	{
		const auto& lobe = lobes[index];
		Require(Near(lobe.initialRadius, repeated[index].initialRadius) &&
			Near(lobe.expansionVelocity, repeated[index].expansionVelocity) &&
			Near(lobe.velocity[0], repeated[index].velocity[0]) &&
			Near(lobe.velocity[1], repeated[index].velocity[1]) &&
			Near(lobe.velocity[2], repeated[index].velocity[2]) &&
			Near(lobe.intrinsicEmission, repeated[index].intrinsicEmission) &&
			Near(lobe.emissionHalfLife, repeated[index].emissionHalfLife),
			"explosion billow shape and glow variation must be deterministic");
		const float radiusScale = lobe.initialRadius / input.initialRadius;
		const float lateRadius = lobe.initialRadius +
			lobe.expansionVelocity * shapedLateAge;
		Require(Near(lobe.expansionVelocity,
			input.expansionVelocity * radiusScale),
			"explosion growth must remain correlated with its stable lobe radius scale");
		Require(Near(lobe.initialDensity, input.initialDensity),
			"billow shaping must not alter authored density");
		minimumInitialRadius = std::min(minimumInitialRadius, lobe.initialRadius);
		maximumInitialRadius = std::max(maximumInitialRadius, lobe.initialRadius);
		minimumLateRadius = std::min(minimumLateRadius, lateRadius);
		maximumLateRadius = std::max(maximumLateRadius, lateRadius);
		totalOpticalWeight += lobe.opticalWeight;
		weightedInitialEmission += lobe.opticalWeight * lobe.intrinsicEmission;
		minimumEmission = std::min(minimumEmission, lobe.intrinsicEmission);
		maximumEmission = std::max(maximumEmission, lobe.intrinsicEmission);
		minimumHalfLife = std::min(minimumHalfLife, lobe.emissionHalfLife);
		maximumHalfLife = std::max(maximumHalfLife, lobe.emissionHalfLife);

		float initialOffsetSquared = 0.0f;
		float outwardDot = 0.0f;
		float relativeVelocitySquared = 0.0f;
		for (uint32_t axis = 0u; axis < 3u; ++axis)
		{
			const float initialOffset = lobe.position[axis] - input.position[axis];
			const float commonVelocity = input.velocity[axis] + input.up[axis] *
				(input.riseVelocity + input.expansionVelocity * 0.08f);
			const float relativeVelocity = lobe.velocity[axis] - commonVelocity;
			initialOffsetSquared += initialOffset * initialOffset;
			outwardDot += initialOffset * relativeVelocity;
			relativeVelocitySquared += relativeVelocity * relativeVelocity;
		}
		const float initialOffset = std::sqrt(initialOffsetSquared);
		if (index < binderCount)
		{
			Require(Near(initialOffset, 0.0f) &&
				Near(lobe.corePlateau, input.corePlateau) &&
				lobe.intrinsicEmission > input.intrinsicEmission,
				"explosion binders must remain central, authored-core hot anchors");
		}
		else
		{
			Require(initialOffset >= lobe.initialRadius * 0.85f - 1.0e-4f &&
				initialOffset <= 0.88f *
					(lobes[0].initialRadius + lobe.initialRadius) + 1.0e-4f,
				"satellites must protrude beyond their own core while overlapping the primary binder");
			Require(Near(lobe.corePlateau, 0.4f) &&
				lobe.intrinsicEmission >= 0.0f &&
				lobe.intrinsicEmission <= input.intrinsicEmission * 0.1f + 1.0e-4f,
				"explosion satellites must use a cooler, softer plateau than binders");
			Require(outwardDot > 0.0f,
				"explosion satellite centers must propagate outward from their authored core");
			const float scaledGrowth = input.expansionVelocity * radiusScale;
			const float relativeSpeed = std::sqrt(relativeVelocitySquared);
			Require(relativeSpeed >= scaledGrowth * 0.9f - 1.0e-4f &&
				relativeSpeed <= scaledGrowth * 1.05f + 1.0e-4f,
				"explosion satellite speed must stay inside its connected growth envelope");
			if (initialOffset > lobe.initialRadius) satellitesOutsideOrigin++;
		}
	}
	Require(Near(totalOpticalWeight, input.opticalAmount) &&
		Near(weightedInitialEmission / totalOpticalWeight,
			input.intrinsicEmission, 1.0e-4f),
		"billow and emission shaping must preserve density-weighted source amount at spawn");
	Require(minimumEmission >= 0.0f &&
		minimumEmission <= input.intrinsicEmission * 0.1f + 1.0e-4f &&
		maximumEmission > input.intrinsicEmission * 3.0f &&
		satellitesOutsideOrigin >= (input.requestedLobeCount - binderCount) / 2u,
		"explosion source and support must separate into hot binders and protruding cool satellites");
	Require(minimumHalfLife >= input.emissionHalfLife * 0.8f - 1.0e-5f &&
		maximumHalfLife <= input.emissionHalfLife * 1.2f + 1.0e-5f &&
		maximumHalfLife > minimumHalfLife,
		"explosion glow decay must vary modestly without leaving its authored envelope");
	Require(Near(maximumInitialRadius / minimumInitialRadius,
		maximumLateRadius / minimumLateRadius, 1.0e-4f) &&
		(maximumLateRadius - minimumLateRadius) /
			((maximumLateRadius + minimumLateRadius) * 0.5f) > 0.3f,
		"late expansion must preserve visible macro-lobe size variation");

	for (const float age : { 0.0f, 1.5f, 3.0f })
	{
		Require(RequestGraphConnected(lobes, input.requestedLobeCount, age),
			"authored positive-growth exponent-at-most-one billows must retain a connected overlap graph");
		float boundsMin[3] = {
			std::numeric_limits<float>::max(),
			std::numeric_limits<float>::max(),
			std::numeric_limits<float>::max()
		};
		float boundsMax[3] = {
			-std::numeric_limits<float>::max(),
			-std::numeric_limits<float>::max(),
			-std::numeric_limits<float>::max()
		};
		const float shapedAge = input.lobeLifetimeSeconds * std::pow(
			age / input.lobeLifetimeSeconds, input.radiusExponent);
		for (uint32_t index = 0u; index < input.requestedLobeCount; ++index)
		{
			const auto& lobe = lobes[index];
			const float radius = lobe.initialRadius +
				lobe.expansionVelocity * shapedAge;
			for (uint32_t axis = 0u; axis < 3u; ++axis)
			{
				const float position = lobe.position[axis] + lobe.velocity[axis] * age;
				boundsMin[axis] = std::min(boundsMin[axis], position - radius);
				boundsMax[axis] = std::max(boundsMax[axis], position + radius);
			}
		}
		for (uint32_t axis = 0u; axis < 3u; ++axis)
			Require(std::isfinite(boundsMin[axis]) && std::isfinite(boundsMax[axis]) &&
				boundsMax[axis] > boundsMin[axis],
				"billow bounds must remain finite and non-empty across absolute time");
	}
	for (const uint32_t reducedCount : { 6u, 4u, 2u })
	{
		auto reducedProfile = NRISmokeTransientClouds::ProfileForQuality(2u);
		reducedProfile.maximumActiveLobes = reducedCount;
		reducedProfile.maximumLobesPerGroup = reducedCount;
		reducedProfile.minimumReducedLobes = reducedCount;
		NRISmokeTransientClouds reducedOwner;
		reducedOwner.Reset(input.epoch);
		reducedOwner.BeginFrame(0.0, reducedCount, reducedProfile);
		const auto admission = reducedOwner.AdmitBatch(lobes,
			input.requestedLobeCount);
		Require(admission.Accepted() && admission.admittedLobes == reducedCount,
			"billow reduction fixture must admit its deterministic target count");
		for (const float age : { 0.1f, 1.5f, 3.0f })
		{
			reducedOwner.BeginFrame(age, reducedCount, reducedProfile);
			const auto& gpuLobes = reducedOwner.GetGpuLobes();
			Require(gpuLobes.size() == reducedCount && GpuGraphConnected(gpuLobes),
				"authored production-domain reduced explosion counts must preserve a connected graph");
			for (uint32_t axis = 0u; axis < 3u; ++axis)
			{
				const float primaryPosition = lobes[0].position[axis] +
					lobes[0].velocity[axis] * age;
				Require(Near(gpuLobes[0].position[axis], primaryPosition),
					"deterministic explosion reduction must retain primary binder geometry");
			}
		}
	}

	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds direct;
	direct.Reset(input.epoch);
	direct.BeginFrame(0.0, 256u, profile);
	const auto directAdmission = direct.AdmitBatch(lobes, 12u);
	Require(directAdmission.Accepted(),
		"billow absolute-time fixture must admit its complete group");
	direct.BeginFrame(2.4, 256u, profile);
	NRISmokeTransientClouds stepped;
	stepped.Reset(input.epoch);
	stepped.BeginFrame(0.0, 256u, profile);
	const auto steppedAdmission = stepped.AdmitBatch(lobes, 12u);
	Require(steppedAdmission.Accepted(),
		"stepped billow fixture must admit its complete group");
	for (uint32_t step = 1u; step <= 12u; ++step)
		stepped.BeginFrame(static_cast<double>(step) * 0.2, 256u, profile);
	Require(direct.GetGpuLobes().size() == stepped.GetGpuLobes().size(),
		"billow dt comparison must retain identical visible populations");
	for (uint32_t index = 0u; index < direct.GetGpuLobes().size(); ++index)
	{
		const auto& a = direct.GetGpuLobes()[index];
		const auto& b = stepped.GetGpuLobes()[index];
		Require(Near(a.radius, b.radius) && Near(a.position[0], b.position[0]) &&
			Near(a.position[1], b.position[1]) && Near(a.position[2], b.position[2]) &&
			Near(a.densityScale, b.densityScale) && Near(a.emissionScale, b.emissionScale),
			"billow position, radius, density, and emission must use absolute time");
	}
	const auto& directGroup = Group(direct, directAdmission.handle);
	const auto& steppedGroup = Group(stepped, steppedAdmission.handle);
	for (uint32_t axis = 0u; axis < 3u; ++axis)
		Require(Near(directGroup.boundsMin[axis], steppedGroup.boundsMin[axis]) &&
			Near(directGroup.boundsMax[axis], steppedGroup.boundsMax[axis]),
			"billow group bounds must be invariant to frame subdivision");
}

void TestTrailCoverage()
{
	NRISmokeTransientGroupShapeInput trail = {};
	trail.velocity[0] = 500.0f;
	trail.up[1] = 1.0f;
	trail.trailAxis[0] = 1.0f;
	trail.trailSpan = 24.0f;
	trail.initialRadius = 0.5f;
	trail.initialDensity = 1.0f;
	trail.opticalAmount = 2.0f;
	trail.expansionVelocity = 0.5f;
	trail.densityHalfLife = 2.0f;
	trail.lobeLifetimeSeconds = 3.0f;
	trail.groupLifetimeSeconds = 3.0f;
	trail.requestedLobeCount = 6u;
	trail.sourceId = 3u;
	trail.epoch = 1u;
	trail.sourceEventSerial = 100u;
	trail.transientClass = NRISmokeTransientClass::TrailChunk;
	NRISmokeTransientLobeRequest lobes[16] = {};
	const uint32_t count = NRIBuildSmokeTransientLobes(trail, lobes, 16u);
	Require(count == 6u && Near(lobes[0].position[0], -12.0f) &&
		Near(lobes[count - 1u].position[0], 12.0f),
		"fast explicit trail must cover the entire authored span, independent of speed");
	for (uint32_t index = 1u; index < count; ++index)
	{
		float distanceSquared = 0.0f;
		for (uint32_t axis = 0u; axis < 3u; ++axis)
		{
			const float delta = lobes[index].position[axis] - lobes[index - 1u].position[axis];
			distanceSquared += delta * delta;
		}
		Require(std::sqrt(distanceSquared) <= 0.9f *
			(lobes[index].initialRadius + lobes[index - 1u].initialRadius) + 1.0e-5f,
			"adjacent explicit trail shoulders must overlap even across a long hitch span");
	}
	NRISmokeTransientLobeRequest pressureReduced[2] = {};
	const uint32_t pressureCount = NRIBuildSmokeTransientLobes(
		trail, pressureReduced, 2u);
	Require(pressureCount == 2u &&
		Near(pressureReduced[0].position[0], -12.0f) &&
		Near(pressureReduced[1].position[0], 12.0f),
		"Low pressure fallback must retain both trail-span endpoints");
	float reducedDistanceSquared = 0.0f;
	for (uint32_t axis = 0u; axis < 3u; ++axis)
	{
		const float delta = pressureReduced[1].position[axis] -
			pressureReduced[0].position[axis];
		reducedDistanceSquared += delta * delta;
	}
	Require(std::sqrt(reducedDistanceSquared) <= 0.9f *
		(pressureReduced[0].initialRadius + pressureReduced[1].initialRadius) + 1.0e-5f,
		"two-lobe pressure fallback must conservatively cover the complete trail span");
	Require(Near(pressureReduced[0].opticalWeight +
		pressureReduced[1].opticalWeight, trail.opticalAmount),
		"two-lobe pressure fallback must retain complete trail optical amount");

	trail.position[0] = 12.0f;
	trail.position[2] = 12.0f;
	trail.velocity[0] = 0.0f;
	trail.trailAxis[0] = 0.0f;
	trail.trailAxis[2] = 1.0f;
	trail.trailSpan = 24.0f;
	trail.sourceEventSerial++;
	NRISmokeTransientLobeRequest turned[16] = {};
	NRIBuildSmokeTransientLobes(trail, turned, 16u);
	Require(Near(turned[0].position[2] - trail.position[2], -12.0f) &&
		Near(turned[count - 1u].position[2] - trail.position[2], 12.0f),
		"zero-drift trail must follow explicit axis through a ninety-degree segment turn");
	float joinDistanceSquared = 0.0f;
	for (uint32_t axis = 0u; axis < 3u; ++axis)
	{
		const float delta = lobes[count - 1u].position[axis] - turned[0].position[axis];
		joinDistanceSquared += delta * delta;
	}
	Require(std::sqrt(joinDistanceSquared) <= 0.9f *
		(lobes[count - 1u].initialRadius + turned[0].initialRadius) + 1.0e-5f,
		"bounded trail chunks must retain shoulder overlap across a ninety-degree join");
}

void TestIdentityLifetimeAndReservation()
{
	NRISmokeTransientClouds owner;
	owner.Reset(3u);
	Require(owner.Admit(Lobe(3u, 1u, 10.0)).dropReason ==
		NRISmokeTransientDropReason::NotPrepared,
		"admission before BeginFrame must fail explicitly");
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	profile.maximumActiveGroups = 4u;
	profile.maximumActiveLobes = 8u;
	owner.BeginFrame(10.0, 8u, profile);
	auto delayed = Lobe(3u, 20u, 10.0);
	delayed.lobeDelaySeconds = 1.0f;
	delayed.lifetimeSeconds = 1.0f;
	delayed.groupLifetimeSeconds = 3.0f;
	const auto admitted = owner.Admit(delayed);
	Require(admitted.Accepted() && owner.IsLive(admitted.handle),
		"delayed admission must return its exact CPU group identity");
	Require(owner.GetGpuLobes().empty() && owner.GetSnapshot().activeLobes == 1u &&
		owner.GetSnapshot().visibleLobes == 0u &&
		(Group(owner, admitted.handle).flags & NRISmokeTransientGroupFlagActive) != 0u,
		"an invisible delayed lobe must reserve a real pool slot and indexed group record");
	owner.BeginFrame(11.25, 8u, profile);
	Require(owner.GetSnapshot().visibleGroups == 1u &&
		owner.GetSnapshot().visibleLobes == 1u,
		"delayed lobe must become visible from absolute gameplay time");
	owner.BeginFrame(12.25, 8u, profile);
	Require(owner.GetSnapshot().visibleLobes == 0u &&
		owner.GetSnapshot().activeGroups == 1u && owner.GetSnapshot().activeLobes == 1u,
		"group and reserved lobe identity may outlive the visible lobe envelope");
	owner.BeginFrame(13.0, 8u, profile);
	Require(!owner.IsLive(admitted.handle) && owner.GetSnapshot().groupsExpired == 1u &&
		owner.GetSnapshot().lobesExpired == 1u,
		"group expiry must retire all member slots without dangling identity");
	auto reused = Lobe(3u, 21u, 13.0);
	reused.groupLifetimeSeconds = 1.0f;
	const auto reusedAdmission = owner.Admit(reused);
	Require(reusedAdmission.Accepted() &&
		reusedAdmission.handle.slot == admitted.handle.slot &&
		reusedAdmission.handle.generation != admitted.handle.generation,
		"slot reuse must advance generation while retaining deterministic first-fit reuse");
	owner.Reset(3u);
	Require(!owner.IsLive(reusedAdmission.handle),
		"reset with an unchanged epoch must still invalidate prior generations");

	owner.BeginFrame(20.0, 8u, profile);
	auto shortGroup = Lobe(3u, 22u, 20.0);
	shortGroup.groupLifetimeSeconds = 0.5f;
	shortGroup.lifetimeSeconds = 4.0f;
	const auto shortAdmission = owner.Admit(shortGroup);
	owner.BeginFrame(20.5, 8u, profile);
	Require(!owner.IsLive(shortAdmission.handle) && owner.GetGpuLobes().empty(),
		"a group may safely expire before a longer member envelope");
}

void TestCapacityAndOpticalReduction()
{
	NRISmokeTransientClouds owner;
	owner.Reset(4u);
	auto profile = NRISmokeTransientClouds::ProfileForQuality(1u);
	owner.BeginFrame(0.0, 256u, profile);
	for (uint32_t group = 0u; group < 16u; ++group)
	{
		auto requests = Batch(4u, 100u + group, 0.0, 16u);
		for (auto& request : requests)
		{
			request.lobeDelaySeconds = 50.0f;
			request.lifetimeSeconds = 100.0f;
			request.groupLifetimeSeconds = 200.0f;
		}
		Require(owner.AdmitBatch(requests.data(),
			static_cast<uint32_t>(requests.size())).admittedLobes == 16u,
			"fixed lobe pool must reserve complete invisible batches");
	}
	Require(owner.GetSnapshot().activeGroups == 16u &&
		owner.GetSnapshot().activeLobes == 256u && owner.GetGpuLobes().empty(),
		"all 256 physical lobe slots must remain reserved while envelopes are invisible");
	auto overflow = Lobe(4u, 999u, 0.0);
	overflow.groupLifetimeSeconds = 200.0f;
	Require(owner.Admit(overflow).dropReason ==
		NRISmokeTransientDropReason::LobeCapacity,
		"invisible reservations must participate in lobe-capacity rejection");

	owner.Reset(5u);
	profile.maximumActiveGroups = 4u;
	profile.maximumActiveLobes = 4u;
	profile.maximumLobesPerGroup = 4u;
	profile.minimumReducedLobes = 2u;
	owner.BeginFrame(0.0, 4u, profile);
	auto varied = Batch(5u, 200u, 0.0, 6u);
	float requestedOpticalQuantity = 0.0f;
	for (uint32_t index = 0u; index < varied.size(); ++index)
	{
		varied[index].initialDensity = 1.0f + static_cast<float>(index);
		varied[index].opticalWeight = 0.25f + static_cast<float>(index) * 0.5f;
		requestedOpticalQuantity += varied[index].initialDensity *
			varied[index].opticalWeight;
	}
	const auto reduced = owner.AdmitBatch(varied.data(),
		static_cast<uint32_t>(varied.size()));
	Require(reduced.Accepted() && reduced.admittedLobes == 4u &&
		owner.GetSnapshot().deterministicallyReducedLobes == 2u,
		"capacity policy must reduce complete groups only above the configured floor");
	float admittedOpticalQuantity = 0.0f;
	for (const auto& gpu : owner.GetGpuLobes()) admittedOpticalQuantity += gpu.densityScale;
	Require(Near(admittedOpticalQuantity, requestedOpticalQuantity),
		"varying-density lobe reduction must conserve deterministic optical quantity");

	owner.Reset(6u);
	profile.maximumActiveLobes = 3u;
	profile.maximumLobesPerGroup = 3u;
	profile.minimumReducedLobes = 3u;
	owner.BeginFrame(0.0, 3u, profile);
	auto occupied = Lobe(6u, 299u, 0.0);
	Require(owner.Admit(occupied).Accepted(),
		"capacity-floor fixture must reserve its first lobe");
	for (auto& request : varied) request.epoch = 6u;
	const auto rejected = owner.AdmitBatch(varied.data(),
		static_cast<uint32_t>(varied.size()));
	Require(!rejected.Accepted() && rejected.dropReason ==
		NRISmokeTransientDropReason::LobeCapacity &&
		owner.GetSnapshot().activeGroups == 1u &&
		owner.GetSnapshot().activeLobes == 1u,
		"reduction below the configured floor must reject the whole group atomically");
}

void TestIntrinsicEmissionOpticalInvariant()
{
	NRISmokeTransientGroupShapeInput input = {};
	input.velocity[2] = 1.0f;
	input.up[1] = 1.0f;
	input.initialRadius = 2.0f;
	input.initialDensity = 1.5f;
	input.opticalAmount = 12.0f;
	input.expansionVelocity = 1.0f;
	input.densityHalfLife = 2.0f;
	input.lobeLifetimeSeconds = 4.0f;
	input.groupLifetimeSeconds = 4.0f;
	input.densitySustainSeconds = 3.0f;
	input.densityReleaseSeconds = 1.0f;
	input.intrinsicEmission = 3.0f;
	input.requestedLobeCount = 8u;
	input.sourceId = 44u;
	input.epoch = 13u;
	input.sourceEventSerial = 900u;
	input.transientClass = NRISmokeTransientClass::Explosion;
	NRISmokeTransientLobeRequest requests[16] = {};
	Require(NRIBuildSmokeTransientLobes(input, requests, 16u) == 8u,
		"intrinsic-emission fixture must produce its full lobe batch");

	auto fullProfile = NRISmokeTransientClouds::ProfileForQuality(1u);
	NRISmokeTransientClouds full;
	full.Reset(13u);
	full.BeginFrame(0.0, 256u, fullProfile);
	Require(full.AdmitBatch(requests, 8u).admittedLobes == 8u,
		"intrinsic-emission fixture must admit its full representation");
	auto reducedProfile = fullProfile;
	reducedProfile.maximumActiveLobes = 4u;
	reducedProfile.maximumLobesPerGroup = 4u;
	reducedProfile.minimumReducedLobes = 4u;
	NRISmokeTransientClouds reduced;
	reduced.Reset(13u);
	reduced.BeginFrame(0.0, 4u, reducedProfile);
	Require(reduced.AdmitBatch(requests, 8u).admittedLobes == 4u,
		"intrinsic-emission fixture must exercise deterministic owner reduction");
	float fullSource = 0.0f;
	for (uint32_t index = 0u; index < full.GetGpuLobes().size(); ++index)
	{
		const auto& lobe = full.GetGpuLobes()[index];
		Require(Near(lobe.emissionScale, requests[index].intrinsicEmission),
			"GPU emission scale must be a coefficient, not another optical weight");
		fullSource += lobe.densityScale * lobe.emissionScale;
	}
	float reducedSource = 0.0f;
	for (const auto& lobe : reduced.GetGpuLobes())
		reducedSource += lobe.densityScale * lobe.emissionScale;
	Require(Near(fullSource, reducedSource),
		"intrinsic source must remain invariant when equal-field lobes are reduced");
}

void TestAbsoluteCurvesAndDtInvariance()
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds direct;
	direct.Reset(7u);
	direct.BeginFrame(0.0, 256u, profile);
	auto request = Lobe(7u, 300u, 0.0);
	request.densityAttackSeconds = 1.0f;
	request.densitySustainSeconds = 3.0f;
	request.densityReleaseSeconds = 1.0f;
	request.groupLifetimeSeconds = 5.0f;
	direct.Admit(request);
	direct.BeginFrame(0.25, 256u, profile);
	Require(direct.GetGpuLobes().size() == 1u &&
		Near(direct.GetGpuLobes()[0].radius, 2.5f) &&
		Near(direct.GetGpuLobes()[0].position[0], 0.25f) &&
		Near(direct.GetGpuLobes()[0].densityScale, 0.3125f),
		"absolute attack curve must use smoothstep without frame integration");
	direct.BeginFrame(1.5, 256u, profile);
	Require(Near(direct.GetGpuLobes()[0].densityScale, 2.0f),
		"density envelope must retain a flat authored plateau");
	direct.BeginFrame(3.25, 256u, profile);
	Require(Near(direct.GetGpuLobes()[0].densityScale, 1.6875f),
		"density release must be a smooth absolute-time curve");

	NRISmokeTransientClouds stepped;
	stepped.Reset(7u);
	stepped.BeginFrame(0.0, 256u, profile);
	stepped.Admit(request);
	for (uint32_t step = 1u; step <= 13u; ++step)
		stepped.BeginFrame(static_cast<double>(step) * 0.25, 256u, profile);
	Require(Near(stepped.GetGpuLobes()[0].radius, direct.GetGpuLobes()[0].radius) &&
		Near(stepped.GetGpuLobes()[0].densityScale,
			direct.GetGpuLobes()[0].densityScale) &&
		Near(stepped.GetGpuLobes()[0].emissionScale,
			direct.GetGpuLobes()[0].emissionScale),
		"lobe radius, density, and emission must be invariant to dt subdivision");
}

void TestValidationAndBatchIdentity()
{
	NRISmokeTransientClouds owner;
	owner.Reset(8u);
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	owner.BeginFrame(10.0, 256u, profile);
	const auto valid = Lobe(8u, 400u, 10.0);
	const float nan = std::numeric_limits<float>::quiet_NaN();
	const double nanDouble = std::numeric_limits<double>::quiet_NaN();
#define REQUIRE_NAN_REJECT(member) \
	do { auto invalid = valid; invalid.member = nan; \
	Require(owner.Admit(invalid).dropReason == NRISmokeTransientDropReason::InvalidRequest, \
		"non-finite " #member " must be rejected"); } while (false)
	REQUIRE_NAN_REJECT(initialRadius);
	REQUIRE_NAN_REJECT(initialDensity);
	REQUIRE_NAN_REJECT(opticalWeight);
	REQUIRE_NAN_REJECT(expansionVelocity);
	REQUIRE_NAN_REJECT(densityHalfLife);
	REQUIRE_NAN_REJECT(lifetimeSeconds);
	REQUIRE_NAN_REJECT(maximumLatencySeconds);
	REQUIRE_NAN_REJECT(groupLifetimeSeconds);
	REQUIRE_NAN_REJECT(lobeDelaySeconds);
	REQUIRE_NAN_REJECT(densityAttackSeconds);
	REQUIRE_NAN_REJECT(densitySustainSeconds);
	REQUIRE_NAN_REJECT(densityReleaseSeconds);
	REQUIRE_NAN_REJECT(radiusExponent);
	REQUIRE_NAN_REJECT(intrinsicEmission);
	REQUIRE_NAN_REJECT(emissionHalfLife);
	REQUIRE_NAN_REJECT(corePlateau);
	REQUIRE_NAN_REJECT(edgeErosion);
	REQUIRE_NAN_REJECT(noiseScale);
	REQUIRE_NAN_REJECT(noiseStrength);
#undef REQUIRE_NAN_REJECT
	for (uint32_t axis = 0u; axis < 3u; ++axis)
	{
		auto invalid = valid;
		invalid.position[axis] = nan;
		Require(owner.Admit(invalid).dropReason ==
			NRISmokeTransientDropReason::InvalidRequest,
			"all position components must be finite");
		invalid = valid;
		invalid.velocity[axis] = nan;
		Require(owner.Admit(invalid).dropReason ==
			NRISmokeTransientDropReason::InvalidRequest,
			"all velocity components must be finite");
		invalid = valid;
		invalid.halfAxisU[axis] = nan;
		Require(owner.Admit(invalid).dropReason ==
			NRISmokeTransientDropReason::InvalidRequest,
			"all U half-axis components must be finite");
		invalid = valid;
		invalid.halfAxisV[axis] = nan;
		Require(owner.Admit(invalid).dropReason ==
			NRISmokeTransientDropReason::InvalidRequest,
			"all V half-axis components must be finite");
	}
	auto invalidTime = valid;
	invalidTime.authoredGameplaySeconds = nanDouble;
	Require(owner.Admit(invalidTime).dropReason ==
		NRISmokeTransientDropReason::InvalidRequest,
		"authored gameplay time must be finite");

	auto batch = Batch(8u, 401u, 10.0, 3u);
	batch[1].sourceEventSerial++;
	Require(owner.AdmitBatch(batch.data(), 3u).dropReason ==
		NRISmokeTransientDropReason::InvalidRequest,
		"mixed event identity must invalidate the complete batch");
	batch = Batch(8u, 401u, 10.0, 3u);
	batch[1].sourceId++;
	Require(owner.AdmitBatch(batch.data(), 3u).dropReason ==
		NRISmokeTransientDropReason::InvalidRequest,
		"mixed source identity must invalidate the complete batch");
	batch = Batch(8u, 401u, 10.0, 3u);
	batch[1].batchIndex = 2u;
	Require(owner.AdmitBatch(batch.data(), 3u).dropReason ==
		NRISmokeTransientDropReason::InvalidRequest,
		"duplicate or out-of-order batch indices must be rejected atomically");
	batch = Batch(8u, 401u, 10.0, 3u);
	batch[2].groupLifetimeSeconds += 1.0f;
	Require(owner.AdmitBatch(batch.data(), 3u).dropReason ==
		NRISmokeTransientDropReason::InvalidRequest,
		"mixed group lifetime must invalidate the complete batch");
	Require(owner.GetSnapshot().activeGroups == 0u &&
		owner.GetSnapshot().activeLobes == 0u,
		"invalid batches must not reserve any group or lobe slots");
}

void TestReplacementAndLightScheduling()
{
	NRISmokeTransientClouds owner;
	owner.Reset(9u);
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	profile.maximumFullLightBuilds = 1u;
	profile.fireRefreshSeconds = 0.5f;
	owner.BeginFrame(0.0, 256u, profile);
	auto fire = Lobe(9u, 500u, 0.0);
	fire.replacementKey = 55u;
	fire.transientClass = NRISmokeTransientClass::FirePacket;
	fire.lightRefresh = NRISmokeTransientLightRefresh::Slow;
	const auto fireAdmission = owner.AdmitLatest(fire);
	Require(fireAdmission.Accepted() && Group(owner, fireAdmission.handle).flags ==
		(NRISmokeTransientGroupFlagActive |
			NRISmokeTransientGroupFlagFullLightAllowed |
			NRISmokeTransientGroupFlagSlowRefresh),
		"new visible fire must receive the bounded fresh-light allowance");
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(0.6, 256u, profile);
	Require(owner.GetSnapshot().fullLightRefreshScheduledThisFrame == 1u,
		"slow fire must become refresh-eligible after its fixed interval");
	auto explosion = Lobe(9u, 501u, 0.6, 10.0f);
	const auto explosionAdmission = owner.Admit(explosion);
	Require(explosionAdmission.Accepted() &&
		owner.GetSnapshot().fullLightFreshScheduledThisFrame == 1u &&
		owner.GetSnapshot().fullLightRefreshScheduledThisFrame == 0u &&
		owner.GetSnapshot().fullLightRefreshDeferredThisFrame == 1u,
		"fresh explosion light must preempt bounded fire maintenance deterministically");
	Require(Group(owner, explosionAdmission.handle).flags ==
		(NRISmokeTransientGroupFlagActive |
			NRISmokeTransientGroupFlagFullLightAllowed) &&
		Group(owner, fireAdmission.handle).flags ==
		(NRISmokeTransientGroupFlagActive |
			NRISmokeTransientGroupFlagFallbackLight |
			NRISmokeTransientGroupFlagSlowRefresh),
		"group flags must remain exactly active/full-or-fallback/slow");
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(0.7, 256u, profile);
	Require(owner.GetSnapshot().fullLightRefreshScheduledThisFrame == 1u,
		"preempted fire refresh must remain due rather than being falsely committed");

	auto replacement = fire;
	replacement.sourceEventSerial++;
	replacement.authoredGameplaySeconds = 0.7;
	const auto replaced = owner.AdmitLatest(replacement);
	Require(replaced.Accepted() && replaced.handle.slot == fireAdmission.handle.slot &&
		replaced.handle.generation != fireAdmission.handle.generation &&
		!owner.IsLive(fireAdmission.handle) && owner.IsLive(replaced.handle),
		"latest replacement must invalidate the old handle with a new generation");
	Require(owner.RetireLatest(55u) && !owner.IsLive(replaced.handle),
		"explicit latest retirement must release the exact replacement group");

	NRISmokeTransientClouds skipped;
	skipped.Reset(10u);
	skipped.BeginFrame(1.0, 256u, profile);
	auto cold = Lobe(10u, 600u, 1.0);
	Require(skipped.Admit(cold).Accepted() &&
		skipped.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"new cold group must request its initial full-light schedule");
	skipped.BeginFrame(1.1, 256u, profile);
	Require(skipped.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"a skipped GPU light dispatch must keep initial lighting fresh and pending");
	skipped.CommitLightDispatchSchedule();
	skipped.BeginFrame(1.2, 256u, profile);
	Require(skipped.GetSnapshot().fullLightFreshRequestedThisFrame == 0u,
		"only explicit dispatch submission acknowledgement may retire initial scheduling");
}

void TestAttackMatureInitialLighting()
{
	NRISmokeTransientClouds owner;
	owner.Reset(15u);
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	profile.maximumFullLightBuilds = 1u;
	profile.fireRefreshSeconds = 0.25f;
	owner.BeginFrame(100.0, 256u, profile);
	auto fire = Lobe(15u, 950u, 100.0);
	fire.transientClass = NRISmokeTransientClass::FirePacket;
	fire.lightRefresh = NRISmokeTransientLightRefresh::Slow;
	fire.densityAttackSeconds = 1.0f;
	const auto admission = owner.Admit(fire);
	Require(admission.Accepted(),
		"attack-maturity fixture must admit its frozen-light group");
	owner.BeginFrame(100.1, 256u, profile);
	const auto immatureIdentity = Group(owner, admission.handle);
	Require(owner.GetSnapshot().visibleLobes == 1u &&
		owner.GetSnapshot().fullLightFreshRequestedThisFrame == 0u &&
		owner.GetSnapshot().fullLightFreshScheduledThisFrame == 0u &&
		immatureIdentity.flags == (NRISmokeTransientGroupFlagActive |
			NRISmokeTransientGroupFlagFallbackLight |
			NRISmokeTransientGroupFlagSlowRefresh),
		"first-visible attack smoke must use fallback without consuming full-light budget");
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(100.81, 256u, profile);
	const auto matureIdentity = Group(owner, admission.handle);
	Require(owner.IsLive(admission.handle) &&
		owner.GetSnapshot().fullLightFreshRequestedThisFrame == 1u &&
		owner.GetSnapshot().fullLightFreshScheduledThisFrame == 1u &&
		matureIdentity.flags == (NRISmokeTransientGroupFlagActive |
			NRISmokeTransientGroupFlagFullLightAllowed |
			NRISmokeTransientGroupFlagSlowRefresh),
		"a group crossing 90 percent attack must receive its pending full build");
	Require(matureIdentity.slot == immatureIdentity.slot &&
		matureIdentity.generation == immatureIdentity.generation &&
		matureIdentity.epoch == immatureIdentity.epoch &&
		matureIdentity.reserved == immatureIdentity.reserved,
		"fallback-to-full maturity must preserve exact group and cache identity");
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(100.9, 256u, profile);
	Require(owner.GetSnapshot().fullLightFreshRequestedThisFrame == 0u,
		"mature submitted frozen lighting must retire only its initial-build request");
}

void TestProfileRevisionRebuild()
{
	NRISmokeTransientClouds owner;
	owner.Reset(11u);
	const auto medium = NRISmokeTransientClouds::ProfileForQuality(2u);
	const auto high = NRISmokeTransientClouds::ProfileForQuality(1u);
	owner.BeginFrame(0.0, 256u, medium);
	const auto admitted = owner.Admit(Lobe(11u, 700u, 0.0));
	Require(admitted.Accepted(), "profile-revision fixture must admit its group");
	const uint32_t mediumRevision = Group(owner, admitted.handle).reserved >> 16u;
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(0.1, 256u, high);
	const uint32_t highRevision = Group(owner, admitted.handle).reserved >> 16u;
	Require(owner.IsLive(admitted.handle) && highRevision != mediumRevision &&
		owner.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"sample-count policy changes must revise lighting identity and request rebuild without geometry churn");
	owner.CommitLightDispatchSchedule();
	owner.BeginFrame(0.2, 256u, high);
	Require((Group(owner, admitted.handle).reserved >> 16u) == highRevision &&
		owner.GetSnapshot().fullLightFreshRequestedThisFrame == 0u,
		"unchanged light policy must retain revision and committed cache scheduling state");
	const auto low = NRISmokeTransientClouds::ProfileForQuality(3u);
	owner.BeginFrame(0.3, 256u, low);
	Require((Group(owner, admitted.handle).reserved >> 16u) != highRevision &&
		owner.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"anchor-count policy changes must invalidate the complete cache identity");

	NRISmokeTransientClouds explicitPolicy;
	explicitPolicy.Reset(12u);
	auto bounded = medium;
	bounded.maximumFullLightBuilds = 1u;
	explicitPolicy.BeginFrame(1.0, 256u, bounded);
	const auto first = explicitPolicy.Admit(Lobe(12u, 800u, 1.0));
	explicitPolicy.CommitLightDispatchSchedule();
	explicitPolicy.BeginFrame(1.1, 256u, bounded);
	const auto second = explicitPolicy.Admit(Lobe(12u, 801u, 1.1, 5.0f));
	explicitPolicy.CommitLightDispatchSchedule();
	explicitPolicy.BeginFrame(1.2, 256u, bounded);
	const uint32_t oldRevision = Group(explicitPolicy, first.handle).reserved >> 16u;
	const uint32_t oldLobeCount = explicitPolicy.GetSnapshot().activeLobes;
	explicitPolicy.InvalidateLighting();
	Require(explicitPolicy.IsLive(first.handle) && explicitPolicy.IsLive(second.handle) &&
		explicitPolicy.GetSnapshot().activeLobes == oldLobeCount &&
		(Group(explicitPolicy, first.handle).reserved >> 16u) != oldRevision,
		"explicit family-policy invalidation must preserve geometry and handles while revising cache identity");
	Require(explicitPolicy.GetSnapshot().fullLightFreshRequestedThisFrame == 2u &&
		explicitPolicy.GetSnapshot().fullLightFreshScheduledThisFrame == 1u &&
		explicitPolicy.GetSnapshot().fullLightFreshDeferredThisFrame == 1u,
		"explicit lighting invalidation rebuilds must obey the fixed per-frame budget");
	explicitPolicy.CommitLightDispatchSchedule();
	explicitPolicy.BeginFrame(1.3, 256u, bounded);
	Require(explicitPolicy.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"deferred invalidated groups must retain pending rebuild state for a later frame");
}
}

int main()
{
	TestProfiles();
	TestSemanticBuilder();
	TestPositiveUpBuoyancy();
	TestNonFirePositiveUpRise();
	TestExplosionBillowShaping();
	TestTrailCoverage();
	TestIdentityLifetimeAndReservation();
	TestCapacityAndOpticalReduction();
	TestIntrinsicEmissionOpticalInvariant();
	TestAbsoluteCurvesAndDtInvariance();
	TestValidationAndBatchIdentity();
	TestReplacementAndLightScheduling();
	TestAttackMatureInitialLighting();
	TestProfileRevisionRebuild();
	std::cout << "Smoke transient group/lobe tests passed.\n";
	return 0;
}
