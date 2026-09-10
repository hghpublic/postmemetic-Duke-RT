#include "nri_smoke_transient_clouds.h"
#include "nri_smoke_source_envelope.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace
{
constexpr uint32_t Epoch = 73u;
constexpr uint32_t FireLobes = 5u;
constexpr float InitialRadius = 21.0f; // max(spawnradius 4, style radius 7 * radiusscale 3)
constexpr float InitialDensity = 3.0f;
constexpr float DensityHalfLife = 6.0f;
constexpr float RadiusExponent = 0.90f;
constexpr float IntrinsicEmission = 0.5f;
constexpr float CurlVelocity = 4.0f;
constexpr float CorePlateau = 0.60f;
constexpr float EdgeErosion = 0.16f;
constexpr float NoiseScale = 0.035f;
constexpr float NoiseStrength = 0.20f;
constexpr float RuleCount = 9.0f;
constexpr float Extinction = 0.008f;
constexpr float StyleDensity = 3.0f;

struct FireTuning
{
	float opticalScale = 0.0f;
	float lifetime = 0.0f;
	float riseVelocity = 0.0f;
	float sustain = 0.0f;
	float release = 0.0f;
	float spread = 0.0f;
	float cadence = 0.0f;
	float lobeRadiusMin = 0.0f;
	float lobeRadiusMax = 0.0f;
	float pulseAmount = 0.0f;
	float densityAttack = 0.0f;
	float emissionHalfLife = 0.0f;
	float expansionVelocity = 0.0f;
	bool continuousBirth = false;
};

void Require(bool condition, const std::string& message)
{
	if (condition) return;
	std::cerr << "FAILED: " << message << '\n';
	std::exit(1);
}

bool Near(float a, float b, float epsilon = 2.0e-5f)
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

uint32_t ProductionShapeSeed(uint64_t eventSerial)
{
	uint32_t value = static_cast<uint32_t>(eventSerial) ^
		static_cast<uint32_t>(eventSerial >> 32u) ^ 0x9e3779b9u;
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

NRISmokeTransientGroupShapeInput FireInput(const FireTuning& tuning,
	uint32_t sourceId, uint64_t eventSerial, double authoredSeconds)
{
	NRISmokeTransientGroupShapeInput input = {};
	// The authored -32 world-Z actor offset becomes +32 in path-tracing Y-up space.
	input.position[1] = 32.0f;
	input.initialRadius = InitialRadius;
	input.initialDensity = InitialDensity;
	input.opticalAmount = RuleCount * tuning.opticalScale;
	input.expansionVelocity = tuning.expansionVelocity;
	input.densityHalfLife = DensityHalfLife;
	input.lobeLifetimeSeconds = tuning.lifetime;
	input.groupLifetimeSeconds = tuning.lifetime;
	input.densityAttackSeconds = tuning.densityAttack;
	input.densitySustainSeconds = tuning.sustain;
	input.densityReleaseSeconds = tuning.release;
	input.radiusExponent = RadiusExponent;
	input.intrinsicEmission = IntrinsicEmission;
	input.emissionHalfLife = tuning.emissionHalfLife;
	input.clusterSpread = tuning.spread;
	input.lobeRadiusMinScale = tuning.lobeRadiusMin;
	input.lobeRadiusMaxScale = tuning.lobeRadiusMax;
	input.riseVelocity = tuning.riseVelocity;
	input.curlVelocity = CurlVelocity;
	input.lobeDelayStepSeconds = tuning.continuousBirth
		? tuning.cadence / static_cast<float>(FireLobes) : 0.0f;
	input.corePlateau = CorePlateau;
	input.edgeErosion = EdgeErosion;
	input.noiseScale = NoiseScale;
	input.noiseStrength = NoiseStrength;
	input.requestedLobeCount = FireLobes;
	input.styleIndex = 1u;
	input.sourceId = sourceId;
	input.epoch = Epoch;
	input.authoredGameplaySeconds = authoredSeconds;
	input.sourceEventSerial = eventSerial;
	input.deterministicSeed = ProductionShapeSeed(eventSerial);
	input.transientClass = NRISmokeTransientClass::FirePacket;
	input.lightRefresh = NRISmokeTransientLightRefresh::Slow;
	return input;
}

std::array<NRISmokeTransientLobeRequest, FireLobes> BuildFire(
	const FireTuning& tuning, uint32_t sourceId, uint64_t eventSerial,
	double authoredSeconds)
{
	std::array<NRISmokeTransientLobeRequest, FireLobes> lobes = {};
	const auto input = FireInput(tuning, sourceId, eventSerial, authoredSeconds);
	Require(NRIBuildSmokeTransientLobes(input, lobes.data(),
		static_cast<uint32_t>(lobes.size())) == lobes.size(),
		"the production five-lobe fire shape must build without reduction");
	return lobes;
}

float SupportRadius(const NRISmokeTransientLobeRequest& request, float groupAge)
{
	const float localAge = std::max(groupAge - request.lobeDelaySeconds, 0.0f);
	const float normalizedAge = std::clamp(localAge / request.lifetimeSeconds,
		0.0f, 1.0f);
	return request.initialRadius + request.expansionVelocity *
		request.lifetimeSeconds * std::pow(normalizedAge, RadiusExponent);
}

struct EvaluatedGroup
{
	NRISmokeTransientGroupGpu group = {};
	std::vector<NRISmokeTransientLobeGpu> lobes;
};

EvaluatedGroup Evaluate(const FireTuning& tuning, double age,
	uint64_t eventSerial = 1u, uint32_t quality = 2u)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(quality);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, profile.maximumActiveLobes, profile);
	const auto requests = BuildFire(tuning, 0x6a086ee7u, eventSerial, 0.0);
	const auto admission = owner.AdmitBatch(requests.data(),
		static_cast<uint32_t>(requests.size()));
	Require(admission.Accepted(), "the production fire group must be admitted");
	owner.BeginFrame(age, profile.maximumActiveLobes, profile);
	Require(owner.IsLive(admission.handle),
		"the comparison stage must remain inside the authored fire lifetime");
	EvaluatedGroup result = {};
	result.group = owner.GetGpuGroups()[admission.handle.slot];
	for (uint32_t index = 0u; index < result.group.lobeCount; ++index)
		result.lobes.push_back(owner.GetGpuLobes()[result.group.firstLobe + index]);
	return result;
}

