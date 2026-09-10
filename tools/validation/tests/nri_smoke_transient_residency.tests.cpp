#include "nri_smoke_transient_residency.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <map>
#include <set>

namespace
{
uint32_t Checks = 0u;
void Require(bool condition, const char* message)
{
	++Checks;
	if (!condition) { std::cerr << "FAILED: " << message << '\n'; std::exit(1); }
}

using Batch = std::array<NRISmokeTransientLobeRequest, 16u>;
Batch Build(uint32_t source, double time, bool fire, float x = 1000.0f,
	float lifetime = 5.5f, uint32_t count = 5u)
{
	NRISmokeTransientGroupShapeInput input = {};
	input.position[0] = x;
	input.position[2] = static_cast<float>(source % 4u) * 20.0f;
	input.initialRadius = 7.0f;
	input.initialDensity = 0.5f;
	input.opticalAmount = 5.0f;
	input.expansionVelocity = 5.0f;
	input.densityHalfLife = 4.0f;
	input.lobeLifetimeSeconds = lifetime;
	input.groupLifetimeSeconds = lifetime;
	input.radiusExponent = 0.6f;
	input.densityAttackSeconds = 0.08f;
	input.densitySustainSeconds = lifetime * 0.5f;
	input.densityReleaseSeconds = lifetime * 0.5f;
	input.riseVelocity = fire ? 120.0f : 0.0f;
	input.lobeDelayStepSeconds = fire ? 0.5f / static_cast<float>(count) : 0.0f;
	input.requestedLobeCount = count;
	input.sourceId = source;
	input.epoch = 7u;
	input.authoredGameplaySeconds = time;
	input.sourceEventSerial = static_cast<uint64_t>(time * 1000.0) + 1u;
	input.deterministicSeed = source * 173u + static_cast<uint32_t>(input.sourceEventSerial);
	input.transientClass = fire ? NRISmokeTransientClass::FirePacket : NRISmokeTransientClass::Explosion;
	input.lightRefresh = fire ? NRISmokeTransientLightRefresh::Slow : NRISmokeTransientLightRefresh::Frozen;
	Batch batch = {};
	Require(NRIBuildSmokeTransientLobes(input, batch.data(), 16u) == count, "fixture builds complete batch");
	return batch;
}

NRISmokeTransientView View(float direction = 1.0f)
{
	NRISmokeTransientView view = {};
	view.valid = true;
	view.planeCount = 1u;
	view.planes[0][0] = direction * 2.0f; // deliberately unnormalized
	return view;
}

void Submit(NRISmokeTransientResidency& owner, const Batch& batch)
{
	Require(owner.SubmitBatch(batch.data(), batch[0].batchCount), "valid event retained");
}

void PressureAndTransition()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	std::map<uint32_t, NRISmokeTransientGroupGpu> previous;
	for (uint32_t frame = 0u; frame < 100u; ++frame)
	{
		const double time = frame * 0.5;
		owner.BeginFrame(time, 7u, profile, View(), clouds);
		const uint32_t fireCount = frame < 30u ? 2u : (frame < 32u ? 3u : 4u);
		for (uint32_t source = 0u; source < fireCount; ++source)
			Submit(owner, Build(source + 1u, time, true));
		for (uint32_t index = 0u; index < 16u; ++index)
			Submit(owner, Build(index + 100u, time, false, -5000.0f, 3.0f, 12u));
		for (uint32_t index = 0u; index < 4u; ++index)
			Submit(owner, Build(index + 300u, time, false, 1000.0f, 1.5f, 12u));
		owner.Resolve(clouds);
		const auto& snapshot = owner.GetSnapshot();
		Require(snapshot.hotFireDeferredGroups == 0u, "two-to-four Hot fires keep every cadence under mixed pressure");
		Require(snapshot.residentFireGroups <= 48u && snapshot.residentFireLobes <= 192u,
			"protected Fire share stays bounded");
		Require(snapshot.residentBurstGroups <= 16u && snapshot.residentBurstLobes <= 64u,
			"bursts stay in their independent bounded share");
		Require(snapshot.unsupportedLoadFrames == 0u, "four production fires remain supported load");
		Require(snapshot.dormantGroups > 0u && snapshot.hiddenResidentGroups == 0u,
			"offscreen bursts retain history but spend no detailed slots");
		if (frame >= 11u && frame < 30u)
			Require(snapshot.residentFireGroups == 22u && snapshot.residentFireLobes == 110u,
				"dumpster pair retains five-lobe full detail");
		if (frame > 41u) Require(snapshot.residentFireGroups == 44u,
			"four stable fires retain their full eleven-cohort histories");
		for (const auto& group : clouds.GetGpuGroups())
		{
			if ((group.flags & NRISmokeTransientGroupFlagActive) == 0u) continue;
			auto old = previous.find(group.slot);
			if (old != previous.end() && old->second.ageSeconds + 0.5f < old->second.groupLifetimeSeconds)
				Require(group.generation == old->second.generation,
					"live visible GPU group is never evicted/replaced by pressure");
		}
		for (const auto& item : previous)
		{
			if (item.second.ageSeconds + 0.5f >= item.second.groupLifetimeSeconds) continue;
			const auto& current = clouds.GetGpuGroups()[item.first];
			Require((current.flags & NRISmokeTransientGroupFlagActive) != 0u &&
				current.generation == item.second.generation,
				"every previously visible unexpired group remains present, not merely unreplaced");
		}
		previous.clear();
		for (const auto& group : clouds.GetGpuGroups())
			if ((group.flags & NRISmokeTransientGroupFlagActive) != 0u) previous[group.slot] = group;
		clouds.CommitLightDispatchSchedule();
	}
}

