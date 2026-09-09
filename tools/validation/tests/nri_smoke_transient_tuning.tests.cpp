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
constexpr float ExpansionVelocity = 10.0f;
constexpr float DensityHalfLife = 6.0f;
constexpr float DensityAttack = 0.08f;
constexpr float RadiusExponent = 0.90f;
constexpr float IntrinsicEmission = 0.5f;
constexpr float EmissionHalfLife = 0.18f;
constexpr float LobeRadiusMin = 0.40f;
constexpr float LobeRadiusMax = 0.70f;
constexpr float CurlVelocity = 4.0f;
constexpr float CorePlateau = 0.60f;
constexpr float EdgeErosion = 0.16f;
constexpr float NoiseScale = 0.035f;
constexpr float NoiseStrength = 0.20f;
constexpr float RuleCount = 9.0f;

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
};

struct EvaluatedGroup
{
	NRISmokeTransientGroupGpu group = {};
	std::vector<NRISmokeTransientLobeGpu> lobes;
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

// Mirrors the private seed transform used immediately before the real lobe builder.
// The PowerShell runner guards the production call site so this cannot silently drift.
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
	input.expansionVelocity = ExpansionVelocity;
	input.densityHalfLife = DensityHalfLife;
	input.lobeLifetimeSeconds = tuning.lifetime;
	input.groupLifetimeSeconds = tuning.lifetime;
	input.densityAttackSeconds = DensityAttack;
	input.densitySustainSeconds = tuning.sustain;
	input.densityReleaseSeconds = tuning.release;
	input.radiusExponent = RadiusExponent;
	input.intrinsicEmission = IntrinsicEmission;
	input.emissionHalfLife = EmissionHalfLife;
	input.clusterSpread = tuning.spread;
	input.lobeRadiusMinScale = tuning.lobeRadiusMin;
	input.lobeRadiusMaxScale = tuning.lobeRadiusMax;
	input.riseVelocity = tuning.riseVelocity;
	input.curlVelocity = CurlVelocity;
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

EvaluatedGroup Evaluate(const FireTuning& tuning, double age,
	uint64_t eventSerial = 1u)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto requests = BuildFire(tuning, 0x6a086ee7u, eventSerial, 0.0);
	const auto admission = owner.AdmitBatch(requests.data(),
		static_cast<uint32_t>(requests.size()));
	Require(admission.Accepted(), "the production fire group must be admitted");
	owner.BeginFrame(age, NRISmokeTransientClouds::FixedLobeCapacity, profile);
	Require(owner.IsLive(admission.handle),
		"the comparison stage must remain inside the authored fire lifetime");
	Require(admission.handle.slot < owner.GetGpuGroups().size(),
		"the admitted fire handle must index the GPU group array");
	EvaluatedGroup result = {};
	result.group = owner.GetGpuGroups()[admission.handle.slot];
	Require(result.group.lobeCount == FireLobes,
		"all five fire lobes must be visible at the comparison stage");
	for (uint32_t index = 0u; index < result.group.lobeCount; ++index)
		result.lobes.push_back(owner.GetGpuLobes()[result.group.firstLobe + index]);
	return result;
}