void TestHistoricalAndSequentialRequests(const FireTuning& original,
	const FireTuning& sparse, const FireTuning& previousDense,
	const FireTuning& candidate)
{
	const auto originalRequests = BuildFire(original, 1u, 101u, 0.0);
	const auto sparseRequests = BuildFire(sparse, 1u, 101u, 0.0);
	const auto previousRequests = BuildFire(previousDense, 1u, 101u, 0.0);
	const auto requests = BuildFire(candidate, 1u, 101u, 0.0);
	float opticalSum = 0.0f;
	for (uint32_t index = 0u; index < FireLobes; ++index)
	{
		Require(Near(originalRequests[index].lobeDelaySeconds, 0.0f) &&
			Near(sparseRequests[index].lobeDelaySeconds, 0.0f) &&
			Near(previousRequests[index].lobeDelaySeconds, 0.0f),
			"historical fire references must retain simultaneous births");
		Require(Near(originalRequests[index].densityAttackSeconds, 0.08f) &&
			Near(originalRequests[index].emissionHalfLife, 0.18f) &&
			Near(sparseRequests[index].densityAttackSeconds, 0.08f) &&
			Near(previousRequests[index].emissionHalfLife, 0.18f),
			"historical references must retain their old attack and cooling constants");
		Require(Near(requests[index].opticalWeight,
			originalRequests[index].opticalWeight * 1.25f) &&
			Near(requests[index].opticalWeight,
			sparseRequests[index].opticalWeight * 5.0f) &&
			Near(requests[index].opticalWeight,
			previousRequests[index].opticalWeight * 2.5f),
			"the production request must preserve the deliberate optical retune ratios");
		const float expectedDelay = candidate.cadence *
			static_cast<float>(index) / static_cast<float>(FireLobes);
		Require(Near(requests[index].lobeDelaySeconds, expectedDelay) &&
			Near(requests[index].lifetimeSeconds, candidate.lifetime - expectedDelay),
			"production lobes must be born sequentially and end at the group lifetime");
		Require(Near(requests[index].position[1], 32.0f),
			"continuous births must remove the old pre-stacked vertical offset");
		Require(Near(requests[index].densityAttackSeconds, candidate.densityAttack) &&
			Near(requests[index].emissionHalfLife, candidate.emissionHalfLife),
			"production requests must carry the new gradual attack and cooling values");
		opticalSum += requests[index].opticalWeight;
	}
	Require(Near(opticalSum, RuleCount * candidate.opticalScale),
		"sequential birth must preserve total optical amount");

	for (uint32_t capacity : { 4u, 2u })
	{
		std::array<NRISmokeTransientLobeRequest, FireLobes> limited = {};
		const auto input = FireInput(candidate, 3u, 103u, 0.0);
		const uint32_t count = NRIBuildSmokeTransientLobes(input, limited.data(), capacity);
		Require(count == capacity, "builder output capacity must reduce spatial complexity");
		float limitedOptical = 0.0f;
		for (uint32_t index = 0u; index < count; ++index)
		{
			const float expectedDelay = candidate.cadence *
				static_cast<float>(index) / static_cast<float>(count);
			Require(Near(limited[index].lobeDelaySeconds, expectedDelay) &&
				Near(limited[index].lifetimeSeconds, candidate.lifetime - expectedDelay),
				"builder reduction must re-space births while preserving the common endpoint");
			limitedOptical += limited[index].opticalWeight;
		}
		Require(Near(limitedOptical, RuleCount * candidate.opticalScale),
			"builder reduction must preserve optical amount");
	}
	std::array<NRISmokeTransientLobeRequest, FireLobes> zeroSpan = {};
	const auto zeroSpanInput = FireInput(previousDense, 5u, 105u, 0.0);
	Require(NRIBuildSmokeTransientLobes(zeroSpanInput, zeroSpan.data(), 4u) == 4u,
		"zero-span fire must retain generic builder reduction");
	for (uint32_t index = 0u; index < 4u; ++index)
		Require(Near(zeroSpan[index].lobeDelaySeconds, 0.0f) &&
			Near(zeroSpan[index].lifetimeSeconds, previousDense.lifetime),
			"zero-span fire reduction must not invent delayed births");

	auto irregular = requests;
	const float irregularDelays[FireLobes] = { 0.0f, 0.05f, 0.20f, 0.35f, 0.40f };
	for (uint32_t index = 0u; index < FireLobes; ++index)
		irregular[index].lobeDelaySeconds = irregularDelays[index];
	auto low = NRISmokeTransientClouds::ProfileForQuality(
		static_cast<uint32_t>(NRISmokeTransientQuality::Low));
	NRISmokeTransientClouds irregularOwner;
	irregularOwner.Reset(Epoch);
	irregularOwner.BeginFrame(0.0, low.maximumActiveLobes, low);
	const auto irregularAdmission = irregularOwner.AdmitBatch(irregular.data(), FireLobes);
	Require(irregularAdmission.Accepted() && irregularAdmission.admittedLobes == 4u,
		"irregular delayed fire must retain generic owner reduction");
	irregularOwner.BeginFrame(1.0, low.maximumActiveLobes, low);
	const auto& irregularGroup =
		irregularOwner.GetGpuGroups()[irregularAdmission.handle.slot];
	const auto& irregularLobes = irregularOwner.GetGpuLobes();
	const float expectedIrregular[4] = { 0.0f, 0.05f, 0.20f, 0.35f };
	for (uint32_t index = 0u; index < 4u; ++index)
	{
		const auto& lobe = irregularLobes[irregularGroup.firstLobe + index];
		const float inferredDelay = 1.0f - (lobe.position[1] - 32.0f) /
			candidate.riseVelocity;
		Require(Near(inferredDelay, expectedIrregular[index], 5.0e-4f),
			"irregular delayed fire must retain midpoint-bucket birth times");
		const float expectedWeight = requests[index].opticalWeight *
			(index == 3u ? 2.0f : 1.0f);
		Require(Near(lobe.densityScale, InitialDensity * expectedWeight, 5.0e-4f),
			"irregular delayed fire must retain generic bucket optical aggregation");
	}
	auto invalid = FireInput(candidate, 4u, 104u, 0.0);
	invalid.lobeDelayStepSeconds = (candidate.lifetime - candidate.densityAttack) /
		static_cast<float>(FireLobes - 1u);
	std::array<NRISmokeTransientLobeRequest, FireLobes> invalidOutput = {};
	Require(NRIBuildSmokeTransientLobes(invalid, invalidOutput.data(), FireLobes) == 0u,
		"a delayed birth that cannot finish attack before group retirement must be rejected");
	std::cout << "birth_delays=0,.1,.2,.3,.4 builder_reductions=4,2 optical=" <<
		opticalSum << '\n';
}

