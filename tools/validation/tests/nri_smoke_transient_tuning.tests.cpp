#include "nri_smoke_transient_clouds.h"

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
	input.lobeRadiusMinScale = LobeRadiusMin;
	input.lobeRadiusMaxScale = LobeRadiusMax;
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

void TestQuarterOpticsAndNormalizedEnvelope(const FireTuning& baseline,
	const FireTuning& candidate)
{
	const auto oldRequests = BuildFire(baseline, 1u, 101u, 0.0);
	const auto newRequests = BuildFire(candidate, 1u, 101u, 0.0);
	for (uint32_t index = 0u; index < FireLobes; ++index)
		Require(Near(newRequests[index].opticalWeight,
			oldRequests[index].opticalWeight * 0.25f),
			"each shaped lobe must carry exactly one quarter of baseline optical weight");

	for (float releasePhase : { 0.0f, 0.25f, 0.5f, 0.75f, 0.99f })
	{
		const double oldAge = baseline.sustain + baseline.release * releasePhase;
		const double newAge = candidate.sustain + candidate.release * releasePhase;
		const auto oldGroup = Evaluate(baseline, oldAge, 101u);
		const auto newGroup = Evaluate(candidate, newAge, 101u);
		for (uint32_t index = 0u; index < FireLobes; ++index)
		{
			const float oldEnvelope = oldGroup.lobes[index].densityScale /
				(InitialDensity * oldRequests[index].opticalWeight);
			const float newEnvelope = newGroup.lobes[index].densityScale /
				(InitialDensity * newRequests[index].opticalWeight);
			Require(Near(oldEnvelope, newEnvelope, 5.0e-4f),
				"baseline and candidate release envelopes must agree at equal normalized phase");
			Require(Near(newGroup.lobes[index].densityScale,
				oldGroup.lobes[index].densityScale * 0.25f, 5.0e-4f),
				"equal-phase GPU density must remain exactly quarter strength");
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
	// The user-visible height target is the developed plume, not the first quarter
	// of release while the longer candidate is still climbing out of the flame.
	for (float releasePhase : { 0.5f, 0.75f, 0.95f })
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

float PacketBridgeMargin(const FireTuning& candidate, uint64_t olderSerial,
	float youngerAge)
{
	auto profile = NRISmokeTransientClouds::ProfileForQuality(2u);
	NRISmokeTransientClouds owner;
	owner.Reset(Epoch);
	owner.BeginFrame(0.0, NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto older = BuildFire(candidate, 0x6a086ee7u, olderSerial, 0.0);
	const auto olderAdmission = owner.AdmitBatch(older.data(),
		static_cast<uint32_t>(older.size()));
	owner.BeginFrame(candidate.cadence, NRISmokeTransientClouds::FixedLobeCapacity,
		profile);
	const auto younger = BuildFire(candidate, 0x6a086ee7u, olderSerial + 1u,
		candidate.cadence);
	const auto youngerAdmission = owner.AdmitBatch(younger.data(),
		static_cast<uint32_t>(younger.size()));
	Require(olderAdmission.Accepted() && youngerAdmission.Accepted(),
		"adjacent production packets must be admitted");
	owner.BeginFrame(static_cast<double>(candidate.cadence + youngerAge),
		NRISmokeTransientClouds::FixedLobeCapacity, profile);
	const auto& groups = owner.GetGpuGroups();
	const auto& gpuLobes = owner.GetGpuLobes();
	const auto& olderGroup = groups[olderAdmission.handle.slot];
	const auto& youngerGroup = groups[youngerAdmission.handle.slot];
	float bestMargin = -std::numeric_limits<float>::max();
	for (uint32_t a = 0u; a < olderGroup.lobeCount; ++a)
		for (uint32_t b = 0u; b < youngerGroup.lobeCount; ++b)
		{
			const auto& oldLobe = gpuLobes[olderGroup.firstLobe + a];
			const auto& newLobe = gpuLobes[youngerGroup.firstLobe + b];
			bestMargin = std::max(bestMargin, oldLobe.radius + newLobe.radius -
				Distance3(oldLobe.position, newLobe.position));
		}
	return bestMargin;
}

void TestRepresentativePacketBridges(const FireTuning& candidate)
{
	float earlyMinimumMargin = std::numeric_limits<float>::max();
	uint32_t earlyConnected = 0u;
	uint32_t earlyTested = 0u;
	// The attack-complete boundary and a shortly-later sample are the demanding
	// bottom-of-plume cases. Keep their outcome diagnostic: randomized adjacent
	// packets are not authored as a universal topology guarantee.
	for (uint64_t serial = 1u; serial <= 32u; ++serial)
		for (float youngerAge : { 0.08f, 0.15f })
		{
			const float margin = PacketBridgeMargin(candidate, serial, youngerAge);
			earlyMinimumMargin = std::min(earlyMinimumMargin, margin);
			earlyConnected += margin >= 0.0f ? 1u : 0u;
			earlyTested++;
		}
	std::cout << "early_packet_bridges=" << earlyConnected << '/' << earlyTested <<
		" minimum_margin=" << earlyMinimumMargin << '\n';
	Require(earlyConnected > 0u && std::isfinite(earlyMinimumMargin),
		"the early packet bridge diagnostic must exercise finite real 3D support");

	// At a comparable, clearly visible fade stage the packet train must actually
	// connect. This is a sphere-pair test across groups, stronger than overlapping
	// group AABBs and bounded to the stage the height comparison evaluates.
	uint32_t lateConnected = 0u;
	float lateMinimumMargin = std::numeric_limits<float>::max();
	const float lateAge = candidate.sustain + candidate.release * 0.5f;
	for (uint64_t serial = 1u; serial <= 32u; ++serial)
	{
		const float margin = PacketBridgeMargin(candidate, serial, lateAge);
		lateMinimumMargin = std::min(lateMinimumMargin, margin);
		lateConnected += margin >= 0.0f ? 1u : 0u;
	}
	std::cout << "late_packet_bridges=" << lateConnected << "/32 minimum_margin=" <<
		lateMinimumMargin << '\n';
	Require(lateConnected == 32u,
		"adjacent packets must have real 3D support overlap at release midpoint");
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
	Require(argc == 8,
		"usage: test optical lifetime rise sustain release spread cadence");
	FireTuning candidate = {};
	candidate.opticalScale = std::stof(argv[1]);
	candidate.lifetime = std::stof(argv[2]);
	candidate.riseVelocity = std::stof(argv[3]);
	candidate.sustain = std::stof(argv[4]);
	candidate.release = std::stof(argv[5]);
	candidate.spread = std::stof(argv[6]);
	candidate.cadence = std::stof(argv[7]);
	const FireTuning baseline = { 0.20f, 3.0f, 32.0f, 1.5f, 1.42f, 0.45f, 0.28f };
	Require(Near(candidate.opticalScale, baseline.opticalScale * 0.25f),
		"production fire optical scale must be exactly one quarter of baseline");
	Require(candidate.lifetime > candidate.sustain && candidate.release > 0.0f &&
		candidate.sustain + candidate.release <= candidate.lifetime + 1.0e-5f &&
		candidate.cadence > 0.0f,
		"candidate lifetime, release envelope, and cadence must be internally valid");

	TestQuarterOpticsAndNormalizedEnvelope(baseline, candidate);
	TestLateVisibleHeight(baseline, candidate);
	TestRepresentativePacketBridges(candidate);
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Medium));
	TestTwoSourceCapacity(candidate,
		static_cast<uint32_t>(NRISmokeTransientQuality::Low));
	TestIntrinsicCoolingUnchanged(baseline, candidate);
	std::cout << "Smoke transient production tuning tests passed.\n";
	return 0;
}