void TestDensityRetuneAndNormalizedEnvelope(const FireTuning& original,
	const FireTuning& sparse, const FireTuning& currentDense,
	const FireTuning& candidate)
{
	const auto oldRequests = BuildFire(original, 1u, 101u, 0.0);
	const auto sparseRequests = BuildFire(sparse, 1u, 101u, 0.0);
	const auto currentDenseRequests = BuildFire(currentDense, 1u, 101u, 0.0);
	const auto newRequests = BuildFire(candidate, 1u, 101u, 0.0);
	for (uint32_t index = 0u; index < FireLobes; ++index)
	{
		Require(Near(newRequests[index].opticalWeight,
			oldRequests[index].opticalWeight * 1.25f),
			"the fire retune must carry 1.25 times the original short-fire optical weight");
		Require(Near(newRequests[index].opticalWeight,
			sparseRequests[index].opticalWeight * 5.0f),
			"the fire retune must carry five times the tall sparse preset's optical weight");
		Require(Near(newRequests[index].opticalWeight,
			currentDenseRequests[index].opticalWeight * 2.5f),
			"the fire retune must carry 2.5 times the preceding dense preset's optical weight");
	}

	for (float releasePhase : { 0.0f, 0.25f, 0.5f, 0.75f, 0.99f })
	{
		const double oldAge = original.sustain + original.release * releasePhase;
		const double sparseAge = sparse.sustain + sparse.release * releasePhase;
		const double currentDenseAge = currentDense.sustain +
			currentDense.release * releasePhase;
		const double newAge = candidate.sustain + candidate.release * releasePhase;
		const auto oldGroup = Evaluate(original, oldAge, 101u);
		const auto sparseGroup = Evaluate(sparse, sparseAge, 101u);
		const auto currentDenseGroup = Evaluate(currentDense, currentDenseAge, 101u);
		const auto newGroup = Evaluate(candidate, newAge, 101u);
		for (uint32_t index = 0u; index < FireLobes; ++index)
		{
			const float oldEnvelope = oldGroup.lobes[index].densityScale /
				(InitialDensity * oldRequests[index].opticalWeight);
			const float newEnvelope = newGroup.lobes[index].densityScale /
				(InitialDensity * newRequests[index].opticalWeight);
			const float sparseEnvelope = sparseGroup.lobes[index].densityScale /
				(InitialDensity * sparseRequests[index].opticalWeight);
			const float currentDenseEnvelope =
				currentDenseGroup.lobes[index].densityScale /
				(InitialDensity * currentDenseRequests[index].opticalWeight);
			Require(Near(oldEnvelope, newEnvelope, 5.0e-4f),
				"original and candidate release envelopes must agree at equal normalized phase");
			Require(Near(sparseEnvelope, newEnvelope, 5.0e-4f),
				"the dense retune must preserve the tall preset's normalized release envelope");
			Require(Near(currentDenseEnvelope, newEnvelope, 5.0e-4f),
				"the longer release must preserve the preceding dense preset's normalized envelope");
			Require(Near(newGroup.lobes[index].densityScale,
				currentDenseGroup.lobes[index].densityScale * 2.5f, 5.0e-4f),
				"equal-phase GPU density must increase 2.5 times over the preceding dense preset");
		}
	}
}

void TestLateVisibleHeight(const FireTuning& baseline,
	const FireTuning& candidate)
{
	float minimumEmitterRatio = std::numeric_limits<float>::max();
	float maximumEmitterRatio = 0.0f;
	float minimumPlaneRatio = std::numeric_limits<float>::max();
	float maximumPlaneRatio = 0.0f;
	// The longer release reaches the requested height late in its visible life. Do
	// not pretend that equal normalized release phase also means equal plume age.
	for (float releasePhase : { 0.75f, 0.95f })
	{
		const auto oldGroup = Evaluate(baseline,
			baseline.sustain + baseline.release * releasePhase, 202u);
		const auto newGroup = Evaluate(candidate,
			candidate.sustain + candidate.release * releasePhase, 202u);
		const float oldFromEmitter = oldGroup.group.boundsMax[1] - 32.0f;
		const float newFromEmitter = newGroup.group.boundsMax[1] - 32.0f;
		Require(oldFromEmitter > 0.0f,
			"baseline upper support must be positive in the late visible stage");
		const float emitterRatio = newFromEmitter / oldFromEmitter;
		const float planeRatio = newGroup.group.boundsMax[1] /
			oldGroup.group.boundsMax[1];
		minimumEmitterRatio = std::min(minimumEmitterRatio, emitterRatio);
		maximumEmitterRatio = std::max(maximumEmitterRatio, emitterRatio);
		minimumPlaneRatio = std::min(minimumPlaneRatio, planeRatio);
		maximumPlaneRatio = std::max(maximumPlaneRatio, planeRatio);
		Require(emitterRatio >= 4.0f && emitterRatio <= 6.0f,
			"candidate upper support from the emitter must remain four-to-six times baseline");
		Require(planeRatio >= 4.0f && planeRatio <= 6.0f,
			"candidate upper support from the flame plane must remain four-to-six times baseline");
	}
	std::cout << "height_ratio_emitter=" << minimumEmitterRatio << ".." <<
		maximumEmitterRatio << " height_ratio_flame_plane=" << minimumPlaneRatio <<
		".." << maximumPlaneRatio << '\n';
}