void ReentryAndLifecycle()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(0.0, 7u, profile, View(), clouds);
	auto batch = Build(9u, 0.0, true);
	for (auto& request : batch) request.maximumLatencySeconds = 0.2f;
	Submit(owner, batch);
	Submit(owner, batch);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().historyGroups == 1u && owner.GetSnapshot().duplicateGroups == 1u,
		"duplicate submissions cannot create duplicate cohorts");
	owner.BeginFrame(0.6, 7u, profile, View(), clouds);
	owner.Resolve(clouds);
	const auto original = clouds.GetGpuGroups()[0];
	Require(clouds.GetSnapshot().fullLightFreshScheduledThisFrame == 1u, "mature visible group gets first-use light");
	clouds.CommitLightDispatchSchedule();
	owner.BeginFrame(0.7, 7u, profile, View(-1.0f), clouds);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().warmGroups == 1u && clouds.GetSnapshot().fullLightAllowedGroups == 0u,
		"recently hidden Warm group freezes full lighting work");
	owner.BeginFrame(1.6, 7u, profile, View(-1.0f), clouds);
	owner.Resolve(clouds);
	Require(clouds.GetSnapshot().activeGroups == 0u && owner.GetSnapshot().historyGroups == 1u,
		"Dormant event releases detail while retaining absolute-time history");
	owner.BeginFrame(2.0, 7u, profile, View(), clouds);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().reenteredGroups == 1u && clouds.GetSnapshot().activeGroups == 1u,
		"surviving dormant event reenters despite original latency gate");
	const auto returned = clouds.GetGpuGroups()[0];
	Require(std::abs(returned.ageSeconds - 2.0f) < 1.0e-6f && returned.generation != original.generation,
		"reentry retains authored age and invalidates physical-slot cache identity");
	Require(clouds.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"first-visible reentry requests coherent fresh lighting");
	Require(clouds.GetGpuLobes()[0].position[1] > 150.0f,
		"returning fire smoke resumes up the plume, not at source birth");
	Require(clouds.GetGpuLobes()[0].deterministicSeed == batch[0].deterministicSeed,
		"original deterministic shape/noise identity survives reentry");
	owner.BeginFrame(6.0, 7u, profile, View(), clouds);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().historyGroups == 0u && clouds.GetSnapshot().activeGroups == 0u,
		"stopped/deleted source leaves only naturally expiring previous emissions");
	owner.BeginFrame(6.1, 7u, profile, View(), clouds);
	auto latest = Build(3u, 6.1, false);
	for (auto& request : latest) request.replacementKey = 777u;
	Submit(owner, latest); owner.Resolve(clouds);
	Require(owner.RetireLatest(777u, clouds) && owner.GetSnapshot().historyGroups == 0u,
		"explicit replacement cancellation clears both detail and history");
	Submit(owner, Build(4u, 6.1, true)); owner.Resolve(clouds);
	owner.BeginFrame(0.0, 7u, profile, View(), clouds); owner.Resolve(clouds);
	Require(owner.GetSnapshot().historyGroups == 0u && clouds.GetSnapshot().activeGroups == 0u,
		"gameplay time rewind cannot resurrect future or previous events");
	Submit(owner, Build(5u, 0.0, true)); owner.Resolve(clouds);
	owner.BeginFrame(0.1, 8u, profile, View(), clouds); owner.Resolve(clouds);
	Require(owner.GetSnapshot().epoch == 8u && owner.GetSnapshot().historyGroups == 0u,
		"epoch reset removes all old source histories");
}

