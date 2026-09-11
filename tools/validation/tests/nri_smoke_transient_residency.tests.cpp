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
	float lifetime = 5.5f, uint32_t count = 5u, bool borrow = false)
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
	input.burstBorrow = borrow;
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

void AircarBorrowedBirthCoverage(bool lateFires)
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	std::set<uint32_t> presented;
	std::map<uint32_t, NRISmokeTransientGroupGpu> previous;
	uint32_t peakExplosions = 0u, peakExplosionLobes = 0u;
	uint32_t births = 0u;
	for (uint32_t tick = 0u; tick <= 370u; ++tick)
	{
		const double time = static_cast<double>(tick) / 30.0;
		owner.BeginFrame(time, 7u, profile, View(), clouds);
		if (tick == 0u)
			for (uint32_t source = 80u; source < 82u; ++source)
			{
				auto normal = Build(source, time, false, 1000.0f, 12.0f, 4u);
				for (auto& lobe : normal) lobe.transientClass = NRISmokeTransientClass::TrailChunk;
				Submit(owner, normal);
			}
		if (tick % 15u == 0u && tick < 210u && (!lateFires || tick >= 60u))
			for (uint32_t source = 1u; source <= 2u; ++source) Submit(owner, Build(source, time, true));
		if (tick >= 4u && tick <= 208u && tick % 4u == 0u)
		{
			auto explosion = Build(1000u + births, time, false, 1000.0f, 5.0f, 12u);
			for (auto& lobe : explosion) lobe.burstBorrow = true;
			Submit(owner, explosion);
			++births;
		}
		owner.Resolve(clouds);
		const auto& status = owner.GetSnapshot();
		Require(status.deferredBorrowExplosionGroups == 0u,
			"every one of the actual aircar's rapid explosion births admits on time");
		Require(status.hotFireDeferredGroups == 0u,
			"explosion loans preserve two established or subsequently arriving Fire streams");
		Require(clouds.GetSnapshot().activeGroups <= 64u && clouds.GetSnapshot().activeLobes <= 256u,
			"loaning never expands the fixed physical GPU limits");
		Require(status.historyRejectedGroups == 0u && status.historyEvictedGroups == 0u,
			"aircar coverage does not conceal rejection in retained CPU history");
		peakExplosions = std::max(peakExplosions, status.residentBorrowExplosionGroups);
		peakExplosionLobes = std::max(peakExplosionLobes, status.residentBorrowExplosionLobes);
		for (const auto& group : clouds.GetGpuGroups())
		{
			if (group.flags == 0u || group.sourceId < 1000u || group.lobeCount == 0u) continue;
			if (presented.insert(group.sourceId).second)
			{
				Require(group.ageSeconds <= 1.0f / 30.0f + 1.0e-5f,
					"first nonzero-density presentation is within one actor tick, not an old deferred tail");
				Require(group.lobeCount == (group.sourceId == 1000u ? 12u : 3u),
					"episode first explosion keeps authored detail; rapid followers carry three optical-preserving lobes");
			}
		}
		for (const auto& item : previous)
		{
			if (item.second.ageSeconds + 1.0f / 30.0f + 1.0e-5f >= item.second.groupLifetimeSeconds) continue;
			const auto& current = clouds.GetGpuGroups()[item.first];
			Require(current.flags != 0u && current.generation == item.second.generation,
				"explosion borrowing never evicts any already-visible unexpired group");
		}
		previous.clear();
		for (const auto& group : clouds.GetGpuGroups())
			if (group.flags != 0u) previous[group.slot] = group;
		clouds.CommitLightDispatchSchedule();
	}
	Require(births == 52u && presented.size() == 52u && owner.GetSnapshot().firstPresentedExplosionEvents == 52u,
		"all 52 authored aircar births, not merely the first poolful, were visibly represented");
	Require(peakExplosions == 38u && peakExplosionLobes == 123u,
		"actual 30Hz/4-tick/five-second episode reaches its expected 38-group/123-lobe bound");
	Require(owner.GetSnapshot().maximumExplosionFirstAgeMilliseconds <= 34u,
		"same-tick synthetic delivery reaches first payload within one actor tick (not a runtime upstream-arrival gate)");
	Require(owner.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds == 0u,
		"actual aircar-shaped workload adds no residency admission waiting after submission");
	Require(owner.GetSnapshot().compactExplosionEvents == 51u && owner.GetSnapshot().historyGroups == 0u,
		"all followers compact once and every original event eventually expires naturally");
}