void TestSmoothFadeAndNativeExpiration(const FireTuning& candidate)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto requests = BuildFire(candidate, 0x6a086ee7u, 303u, 0.0);
	const auto admission = owner.AdmitBatch(requests.data(),
		static_cast<uint32_t>(requests.size()));
	Require(admission.Accepted(), "the fade fixture must admit its fire packet");

	constexpr double Tick = 1.0 / 120.0;
	const float initialOpticalDensity = InitialDensity * RuleCount *
		candidate.opticalScale;
	float previousDensity = initialOpticalDensity;
	float lastVisibleDensity = previousDensity;
	float lastOpticalDepthBound = 0.0f;
	for (double age = static_cast<double>(candidate.sustain); age <
		static_cast<double>(candidate.lifetime); age += Tick)
	{
		owner.BeginFrame(age, NRISmokeTransientClouds::FixedLobeCapacity, profile);
		Require(owner.IsLive(admission.handle),
			"the group must remain live throughout the authored release interval");
		float density = 0.0f;
		lastOpticalDepthBound = 0.0f;
		for (const auto& lobe : owner.GetGpuLobes())
		{
			density += lobe.densityScale;
			// Bound every kernel by one and every ray chord by the full diameter.
			// Production style density=3, extinction=.008 are guarded by the runner.
			lastOpticalDepthBound += 2.0f * lobe.radius * lobe.densityScale * 3.0f * 0.008f;
		}
		Require(density <= previousDensity + 2.0e-5f,
			"120 Hz release density must be monotonic");
		Require((previousDensity - density) / initialOpticalDensity <=
			static_cast<float>(1.5 * Tick / candidate.release) + 2.0e-5f,
			"release must respect the smooth curve's maximum slope, not just be monotonic");
		previousDensity = density;
		lastVisibleDensity = density;
	}
	Require(lastVisibleDensity / initialOpticalDensity < 5.0e-5f,
		"the last 120 Hz sample must be optically tiny before native expiration");
	const float lastOpacityBound = 1.0f - std::exp(-lastOpticalDepthBound);
	Require(lastOpacityBound < 0.001f,
		"even a worst-case ray through the last 120 Hz packet must have less than 0.1% opacity");
	owner.BeginFrame(candidate.lifetime,
		NRISmokeTransientClouds::FixedLobeCapacity, profile);
	Require(!owner.IsLive(admission.handle) && owner.GetSnapshot().activeGroups == 0u &&
		owner.GetSnapshot().visibleGroups == 0u && owner.GetGpuLobes().empty() &&
		owner.GetSnapshot().groupsExpired == 1u &&
		owner.GetSnapshot().lobesExpired == FireLobes,
		"native expiration must retire the already-negligible packet exactly at lifetime");
	std::cout << "fade_last_relative_density=" <<
		(lastVisibleDensity / initialOpticalDensity) <<
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
	owner.BeginFrame(0.25, FireLobes, profile);
	const auto first = BuildFire(candidate, 0x101u, 401u, 0.0);
	const auto accepted = owner.AdmitBatch(first.data(),
		static_cast<uint32_t>(first.size()));
	Require(accepted.Accepted(), "the capacity fixture must admit its first packet");
	const auto groupsBefore = owner.GetGpuGroups();
	const auto lobesBefore = owner.GetGpuLobes();
	Require(lobesBefore.size() == FireLobes,
		"the accepted capacity fixture must expose all five lobes");

	const auto second = BuildFire(candidate, 0x102u, 402u, 0.25);
	const auto rejected = owner.AdmitBatch(second.data(),
		static_cast<uint32_t>(second.size()));
	Require(!rejected.Accepted() &&
		rejected.dropReason == NRISmokeTransientDropReason::GroupCapacity,
		"a full custom profile must reject the new group for group capacity");
	Require(owner.IsLive(accepted.handle) && owner.GetSnapshot().activeGroups == 1u &&
		owner.GetSnapshot().activeLobes == FireLobes &&
		owner.GetSnapshot().droppedGroupCapacity == FireLobes,
		"capacity rejection must retain the accepted group and account only the rejected lobes");
	const auto& groupsAfter = owner.GetGpuGroups();
	const auto& lobesAfter = owner.GetGpuLobes();
	Require(groupsAfter.size() == groupsBefore.size() &&
		lobesAfter.size() == lobesBefore.size(),
		"capacity rejection must not alter existing GPU record counts");
	const auto& groupBefore = groupsBefore[accepted.handle.slot];
	const auto& groupAfter = groupsAfter[accepted.handle.slot];
	Require(groupAfter.generation == groupBefore.generation &&
		groupAfter.firstLobe == groupBefore.firstLobe &&
		groupAfter.lobeCount == groupBefore.lobeCount,
		"capacity rejection must preserve the existing group handle mapping");
	for (uint32_t index = 0u; index < FireLobes; ++index)
	{
		for (uint32_t axis = 0u; axis < 3u; ++axis)
			Require(Near(lobesAfter[index].position[axis],
				lobesBefore[index].position[axis]),
				"capacity rejection must preserve existing lobe positions");
		Require(Near(lobesAfter[index].densityScale,
			lobesBefore[index].densityScale),
			"capacity rejection must preserve existing lobe density");
	}
	std::cout << "capacity_reject_preserved=" << lobesAfter.size() <<
		"lobes dropped=" << owner.GetSnapshot().droppedGroupCapacity << '\n';
}