void ConservativeVisibilityAndMixedExpiry()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(0.0, 7u, profile, View(), clouds);
	auto rising = Build(2u, 0.0, true, -600.0f);
	for (auto& request : rising) request.velocity[0] = 160.0f;
	Submit(owner, rising);
	Submit(owner, Build(3u, 0.0, false, -100.0f));
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotGroups == 2u,
		"whole-lifetime plume intersection and near-camera guard prevent source-point culling");
	owner.BeginFrame(0.1, 7u, profile, {}, clouds);
	Submit(owner, Build(4u, 0.1, false, -5000.0f)); owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotGroups == 3u, "invalid view falls back to conservative Hot interest");
	NRISmokeTransientClouds retained;
	retained.Reset(7u); retained.BeginFrame(2.0, 256u, profile);
	auto mixed = Build(5u, 0.0, false, 1000.0f, 5.0f, 2u);
	mixed[0].lifetimeSeconds = 1.0f;
	const auto admission = retained.AdmitRetainedBatch(mixed.data(), 2u, 2u);
	Require(admission.Accepted() && retained.GetGpuLobes().size() == 1u,
		"one expired lobe does not reject a retained group with another living member");
	Require(retained.Release(admission.handle) && !retained.Release(admission.handle),
		"released handles are stale-proof");
}

void BoundedHistoryAndSourceFairness()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(0.0, 7u, profile, View(), clouds);
	Submit(owner, Build(1u, 0.0, true)); owner.Resolve(clouds);
	const auto visible = clouds.GetGpuGroups()[0];
	for (uint32_t source = 100u; source < 1300u; ++source)
		Submit(owner, Build(source, 0.0, false, -5000.0f, 20.0f));
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().historyGroups == 513u && owner.GetSnapshot().historyEvictedGroups > 0u,
		"hidden burst history cannot consume reserved Fire descriptor capacity");
	for (uint32_t source = 1500u; source < 2700u; ++source)
		Submit(owner, Build(source, 0.0, true, -5000.0f, 20.0f));
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().historyGroups == 1024u && clouds.GetGpuGroups()[0].generation == visible.generation,
		"bounded history pressure never drops resident visible smoke");
	Require(owner.GetSnapshot().allocatedHistoryBytes < 8u * 1024u * 1024u,
		"descriptor allocation remains an explicit bounded CPU cost");
	std::cout << "Bounded descriptor allocation: " << owner.GetSnapshot().allocatedHistoryBytes << " bytes.\n";
	NRISmokeTransientResidency fair;
	NRISmokeTransientClouds fairClouds;
	std::set<uint32_t> admittedSources;
	for (uint32_t frame = 0u; frame < 60u; ++frame)
	{
		const double time = frame * 0.5;
		fair.BeginFrame(time, 7u, profile, View(), fairClouds);
		for (uint32_t source = 6u; source > 0u; --source)
			Submit(fair, Build(source, time, true));
		fair.Resolve(fairClouds);
		if (frame > 20u)
			for (const auto& group : fairClouds.GetGpuGroups())
				if (group.flags != 0u) admittedSources.insert(group.sourceId);
	}
	Require(fair.GetSnapshot().unsupportedLoadFrames > 0u &&
		fair.GetSnapshot().hotFireDeferredGroups > 0u, "over-limit visible load reports real deferred cadence coverage");
	Require(admittedSources.size() == 6u, "fair source arbitration prevents traversal-order source starvation");
}