void BorrowOptInAndEpisodeIdentity()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(0.2, 7u, profile, View(), clouds);
	auto later = Build(91u, 0.133333333, false, 1000.0f, 5.0f, 12u);
	auto first = Build(92u, 0.0, false, 1000.0f, 5.0f, 12u);
	for (auto* batch : { &later, &first }) for (auto& lobe : *batch) lobe.burstBorrow = true;
	Submit(owner, later); Submit(owner, first); // deliberately reversed actor traversal
	owner.Resolve(clouds);
	for (const auto& group : clouds.GetGpuGroups())
		if (group.flags != 0u)
			Require(group.lobeCount == (group.sourceId == 92u ? 12u : 3u),
				"same-frame episode stamping uses authored time, not submission traversal");
	owner.BeginFrame(1.0, 7u, profile, View(-1.0f), clouds); owner.Resolve(clouds);
	owner.BeginFrame(1.1, 7u, profile, View(), clouds); owner.Resolve(clouds);
	for (const auto& group : clouds.GetGpuGroups())
		if (group.flags != 0u)
			Require(group.lobeCount == (group.sourceId == 92u ? 12u : 3u),
				"true-age reentry cannot restamp compact followers as isolated full-detail explosions");
	auto isolated = Build(93u, 1.1, false, 1000.0f, 5.0f, 12u);
	for (auto& lobe : isolated) lobe.burstBorrow = true;
	Submit(owner, isolated); owner.Resolve(clouds);
	owner.BeginFrame(1.3, 7u, profile, View(), clouds); owner.Resolve(clouds);
	for (const auto& group : clouds.GetGpuGroups())
		if (group.sourceId == 93u) Require(group.lobeCount == 12u, "a quiet-gap isolated explosion retains authored art");
	NRISmokeTransientClouds reduction;
	reduction.Reset(7u); reduction.BeginFrame(0.5, 256u, profile);
	const auto reduced = reduction.AdmitRetainedBatch(first.data(), 12u, 3u);
	Require(reduced.Accepted(), "compact explosion uses the existing deterministic reducer");
	double authoredOptical = 0.0, reducedOptical = 0.0;
	for (uint32_t index = 0u; index < 12u; ++index)
		authoredOptical += first[index].initialDensity * first[index].opticalWeight;
	for (const auto& lobe : reduction.GetGpuLobes()) reducedOptical += lobe.densityScale;
	Require(std::abs(authoredOptical - reducedOptical) < 1.0e-5,
		"three-lobe explosion representation preserves authored optical quantity at full envelope");
	NRISmokeTransientResidency unflagged;
	NRISmokeTransientClouds unflaggedClouds;
	unflagged.BeginFrame(0.2, 7u, profile, View(), unflaggedClouds);
	for (uint32_t source = 1u; source <= 8u; ++source)
		Submit(unflagged, Build(source, 0.0, false, 1000.0f, 5.0f, 12u));
	unflagged.Resolve(unflaggedClouds);
	Require(unflagged.GetSnapshot().residentBurstLobes == 64u &&
		unflagged.GetSnapshot().residentBorrowExplosionGroups == 0u && unflagged.GetSnapshot().hotBurstDeferredGroups > 0u,
		"unflagged explosions cannot take the opted-in loan policy");
	const auto builderFlag = Build(99u, 0.0, false, 1000.0f, 5.0f, 12u, true);
	for (uint32_t index = 0u; index < 12u; ++index)
		Require(builderFlag[index].burstBorrow, "semantic shape input propagates opt-in to every immutable lobe request");
	auto mismatched = builderFlag;
	mismatched[4].burstBorrow = false;
	Require(!NRISmokeTransientClouds::ValidateBatch(mismatched.data(), 12u),
		"one group cannot contain contradictory borrowing policies");
}