struct BridgeMargins
{
	float outer = -std::numeric_limits<float>::max();
	float halfKernel = -std::numeric_limits<float>::max();
};

BridgeMargins PacketBridgeMargins(const FireTuning& tuning,
	uint64_t olderSerial, float youngerAge)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto older = BuildFire(tuning, 0x6a086ee7u, olderSerial, 0.0);
	const auto olderAdmission = owner.AdmitBatch(older.data(),
		static_cast<uint32_t>(older.size()));
	owner.BeginFrame(tuning.cadence, NRISmokeTransientClouds::FixedLobeCapacity,
		profile);
	const auto younger = BuildFire(tuning, 0x6a086ee7u, olderSerial + 1u,
		tuning.cadence);
	const auto youngerAdmission = owner.AdmitBatch(younger.data(),
		static_cast<uint32_t>(younger.size()));
	Require(olderAdmission.Accepted() && youngerAdmission.Accepted(),
		"adjacent production packets must be admitted");
	owner.BeginFrame(static_cast<double>(tuning.cadence + youngerAge),
		NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto& groups = owner.GetGpuGroups();
	const auto& gpuLobes = owner.GetGpuLobes();
	const auto& olderGroup = groups[olderAdmission.handle.slot];
	const auto& youngerGroup = groups[youngerAdmission.handle.slot];
	BridgeMargins result = {};
	for (uint32_t a = 0u; a < olderGroup.lobeCount; ++a)
		for (uint32_t b = 0u; b < youngerGroup.lobeCount; ++b)
		{
			const auto& oldLobe = gpuLobes[olderGroup.firstLobe + a];
			const auto& newLobe = gpuLobes[youngerGroup.firstLobe + b];
			const float distance = Distance3(oldLobe.position, newLobe.position);
			result.outer = std::max(result.outer,
				oldLobe.radius + newLobe.radius - distance);
			// The un-eroded parabolic sphere shell is (1-q*q)/(1-p*p).
			// At p=0.6, q=0.8 gives 0.5625: a conservative >=half-kernel
			// inner region. This excludes boundary erosion and pixel integration.
			result.halfKernel = std::max(result.halfKernel,
				0.8f * (oldLobe.radius + newLobe.radius) - distance);
		}
	return result;
}