void TestGradualBirthGrowthCooling(const FireTuning& candidate)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, profile.maximumActiveLobes, profile);
	const auto requests = BuildFire(candidate, 0x200u, 201u, 0.0);
	const auto admission = owner.AdmitBatch(requests.data(), FireLobes);
	Require(admission.Accepted(), "the gradual-birth fixture must be admitted");
	for (uint32_t stage = 0u; stage < FireLobes; ++stage)
	{
		const float age = 0.05f + 0.1f * static_cast<float>(stage);
		owner.BeginFrame(age, profile.maximumActiveLobes, profile);
		Require(owner.GetSnapshot().visibleLobes == stage + 1u,
			"one additional lobe must appear at each sequential birth stage");
	}
	const float age = 0.45f;
	const auto& group = owner.GetGpuGroups()[admission.handle.slot];
	const auto& lobes = owner.GetGpuLobes();
	Require(group.lobeCount == FireLobes, "all sequential lobes must be visible after 0.45 seconds");
	for (uint32_t index = 0u; index < FireLobes; ++index)
	{
		const auto& lobe = lobes[group.firstLobe + index];
		const float localAge = age - requests[index].lobeDelaySeconds;
		Require(Near(lobe.position[1], 32.0f + candidate.riseVelocity * localAge,
			5.0e-4f) && Near(lobe.radius, SupportRadius(requests[index], age), 5.0e-4f),
			"each born lobe must grow and rise from its own local age");
		const float expectedEmission = IntrinsicEmission *
			std::exp2(-localAge / candidate.emissionHalfLife);
		Require(Near(lobe.emissionScale, expectedEmission, 5.0e-5f),
			"each lobe must cool from its own birth time");
		if (index > 0u)
			Require(lobes[group.firstLobe + index - 1u].emissionScale < lobe.emissionScale,
				"older lobes must be cooler than newly born lobes");
	}
	const auto& newest = lobes[group.firstLobe + FireLobes - 1u];
	Require(newest.position[1] - newest.radius <= 32.0f,
		"the newest growing lobe must retain sphere support at the flame base");
	std::cout << "gradual_visible=1,2,3,4,5 newest_base_margin=" <<
		32.0f - (newest.position[1] - newest.radius) << '\n';
}

