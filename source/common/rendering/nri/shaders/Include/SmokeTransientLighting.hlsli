#ifndef NRI_SMOKE_TRANSIENT_LIGHTING_HLSLI
#define NRI_SMOKE_TRANSIENT_LIGHTING_HLSLI

#include "SmokeTransientData.hlsli"

static const float3 NRI_SMOKE_TRANSIENT_LIGHT_AXES[6] = {
	float3(1.0, 0.0, 0.0), float3(-1.0, 0.0, 0.0),
	float3(0.0, 1.0, 0.0), float3(0.0, -1.0, 0.0),
	float3(0.0, 0.0, 1.0), float3(0.0, 0.0, -1.0)
};

uint SmokeTransientLightWord(SmokeTransientLightAnchor record, uint index)
{
	if (index < 4u) return record.Data0[index];
	if (index < 8u) return record.Data1[index - 4u];
	if (index < 12u) return record.Data2[index - 8u];
	return record.Data3[index - 12u];
}

void SmokeTransientLightStoreWord(inout SmokeTransientLightAnchor record, uint index, uint value)
{
	if (index < 4u) record.Data0[index] = value;
	else if (index < 8u) record.Data1[index - 4u] = value;
	else if (index < 12u) record.Data2[index - 8u] = value;
	else record.Data3[index - 12u] = value;
}

void SmokeTransientLightStoreHalf(inout SmokeTransientLightAnchor record, uint halfIndex, float value)
{
	const uint wordIndex = halfIndex >> 1u;
	const uint oldWord = SmokeTransientLightWord(record, wordIndex);
	const uint packed = f32tof16(clamp(isfinite(value) ? value : 0.0, 0.0, 65504.0));
	SmokeTransientLightStoreWord(record, wordIndex, (halfIndex & 1u) == 0u
		? (oldWord & 0xffff0000u) | packed
		: (oldWord & 0x0000ffffu) | (packed << 16u));
}

void SmokeTransientLightStoreLobe(inout SmokeTransientLightAnchor record, uint lobe, float3 value)
{
	const uint base = min(lobe, 5u) * 3u;
	SmokeTransientLightStoreHalf(record, base, value.x);
	SmokeTransientLightStoreHalf(record, base + 1u, value.y);
	SmokeTransientLightStoreHalf(record, base + 2u, value.z);
}

float SmokeTransientLightLoadHalf(SmokeTransientLightAnchor record, uint halfIndex)
{
	const uint word = SmokeTransientLightWord(record, halfIndex >> 1u);
	return f16tof32((halfIndex & 1u) == 0u ? word & 0xffffu : word >> 16u);
}

float3 SmokeTransientLightLobe(SmokeTransientLightAnchor record, uint lobe)
{
	const uint base = min(lobe, 5u) * 3u;
	return float3(SmokeTransientLightLoadHalf(record, base),
		SmokeTransientLightLoadHalf(record, base + 1u),
		SmokeTransientLightLoadHalf(record, base + 2u));
}

float3 SmokeTransientLightAnchorPosition(SmokeTransientLightAnchor record)
{
	return asfloat(uint3(record.Data2.y, record.Data2.z, record.Data2.w));
}

bool SmokeTransientAnchorIdentityMatches(SmokeTransientLightAnchor record,
	SmokeTransientGroup group, uint anchorIndex)
{
	return record.Data3.x == group.Slot && record.Data3.y == group.Generation &&
		record.Data3.z == group.Epoch &&
		(record.Data3.w & NRI_SMOKE_TRANSIENT_ANCHOR_WRITTEN) != 0u &&
		(record.Data3.w & 3u) == anchorIndex;
}

bool SmokeTransientHeaderIdentityMatches(SmokeTransientLightHeader header,
	SmokeTransientGroup group)
{
	return (header.PublishedState & NRI_SMOKE_TRANSIENT_LIGHT_VALID) != 0u &&
		header.GroupSlot == group.Slot && header.GroupGeneration == group.Generation &&
		header.Epoch == group.Epoch && header.RequiredAnchorMask == group.RequiredAnchorMask &&
		header.PublishedAnchorMask == group.RequiredAnchorMask &&
		header.ShapeRevision == SmokeTransientShapeRevision(group) &&
		header.LightingBoundsRevision == SmokeTransientLightingBoundsRevision(group);
}

float3 SmokeTransientAnchorPosition(uint anchorIndex, float3 lower, float3 upper)
{
	const float3 center = (lower + upper) * 0.5;
	const float3 extent = (upper - lower) * 0.2886751346;
	if (anchorIndex == 0u) return center + extent * float3(1.0, 1.0, 1.0);
	if (anchorIndex == 1u) return center + extent * float3(-1.0, -1.0, 1.0);
	if (anchorIndex == 2u) return center + extent * float3(-1.0, 1.0, -1.0);
	return center + extent * float3(1.0, -1.0, -1.0);
}