void TestRepresentativePacketBridges(const FireTuning& sparse,
	const FireTuning& candidate)
{
	float earlyMinimumMargin = std::numeric_limits<float>::max();
	float innerMinimumMargin = std::numeric_limits<float>::max();
	uint32_t earlyConnected = 0u;
	uint32_t innerConnected = 0u;
	uint32_t sparseConnected = 0u;
	uint32_t earlyTested = 0u;
	// This is a bounded representative seed set, not a claim over every uint64 seed.
	// Real 3D sphere support is tested at attack completion and shortly thereafter,
	// rather than inferring continuity from group AABBs.
	for (uint64_t serial = 1u; serial <= 32u; ++serial)
		for (float youngerAge : { 0.08f, 0.15f })
		{
			const BridgeMargins denseMargins = PacketBridgeMargins(candidate, serial,
				youngerAge);
			const BridgeMargins sparseMargins = PacketBridgeMargins(sparse, serial,
				youngerAge);
			earlyMinimumMargin = std::min(earlyMinimumMargin, denseMargins.outer);
			innerMinimumMargin = std::min(innerMinimumMargin, denseMargins.halfKernel);
			earlyConnected += denseMargins.outer >= 0.0f ? 1u : 0u;
			innerConnected += denseMargins.halfKernel >= 0.0f ? 1u : 0u;
			sparseConnected += sparseMargins.outer >= 0.0f ? 1u : 0u;
			earlyTested++;
		}
	std::cout << "early_packet_bridges_dense=" << earlyConnected << '/' <<
		earlyTested << " sparse=" << sparseConnected << '/' << earlyTested <<
		" minimum_margin=" << earlyMinimumMargin << " half_kernel=" <<
		innerConnected << '/' << earlyTested << " half_kernel_minimum_margin=" <<
		innerMinimumMargin << '\n';
	Require(earlyConnected == earlyTested,
		"all bounded representative adjacent packets must overlap outer support early");
	Require(innerConnected > sparseConnected,
		"larger dense-fire lobes must improve meaningful inner support over the sparse preset");
	Require(innerConnected == earlyTested,
		"all bounded representative dense-fire pairs must overlap conservative inner support");

	// At a comparable, clearly visible fade stage the packet train must actually
	// connect. This is a sphere-pair test across groups, stronger than overlapping
	// group AABBs and bounded to the stage the height comparison evaluates.
	uint32_t lateConnected = 0u;
	float lateMinimumMargin = std::numeric_limits<float>::max();
	const float lateAge = candidate.sustain + candidate.release * 0.5f;
	for (uint64_t serial = 1u; serial <= 32u; ++serial)
	{
		const BridgeMargins margins = PacketBridgeMargins(candidate, serial, lateAge);
		lateMinimumMargin = std::min(lateMinimumMargin, margins.outer);
		lateConnected += margins.outer >= 0.0f ? 1u : 0u;
	}
	std::cout << "late_packet_bridges=" << lateConnected << "/32 minimum_margin=" <<
		lateMinimumMargin << '\n';
	Require(lateConnected == 32u,
		"adjacent packets must have real 3D support overlap at release midpoint");
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
	Require(candidateMinimum >= 1.0f - candidate.pulseAmount - 1.0e-5f,
		"actual source-envelope samples must respect the new dense-fire pulse floor");
	Require(candidateMinimum > sparseMinimum + 0.5f,
		"the retune must materially raise the minimum packet mass over tall sparse fire");
	Require(std::abs(candidateSum - static_cast<double>(Period)) < 1.0e-5,
		"one pulse period must retain unit mean source mass");
	std::cout << "pulse_min_dense=" << candidateMinimum << " sparse=" <<
		sparseMinimum << " period_sum=" << candidateSum << '\n';
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
	const uint32_t steps = static_cast<uint32_t>(std::floor(40.0f /
		candidate.cadence));
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
			const auto requests = BuildFire(candidate, 0x100u + source, serial, boundary);
			const auto admission = owner.AdmitBatch(requests.data(),
				static_cast<uint32_t>(requests.size()));
			Require(admission.Accepted(),
				"every two-source cadence packet must be admitted through 40 seconds");
		}
		RequireNoDrops(owner.GetSnapshot());
		accumulated += candidate.cadence;
	}

	const uint32_t groupsPerSource = static_cast<uint32_t>(std::ceil(
		candidate.lifetime / candidate.cadence - 1.0e-5f));
	const uint32_t expectedGroups = groupsPerSource * 2u;
	const uint32_t lobesPerGroup = std::min(FireLobes, profile.maximumLobesPerGroup);
	const uint32_t expectedLobes = expectedGroups * lobesPerGroup;
	const auto& snapshot = owner.GetSnapshot();
	Require(snapshot.activeGroups == expectedGroups &&
		snapshot.activeLobes == expectedLobes,
		"steady-state population must match lifetime/cadence and profile reduction");
	if (quality == static_cast<uint32_t>(NRISmokeTransientQuality::Low))
	{
		Require(snapshot.maximumActiveGroups - snapshot.activeGroups >= 2u &&
			snapshot.maximumActiveLobes - snapshot.activeLobes >= 8u,
			"Low must preserve the existing two-group/eight-lobe finite sharing headroom");
	}
	std::cout << (quality == 2u ? "medium" : "low") << "_steady=" <<
		snapshot.activeGroups << "g/" << snapshot.activeLobes << "l headroom=" <<
		(snapshot.maximumActiveGroups - snapshot.activeGroups) << "g/" <<
		(snapshot.maximumActiveLobes - snapshot.activeLobes) << "l\n";
}