void TestLowReductionAndLightMaturity(const FireTuning& candidate)
{
	auto low = NRISmokeTransientClouds::ProfileForQuality(
		static_cast<uint32_t>(NRISmokeTransientQuality::Low));
	NRISmokeTransientClouds lowOwner;
	lowOwner.Reset(Epoch);
	lowOwner.BeginFrame(0.0, low.maximumActiveLobes, low);
	const auto requests = BuildFire(candidate, 0x300u, 301u, 0.0);
	const auto admission = lowOwner.AdmitBatch(requests.data(), FireLobes);
	Require(admission.Accepted() && admission.admittedLobes == 4u,
		"Low must reduce the five-birth packet to four lobes");
	lowOwner.BeginFrame(1.0, low.maximumActiveLobes, low);
	const auto& group = lowOwner.GetGpuGroups()[admission.handle.slot];
	const auto& lobes = lowOwner.GetGpuLobes();
	const float expectedDelays[4] = { 0.0f, 0.125f, 0.25f, 0.375f };
	float densitySum = 0.0f;
	for (uint32_t index = 0u; index < group.lobeCount; ++index)
	{
		const auto& lobe = lobes[group.firstLobe + index];
		const float inferredDelay = 1.0f -
			(lobe.position[1] - 32.0f) /
			candidate.riseVelocity;
		Require(Near(inferredDelay, expectedDelays[index], 5.0e-4f),
			"Low owner reduction must evenly re-space births over the packet cadence");
		Require(Near(lobe.densityScale, InitialDensity * RuleCount *
			candidate.opticalScale / 4.0f, 5.0e-4f),
			"Low continuous-birth reduction must give every retained birth equal optical mass");
		densitySum += lobe.densityScale;
	}
	Require(Near(densitySum, InitialDensity * RuleCount * candidate.opticalScale,
		5.0e-4f), "Low owner reduction must preserve total sustained optical amount");

	auto medium = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds lightOwner;
	lightOwner.Reset(Epoch);
	lightOwner.BeginFrame(0.0, medium.maximumActiveLobes, medium);
	const auto lightAdmission = lightOwner.AdmitBatch(requests.data(), FireLobes);
	Require(lightAdmission.Accepted(), "the light-maturity fixture must be admitted");
	lightOwner.BeginFrame(0.2, medium.maximumActiveLobes, medium);
	Require(lightOwner.GetSnapshot().fullLightAllowedGroups == 0u &&
		lightOwner.GetSnapshot().fallbackLightGroups == 1u,
		"a partially born fire packet must remain on coherent fallback lighting");
	lightOwner.BeginFrame(0.6, medium.maximumActiveLobes, medium);
	const auto& snapshot = lightOwner.GetSnapshot();
	Require(snapshot.fullLightFreshRequestedThisFrame == 1u &&
		snapshot.fullLightFreshScheduledThisFrame == 1u &&
		snapshot.fullLightAllowedGroups == 1u && snapshot.fallbackLightGroups == 0u &&
		snapshot.lightAnchorsScheduledThisFrame == medium.anchorsPerGroup &&
		snapshot.lightSamplesScheduledThisFrame == medium.anchorsPerGroup *
			medium.samplesPerAnchor,
		"the complete mature packet must receive exactly one budgeted full-light build");
	std::cout << "low_delays=0,.125,.25,.375 low_density=" << densitySum <<
		" maturity=fallback@.2/full@.6\n";
}