void LateFireCannotSpendPromisedCadences()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(5.0, 7u, profile, View(), clouds);
	for (uint32_t source = 1u; source <= 2u; ++source)
		for (uint32_t cohort = 0u; cohort < 12u; ++cohort) Submit(owner, Build(source, cohort * 0.45, true));
	for (uint32_t index = 0u; index < 38u; ++index)
		Submit(owner, Build(1000u + index, 5.0 - static_cast<double>(37u - index) * 4.0 / 30.0,
			false, 1000.0f, 5.0f, 12u, true));
	for (uint32_t source = 80u; source < 82u; ++source)
	{
		auto normal = Build(source, 5.0, false, 1000.0f, 12.0f, 4u);
		for (auto& lobe : normal) lobe.transientClass = NRISmokeTransientClass::TrailChunk;
		Submit(owner, normal);
	}
	owner.Resolve(clouds);
	Require(clouds.GetSnapshot().activeGroups == 64u && clouds.GetSnapshot().activeLobes == 251u,
		"full promised-window fixture exactly fills the 64-group/251-lobe guarantee");
	owner.BeginFrame(5.01, 7u, profile, View(), clouds);
	Submit(owner, Build(3u, 5.01, true)); owner.Resolve(clouds);
	Require(owner.GetSnapshot().hotFireDeferredGroups == 1u && owner.GetSnapshot().residentFireGroups == 24u,
		"late third Fire waits rather than stealing existing pair's promised future capacity");
	bool thirdEventuallyAdmitted = false;
	for (uint32_t step = 1u; step <= 50u; ++step)
	{
		const double time = 5.0 + step * 0.05;
		owner.BeginFrame(time, 7u, profile, View(), clouds);
		if (step % 10u == 0u)
			for (uint32_t source = 1u; source <= 2u; ++source) Submit(owner, Build(source, time, true));
		owner.Resolve(clouds);
		if (step % 10u == 0u)
			for (uint32_t source = 1u; source <= 2u; ++source)
			{
				bool cadencePresent = false;
				for (const auto& group : clouds.GetGpuGroups())
					cadencePresent = cadencePresent || (group.flags != 0u && group.sourceId == source && group.ageSeconds < 1.0e-4f);
				Require(cadencePresent, "established Fire still admits every cadence while an extra source waits for loan repayment");
			}
		for (const auto& group : clouds.GetGpuGroups())
			thirdEventuallyAdmitted = thirdEventuallyAdmitted || (group.flags != 0u && group.sourceId == 3u);
	}
	Require(thirdEventuallyAdmitted, "extra source can enter at actual age after natural loan repayment opens its complete window");
}

void EstablishedFireWindowsPrecedeLoans()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(5.4, 7u, profile, View(), clouds);
	for (uint32_t source = 1u; source <= 4u; ++source)
		for (uint32_t cohort = 0u; cohort < 12u; ++cohort) Submit(owner, Build(source, cohort * 0.49, true));
	for (uint32_t source = 80u; source < 82u; ++source)
	{
		auto normal = Build(source, 5.0, false, 1000.0f, 12.0f, 4u, true);
		for (auto& lobe : normal) lobe.transientClass = NRISmokeTransientClass::TrailChunk;
		Submit(owner, normal); // even a wrongly opted-in Trail must remain ordinary
	}
	for (uint32_t index = 0u; index < 38u; ++index)
		Submit(owner, Build(1000u + index, 5.4 - static_cast<double>(37u - index) * 4.0 / 30.0,
			false, 1000.0f, 5.0f, 12u, true));
	owner.Resolve(clouds);
	const auto& state = owner.GetSnapshot();
	Require(state.residentFireGroups == 48u && state.hotFireDeferredGroups == 0u &&
		state.protectedFireGroups == 48u && state.protectedFireLobes == 192u,
		"four existing Fire windows remain protected before new explosions receive borrowing rights");
	Require(state.borrowExplosionGroupBudget == 14u && state.residentBorrowExplosionGroups == 14u &&
		state.deferredBorrowExplosionGroups == 24u && state.residentBurstGroups == 16u,
		"heavier established load truthfully reports unserved burst events instead of promising incompatible capacity");
	Require(clouds.GetSnapshot().activeGroups == 64u && state.residentBorrowExplosionLobes <= 56u,
		"wrongly flagged non-explosion effects stay ordinary and cannot enlarge loans");
}

