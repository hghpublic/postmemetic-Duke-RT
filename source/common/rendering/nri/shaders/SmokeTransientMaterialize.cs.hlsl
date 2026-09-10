#include "Include/SmokeResources.hlsli"
#include "Include/SmokeFroxel.hlsli"
#include "Include/SmokePhase.hlsli"
#include "Include/SmokeLightParameters.hlsli"
#include "Include/SmokeTransientData.hlsli"
#include "Include/SmokeTransientLighting.hlsli"

bool SmokeTransientLoadCache(SmokeTransientGroup group,
	out SmokeTransientLightHeader header,
	out SmokeTransientLightAnchor anchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT])
{
	header = (SmokeTransientLightHeader)0;
	uint headerCapacity, headerStride;
	gSmokeTransientLightHeaders.GetDimensions(headerCapacity, headerStride);
	if (group.Slot >= headerCapacity)
		return false;
	header = gSmokeTransientLightHeaders[group.Slot];
	if (!SmokeTransientHeaderIdentityMatches(header, group))
		return false;
	const bool bankB = (header.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_BANK_B) != 0u;
	uint anchorCapacity, anchorStride;
	if (bankB) gSmokeTransientLightAnchorsB.GetDimensions(anchorCapacity, anchorStride);
	else gSmokeTransientLightAnchorsA.GetDimensions(anchorCapacity, anchorStride);
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
	{
		anchors[anchorIndex] = (SmokeTransientLightAnchor)0;
		if ((group.RequiredAnchorMask & (1u << anchorIndex)) == 0u)
			continue;
		const uint inputIndex = group.Slot * NRI_SMOKE_TRANSIENT_ANCHOR_COUNT + anchorIndex;
		if (inputIndex >= anchorCapacity)
			return false;
		if (bankB) anchors[anchorIndex] = gSmokeTransientLightAnchorsB[inputIndex];
		else anchors[anchorIndex] = gSmokeTransientLightAnchorsA[inputIndex];
		if (!SmokeTransientAnchorIdentityMatches(anchors[anchorIndex], group, anchorIndex))
			return false;
	}
	return true;
}

bool SmokeTransientLoadPreviousFireCache(SmokeTransientGroup group,
	SmokeTransientLightHeader currentHeader,
	SmokeTransientLightAnchor currentAnchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT],
	out SmokeTransientLightAnchor previousAnchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT],
	out float currentWeight)
{
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
		previousAnchors[anchorIndex] = (SmokeTransientLightAnchor)0;
	currentWeight = 1.0;
	if (group.TransientClass != NRI_SMOKE_TRANSIENT_CLASS_FIRE ||
		(currentHeader.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_FULL) == 0u)
		return false;

	// Every anchor in a complete bank carries the same build age. Read the first
	// required current anchor before touching the inactive bank; settled Fire
	// packets therefore keep the original one-bank materialization cost.
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
	{
		if ((group.RequiredAnchorMask & (1u << anchorIndex)) == 0u) continue;
		currentWeight = SmokeTransientFireLightBlend(group, group.AgeSeconds,
			currentAnchors[anchorIndex]);
		break;
	}
	if (currentWeight >= 1.0)
		return false;

	const bool previousBankB =
		(currentHeader.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_BANK_B) == 0u;
	uint anchorCapacity, anchorStride;
	if (previousBankB) gSmokeTransientLightAnchorsB.GetDimensions(anchorCapacity, anchorStride);
	else gSmokeTransientLightAnchorsA.GetDimensions(anchorCapacity, anchorStride);
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
	{
		if ((group.RequiredAnchorMask & (1u << anchorIndex)) == 0u)
			continue;
		const uint inputIndex = group.Slot * NRI_SMOKE_TRANSIENT_ANCHOR_COUNT + anchorIndex;
		if (inputIndex >= anchorCapacity)
		{
			currentWeight = 1.0;
			return false;
		}
		if (previousBankB) previousAnchors[anchorIndex] = gSmokeTransientLightAnchorsB[inputIndex];
		else previousAnchors[anchorIndex] = gSmokeTransientLightAnchorsA[inputIndex];
		if (!SmokeTransientAnchorIdentityMatches(previousAnchors[anchorIndex], group, anchorIndex) ||
			!SmokeTransientFireAnchorRevisionMatches(previousAnchors[anchorIndex], group))
		{
			currentWeight = 1.0;
			return false;
		}
	}
	return true;
}