struct ContinuityMetrics
{
	float earlyOuter = -std::numeric_limits<float>::max();
	float developedCore = -std::numeric_limits<float>::max();
	float baseMargin = -std::numeric_limits<float>::max();
};

ContinuityMetrics EvaluatePacketBoundary(const FireTuning& candidate,
	uint32_t quality, uint64_t serial)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(quality);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, profile.maximumActiveLobes, profile);
	const auto older = BuildFire(candidate, 0x400u, serial, 0.0);
	const auto olderAdmission = owner.AdmitBatch(older.data(), FireLobes);
	owner.BeginFrame(candidate.cadence, profile.maximumActiveLobes, profile);
	const auto younger = BuildFire(candidate, 0x400u, serial + 1u, candidate.cadence);
	const auto youngerAdmission = owner.AdmitBatch(younger.data(), FireLobes);
	Require(olderAdmission.Accepted() && youngerAdmission.Accepted(),
		"adjacent production packets must be admitted");

	ContinuityMetrics result = {};
	owner.BeginFrame(candidate.cadence + 0.05f,
		profile.maximumActiveLobes, profile);
	auto groups = owner.GetGpuGroups();
	auto lobes = owner.GetGpuLobes();
	const auto& olderEarly = groups[olderAdmission.handle.slot];
	const auto& youngerEarly = groups[youngerAdmission.handle.slot];
	Require(youngerEarly.lobeCount == 1u,
		"the next packet must begin with one gradual birth");
	const auto& baseLobe = lobes[youngerEarly.firstLobe];
	result.baseMargin = 32.0f - (baseLobe.position[1] - baseLobe.radius);
	for (uint32_t a = 0u; a < olderEarly.lobeCount; ++a)
		for (uint32_t b = 0u; b < youngerEarly.lobeCount; ++b)
		{
			const auto& lhs = lobes[olderEarly.firstLobe + a];
			const auto& rhs = lobes[youngerEarly.firstLobe + b];
			result.earlyOuter = std::max(result.earlyOuter,
				lhs.radius + rhs.radius - Distance3(lhs.position, rhs.position));
		}

	owner.BeginFrame(candidate.cadence + 0.75f,
		profile.maximumActiveLobes, profile);
	groups = owner.GetGpuGroups();
	lobes = owner.GetGpuLobes();
	const auto& olderDeveloped = groups[olderAdmission.handle.slot];
	const auto& youngerDeveloped = groups[youngerAdmission.handle.slot];
	for (uint32_t a = 0u; a < olderDeveloped.lobeCount; ++a)
		for (uint32_t b = 0u; b < youngerDeveloped.lobeCount; ++b)
		{
			const auto& lhs = lobes[olderDeveloped.firstLobe + a];
			const auto& rhs = lobes[youngerDeveloped.firstLobe + b];
			result.developedCore = std::max(result.developedCore,
				CorePlateau * (lhs.radius + rhs.radius) -
				Distance3(lhs.position, rhs.position));
		}
	return result;
}

void TestRepresentativePacketContinuity(const FireTuning& candidate)
{
	for (uint32_t quality : { 2u, 3u })
	{
		float minimumOuter = std::numeric_limits<float>::max();
		float minimumCore = std::numeric_limits<float>::max();
		float minimumBase = std::numeric_limits<float>::max();
		for (uint64_t serial = 1u; serial <= 32u; ++serial)
		{
			const auto metrics = EvaluatePacketBoundary(candidate, quality, serial);
			minimumOuter = std::min(minimumOuter, metrics.earlyOuter);
			minimumCore = std::min(minimumCore, metrics.developedCore);
			minimumBase = std::min(minimumBase, metrics.baseMargin);
		}
		Require(minimumOuter >= 0.0f,
			"all representative packet boundaries must overlap physical support early");
		Require(minimumCore >= 0.0f,
			"all representative packet boundaries must overlap developed plateau cores");
		Require(minimumBase >= 0.0f,
			"every representative next packet must retain support at the flame base");
		std::cout << (quality == 2u ? "medium" : "low") <<
			"_boundary_outer=" << minimumOuter << " core=" << minimumCore <<
			" base=" << minimumBase << '\n';
	}
}

