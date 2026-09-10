$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
function Read-RepoFile([string]$relativePath) {
    Get-Content -Raw (Join-Path $root $relativePath)
}
function Require-Match([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}
function Require-NoMatch([string]$text, [string]$pattern, [string]$message) {
    if ($text -match $pattern) { throw $message }
}

$data = Read-RepoFile 'source/common/rendering/nri/shaders/Include/SmokeTransientData.hlsli'
$lighting = Read-RepoFile 'source/common/rendering/nri/shaders/Include/SmokeTransientLighting.hlsli'
$clear = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientClear.cs.hlsl'
$bins = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientBuildBins.cs.hlsl'
$build = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientLightBuild.cs.hlsl'
$materialize = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientMaterialize.cs.hlsl'

Require-Match $data 'NRI_SMOKE_TRANSIENT_MAX_GROUPS\s+64u' 'Transient group capacity changed from the CPU fixed pool.'
Require-Match $data 'NRI_SMOKE_TRANSIENT_MAX_LOBES\s+256u' 'Transient lobe capacity changed from the CPU fixed pool.'
Require-Match $data 'NRI_SMOKE_TRANSIENT_BIN_SIZE_XY\s+4u[\s\S]*NRI_SMOKE_TRANSIENT_BIN_SIZE_Z\s+4u' 'Transient bins are not 4x4x4.'
Require-Match $data 'gSmokeTransientGroups\s*:\s*register\(t3, space0\)' 'Transient groups are not bound at t3/space0.'
Require-Match $data 'gSmokeTransientLobes\s*:\s*register\(t4, space0\)' 'Transient lobes are not bound at t4/space0.'
foreach ($binding in @(
    @('gSmokeTransientBinHeaders', 61), @('gSmokeTransientBinIndices', 62),
    @('gSmokeTransientFroxelMedium', 63), @('gSmokeTransientLightAnchorsA', 64),
    @('gSmokeTransientLightAnchorsB', 65), @('gSmokeTransientLightHeaders', 66))) {
    Require-Match $data (('{0}\s*:\s*register\(u{1}, space1\)' -f $binding[0], $binding[1])) "Missing transient UAV $($binding[0]) at u$($binding[1])."
}
Require-Match $data 'struct SmokeTransientLightHeader\s*\{[\s\S]*uint GroupSlot;[\s\S]*uint FamilySuccessMask;[\s\S]*\};' 'The complete 64-byte light header contract is missing.'
Require-Match $data 'NRI_SMOKE_TRANSIENT_LIGHT_VALID\s+0x80000000u' 'Transient light validity is not an explicit publish-last bit.'
Require-Match $data 'NRI_SMOKE_TRANSIENT_SELF_SHADOW\s+0x200u' 'Transient self-shadowing is not independently controlled by the renderer light-source flags.'
foreach ($alias in @(
    @('GROUP_COUNT', 'CommandCount'), @('LOBE_COUNT', 'ParticleCapacity'),
    @('FULL_BUILD_BUDGET', 'MaxLightCandidates'), @('POINT_BUDGET', 'LightSamples'))) {
    Require-Match $data (('NRI_SMOKE_TRANSIENT_{0}\s+gSmokeConstants\.{1}' -f $alias[0], $alias[1])) "Missing pass-local ABI alias $($alias[0])."
}

Require-Match $clear 'Flags\s*&\s*1u[\s\S]*gSmokeTransientLightHeaders' 'Persistent cache headers are not reset on a fresh allocation/epoch reset.'
Require-NoMatch $clear 'gSmokeTransientLightAnchors[AB]\s*\[' 'Per-frame clear must not erase persistent light anchors.'
Require-Match $bins 'minimumSlice[\s\S]*maximumSlice[\s\S]*NRI_SMOKE_TRANSIENT_BIN_SIZE_Z' 'Transient binning does not conservatively retain depth bounds.'
Require-Match $bins 'NRI_SMOKE_TRANSIENT_MAX_GROUPS_PER_BIN' 'Transient bins are not bounded by fixed group capacity.'
Require-NoMatch $bins 'MAX_LOBES_PER_BIN|256u\s*\+\s*slot' 'Transient bin storage regressed to a lobe-sized list per cluster.'

Require-Match $lighting 'SmokeTransientSpherePlateauIntegral[\s\S]*coreIntegral[\s\S]*shellIntegral' 'The exact compact-core/shell sphere integral is missing.'
Require-Match $lighting 'shellIntegral\s*\*=\s*lerp' 'Boundary detail is not isolated to the shell integral.'
Require-Match $lighting 'SmokeTransientBoundaryErosionAmplitude[\s\S]*1\.0\s*-\s*\(1\.0\s*-\s*edge\)\s*\*\s*\(1\.0\s*-\s*strength\)' 'Independent boundary controls are not combined into a useful bounded amplitude.'
Require-NoMatch $lighting 'EdgeErosion\s*\*\s*lobe\.NoiseStrength|lobe\.EdgeErosion\s*\*\s*NoiseStrength' 'Boundary amplitude regressed to the imperceptible product of authored controls.'
Require-Match $lighting 'shellIntegral\s*>\s*0\.0\s*&&\s*\(lobe\.EdgeErosion\s*>\s*0\.0\s*\|\|\s*lobe\.NoiseStrength\s*>\s*0\.0\)' 'Either independent boundary control must activate shell modulation.'
Require-NoMatch $lighting 'lobe\.EdgeErosion\s*>\s*0\.0\s*&&\s*lobe\.NoiseStrength\s*>\s*0\.0' 'Boundary modulation incorrectly requires both independent controls.'
Require-NoMatch $lighting 'NoiseScale\s*\*\s*lobe\.Radius|lobe\.NoiseScale\s*\*\s*lobe\.Radius' 'Noise frequency changes as the lobe radius grows.'
Require-Match $lighting 'f\s*\*\s*f\s*\*\s*\(3\.0\s*-\s*2\.0\s*\*\s*f\)' 'Boundary noise is not smoothly interpolated in fixed space.'
Require-Match $lighting 'Materialization only removes shell mass[\s\S]*conservative upper optical-depth bound[\s\S]*opticalDepth\s*\+=\s*\(coreIntegral\s*\+\s*shellIntegral\)' 'Self-shadow optical depth must conservatively bound the boundary-eroded materialized medium.'
Require-Match $lighting 'header\.ShapeRevision\s*==\s*SmokeTransientShapeRevision\(group\)[\s\S]*header\.LightingBoundsRevision\s*==\s*SmokeTransientLightingBoundsRevision\(group\)' 'Cache identity does not reject stale shape or lighting-bounds revisions.'
Require-Match $lighting 'SmokeTransientAnchorPosition[\s\S]*\(upper\s*-\s*lower\)\s*\*\s*0\.07216878365' 'Transient cache anchors must retain the symmetric one-quarter-radius inset.'
Require-NoMatch $lighting 'SmokeTransientAnchorPosition[\s\S]{0,300}\(upper\s*-\s*lower\)\s*\*\s*0\.2886751346' 'Transient cache anchors regressed to the empty support-surface tetrahedron.'

Require-Match $build 'if\s*\(wantsFull\)[\s\S]*TransientLightFullBuildClaims' 'Fallback groups can consume the full-build budget.'
Require-Match $build 'previousValid\s*\?\s*!previousBankB\s*:\s*!fallbackBankB' 'A refresh can overwrite its active cache bank before publication.'
Require-Match $build 'DeviceMemoryBarrier\(\);[\s\S]*PublishedState\s*=\s*state' 'Light header validity is not published after completed anchor writes.'
Require-Match $build 'writtenMask\s*!=\s*group\.RequiredAnchorMask' 'A partial fallback can be published.'
Require-Match $build 'fullWrittenMask\s*!=\s*group\.RequiredAnchorMask' 'A partial full build can be published.'
Require-Match $build 'SmokeTransientSelectPointLights\(group\.Center' 'Point-light selection is not stable in group/world space.'
Require-Match $build 'uint\s+selectedCount\s*=\s*0u;[\s\S]*LightMode\s*>\s*0u[\s\S]*LightSourceFlags\s*&\s*NRI_SMOKE_LIGHT_SOURCE_POINT[\s\S]*NRI_SMOKE_TRANSIENT_POINT_BUDGET\s*!=\s*0u[\s\S]*SmokeTransientSelectPointLights' 'Point-light buffers can be read when the point-light descriptor set is unavailable.'
Require-Match $build 'environment\s*=\s*all\(isfinite\(sampled\)\)\s*\?\s*max\(sampled,\s*0\.0\)\s*:\s*0\.0[\s\S]*cubemapQuadratureWeight\s*=\s*2\.094395' 'Optional sky lighting must use zero-preserving six-axis solid-angle quadrature.'
Require-NoMatch $build 'max\(sampled,\s*0\.02|:\s*0\.02\.xxx' 'A black sky must not acquire an artificial transient ambient floor.'
Require-NoMatch $build 'gSmokeRuntimeLightTileHeaders|gSmokeRuntimeLightTileIndices' 'Transient cache selection acquired camera-tile identity.'
if ([regex]::Matches($build, 'fullBuild\s*&&\s*(?:group\.TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*&&\s*)?\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_TRANSIENT_SELF_SHADOW\)').Count -ne 3) {
    throw 'All three full-cache self-transmittance paths must honor nri_ptsmoketransientselfshadow through LightSourceFlags.'
}
Require-Match $build 'fullBuild\s*&&\s*group\.TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*&&\s*\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_TRANSIENT_SELF_SHADOW\)' 'Fire directional self attenuation must move out of the anchor build; other classes retain it.'
Require-Match $materialize 'LightSourceFlags\s*&\s*NRI_SMOKE_TRANSIENT_SELF_SHADOW[\s\S]*localSelfTransmittance\s*=\s*SmokeTransientSelfTransmittance' 'Local Fire self attenuation must honor the same independent self-shadow control.'

Require-Match $materialize 'SmokeTransientRaySegmentIntersectsAabb[\s\S]*cacheLoaded' 'Cache taps are not deferred until after conservative group rejection.'
Require-Match $materialize 'if\s*\(!cacheLoaded\)[\s\S]*SmokeTransientLoadCache' 'Anchor records are loaded before any positive lobe contribution.'
Require-Match $materialize 'currentAnchorPosition\s*=\s*SmokeTransientAnchorPosition\(anchorIndex,[\s\S]*group\.BoundsMin,\s*group\.BoundsMax\)' 'Frozen radiance is not interpolated in the current group-local bounds.'
Require-NoMatch $materialize 'SmokeTransientLightAnchorPosition\(anchors\[anchorIndex\]\)' 'Materialization regressed to frozen world-space anchor interpolation.'
$resolveStart = $materialize.IndexOf('void SmokeTransientResolveIncident')
$observeStart = $materialize.IndexOf('void SmokeTransientObserveGroup')
if ($resolveStart -lt 0 -or $observeStart -le $resolveStart) { throw 'Could not isolate transient incident-cache resolver.' }
$resolveIncident = $materialize.Substring($resolveStart, $observeStart - $resolveStart)
Require-NoMatch $resolveIncident 'gSmokeConstants\.CameraPosition' 'Group-local cache interpolation acquired camera-relative identity.'
Require-Match $materialize 'previousMedium\s*\+\s*transientMedium' 'Mixed grid/transient extinction and scattering are not additive.'
Require-Match $materialize 'max\(previousSource\.rgb,\s*0\.0\)\s*\+\s*source' 'Mixed grid/transient source is not additive.'
Require-Match $materialize 'previousPhase\.x\s*\*\s*previousWeight\s*\+\s*weightedAnisotropy' 'Mixed phase is not scattering-weighted.'
Require-Match $materialize 'if\s*\(!wasOccupied\)[\s\S]*OccupiedCount' 'Transient materialization can append duplicate occupied froxels.'
Require-Match $materialize 'group\.Slot\s*>=\s*headerCapacity[\s\S]*return;[\s\S]*InterlockedExchange[\s\S]*originalFrame\s*==\s*gSmokeConstants\.FrameIndex[\s\S]*return;[\s\S]*TransientLightObservedGroups' 'First-visible readiness must bounds-check group identity and reject repeated current-frame observations.'
Require-Match $materialize 'all\(froxel\s*==\s*0u\)[\s\S]*FroxelWidth\s*\*[\s\S]*FroxelHeight\s*\*\s*gSmokeConstants\.FroxelDepth[\s\S]*TransientMaterializeFroxelsTested' 'Tested-froxel telemetry must use one exact dispatch-sized atomic.'
Require-Match $materialize 'lobeTests\+\+;[\s\S]*lobeContributions\+\+;[\s\S]*WaveActiveSum\(lobeTests\)[\s\S]*WaveActiveSum\(lobeContributions\)' 'Per-lobe telemetry must be accumulated per lane and reduced per wave.'
Require-Match $materialize 'float3\s+groupSource\[4\];[\s\S]*groupSource\[lane\]\s*\+=\s*max\(externalSource\s*\+\s*intrinsicSource,\s*0\.0\);[\s\S]*laneSource\[lane\]\s*\+=\s*min\(groupSource\[lane\],\s*32\.0\)' 'Source radiance must be accumulated and clamped once per group/coverage lane, not once per lobe.'
Require-NoMatch $materialize 'source\s*\+=\s*min\(max\(externalSource\s*\+\s*intrinsicSource' 'Per-lobe source clamping breaks lobe-count invariance.'
Require-Match $materialize 'if\s*\(groupContributed\)[\s\S]*SmokeTransientObserveGroup\(group,\s*lightHeader,\s*cacheValid\)' 'Every contributing lane must attempt its own group-slot observation.'
Require-NoMatch $materialize 'WavePrefixCountBits\(groupContributed\)' 'Candidate-iteration wave aggregation can undercount heterogeneous group IDs.'
Require-Match $materialize 'waveApplied\s*=\s*WaveActiveSum\(1u\)[\s\S]*TransientMaterializeFroxelsApplied,\s*waveApplied' 'Applied-froxel telemetry must be reduced per active wave.'
Require-NoMatch $materialize 'TransientMaterialize(LobeTests|LobeContributions|FroxelsApplied),\s*1u' 'Transient materialization regressed to one global telemetry atomic per event.'
Require-NoMatch $materialize 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible' 'Transient cache application must issue zero scene rays.'

Write-Output 'Smoke transient shader structural tests passed.'