void LowProfileAndDownswitch()
{
	NRISmokeTransientResidency lowOwner;
	NRISmokeTransientClouds lowClouds;
	NRISmokeTransientResidency switchOwner;
	NRISmokeTransientClouds switchClouds;
	const auto low = lowClouds.ProfileForQuality(3u);
	const auto medium = lowClouds.ProfileForQuality(2u);
	for (uint32_t frame = 0u; frame < 28u; ++frame)
	{
		const double time = frame * 0.5;
		lowOwner.BeginFrame(time, 7u, low, View(), lowClouds);
		switchOwner.BeginFrame(time, 7u, frame < 15u ? medium : low, View(), switchClouds);
		for (uint32_t source = 1u; source <= 2u; ++source)
		{
			const auto batch = Build(source, time, true);
			Submit(lowOwner, batch);
			if (frame < 15u) Submit(switchOwner, batch);
		}
		Submit(lowOwner, Build(90u, time, false, 1000.0f, 1.0f, 12u));
		lowOwner.Resolve(lowClouds); switchOwner.Resolve(switchClouds);
		Require(lowOwner.GetSnapshot().hotFireDeferredGroups == 0u &&
			lowOwner.GetSnapshot().residentFireLobes <= 88u,
			"Low independently protects two four-lobe fire streams under bursts");
		if (frame == 15u)
			Require(switchOwner.GetSnapshot().overBudgetResidentLobes > 0u &&
				switchOwner.GetSnapshot().residentFireLobes == 100u,
				"profile down-switch reports grandfathered live-detail excess without eviction");
	}
	Require(switchOwner.GetSnapshot().historyGroups == 0u &&
		switchOwner.GetSnapshot().overBudgetResidentLobes == 0u,
		"grandfathered down-switch population returns to budget by natural expiry");
}

void WarmFrozenLighting()
{
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	clouds.Reset(7u);
	clouds.BeginFrame(0.6, 256u, profile);
	const auto batch = Build(7u, 0.0, false);
	const auto first = clouds.AdmitRetainedBatch(batch.data(), 5u, 5u);
	Require(first.Accepted() && clouds.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"initial mature Frozen field is scheduled once");
	clouds.CommitLightDispatchSchedule();
	clouds.SetInterest(first.handle, NRISmokeTransientInterest::Warm);
	clouds.BeginFrame(0.7, 256u, profile);
	clouds.SetInterest(first.handle, NRISmokeTransientInterest::Hot);
	Require(clouds.GetSnapshot().fullLightFreshRequestedThisFrame == 0u &&
		clouds.GetSnapshot().fullLightAllowedGroups == 0u,
		"Warm-to-Hot Frozen cache reuse does not falsely schedule a GPU-disallowed rebuild");
	const auto secondBatch = Build(8u, 0.0, false);
	const auto second = clouds.AdmitRetainedBatch(secondBatch.data(), 5u, 5u);
	clouds.SetInterest(second.handle, NRISmokeTransientInterest::Warm);
	clouds.BeginFrame(0.8, 256u, profile);
	Require(clouds.GetSnapshot().fullLightFreshRequestedThisFrame == 0u,
		"never-built Warm Frozen group spends no first-use rays while hidden");
	clouds.SetInterest(second.handle, NRISmokeTransientInterest::Hot);
	Require(clouds.GetSnapshot().fullLightFreshScheduledThisFrame == 1u,
		"never-built Warm Frozen group retains its pending first-use build on Hot entry");
}