void TestLateVisibleHeight(const FireTuning& baseline,
	const FireTuning& candidate)
{
	constexpr double Tick = 1.0 / 120.0;
	const double baselineVisibleEnd = std::min(baseline.lifetime,
		baseline.sustain + baseline.release);
	const double candidateVisibleEnd = std::min(candidate.lifetime,
		candidate.sustain + candidate.release);
	const auto oldGroup = Evaluate(baseline, baselineVisibleEnd - Tick, 202u);
	const auto newGroup = Evaluate(candidate, candidateVisibleEnd - Tick, 202u);
	const float oldFromEmitter = oldGroup.group.boundsMax[1] - 32.0f;
	const float newFromEmitter = newGroup.group.boundsMax[1] - 32.0f;
	const float emitterRatio = newFromEmitter / oldFromEmitter;
	const float planeRatio = newGroup.group.boundsMax[1] /
		oldGroup.group.boundsMax[1];
	std::cout << "eventual_height_ratio_emitter=" << emitterRatio <<
		" flame_plane=" << planeRatio << '\n';
	Require(emitterRatio >= 4.0f && emitterRatio <= 6.0f &&
		planeRatio >= 4.0f && planeRatio <= 6.0f,
		"the sequential plume must retain its eventual four-to-six-times height reach");
}

void TestSmoothFadeAndNativeExpiration(const FireTuning& candidate)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, profile.maximumActiveLobes, profile);
	const auto requests = BuildFire(candidate, 0x500u, 501u, 0.0);
	const auto admission = owner.AdmitBatch(requests.data(), FireLobes);
	Require(admission.Accepted(), "the fade fixture must admit its fire packet");
	constexpr double Tick = 1.0 / 120.0;
	const double latestReleaseStart = requests.back().lobeDelaySeconds +
		candidate.sustain;
	const float initialOpticalDensity = InitialDensity * RuleCount *
		candidate.opticalScale;
	owner.BeginFrame(latestReleaseStart - Tick, profile.maximumActiveLobes, profile);
	float previousDensity = 0.0f;
	for (const auto& lobe : owner.GetGpuLobes()) previousDensity += lobe.densityScale;
	float maximumDensitySlope = 0.0f;
	for (const auto& request : requests)
	{
		const float releaseDuration = std::min(request.densityReleaseSeconds,
			request.lifetimeSeconds - request.densitySustainSeconds);
		maximumDensitySlope += request.initialDensity * request.opticalWeight *
			1.5f / releaseDuration;
	}
	float lastVisibleDensity = previousDensity;
	float lastOpticalDepthBound = 0.0f;
	const uint32_t sampleCount = static_cast<uint32_t>(std::floor(
		(candidate.lifetime - latestReleaseStart) / Tick + 1.0e-4));
	for (uint32_t sample = 0u; sample < sampleCount; ++sample)
	{
		const double age = latestReleaseStart + Tick * static_cast<double>(sample);
		owner.BeginFrame(age, profile.maximumActiveLobes, profile);
		Require(owner.IsLive(admission.handle),
			"the packet must remain live throughout its authored release");
		float density = 0.0f;
		lastOpticalDepthBound = 0.0f;
		for (const auto& lobe : owner.GetGpuLobes())
		{
			density += lobe.densityScale;
			lastOpticalDepthBound += 2.0f * lobe.radius * lobe.densityScale *
				StyleDensity * Extinction;
		}
		Require(density <= previousDensity + 2.0e-5f,
			"120 Hz sequential release density must be monotonic");
		Require(previousDensity - density <= maximumDensitySlope *
			static_cast<float>(Tick) + 2.0e-5f,
			"release must obey the smooth curve slope, not just a monotonic staircase");
		previousDensity = density;
		lastVisibleDensity = density;
	}
	Require(lastVisibleDensity > 0.0f &&
		lastVisibleDensity / initialOpticalDensity < 5.0e-5f,
		"all staggered lobes must be optically tiny immediately before retirement");
	const float lastOpacityBound = 1.0f - std::exp(-lastOpticalDepthBound);
	Require(lastOpacityBound < 0.001f,
		"the conservative last-slice packet opacity bound must remain below 0.1 percent");
	owner.BeginFrame(candidate.lifetime, profile.maximumActiveLobes, profile);
	Require(!owner.IsLive(admission.handle) && owner.GetSnapshot().activeGroups == 0u &&
		owner.GetSnapshot().visibleGroups == 0u && owner.GetGpuLobes().empty() &&
		owner.GetSnapshot().groupsExpired == 1u &&
		owner.GetSnapshot().lobesExpired == FireLobes,
		"group retirement must remove all sequential lobes at the common endpoint");
	std::cout << "fade_last_relative_density=" <<
		lastVisibleDensity / initialOpticalDensity <<
		" opacity_bound=" << lastOpacityBound << '\n';
}