void SmokeTransientResolveIncident(float3 position, SmokeTransientGroup group,
	SmokeTransientLightAnchor anchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT],
	out float3 incidentLobes[6], out float directionalTransport)
{
	[unroll]
	for (uint lobe = 0u; lobe < 6u; ++lobe)
		incidentLobes[lobe] = 0.0;
	directionalTransport = 0.0;
	float weights[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT];
	float weightSum = 0.0;
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
	{
		if ((group.RequiredAnchorMask & (1u << anchorIndex)) == 0u)
		{
			weights[anchorIndex] = 0.0;
			continue;
		}
		// Radiance and scene visibility remain frozen at the one-off build, but
		// interpolate them as a group-local field which advects and expands with
		// the current bounds. This preserves the cached gradient topology without
		// issuing refresh rays or making cache identity camera-dependent.
		const float3 currentAnchorPosition = SmokeTransientAnchorPosition(anchorIndex,
			group.BoundsMin, group.BoundsMax);
		const float distanceSquared = dot(position - currentAnchorPosition,
			position - currentAnchorPosition);
		weights[anchorIndex] = rcp(max(distanceSquared, 0.01));
		weightSum += weights[anchorIndex];
	}
	[unroll]
	for (uint anchorIndex = 0u; anchorIndex < NRI_SMOKE_TRANSIENT_ANCHOR_COUNT; ++anchorIndex)
	{
		const float weight = weights[anchorIndex] / max(weightSum, 1e-6);
		[unroll]
		for (uint lobe = 0u; lobe < 6u; ++lobe)
			incidentLobes[lobe] += SmokeTransientLightLobe(anchors[anchorIndex], lobe) * weight;
		if (group.TransientClass == NRI_SMOKE_TRANSIENT_CLASS_FIRE)
			directionalTransport += SmokeTransientFireDirectionalTransport(
				anchors[anchorIndex]) * weight;
	}
}

void SmokeTransientObserveGroup(SmokeTransientGroup group,
	SmokeTransientLightHeader header, bool cacheValid)
{
	uint headerCapacity, headerStride;
	gSmokeTransientLightHeaders.GetDimensions(headerCapacity, headerStride);
	if (group.Slot >= headerCapacity)
		return;
	uint originalFrame;
	// Cache loads can see another froxel's current-frame observation. Comparing
	// against that loaded value would let current->current CAS count twice.
	InterlockedExchange(gSmokeTransientLightHeaders[group.Slot].ObservedFrame,
		gSmokeConstants.FrameIndex, originalFrame);
	if (originalFrame == gSmokeConstants.FrameIndex)
		return;
	if (!cacheValid)
	{
		if ((header.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_VALID) != 0u)
			InterlockedAdd(gSmokeControl[0].TransientLightIdentityRejects, 1u);
		else
			InterlockedAdd(gSmokeControl[0].TransientLightMissing, 1u);
		return;
	}
	InterlockedAdd(gSmokeControl[0].TransientLightObservedGroups, 1u);
	if ((header.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_FULL) != 0u)
		InterlockedAdd(gSmokeControl[0].TransientLightObservedFull, 1u);
	else
		InterlockedAdd(gSmokeControl[0].TransientLightObservedFallback, 1u);
}

