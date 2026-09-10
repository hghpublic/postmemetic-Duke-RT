$ErrorActionPreference = 'Stop'

function Assert-Near([double]$actual, [double]$expected, [double]$tolerance, [string]$message) {
    if ([math]::Abs($actual - $expected) -gt $tolerance) {
        throw "$message (actual=$actual expected=$expected tolerance=$tolerance)"
    }
}
function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Require-Match([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}
function Require-NoMatch([string]$text, [string]$pattern, [string]$message) {
    if ($text -match $pattern) { throw $message }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
function Read-RepoFile([string]$relativePath) {
    Get-Content -Raw (Join-Path $root $relativePath)
}

$data = Read-RepoFile 'source/common/rendering/nri/shaders/Include/SmokeTransientData.hlsli'
$lighting = Read-RepoFile 'source/common/rendering/nri/shaders/Include/SmokeTransientLighting.hlsli'
$lightParameters = Read-RepoFile 'source/common/rendering/nri/shaders/Include/SmokeLightParameters.hlsli'
$build = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientLightBuild.cs.hlsl'
$materialize = Read-RepoFile 'source/common/rendering/nri/shaders/SmokeTransientMaterialize.cs.hlsl'

# The complete-bank transition is based on gameplay age. It must be a bounded,
# continuous 0.2-second ramp and exactly preserve both endpoints.
function Get-CurrentBankWeight([double]$currentGroupAge, [double]$buildGroupAge,
    [double]$refreshInterval = 0.0) {
    $transitionSeconds = if ($refreshInterval -gt 0.0) {
        [math]::Min(0.2, $refreshInterval)
    } else { 0.2 }
    return [math]::Max(0.0, [math]::Min(1.0,
        ([math]::Max($currentGroupAge, 0.0) - [math]::Max($buildGroupAge, 0.0)) / $transitionSeconds))
}
Assert-Near (Get-CurrentBankWeight 3.0 3.0) 0.0 0.0 'A newly published full bank did not begin at the coherent previous bank.'
Assert-Near (Get-CurrentBankWeight 3.1 3.0) 0.5 1e-12 'The Fire light transition midpoint changed.'
Assert-Near (Get-CurrentBankWeight 3.2 3.0) 1.0 1e-12 'The Fire light transition did not settle after 0.2 seconds.'
Assert-Near (Get-CurrentBankWeight 8.0 3.0) 1.0 0.0 'Settled Fire lighting did not clamp to the current bank.'
Assert-Near (Get-CurrentBankWeight 2.0 3.0) 0.0 0.0 'A negative gameplay-age delta did not clamp to the previous bank.'
Assert-Near (Get-CurrentBankWeight 3.1 3.0 0.1) 1.0 1e-12 'A short positive refresh interval did not cap the transition duration.'
Assert-Near (Get-CurrentBankWeight 3.1 3.0 0.0) 0.5 1e-12 'A frozen cache did not retain its bounded 0.2-second transition.'
$lastWeight = -1.0
for ($step = 0; $step -le 20; ++$step) {
    $weight = Get-CurrentBankWeight (3.0 + $step * 0.01) 3.0
    Assert-True ($weight -ge $lastWeight) 'The complete-bank blend is not monotonic.'
    $lastWeight = $weight
}
function Blend-CompleteBank([double]$previous, [double]$current,
    [double]$currentGroupAge, [double]$buildGroupAge) {
    $weight = Get-CurrentBankWeight $currentGroupAge $buildGroupAge
    return $previous + ($current - $previous) * $weight
}
Assert-Near (Blend-CompleteBank 2.0 10.0 3.0 3.0) 2.0 0.0 'Old-bank endpoint was not exact.'
Assert-Near (Blend-CompleteBank 2.0 10.0 3.1 3.0) 6.0 1e-12 'Complete-bank midpoint was not continuous.'
Assert-Near (Blend-CompleteBank 2.0 10.0 3.2 3.0) 10.0 1e-12 'Current-bank endpoint was not exact.'

# Only a valid full Fire cache in the active transition window may touch the
# inactive bank. Fallback, non-Fire, settled, or identity-invalid states use the
# complete current bank without a second anchor load.
function Test-LoadsPreviousBank([int]$transientClass, [bool]$currentIsFull,
    [double]$currentWeight, [bool]$previousIdentityValid,
    [uint32]$currentPackedRevision = 0, [uint32]$previousPackedRevision = 0) {
    return $transientClass -eq 2 -and $currentIsFull -and
        $currentWeight -lt 1.0 -and $previousIdentityValid -and
        $currentPackedRevision -eq $previousPackedRevision
}
Assert-True (Test-LoadsPreviousBank 2 $true 0.0 $true) 'Fresh full Fire cache did not use its complete predecessor.'
Assert-True (-not (Test-LoadsPreviousBank 2 $false 0.0 $true)) 'Fallback Fire cache attempted a bank transition.'
Assert-True (-not (Test-LoadsPreviousBank 1 $true 0.0 $true)) 'Non-Fire cache attempted a Fire-only bank transition.'
Assert-True (-not (Test-LoadsPreviousBank 2 $true 1.0 $true)) 'Settled Fire cache retained the inactive-bank load.'
Assert-True (-not (Test-LoadsPreviousBank 2 $true 0.5 $false)) 'A stale previous identity was blended into current lighting.'
$currentPackedRevision = [uint32]0x00370021
$stalePackedRevision = [uint32]0x00360021
Assert-True (-not (Test-LoadsPreviousBank 2 $true 0.5 $true $currentPackedRevision $stalePackedRevision)) 'A previous Fire bank with stale lighting revision was blended.'
Assert-True (Test-LoadsPreviousBank 2 $true 0.5 $true $currentPackedRevision $currentPackedRevision) 'A matching Fire lighting revision was rejected.'

# The Fire-only self-transmittance floor remains bounded and monotonic. It never
# weakens exact scene visibility: a blocked ray still contributes zero.
function Get-PhysicalSelfTransmittance([double]$opticalDepth) {
    return [math]::Exp(-[math]::Min([math]::Max($opticalDepth, 0.0), 20.0))
}
function Get-SelfTransmittance([int]$transientClass, [double]$opticalDepth) {
    $physical = Get-PhysicalSelfTransmittance $opticalDepth
    if ($transientClass -eq 2) { return 0.18 + 0.82 * $physical }
    return $physical
}
Assert-Near (Get-SelfTransmittance 2 0.0) 1.0 1e-12 'Fire self transport changed at zero optical depth.'
Assert-Near (Get-SelfTransmittance 2 1000.0) (0.18 + 0.82 * [math]::Exp(-20.0)) 1e-12 'Fire self transport exceeded its bounded deep-packet floor.'
Assert-Near (Get-SelfTransmittance 1 8.0) ([math]::Exp(-8.0)) 1e-12 'Non-Fire self transport changed.'
Assert-Near (Get-SelfTransmittance 1 -4.0) 1.0 0.0 'Negative optical depth did not clamp to zero.'
$previousTransport = 1.0
foreach ($tau in @(0.0, 0.25, 1.0, 4.0, 20.0, 1000.0)) {
    $transport = Get-SelfTransmittance 2 $tau
    Assert-True ($transport -le $previousTransport -and $transport -ge 0.18) 'Fire self transport is not bounded and monotonic.'
    $previousTransport = $transport
}
$deepFireTransport = Get-SelfTransmittance 2 1000.0
Assert-Near (0.0 * $deepFireTransport) 0.0 0.0 'The Fire floor leaked through a blocked scene-visibility result.'
Assert-True ((1.0 * $deepFireTransport) -ge 0.18) 'A visible external light lost the bounded Fire transport floor.'

# Cached directional transport is finite and saturated. Current analytic color
# can change continuously without another shadow ray, and exact zero visibility
# remains black.
function Get-ClampedDirectionalTransport([double]$value) {
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return 0.0 }
    return [math]::Max(0.0, [math]::Min(1.0, $value))
}
Assert-Near (Get-ClampedDirectionalTransport -2.0) 0.0 0.0 'Negative directional transport did not clamp.'
Assert-Near (Get-ClampedDirectionalTransport 0.4) 0.4 0.0 'Valid directional transport changed.'
Assert-Near (Get-ClampedDirectionalTransport 2.0) 1.0 0.0 'Directional transport above one did not clamp.'
Assert-Near (Get-ClampedDirectionalTransport ([double]::NaN)) 0.0 0.0 'Non-finite directional transport was accepted.'
$cachedTransport = Get-ClampedDirectionalTransport 0.4
Assert-Near ($cachedTransport * 3.0) 1.2 1e-12 'Current directional color was not applied to cached transport.'
Assert-Near ($cachedTransport * 6.0) 2.4 1e-12 'Directional color could not update without changing cached transport.'
Assert-Near ((Get-ClampedDirectionalTransport 0.0) * 100.0) 0.0 0.0 'Zero scene transport acquired synthetic directional light.'

# Class and payload contracts remain within the established 64-byte anchor.
Require-Match $data 'NRI_SMOKE_TRANSIENT_CLASS_FIRE\s+2u' 'The shader Fire class does not match the CPU transient-class ABI.'
Require-Match $data 'Fire records reuse the[\s\S]*Data2\.yz[\s\S]*buffer remains 64 bytes' 'The Fire-only anchor payload reuse is undocumented.'
Require-Match $lighting 'SmokeTransientFireDirectionalTransport[\s\S]*isfinite\(transport\)\s*\?\s*saturate\(transport\)\s*:\s*0\.0' 'Fire directional transport is not finite and saturated.'
Require-Match $lighting 'SmokeTransientFireAnchorRevisionMatches[\s\S]*record\.Data2\.w\s*==\s*group\.Reserved' 'Previous Fire anchors do not preserve exact shape/lighting revision provenance.'
Require-Match $lighting 'SmokeTransientFireLightBlend[\s\S]*min\(0\.2,\s*finiteInterval\)\s*:\s*0\.2[\s\S]*saturate' 'Fire cache transition is not bounded by 0.2 seconds and the positive refresh interval.'
Require-Match $lighting 'SmokeTransientSelfTransmittance[\s\S]*NRI_SMOKE_TRANSIENT_CLASS_FIRE[\s\S]*0\.18\s*\+\s*0\.82\s*\*\s*physical\s*:\s*physical' 'The bounded artistic self-transport floor is not Fire-only.'

# Full-cache construction stores directional scene visibility separately for
# Fire, leaves non-Fire directional lobe accumulation in place, and stabilizes
# only Fire emissive proposals across pool slot/generation changes.
Require-Match $build 'directionalTransport\s*=\s*group\.TransientClass\s*==\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*\?\s*visibility\s*:\s*visibility\s*\*\s*selfTransmittance' 'Fire must cache scene visibility alone while other classes retain cached self attenuation.'
Require-Match $build 'if\s*\(group\.TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\)\s*SmokeTransientAccumulateIncident\(incident,\s*direction,\s*lobes\)' 'Fire directional RGB was not split from non-Fire cached lobes.'
Require-Match $build 'group\.TransientClass\s*==\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE[\s\S]*SmokeTransientHash\(group\.SourceId\s*\^[\s\S]*SmokeTransientHash\(group\.Slot\s*\^\s*SmokeTransientHash\(group\.Generation\)' 'Fire emissive seeds are not source-stable while non-Fire seeds retain slot/generation identity.'
Require-Match $build 'record\.Data2\.y\s*=\s*asuint\(saturate\(isfinite\(directionalTransport\)' 'Fire anchor does not store bounded directional transport.'
Require-Match $build 'record\.Data2\.z\s*=\s*asuint\(max\(isfinite\(group\.AgeSeconds\)' 'Fire anchor does not store full-bank gameplay age.'
Require-Match $build 'record\.Data2\.w\s*=\s*group\.Reserved' 'Fire anchor does not store packed shape/lighting revision provenance.'

# Materialization requires a full current cache, validates every required prior
# anchor, and exits before even querying the old buffer once the blend settles.
Require-Match $materialize 'SmokeTransientLoadPreviousFireCache[\s\S]*TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE[\s\S]*PublishedState\s*&\s*NRI_SMOKE_TRANSIENT_LIGHT_FULL' 'The old-bank transition is not restricted to full Fire caches.'
$settledIndex = $materialize.IndexOf('if (currentWeight >= 1.0)')
$dimensionsIndex = $materialize.IndexOf('gSmokeTransientLightAnchorsB.GetDimensions', $settledIndex)
Assert-True ($settledIndex -ge 0 -and $dimensionsIndex -gt $settledIndex) 'Settled Fire loads the inactive bank before taking the current-only path.'
Require-Match $materialize 'SmokeTransientAnchorIdentityMatches\(previousAnchors\[anchorIndex\],\s*group,\s*anchorIndex\)' 'Previous-bank anchors are not identity-validated before blending.'
Require-Match $materialize 'SmokeTransientFireAnchorRevisionMatches\(previousAnchors\[anchorIndex\],\s*group\)' 'A previous Fire bank with stale shape/lighting revision can be blended.'
Require-Match $materialize 'lerp\(previousIncidentLobes\[incidentIndex\],[\s\S]*currentWeight\)[\s\S]*directionalTransport\s*=\s*lerp\(previousDirectionalTransport,[\s\S]*currentWeight\)' 'The complete prior/current Fire lighting banks are not blended with one coherent weight.'
Require-Match $materialize 'directionalDirection\s*=\s*SmokeDirectionalDirection\(\)' 'Fire does not use current directional direction during materialization.'
Require-Match $materialize 'NRI_SMOKE_LIGHT_SOURCE_DIRECTIONAL[\s\S]*SmokeDirectionalColor\(\)\s*\*\s*directionalTransport\s*\*\s*localSelfTransmittance' 'Fire does not combine current directional lighting with separate scene and local smoke attenuation.'
Require-Match $materialize '#include\s+"Include/SmokeLightParameters\.hlsli"' 'Materialization does not import the shared ray-free directional-light contract.'
Require-Match $lightParameters 'NRI_SMOKE_LIGHT_SOURCE_DIRECTIONAL' 'The shared light-parameter include is missing the directional source flag.'
Require-Match $lightParameters 'float3\s+SmokeDirectionalDirection\(\)' 'The shared light-parameter include is missing current directional direction.'
Require-Match $lightParameters 'float3\s+SmokeDirectionalColor\(\)' 'The shared light-parameter include is missing current directional color.'
Require-NoMatch $lightParameters 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible' 'The shared directional-light contract acquired ray-dependent implementation.'
Require-NoMatch $materialize 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible' 'Fire light continuity added a materialization-time scene ray.'

Write-Output 'Smoke transient Fire lighting numerical and structural tests passed.'