void TestCapacityRejectionDoesNotEvict(const FireTuning& candidate)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	profile.maximumActiveGroups = 1u;
	profile.maximumActiveLobes = FireLobes;
	profile.maximumLobesPerGroup = FireLobes;
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.45, FireLobes, profile);
	const auto first = BuildFire(candidate, 0x600u, 601u, 0.0);
	const auto accepted = owner.AdmitBatch(first.data(), FireLobes);
	Require(accepted.Accepted(), "the capacity fixture must admit its first packet");
	const auto groupsBefore = owner.GetGpuGroups();
	const auto lobesBefore = owner.GetGpuLobes();
	const auto second = BuildFire(candidate, 0x601u, 602u, 0.45);
	const auto rejected = owner.AdmitBatch(second.data(), FireLobes);
	Require(!rejected.Accepted() &&
		rejected.dropReason == NRISmokeTransientDropReason::GroupCapacity,
		"a full custom profile must reject the new group for group capacity");
	Require(owner.IsLive(accepted.handle) && owner.GetSnapshot().activeGroups == 1u &&
		owner.GetSnapshot().activeLobes == FireLobes &&
		owner.GetSnapshot().droppedGroupCapacity == FireLobes,
		"capacity rejection must retain the accepted group and account the rejected lobes");
	const auto& groupsAfter = owner.GetGpuGroups();
	const auto& lobesAfter = owner.GetGpuLobes();
	Require(groupsAfter[accepted.handle.slot].generation ==
		groupsBefore[accepted.handle.slot].generation &&
		lobesAfter.size() == lobesBefore.size(),
		"capacity rejection must preserve the existing handle and GPU record count");
	for (uint32_t index = 0u; index < lobesAfter.size(); ++index)
	{
		for (uint32_t axis = 0u; axis < 3u; ++axis)
			Require(Near(lobesAfter[index].position[axis], lobesBefore[index].position[axis]),
				"capacity rejection must preserve existing lobe positions");
		Require(Near(lobesAfter[index].densityScale, lobesBefore[index].densityScale),
			"capacity rejection must preserve existing lobe density");
	}
	std::cout << "capacity_reject_preserved=" << lobesAfter.size() <<
		" dropped=" << owner.GetSnapshot().droppedGroupCapacity << '\n';
}

void RequireNoDrops(const NRISmokeTransientSnapshot& snapshot)
{
	Require(snapshot.groupsRejected == 0u && snapshot.droppedNotPrepared == 0u &&
		snapshot.droppedDisabled == 0u && snapshot.droppedInvalidRequest == 0u &&
		snapshot.droppedStaleEpoch == 0u && snapshot.droppedExpiredOnArrival == 0u &&
		snapshot.droppedStaleOnArrival == 0u && snapshot.droppedGroupCapacity == 0u &&
		snapshot.droppedLobeCapacity == 0u,
		"the two-fire steady-state fixture must not drop groups or lobes");
}

void TestTwoSourceCapacity(const FireTuning& candidate, uint32_t quality)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(quality);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	float accumulated = 0.0f;
	const uint32_t steps = static_cast<uint32_t>(std::floor(40.0f / candidate.cadence));
	for (uint32_t ordinal = 0u; ordinal <= steps; ++ordinal)
	{
		const double boundary = static_cast<double>(accumulated);
		if (ordinal > 0u)
		{
			owner.BeginFrame(std::nextafter(boundary,
				-std::numeric_limits<double>::infinity()),
				profile.maximumActiveLobes, profile);
			RequireNoDrops(owner.GetSnapshot());
		}
		owner.BeginFrame(boundary, profile.maximumActiveLobes, profile);
		for (uint32_t source = 0u; source < 2u; ++source)
		{
			const uint64_t serial = static_cast<uint64_t>(ordinal) * 2u + source + 1u;
			const auto requests = BuildFire(candidate, 0x700u + source, serial, boundary);
			Require(owner.AdmitBatch(requests.data(), FireLobes).Accepted(),
				"every two-source cadence packet must be admitted through 40 seconds");
		}
		RequireNoDrops(owner.GetSnapshot());
		accumulated += candidate.cadence;
	}
	const uint32_t expectedGroups = 2u * static_cast<uint32_t>(std::ceil(
		candidate.lifetime / candidate.cadence - 1.0e-5f));
	const uint32_t lobesPerGroup = std::min(FireLobes, profile.maximumLobesPerGroup);
	const auto& snapshot = owner.GetSnapshot();
	Require(snapshot.activeGroups == expectedGroups &&
		snapshot.activeLobes == expectedGroups * lobesPerGroup,
		"steady population must match lifetime, cadence, and profile reduction");
	if (quality == static_cast<uint32_t>(NRISmokeTransientQuality::Low))
		Require(snapshot.maximumActiveGroups - snapshot.activeGroups >= 2u &&
			snapshot.maximumActiveLobes - snapshot.activeLobes >= 8u,
			"Low must preserve two-group/eight-lobe finite sharing headroom");
	std::cout << (quality == 2u ? "medium" : "low") << "_steady=" <<
		snapshot.activeGroups << "g/" << snapshot.activeLobes << "l headroom=" <<
		(snapshot.maximumActiveGroups - snapshot.activeGroups) << "g/" <<
		(snapshot.maximumActiveLobes - snapshot.activeLobes) << "l\n";
}