[numthreads(4, 4, 4)]
void main(uint3 froxel : SV_DispatchThreadID)
{
	if (froxel.x >= gSmokeConstants.FroxelWidth ||
		froxel.y >= gSmokeConstants.FroxelHeight ||
		froxel.z >= gSmokeConstants.FroxelDepth)
		return;
	if (all(froxel == 0u))
	{
		const uint dispatchedFroxels = gSmokeConstants.FroxelWidth *
			gSmokeConstants.FroxelHeight * gSmokeConstants.FroxelDepth;
		InterlockedAdd(gSmokeControl[0].TransientMaterializeFroxelsTested,
			dispatchedFroxels);
	}
	const uint3 binCount = SmokeTransientBinCount(uint3(gSmokeConstants.FroxelWidth,
		gSmokeConstants.FroxelHeight, gSmokeConstants.FroxelDepth));
	if (any(binCount == 0u)) return;
	const uint3 bin = uint3(froxel.xy / NRI_SMOKE_TRANSIENT_BIN_SIZE_XY,
		froxel.z / NRI_SMOKE_TRANSIENT_BIN_SIZE_Z);
	const uint binIndex = SmokeTransientBinIndex(bin, binCount);
	uint binHeaderCapacity, binHeaderStride, binIndexCapacity, binIndexStride;
	gSmokeTransientBinHeaders.GetDimensions(binHeaderCapacity, binHeaderStride);
	gSmokeTransientBinIndices.GetDimensions(binIndexCapacity, binIndexStride);
	if (binIndex >= binHeaderCapacity) return;
	const uint candidateCount = min(gSmokeTransientBinHeaders[binIndex].Count,
		NRI_SMOKE_TRANSIENT_MAX_GROUPS_PER_BIN);
	if (candidateCount == 0u) return;

	const float nearDepth = SmokeSliceNearDepth(froxel.z);
	const float farDepth = SmokeSliceFarDepth(froxel.z);
	const float3 ray = SmokeFroxelRay(froxel.xy);
	const float3 viewRay = normalize(ray);
	const float3 samplePosition = SmokeFroxelCenter(froxel, ray);
	float extinction = 0.0;
	float3 scattering = 0.0;
	float3 source = 0.0;
	float weightedAnisotropy = 0.0;
	float anisotropyWeight = 0.0;
	uint contributors = 0u;
	uint lobeTests = 0u;
	uint lobeContributions = 0u;
	uint groupCapacity, groupStride, lobeCapacity, lobeStride;
	gSmokeTransientGroups.GetDimensions(groupCapacity, groupStride);
	gSmokeTransientLobes.GetDimensions(lobeCapacity, lobeStride);
	const uint activeGroupCount = min(NRI_SMOKE_TRANSIENT_GROUP_COUNT,
		min(groupCapacity, NRI_SMOKE_TRANSIENT_MAX_GROUPS));
	const uint activeLobeCount = min(NRI_SMOKE_TRANSIENT_LOBE_COUNT,
		min(lobeCapacity, NRI_SMOKE_TRANSIENT_MAX_LOBES));

	[loop]
	for (uint candidate = 0u; candidate < candidateCount; ++candidate)
	{
		const uint listIndex = binIndex * NRI_SMOKE_TRANSIENT_MAX_GROUPS_PER_BIN + candidate;
		if (listIndex >= binIndexCapacity) break;
		const uint groupIndex = gSmokeTransientBinIndices[listIndex];
		if (groupIndex >= activeGroupCount) continue;
		const SmokeTransientGroup group = gSmokeTransientGroups[groupIndex];
		if ((group.Flags & NRI_SMOKE_TRANSIENT_GROUP_ACTIVE) == 0u ||
			group.Epoch != gSmokeConstants.SimulationEpoch || group.LobeCount == 0u)
			continue;
		if (!SmokeTransientRaySegmentIntersectsAabb(ray, nearDepth, farDepth,
			group.BoundsMin, group.BoundsMax)) continue;

		SmokeTransientLightHeader lightHeader = (SmokeTransientLightHeader)0;
		SmokeTransientLightAnchor lightAnchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT];
		SmokeTransientLightAnchor previousLightAnchors[NRI_SMOKE_TRANSIENT_ANCHOR_COUNT];
		bool cacheLoaded = false;
		bool cacheValid = false;
		float3 incidentLobes[6];
		float directionalTransport = 0.0;
		bool groupContributed = false;
		float3 groupSource = 0.0;
		const uint endLobe = min(group.FirstLobe + min(group.LobeCount,
			NRI_SMOKE_TRANSIENT_MAX_LOBES_PER_GROUP), activeLobeCount);
		[loop]
		for (uint lobeIndex = group.FirstLobe; lobeIndex < endLobe; ++lobeIndex)
		{
			lobeTests++;
			const SmokeTransientLobe lobe = gSmokeTransientLobes[lobeIndex];
			if ((lobe.Flags & NRI_SMOKE_TRANSIENT_LOBE_ACTIVE) == 0u ||
				lobe.GroupSlot != group.Slot || lobe.GroupGeneration != group.Generation ||
				lobe.Epoch != group.Epoch || lobe.StyleIndex >= gSmokeConstants.StyleCount ||
				!isfinite(lobe.Radius) || lobe.Radius <= 0.0 ||
				!isfinite(lobe.DensityScale) || lobe.DensityScale <= 0.0)
				continue;
			const float kernel = lobe.Shape == NRI_SMOKE_INJECTION_SHAPE_RECTANGLE
				? SmokeTransientRectangleKernelAverage(lobe, ray, nearDepth, farDepth)
				: SmokeTransientSphereKernelAverage(lobe, ray, nearDepth, farDepth);
			if (kernel <= 0.0) continue;
			const SmokeStyle style = gSmokeStyles[lobe.StyleIndex];
			const float density = max(style.Density, 0.0) * lobe.DensityScale;
			const float sigmaT = kernel * density * max(style.Extinction, 0.0) *
				gSmokeConstants.DensityScale;
			if (!(sigmaT > 1e-6) || !isfinite(sigmaT)) continue;
			const float3 sigmaS = sigmaT * saturate(style.Albedo);
			float3 externalSource = 0.0;
			if (!cacheLoaded)
			{
				cacheLoaded = true;
				cacheValid = SmokeTransientLoadCache(group, lightHeader, lightAnchors);
				if (cacheValid)
				{
					SmokeTransientResolveIncident(samplePosition, group, lightAnchors,
						incidentLobes, directionalTransport);
					float currentWeight;
					if (SmokeTransientLoadPreviousFireCache(group, lightHeader, lightAnchors,
						previousLightAnchors, currentWeight))
					{
						float3 previousIncidentLobes[6];
						float previousDirectionalTransport;
						SmokeTransientResolveIncident(samplePosition, group, previousLightAnchors,
							previousIncidentLobes, previousDirectionalTransport);
						[unroll]
						for (uint incidentIndex = 0u; incidentIndex < 6u; ++incidentIndex)
							incidentLobes[incidentIndex] = lerp(previousIncidentLobes[incidentIndex],
								incidentLobes[incidentIndex], currentWeight);
						directionalTransport = lerp(previousDirectionalTransport,
							directionalTransport, currentWeight);
					}
				}
			}
			if (cacheValid)
			{
				[unroll]
				for (uint incidentIndex = 0u; incidentIndex < 6u; ++incidentIndex)
					externalSource += sigmaS * incidentLobes[incidentIndex] *
						SmokePhaseResponse(dot(NRI_SMOKE_TRANSIENT_LIGHT_AXES[incidentIndex],
							viewRay), style.Anisotropy);
				if (group.TransientClass == NRI_SMOKE_TRANSIENT_CLASS_FIRE &&
					gSmokeConstants.LightMode > 0u &&
					(gSmokeConstants.LightSourceFlags & NRI_SMOKE_LIGHT_SOURCE_DIRECTIONAL) != 0u)
				{
					// Directional scene/self visibility remains a bounded group-cache result,
					// while current sun color/direction is cheap analytic work with no rays.
					const float3 direction = SmokeDirectionalDirection();
					externalSource += sigmaS * SmokeDirectionalColor() * directionalTransport *
						SmokePhaseResponse(dot(direction, viewRay), style.Anisotropy);
				}
			}
			const float3 intrinsicSource = sigmaT * max(lobe.EmissionScale, 0.0) *
				SmokeTransientIntrinsicColor(lobe.TransientClass);
			extinction += sigmaT;
			scattering += sigmaS;
			groupSource += max(externalSource + intrinsicSource, 0.0);
			const float weight = dot(sigmaS, float3(0.2126, 0.7152, 0.0722));
			weightedAnisotropy += weight * clamp(style.Anisotropy, -0.95, 0.95);
			anisotropyWeight += weight;
			contributors++;
			groupContributed = true;
			lobeContributions++;
		}
		source += min(groupSource, 32.0) * max(gSmokeConstants.RadianceScale, 0.0);
		// Candidate iteration is not a group identity: lanes in the same wave can
		// be visiting different bins and therefore different group slots here.
		// Let every contributing lane exchange the per-group frame word. The first
		// lane for each distinct group claims telemetry; later lanes return early.
		if (groupContributed)
			SmokeTransientObserveGroup(group, lightHeader, cacheValid);
	}
	const uint waveLobeTests = WaveActiveSum(lobeTests);
	const uint waveLobeContributions = WaveActiveSum(lobeContributions);
	if (WaveIsFirstLane())
	{
		InterlockedAdd(gSmokeControl[0].TransientMaterializeLobeTests, waveLobeTests);
		InterlockedAdd(gSmokeControl[0].TransientMaterializeLobeContributions,
			waveLobeContributions);
	}
	if (!(extinction > 1e-6)) return;

	const uint froxelIndex = SmokeFroxelIndex(froxel.x, froxel.y, froxel.z);
	uint mediumCapacity, mediumStride, transientCapacity, transientStride;
	uint phaseCapacity, phaseStride, sourceCapacity, sourceStride;
	gSmokeFroxelMedium.GetDimensions(mediumCapacity, mediumStride);
	gSmokeTransientFroxelMedium.GetDimensions(transientCapacity, transientStride);
	gSmokeFroxelPhase.GetDimensions(phaseCapacity, phaseStride);
	gSmokeFroxelSource.GetDimensions(sourceCapacity, sourceStride);
	if (froxelIndex >= min(min(mediumCapacity, transientCapacity),
		min(phaseCapacity, sourceCapacity))) return;
	const float4 previousMedium = gSmokeFroxelMedium[froxelIndex];
	const float4 previousPhase = gSmokeFroxelPhase[froxelIndex];
	const float4 previousSource = gSmokeFroxelSource[froxelIndex];
	const bool wasOccupied = previousMedium.w > 1e-6;
	const float4 transientMedium = float4(scattering, extinction);
	gSmokeTransientFroxelMedium[froxelIndex] = transientMedium;
	gSmokeFroxelMedium[froxelIndex] = previousMedium + transientMedium;
	const float previousWeight = max(previousPhase.y, 0.0);
	const float combinedWeight = previousWeight + anisotropyWeight;
	const float anisotropy = combinedWeight > 1e-6
		? (previousPhase.x * previousWeight + weightedAnisotropy) / combinedWeight : 0.0;
	gSmokeFroxelPhase[froxelIndex] = float4(anisotropy, combinedWeight,
		max(previousPhase.z, 0.0) + (float)contributors,
		(float)(SmokeFroxelCarrierOwnership(previousPhase) | NRI_SMOKE_FROXEL_CARRIER_TRANSIENT));
	uint metadata = SmokeFroxelMetadata(previousSource.w);
	if (!wasOccupied || !SmokeFroxelCarrierValid(metadata))
	{
		metadata = SmokeFroxelCarrierMetadata(gSmokeConstants.SimulationEpoch);
		metadata = SmokeFroxelResolveRadiance(metadata, gSmokeConstants.SimulationEpoch,
			NRI_SMOKE_FALLBACK_ANALYTIC, 0u);
	}
	gSmokeFroxelSource[froxelIndex] = float4(max(previousSource.rgb, 0.0) + source,
		SmokeFroxelMetadataValue(metadata));
	if (!wasOccupied)
	{
		uint occupiedCapacity, occupiedStride, occupiedSlot;
		gSmokeOccupiedFroxelIndices.GetDimensions(occupiedCapacity, occupiedStride);
		InterlockedAdd(gSmokeControl[0].OccupiedCount, 1u, occupiedSlot);
		if (occupiedSlot < occupiedCapacity)
			gSmokeOccupiedFroxelIndices[occupiedSlot] = froxelIndex;
		else
			InterlockedAdd(gSmokeControl[0].OccupiedOverflow, 1u);
	}
	const uint waveApplied = WaveActiveSum(1u);
	if (WaveIsFirstLane())
		InterlockedAdd(gSmokeControl[0].TransientMaterializeFroxelsApplied, waveApplied);
}