void ExplosionAdmissionLatencySeparatesArrivalAndQueue()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(0.2, 7u, profile, View(), clouds);
	const auto oldAtArrival = Build(40u, 0.0, false, 1000.0f, 5.0f, 12u, true);
	Submit(owner, oldAtArrival); owner.Resolve(clouds);
	Require(owner.GetSnapshot().maximumExplosionFirstAgeMilliseconds >= 200u &&
		owner.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds == 0u,
		"old authored birth arriving this frame is immediate admission, not scheduler queue latency");
	owner.BeginFrame(0.4, 7u, profile, View(), clouds);
	Submit(owner, oldAtArrival); owner.Resolve(clouds);
	Require(owner.GetSnapshot().duplicateGroups == 1u &&
		owner.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds == 0u,
		"duplicates neither restart the original submission clock nor add fake admission latency");
	owner.BeginFrame(1.5, 7u, profile, View(-1.0f), clouds); owner.Resolve(clouds);
	owner.BeginFrame(2.0, 7u, profile, View(), clouds); owner.Resolve(clouds);
	Require(owner.GetSnapshot().reenteredGroups == 1u &&
		owner.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds == 0u &&
		owner.GetSnapshot().maximumExplosionFirstAgeMilliseconds == 200u,
		"reentry preserves original submission and first-presentation metrics without counting a second first admission");
	NRISmokeTransientResidency queued;
	NRISmokeTransientClouds queuedClouds;
	const auto low = queuedClouds.ProfileForQuality(3u);
	queued.BeginFrame(0.2, 7u, low, View(), queuedClouds);
	Submit(queued, Build(10u, 0.0, false, 1000.0f, 0.5f, 4u, true));
	Submit(queued, Build(11u, 0.1, false, 1000.0f, 0.5f, 4u, true));
	const auto held = Build(12u, 0.2, false, 1000.0f, 1.0f, 4u, true);
	Submit(queued, held); queued.Resolve(queuedClouds);
	Require(queued.GetSnapshot().deferredBorrowExplosionGroups == 1u &&
		queued.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds == 0u,
		"capacity-held events report deferral but do not claim admission before a slot exists");
	queued.BeginFrame(0.4, 7u, low, View(), queuedClouds);
	Submit(queued, held); queued.Resolve(queuedClouds);
	queued.BeginFrame(0.55, 7u, low, View(), queuedClouds); queued.Resolve(queuedClouds);
	Require(queued.GetSnapshot().deferredBorrowExplosionGroups == 0u &&
		queued.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds >= 349u &&
		queued.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds <= 351u,
		"real admission waiting measures from the original submission despite a queued duplicate");
}

void BatchedAircarWithoutFireUsesRealHeadroom()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	std::array<double, 52u> authored = {}, delivery = {};
	for (uint32_t index = 0u; index < 52u; ++index)
		authored[index] = delivery[index] = static_cast<double>(index + 1u) * 4.0 / 30.0;
	// Valid, monotonic authored times: event44 crosses early afterevent43.
	// Both are delivered together. This intentionally exceeds the ideal
	// cadence's 38-live-event bound before the oldest surviving event expires.
	authored[43] -= 0.1;
	delivery[42] = delivery[43] = authored[43] + 1.0 / 60.0;
	std::array<bool, 52u> submitted = {};
	std::set<uint32_t> presented;
	uint32_t peakGroups = 0u;
	for (uint32_t frame = 0u; frame <= 750u; ++frame)
	{
		const double time = static_cast<double>(frame) / 60.0;
		owner.BeginFrame(time, 7u, profile, View(), clouds);
		if (frame == 0u)
			for (uint32_t source = 80u; source < 82u; ++source)
			{
				auto normal = Build(source, time, false, 1000.0f, 12.0f, 4u);
				for (auto& lobe : normal) lobe.transientClass = NRISmokeTransientClass::TrailChunk;
				Submit(owner, normal);
			}
		for (uint32_t reverse = 52u; reverse > 0u; --reverse)
		{
			const uint32_t index = reverse - 1u;
			if (submitted[index] || delivery[index] > time + 1.0e-8) continue;
			Require(authored[index] <= time + 1.0e-8, "batched fixture never invents a future-authored birth");
			Submit(owner, Build(1000u + index, authored[index], false, 1000.0f, 5.0f, 12u, true));
			submitted[index] = true;
		}
		owner.Resolve(clouds);
		const auto& status = owner.GetSnapshot();
		peakGroups = std::max(peakGroups, status.residentBorrowExplosionGroups);
		Require(status.deferredBorrowExplosionGroups == 0u &&
			status.maximumExplosionAdmissionDelayMilliseconds == 0u,
			"batched no-Fire aircar consumes real spare capacity without introducing residency queueing");
		Require(status.protectedFireGroups == 12u && status.protectedFireLobes == 60u &&
			status.borrowExplosionGroupBudget >= 50u && status.borrowExplosionLobeBudget >= 188u,
			"zero Fire preserves one whole future window, not an artificial 38-event ceiling");
		Require(clouds.GetSnapshot().activeGroups <= 64u && clouds.GetSnapshot().activeLobes <= 256u,
			"batch slack never expands the physical pool");
		for (const auto& group : clouds.GetGpuGroups())
			if (group.flags != 0u && group.sourceId >= 1000u && group.lobeCount > 0u)
				presented.insert(group.sourceId);
	}
	Require(peakGroups >= 39u && presented.size() == 52u && owner.GetSnapshot().firstPresentedExplosionEvents == 52u,
		"all 52 jittered births present, including the 39th living event the old cap deferred");
	std::cout << "Batched aircar peak=" << peakGroups << " published=" << presented.size()
		<< " max_admission_delay_ms=" << owner.GetSnapshot().maximumExplosionAdmissionDelayMilliseconds << '\n';
}