void TestIntrinsicCoolingUnchanged(const FireTuning& baseline,
	const FireTuning& candidate)
{
	const auto oldRequests = BuildFire(baseline, 7u, 707u, 0.0);
	const auto newRequests = BuildFire(candidate, 7u, 707u, 0.0);
	for (uint32_t index = 0u; index < FireLobes; ++index)
	{
		Require(Near(oldRequests[index].intrinsicEmission,
			newRequests[index].intrinsicEmission) &&
			Near(oldRequests[index].emissionHalfLife,
				newRequests[index].emissionHalfLife),
			"density/height tuning must not alter intrinsic emission or its half-life");
	}
	for (float age : { 0.18f, 0.36f, 0.54f })
	{
		const auto oldGroup = Evaluate(baseline, age, 707u);
		const auto newGroup = Evaluate(candidate, age, 707u);
		for (uint32_t index = 0u; index < FireLobes; ++index)
			Require(Near(oldGroup.lobes[index].emissionScale,
				newGroup.lobes[index].emissionScale),
				"GPU intrinsic cooling must remain independent of density envelope tuning");
	}
}
}

int main(int argc, char** argv)
{
	Require(argc == 11,
		"usage: test optical lifetime rise sustain release spread cadence radius_min radius_max pulse");
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
	const FireTuning original = { 0.20f, 3.0f, 32.0f, 1.5f, 1.42f, 0.45f,
		0.28f, LobeRadiusMin, LobeRadiusMax, 0.90f };
	const FireTuning sparse = { 0.05f, 5.5f, 120.0f, 2.75f, 2.75f, 1.30f,
		0.50f, LobeRadiusMin, LobeRadiusMax, 0.90f };
	const FireTuning currentDense = { 0.10f, 5.5f, 120.0f, 2.75f, 2.75f, 1.30f,
		0.50f, 0.70f, 1.00f, 0.15f };
	Require(Near(candidate.opticalScale, 0.25f),
		"production fire optical scale must remain at the denser 0.25 target");
	Require(Near(candidate.lifetime, currentDense.lifetime) &&
		Near(candidate.riseVelocity, currentDense.riseVelocity) &&
		Near(candidate.cadence, currentDense.cadence),
		"density release tuning must preserve the 5.5-second life, rise, and cadence");
	Require(candidate.lifetime > candidate.sustain && candidate.release > 0.0f &&
		candidate.sustain + candidate.release <= candidate.lifetime + 1.0e-5f &&
		candidate.cadence > 0.0f && candidate.lobeRadiusMin > 0.0f &&
		candidate.lobeRadiusMax >= candidate.lobeRadiusMin &&
		candidate.pulseAmount >= 0.0f && candidate.pulseAmount <= 1.0f,
		"candidate lifetime, release envelope, and cadence must be internally valid");

	TestDensityRetuneAndNormalizedEnvelope(original, sparse, currentDense, candidate);
	TestLateVisibleHeight(original, candidate);
	TestRepresentativePacketBridges(sparse, candidate);
	TestPulseFloor(sparse, candidate);
	TestSmoothFadeAndNativeExpiration(candidate);
	TestCapacityRejectionDoesNotEvict(candidate);
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Medium));
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Low));
	TestIntrinsicCoolingUnchanged(original, candidate);
	std::cout << "Smoke transient production tuning tests passed.\n";
	return 0;
}