void SmokeTransientAccumulateIncident(float3 incident, float3 lightDirection,
	inout float3 lobes[6])
{
	float weights[6];
	float sum = 0.0;
	const float3 direction = normalize(lightDirection);
	[unroll]
	for (uint lobe = 0u; lobe < 6u; ++lobe)
	{
		weights[lobe] = max(dot(direction, NRI_SMOKE_TRANSIENT_LIGHT_AXES[lobe]), 0.0);
		sum += weights[lobe];
	}
	[unroll]
	for (uint lobe = 0u; lobe < 6u; ++lobe)
		lobes[lobe] += max(incident, 0.0) * weights[lobe] / max(sum, 1e-6);
}

// Exact line integrals for a unit plateau plus parabolic shell. Core remains
// untouched by boundary noise, preventing high-frequency holes through the cloud.
void SmokeTransientSpherePlateauIntegral(float3 center, float radius, float plateau,
	float3 rayOrigin, float3 unitRay, float segmentNear, float segmentFar,
	out float coreIntegral, out float shellIntegral)
{
	coreIntegral = 0.0;
	shellIntegral = 0.0;
	const float safeRadius = max(radius, 0.001);
	const float radiusSquared = safeRadius * safeRadius;
	const float3 originToCenter = center - rayOrigin;
	const float closest = dot(originToCenter, unitRay);
	const float3 perpendicular = rayOrigin + unitRay * closest - center;
	const float perpendicularSquared = dot(perpendicular, perpendicular);
	if (perpendicularSquared >= radiusSquared)
		return;
	const float outerHalfChord = sqrt(max(radiusSquared - perpendicularSquared, 0.0));
	const float q0 = max(segmentNear - closest, -outerHalfChord);
	const float q1 = min(segmentFar - closest, outerHalfChord);
	if (q1 <= q0)
		return;

	const float p = clamp(plateau, 0.0, 0.95);
	const float coreRadiusSquared = radiusSquared * p * p;
	const float denominator = max(radiusSquared - coreRadiusSquared, radiusSquared * 0.0975);
	const float radial = radiusSquared - perpendicularSquared;
	const float shellPrimitive0 = (radial * q0 - q0 * q0 * q0 / 3.0) / denominator;
	const float shellPrimitive1 = (radial * q1 - q1 * q1 * q1 / 3.0) / denominator;
	shellIntegral = max(shellPrimitive1 - shellPrimitive0, 0.0);
	if (perpendicularSquared < coreRadiusSquared)
	{
		const float coreHalfChord = sqrt(max(coreRadiusSquared - perpendicularSquared, 0.0));
		const float c0 = max(q0, -coreHalfChord);
		const float c1 = min(q1, coreHalfChord);
		if (c1 > c0)
		{
			const float shellCore0 = (radial * c0 - c0 * c0 * c0 / 3.0) / denominator;
			const float shellCore1 = (radial * c1 - c1 * c1 * c1 / 3.0) / denominator;
			coreIntegral = c1 - c0;
			shellIntegral = max(shellIntegral - max(shellCore1 - shellCore0, 0.0), 0.0);
		}
	}
}

uint SmokeTransientHash(uint value)
{
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	return value ^ (value >> 16u);
}

float SmokeTransientBoundaryNoise(float3 worldPosition, float scale, uint seed)
{
	const float3 lattice = worldPosition * max(scale, 0.0001);
	const int3 base = int3(floor(lattice));
	const float3 f = frac(lattice);
	const float3 blend = f * f * (3.0 - 2.0 * f);
	float values[8];
	[unroll]
	for (uint corner = 0u; corner < 8u; ++corner)
	{
		const int3 cell = base + int3(corner & 1u, (corner >> 1u) & 1u,
			(corner >> 2u) & 1u);
		const uint3 bits = asuint(cell);
		const uint hash = SmokeTransientHash(bits.x ^ SmokeTransientHash(bits.y) ^
			SmokeTransientHash(bits.z) ^ SmokeTransientHash(seed));
		values[corner] = (float)(hash & 0x00ffffffu) / 16777215.0;
	}
	const float x00 = lerp(values[0], values[1], blend.x);
	const float x10 = lerp(values[2], values[3], blend.x);
	const float x01 = lerp(values[4], values[5], blend.x);
	const float x11 = lerp(values[6], values[7], blend.x);
	return lerp(lerp(x00, x10, blend.y), lerp(x01, x11, blend.y), blend.z);
}