void OneFireWindowSurvivesMaximumZeroFireLoans()
{
	NRISmokeTransientResidency owner;
	NRISmokeTransientClouds clouds;
	const auto profile = clouds.ProfileForQuality(2u);
	owner.BeginFrame(4.9, 7u, profile, View(), clouds);
	for (uint32_t index = 0u; index < 50u; ++index)
		Submit(owner, Build(1000u + index, index * 0.1, false, 1000.0f, 5.0f, 12u, true));
	for (uint32_t source = 80u; source < 82u; ++source)
	{
		auto normal = Build(source, 4.9, false, 1000.0f, 12.0f, 4u);
		for (auto& lobe : normal) lobe.transientClass = NRISmokeTransientClass::TrailChunk;
		Submit(owner, normal);
	}
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().residentBorrowExplosionGroups == 50u &&
		owner.GetSnapshot().deferredBorrowExplosionGroups == 0u,
		"no-Fire loans can use all fifty groups outside the future-Fire/ordinary windows");
	owner.BeginFrame(4.91, 7u, profile, View(), clouds);
	Submit(owner, Build(1u, 4.91, true));
	Submit(owner, Build(2u, 4.91, true));
	owner.Resolve(clouds);
	Require(owner.GetSnapshot().residentFireGroups == 1u && owner.GetSnapshot().hotFireDeferredGroups == 1u,
		"one late Fire immediately fits the promised window; the second waits for a complete window");
	bool secondEntered = false;
	for (uint32_t step = 1u; step <= 50u; ++step)
	{
		const double time = 4.91 + step * 0.05;
		owner.BeginFrame(time, 7u, profile, View(), clouds);
		if (step % 10u == 0u) Submit(owner, Build(1u, time, true));
		owner.Resolve(clouds);
		if (step % 10u == 0u)
		{
			bool firstCadence = false;
			for (const auto& group : clouds.GetGpuGroups())
				firstCadence = firstCadence || (group.flags != 0u && group.sourceId == 1u && group.ageSeconds < 1.0e-4f);
			Require(firstCadence, "second Fire cannot interrupt the first Fire's reserved ongoing cadence");
		}
		for (const auto& group : clouds.GetGpuGroups())
			secondEntered = secondEntered || (group.flags != 0u && group.sourceId == 2u);
	}
	Require(secondEntered, "second Fire enters at its original age after natural loan repayment opens another window");
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
	AircarBorrowedBirthCoverage(false);
	AircarBorrowedBirthCoverage(true);
	BorrowOptInAndEpisodeIdentity();
	LateFireCannotSpendPromisedCadences();
	EstablishedFireWindowsPrecedeLoans();
	ExplosionAdmissionLatencySeparatesArrivalAndQueue();
	BatchedAircarWithoutFireUsesRealHeadroom();
	OneFireWindowSurvivesMaximumZeroFireLoans();
	std::cout << "Transient residency tests passed: " << Checks << " checks.\n";
	return 0;
}