void RotatingPairsRetainCapacity()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	auto sourceHistory = [&](uint32_t source, float x, float z)
	{
		for (uint32_t cohort = 0u; cohort < 12u; ++cohort)
		{
			auto batch = Build(source, cohort * 0.49, true, x);
			for (auto& request : batch) request.position[2] = z;
			Submit(owner, batch);
		}
	};
	owner.BeginFrame(5.40, 7u, profile, View(), clouds);
	sourceHistory(1u, 1000.0f, 1000.0f);
	sourceHistory(2u, 1000.0f, -1000.0f);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().residentFireGroups == 24u && owner.GetSnapshot().residentFireLobes == 120u,
		"adversarial pair retains maximum twelve five-lobe cohorts each");
	auto rotated = View();
	rotated.planes[0][0] = 0.0f;
	rotated.planes[0][2] = -1.0f;
	owner.BeginFrame(5.45, 7u, profile, rotated, clouds);
	sourceHistory(3u, -1000.0f, -1000.0f);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotFireSources == 2u && owner.GetSnapshot().warmGroups == 12u &&
		owner.GetSnapshot().residentFireLobes == 156u,
		"old Warm full-detail source counts toward quality reservation for next Hot pair");
	owner.BeginFrame(5.46, 7u, profile, {}, clouds); // camera cut: all bounds conservatively Hot
	sourceHistory(4u, -1000.0f, 1000.0f);
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotFireSources == 4u && owner.GetSnapshot().residentFireGroups == 48u &&
		owner.GetSnapshot().residentFireLobes == 192u && owner.GetSnapshot().hotFireDeferredGroups == 0u,
		"four-source return after rotating Hot pairs fits exact maximum reservation without cadence gaps");
}

void RetimedRepresentativeBounds()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	auto profile = clouds.ProfileForQuality(2u);
	profile.maximumLobesPerGroup = 2u;
	auto view = View();
	view.position[0] = 10000.0f;
	view.hotPadding = view.warmPadding = view.nearDistance = 0.0f;
	auto batch = Build(19u, 0.0, true);
	for (uint32_t index = 0u; index < 5u; ++index)
	{
		auto& request = batch[index];
		request.position[0] = -2115.0f;
		request.position[1] = request.position[2] = 0.0f;
		request.velocity[0] = request.velocity[1] = request.velocity[2] = 0.0f;
		request.initialRadius = 1.0f;
		request.expansionVelocity = 0.0f;
		request.radiusExponent = 1.0f;
	}
	// 5->2 reduction selects original member three for the second bucket,
	// moving its birth from .3 to .25 and extending local life from5.2to5.25.
	batch[3].velocity[0] = 400.0f;
	batch[3].expansionVelocity = 5.0f;
	const float originalEnd = batch[3].position[0] +
		(batch[3].velocity[0] + batch[3].expansionVelocity) * batch[3].lifetimeSeconds +
		batch[3].initialRadius;
	Require(originalEnd < 0.0f, "original-member lifetime bound lies wholly outside the Hot plane");
	owner.BeginFrame(0.0, 7u, profile, view, clouds);
	Submit(owner, batch); owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotGroups == 1u && owner.GetSnapshot().residentFireLobes == 2u,
		"whole-group lifetime bound retains a reduced representative whose extended future enters view");
	auto away = view;
	away.planes[0][0] = 1.0f;
	away.planes[0][3] = -20000.0f;
	owner.BeginFrame(1.0, 7u, profile, away, clouds); owner.Resolve(clouds);
	Require(owner.GetSnapshot().dormantGroups == 1u && clouds.GetSnapshot().activeGroups == 0u,
		"the bound fixture really demotes when its complete future is elsewhere");
	owner.BeginFrame(5.48, 7u, profile, view, clouds); owner.Resolve(clouds);
	Require(owner.GetSnapshot().reenteredGroups == 1u && owner.GetSnapshot().hotGroups == 1u,
		"retained two-lobe reentry preserves conservative bounds without near-camera or margin masking");
	bool reachesView = false;
	for (const auto& lobe : clouds.GetGpuLobes())
		reachesView = reachesView || lobe.position[0] + lobe.radius > 0.0f;
	Require(reachesView, "the re-timed high-velocity/high-growth representative really reaches the visible side");
}
}

int main()
{
	PressureAndTransition();
	ReentryAndLifecycle();
	ConservativeVisibilityAndMixedExpiry();
	BoundedHistoryAndSourceFairness();
	LowProfileAndDownswitch();
	WarmFrozenLighting();
	RotatingPairsRetainCapacity();
	RetimedRepresentativeBounds();
	std::cout << "Transient residency tests passed: " << Checks << " checks.\n";
	return 0;
}