void TestPulseFloor(const FireTuning& sparse, const FireTuning& candidate)
{
	constexpr uint32_t Period = 12u;
	constexpr float Phase = 0.7916667f;
	float sparseMinimum = std::numeric_limits<float>::max();
	float candidateMinimum = std::numeric_limits<float>::max();
	double candidateSum = 0.0;
	for (uint64_t ordinal = 1u; ordinal <= Period; ++ordinal)
	{
		sparseMinimum = std::min(sparseMinimum, NRIEvaluateSmokeSourceEnvelope(
			{ sparse.pulseAmount, Period, Phase }, ordinal));
		const float weight = NRIEvaluateSmokeSourceEnvelope(
			{ candidate.pulseAmount, Period, Phase }, ordinal);
		candidateMinimum = std::min(candidateMinimum, weight);
		candidateSum += weight;
	}
	Require(candidateMinimum >= 1.0f - candidate.pulseAmount - 1.0e-5f &&
		candidateMinimum > sparseMinimum + 0.5f &&
		std::abs(candidateSum - static_cast<double>(Period)) < 1.0e-5,
		"production source pulsing must retain its dense floor and unit mean");
	std::cout << "pulse_min=" << candidateMinimum << " sparse=" << sparseMinimum <<
		" period_sum=" << candidateSum << '\n';
}
}

int main(int argc, char** argv)
{
	Require(argc == 14,
		"usage: test optical lifetime rise sustain release spread cadence radius_min radius_max pulse attack emission_half expansion");
	FireTuning candidate = {};
	candidate.opticalScale = std::stof(argv[1]);
	candidate.lifetime = std::stof(argv[2]);
	candidate.riseVelocity = std::stof(argv[3]);
	candidate.sustain = std::stof(argv[4]);
	candidate.release = std::stof(argv[5]);
	candidate.spread = std::stof(argv[6]);
	candidate.cadence = std::stof(argv[7]);
	candidate.lobeRadiusMin = std::stof(argv[8]);
	candidate.lobeRadiusMax = std::stof(argv[9]);
	candidate.pulseAmount = std::stof(argv[10]);
	candidate.densityAttack = std::stof(argv[11]);
	candidate.emissionHalfLife = std::stof(argv[12]);
	candidate.expansionVelocity = std::stof(argv[13]);
	candidate.continuousBirth = true;
	const FireTuning original = { 0.20f, 3.0f, 32.0f, 1.5f, 1.42f, 0.45f,
		0.28f, 0.40f, 0.70f, 0.90f, 0.08f, 0.18f, 10.0f, false };
	const FireTuning sparse = { 0.05f, 5.5f, 120.0f, 2.75f, 2.75f, 1.30f,
		0.50f, 0.40f, 0.70f, 0.90f, 0.08f, 0.18f, 10.0f, false };
	const FireTuning previousDense = { 0.10f, 5.5f, 120.0f, 2.75f, 2.75f, 1.30f,
		0.50f, 0.70f, 1.00f, 0.15f, 0.08f, 0.18f, 10.0f, false };
	Require(Near(candidate.lifetime, 5.5f) && Near(candidate.riseVelocity, 120.0f) &&
		Near(candidate.cadence, 0.5f) && Near(candidate.cadence /
			static_cast<float>(FireLobes), 0.1f),
		"production sequential fire must preserve life/rise/cadence and 0.1-second births");
	Require(candidate.lifetime > candidate.sustain && candidate.release > 0.0f &&
		candidate.sustain + candidate.release <= candidate.lifetime + 1.0e-5f &&
		candidate.lobeRadiusMin > 0.0f &&
		candidate.lobeRadiusMax >= candidate.lobeRadiusMin &&
		candidate.densityAttack > 0.0f && candidate.emissionHalfLife > 0.0f &&
		candidate.expansionVelocity >= 0.0f,
		"production sequential fire parameters must be internally valid");

	TestHistoricalAndSequentialRequests(original, sparse, previousDense, candidate);
	TestGradualBirthGrowthCooling(candidate);
	TestLowReductionAndLightMaturity(candidate);
	TestRepresentativePacketContinuity(candidate);
	TestLateVisibleHeight(original, candidate);
	TestPulseFloor(sparse, candidate);
	TestSmoothFadeAndNativeExpiration(candidate);
	TestCapacityRejectionDoesNotEvict(candidate);
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Medium));
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Low));
	std::cout << "Smoke transient sequential-fire tuning tests passed.\n";
	return 0;
}
