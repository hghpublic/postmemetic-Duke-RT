$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$header = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.h') -Raw
$source = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.cpp') -Raw
$fixture = Get-Content (Join-Path $root 'tools\validation\overlays\smoke-transient-fixtures\LIGHTOVR') -Raw
$release = Get-Content (Join-Path $root 'release-overlay\LIGHTOVR') -Raw

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

Assert-Match $header 'vector<NRISmokeAnalyticCarrierRequest>& analyticRequests,[\s\S]*vector<NRISmokeTransientLobeRequest>& transientRequests' 'Legacy analytic and transient requests must use separate output streams.'
Assert-Match $header 'SetTransientClassMask\(uint32_t mask\)' 'The per-class session rollback mask is missing.'
Assert-Match $header 'NRISmokeEmitterRouteSnapshot[\s\S]*gatherId[\s\S]*gridCommands[\s\S]*analyticCarriers[\s\S]*transientGroups[\s\S]*transientLobes' 'Measured per-gather routing attribution is incomplete.'
Assert-Match $source 'EffectiveSmokeRepresentation[\s\S]*TransientClassBit' 'Transient class masking must resolve one effective representation.'
Assert-Match $source 'case LightOverlaySmokeTransientClass::Explosion:[\s\S]*case LightOverlaySmokeTransientClass::TrailChunk:[\s\S]*case LightOverlaySmokeTransientClass::FirePacket:[\s\S]*return LightOverlaySmokeRepresentation::Grid' 'Explosion, trail, and fire rollback must select their original grid route.'
Assert-Match $source 'case LightOverlaySmokeTransientClass::Muzzle:[\s\S]*case LightOverlaySmokeTransientClass::Impact:[\s\S]*return LightOverlaySmokeRepresentation::Analytic' 'Muzzle and impact rollback must select the legacy analytic route.'
Assert-Match $source 'if \(representation == LightOverlaySmokeRepresentation::Grid\)[\s\S]*if \(representation == LightOverlaySmokeRepresentation::TransientCloud\)[\s\S]*Keep the original comparison carrier behavior' 'Command routing must remain an explicit grid/transient/legacy-analytic split.'
Assert-Match $source 'NRIBuildSmokeTransientLobes\(shape, lobes, 16u\)' 'Emitter code must use the transient owner shaping helper.'
Assert-Match $source 'shape\.requestedLobeCount = std::clamp\(transientLobeCount, 1u, 16u\)' 'Transient spatial complexity must come from lobecount.'
Assert-Match $source 'shape\.opticalAmount = static_cast<float>\(command\.count\)' 'Authored source quantity must remain independent from lobe count.'
Assert-Match $source 'transientRequests\.insert' 'Transient batches must not be appended to the legacy analytic request stream.'
Assert-Match $source 'effectiveRepresentation ==[\s\S]*LightOverlaySmokeRepresentation::TransientCloud[\s\S]*TrailChunk[\s\S]*compresses hitch work spatially' 'Trail hitches must become bounded spatial chunks instead of dropping an old prefix.'
Assert-Match $source 'WorldToPathTracingDirection\(emission\.trailDirection, transientTrailAxis\)[\s\S]*transientTrailAxisPointer, emission\.trailSpan' 'Trail shape orientation and covered span must be independent of source velocity magnitude.'
Assert-Match $source 'shape\.clusterSpread = authoredStyle->clusterSpread;[\s\S]*shape\.trailAxis[\s\S]*shape\.trailSpan = transientTrailSpan' 'Trail span must not inflate class radial spread.'
Assert-Match $source 'NRISumSmokeSourceEnvelope\(sourceEnvelope,[\s\S]*emission\.firstCadenceOrdinal,[\s\S]*emission\.lastCadenceOrdinal' 'Compressed trail chunks must preserve the logical cadence envelope.'
Assert-Match $source 'effectiveRepresentation == LightOverlaySmokeRepresentation::Grid[\s\S]*queuePolicy == LightOverlaySmokeQueuePolicy::Latest' 'Grid bridge classification must use the effective route.'
Assert-Match $source 'event=frame-summary gather=%llu[\s\S]*event=source gather=%llu' 'Routing diagnostics must report measured frame and per-source attribution.'

# Mirror the integer partition used by the emitter and prove that bounded hitch
# chunks cover every logical crossing exactly once, in deterministic order.
foreach ($case in @(
    @{ Candidates = 1; Capacity = 4 },
    @{ Candidates = 7; Capacity = 4 },
    @{ Candidates = 73; Capacity = 4 },
    @{ Candidates = 257; Capacity = 8 })) {
    $candidateCount = [int]$case.Candidates
    $emitCount = [math]::Min($candidateCount, [int]$case.Capacity)
    $previousLast = -1
    for ($chunk = 0; $chunk -lt $emitCount; $chunk++) {
        $first = [int][math]::Floor(([int64]$chunk * $candidateCount) / $emitCount)
        $last = [int][math]::Floor(([int64]($chunk + 1) * $candidateCount) / $emitCount) - 1
        if ($first -ne $previousLast + 1 -or $last -lt $first) {
            throw "Trail chunk partition left a gap or overlap for $candidateCount/$emitCount."
        }
        $previousLast = $last
    }
    if ($previousLast -ne $candidateCount - 1) {
        throw "Trail chunk partition did not retain the newest crossing for $candidateCount/$emitCount."
    }
}

# Two independently partitioned frame segments share the turn vertex. Each
# segment is complete, so a change in direction cannot discard the pre-turn tail.
$turnSegments = @(
    @{ Start = @(0.0, 0.0); End = @(48.0, 0.0); Candidates = 8 },
    @{ Start = @(48.0, 0.0); End = @(48.0, 36.0); Candidates = 6 })
if ($turnSegments[0].End[0] -ne $turnSegments[1].Start[0] -or
    $turnSegments[0].End[1] -ne $turnSegments[1].Start[1]) {
    throw 'Turn fixture does not share the segment boundary.'
}

foreach ($class in @('explosion', 'trail', 'fire', 'muzzle', 'impact')) {
    Assert-Match $fixture ('effectclass\s+' + $class) "Missing transient fixture for $class."
}
Assert-Match $fixture 'count\s+48[\s\S]*lobecount\s+12' 'The fixture must prove optical quantity and lobe count are independently authored.'
if ($release -match 'representation\s+transient-cloud') {
    throw 'Production LIGHTOVR must remain unchanged until the runtime gate is accepted.'
}

Write-Host 'Smoke transient routing static validation passed.'