float SmokeTransientSphereKernelAverage(SmokeTransientLobe lobe, float3 ray,
	float nearDepth, float farDepth)
{
	const float rayLength = max(length(ray), 1e-6);
	const float3 unitRay = ray / rayLength;
	float coreIntegral, shellIntegral;
	SmokeTransientSpherePlateauIntegral(lobe.Position, lobe.Radius, lobe.CorePlateau,
		gSmokeConstants.CameraPosition, unitRay, nearDepth * rayLength, farDepth * rayLength,
		coreIntegral, shellIntegral);
	const float segmentLength = max((farDepth - nearDepth) * rayLength, 1e-6);
	if (shellIntegral > 0.0 && lobe.EdgeErosion > 0.0 && lobe.NoiseStrength > 0.0)
	{
		const float3 samplePosition = gSmokeConstants.CameraPosition + ray * ((nearDepth + farDepth) * 0.5);
		const float noise = SmokeTransientBoundaryNoise(samplePosition,
			lobe.NoiseScale, lobe.DeterministicSeed);
		const float erosion = saturate(lobe.EdgeErosion * lobe.NoiseStrength);
		// Only the shell is eroded, and its floor remains non-zero.
		shellIntegral *= lerp(1.0, 0.35 + 0.65 * noise, erosion);
	}
	return max((coreIntegral + shellIntegral) / segmentLength, 0.0);
}

bool SmokeTransientRaySegmentIntersectsAabb(float3 ray, float nearDepth, float farDepth,
	float3 lower, float3 upper)
{
	float entry = nearDepth;
	float exit = farDepth;
	[unroll]
	for (uint axis = 0u; axis < 3u; ++axis)
	{
		const float origin = gSmokeConstants.CameraPosition[axis];
		const float direction = ray[axis];
		if (abs(direction) <= 1e-8)
		{
			if (origin < lower[axis] || origin > upper[axis]) return false;
			continue;
		}
		const float inverseDirection = rcp(direction);
		const float t0 = (lower[axis] - origin) * inverseDirection;
		const float t1 = (upper[axis] - origin) * inverseDirection;
		entry = max(entry, min(t0, t1));
		exit = min(exit, max(t0, t1));
		if (exit <= entry) return false;
	}
	return exit > entry;
}

float SmokeTransientRectangleKernelAverage(SmokeTransientLobe lobe, float3 ray,
	float nearDepth, float farDepth)
{
	float result = 0.0;
	[unroll]
	for (uint sampleIndex = 0u; sampleIndex < 4u; ++sampleIndex)
	{
		const float depth = lerp(nearDepth, farDepth, ((float)sampleIndex + 0.5) * 0.25);
		const float3 position = gSmokeConstants.CameraPosition + ray * depth;
		const float3 closest = SmokeInjectionClosestRectanglePoint(position, lobe.Position,
			lobe.HalfAxisU, lobe.HalfAxisV);
		const float normalized = saturate(distance(position, closest) / max(lobe.Radius, 0.001));
		const float plateau = clamp(lobe.CorePlateau, 0.0, 0.95);
		const float shell = saturate((1.0 - normalized) / max(1.0 - plateau, 0.05));
		result += normalized <= plateau ? 1.0 : shell * shell * (3.0 - 2.0 * shell);
	}
	return result * 0.25;
}

float SmokeTransientGroupOpticalDepth(SmokeTransientGroup group, float3 origin,
	float3 lightDirection, float maximumDistance)
{
	float opticalDepth = 0.0;
	const float3 direction = normalize(lightDirection);
	uint lobeCapacity, lobeStride;
	gSmokeTransientLobes.GetDimensions(lobeCapacity, lobeStride);
	const uint endLobe = min(group.FirstLobe + min(group.LobeCount,
		NRI_SMOKE_TRANSIENT_MAX_LOBES_PER_GROUP), lobeCapacity);
	[loop]
	for (uint lobeIndex = group.FirstLobe; lobeIndex < endLobe; ++lobeIndex)
	{
		const SmokeTransientLobe lobe = gSmokeTransientLobes[lobeIndex];
		if ((lobe.Flags & NRI_SMOKE_TRANSIENT_LOBE_ACTIVE) == 0u ||
			lobe.GroupSlot != group.Slot || lobe.GroupGeneration != group.Generation ||
			lobe.Epoch != group.Epoch || lobe.StyleIndex >= gSmokeConstants.StyleCount)
			continue;
		float coreIntegral, shellIntegral;
		const float supportRadius = lobe.Shape == NRI_SMOKE_INJECTION_SHAPE_RECTANGLE
			? lobe.Radius + length(lobe.HalfAxisU) + length(lobe.HalfAxisV) : lobe.Radius;
		SmokeTransientSpherePlateauIntegral(lobe.Position, supportRadius, lobe.CorePlateau,
			origin, direction, 0.001, maximumDistance, coreIntegral, shellIntegral);
		const SmokeStyle style = gSmokeStyles[lobe.StyleIndex];
		opticalDepth += (coreIntegral + shellIntegral) * max(lobe.DensityScale, 0.0) *
			max(style.Density, 0.0) * max(style.Extinction, 0.0) * gSmokeConstants.DensityScale;
	}
	return max(isfinite(opticalDepth) ? opticalDepth : 0.0, 0.0);
}

float3 SmokeTransientIntrinsicColor(uint transientClass)
{
	// Explosion, fire, muzzle, and impact emission share a bounded warm source;
	// authored EmissionScale controls its intensity and decay.
	return transientClass == 1u ? float3(0.80, 0.30, 0.06) : float3(1.0, 0.34, 0.07);
}

#endif
