$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$cvarsHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_cvars.h') -Raw
$cvarsSource = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_cvars.cpp') -Raw
$settingsHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_renderer_settings.h') -Raw
$settingsSource = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_renderer_settings.cpp') -Raw
$emitterHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.h') -Raw
$emitterSource = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.cpp') -Raw
$smokeOwner = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke.cpp') -Raw
$lightOverlayHeader = Get-Content (Join-Path $root 'source\core\lightoverlay.h') -Raw

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-OrderedOffsets($Offsets, [string]$Message) {
    $previous = -1
    foreach ($name in $Offsets.Keys) {
        $current = [int]$Offsets[$name]
        if ($current -lt 0 -or $current -le $previous) {
            throw "$Message ($name offset $current after $previous)"
        }
        $previous = $current
    }
}

Assert-Match $cvarsHeader 'EXTERN_CVAR\(Int, nri_ptsmokesourceclassmask\)' `
    'The authored smoke source-class mask CVar declaration is missing.'
Assert-Match $cvarsSource 'CVAR\(Int, nri_ptsmokesourceclassmask, 63, 0\)' `
    'The source-class mask must be default-all and session-only.'
Assert-Match $settingsHeader 'uint32_t sourceClassMask = 63;' `
    'The immutable per-frame smoke settings snapshot must carry the source mask.'
Assert-Match $settingsSource `
    'settings\.sourceClassMask = \(uint32_t\)std::clamp\(\(int\)nri_ptsmokesourceclassmask, 0, 63\);' `
    'The CVar must be clamped before entering the immutable settings snapshot.'

Assert-Match $lightOverlayHeader `
    'enum class LightOverlaySmokeTransientClass : uint8_t\s*\{\s*Explosion,\s*TrailChunk,\s*FirePacket,\s*Muzzle,\s*Impact,\s*Diagnostic,' `
    'The authored source-class bit order changed.'
Assert-Match $emitterSource `
    'static_assert\(\(1u << static_cast<uint32_t>\(LightOverlaySmokeTransientClass::Diagnostic\)\) == 32u' `
    'The legacy diagnostic class must remain bit 32.'

Assert-Match $emitterHeader `
    'NRISmokeEmitterRouteSnapshot[\s\S]*sourceClassMask = 0x3fu;[\s\S]*suppressedActorRules = 0u;[\s\S]*suppressedEventRules = 0u;' `
    'Route snapshots must expose the effective mask and both suppressed-rule counts.'
Assert-Match $emitterHeader `
    'SetSourceClassMask\(uint32_t mask\)[\s\S]*mSourceClassMask = 0x3fu;' `
    'The emitter owner must expose a default-all authored class filter.'
Assert-Match $emitterSource `
    'SetSourceClassMask\(uint32_t mask\)[\s\S]*mask &= 0x3fu;[\s\S]*if \(mSourceClassMask == mask\)[\s\S]*mSourceClassMask = mask;[\s\S]*Reset\(\);' `
    'Only a changed source mask may reset emitter cadence and identity state.'

$setterStart = $emitterSource.IndexOf('void NRISmokeEmitterSystem::SetSourceClassMask', [StringComparison]::Ordinal)
$setterEnd = $emitterSource.IndexOf('void NRISmokeEmitterSystem::Reset', $setterStart + 1, [StringComparison]::Ordinal)
if ($setterStart -lt 0 -or $setterEnd -le $setterStart) {
    throw 'Could not isolate the source-mask transition implementation.'
}
$setterBody = $emitterSource.Substring($setterStart, $setterEnd - $setterStart)
if ($setterBody -match 'mTransientClassMask\s*=' -or $setterBody -match 'mMapEmittersEnabled\s*=') {
    throw 'Source isolation must preserve the independent route rollback and map-emitter switches.'
}
Assert-Match $emitterSource `
    'void NRISmokeEmitterSystem::Reset\(\)[\s\S]*mActorStates\.clear\(\);[\s\S]*mContinuousSources\.Reset\(\);[\s\S]*mNextContinuousSourceGeneration = 0u;[\s\S]*mEditorPreviewState = \{\}' `
    'A source-filter transition must clear actor cadence, continuous-source identity, and preview state.'
Assert-Match $emitterSource `
    'mRouteSnapshot\.classMask = mTransientClassMask;\s*mRouteSnapshot\.sourceClassMask = mSourceClassMask;\s*mRouteSnapshot\.mapEmittersEnabled = mMapEmittersEnabled;' `
    'Reset and gather snapshots must preserve all independent route controls.'

$snapshotStart = $emitterSource.IndexOf('mRouteSnapshot.gatherId = ++mNextRouteGatherId;', [StringComparison]::Ordinal)
$actorLoop = $emitterSource.IndexOf('for (uint32_t ruleIndex = 0; ruleIndex < resolved.smokeActorRules.Size(); ++ruleIndex)', $snapshotStart, [StringComparison]::Ordinal)
$actorFilter = $emitterSource.IndexOf('if ((mSourceClassMask & TransientClassBit(rule.transientClass)) == 0u) continue;', $actorLoop, [StringComparison]::Ordinal)
$actorState = $emitterSource.IndexOf('auto stateIt = mActorStates.find(identity);', $actorLoop, [StringComparison]::Ordinal)
$actorRoute = $emitterSource.IndexOf('const bool routed = routeCommand(', $actorLoop, [StringComparison]::Ordinal)
Assert-OrderedOffsets ([ordered]@{
    Snapshot = $snapshotStart
    ActorLoop = $actorLoop
    ActorFilter = $actorFilter
    ActorState = $actorState
    ActorRoute = $actorRoute
}) 'Actor source filtering must precede state, cadence, and emission'

$eventCounters = $emitterSource.IndexOf('uint32_t eventCommands = 0;', [StringComparison]::Ordinal)
$eventLoop = $emitterSource.IndexOf('for (const PathTracingWeaponLightEvent& event : weaponEvents)', $eventCounters, [StringComparison]::Ordinal)
$eventFilter = $emitterSource.IndexOf('if ((mSourceClassMask & TransientClassBit(rule.transientClass)) == 0u)', $eventLoop, [StringComparison]::Ordinal)
$eventMatched = $emitterSource.IndexOf('matchedEventRule = true;', $eventLoop, [StringComparison]::Ordinal)
$eventSerial = $emitterSource.IndexOf('command.serial = nextSerial++;', $eventLoop, [StringComparison]::Ordinal)
$eventRoute = $emitterSource.IndexOf('const bool routed = routeCommand(', $eventLoop, [StringComparison]::Ordinal)
Assert-OrderedOffsets ([ordered]@{
    EventCounters = $eventCounters
    EventLoop = $eventLoop
    EventFilter = $eventFilter
    EventMatched = $eventMatched
    EventSerial = $eventSerial
    EventRoute = $eventRoute
}) 'Event source filtering must precede matching, serial allocation, and emission'

Assert-Match $emitterSource `
    'for \(const auto& rule : resolved\.smokeActorRules\)[\s\S]*suppressedActorRules\+\+;[\s\S]*for \(const auto& rule : resolved\.smokeEventRules\)[\s\S]*suppressedEventRules\+\+;' `
    'Suppressed rule counts must be gathered once from resolved rules, not multiplied by actors or events.'
Assert-Match $emitterSource 'if \(suppressedEventRule\)[\s\S]*reason=source-class-filter[\s\S]*reason=no-rule' `
    'A matching filtered event must not be mislabeled as an unauthored event.'

$mapStart = $emitterSource.IndexOf('struct MapEmissionStats', [StringComparison]::Ordinal)
$mapEnd = $emitterSource.IndexOf('uint32_t eventCommands = 0;', $mapStart, [StringComparison]::Ordinal)
if ($mapStart -lt 0 -or $mapEnd -le $mapStart) {
    throw 'Could not isolate map-emitter routing.'
}
$mapBody = $emitterSource.Substring($mapStart, $mapEnd - $mapStart)
if ($mapBody -match 'mSourceClassMask') {
    throw 'Authored actor/event source isolation must not silently filter map emitters.'
}

$setSourceOffset = $smokeOwner.IndexOf('mEmitters.SetSourceClassMask(mSettings.sourceClassMask);', [StringComparison]::Ordinal)
$gatherOffset = $smokeOwner.IndexOf('mEmitters.Gather(', $setSourceOffset, [StringComparison]::Ordinal)
Assert-OrderedOffsets ([ordered]@{
    SetSourceMask = $setSourceOffset
    Gather = $gatherOffset
}) 'PrepareFrame must apply the immutable source mask before gathering emitters'
Assert-Match $smokeOwner `
    'PERF pt smoke route frame NRI:[^\n]*source_mask=%u suppressed_actor_rules=%u suppressed_event_rules=%u' `
    'Frame-linked route telemetry must expose source-isolation proof.'
Assert-Match $emitterSource `
    'NRI PT smoke routing: event=frame-summary[^\n]*source_mask=%u suppressed_actor_rules=%u suppressed_event_rules=%u' `
    'Emitter gather telemetry must expose source-isolation proof.'

$classBits = @(1, 2, 4, 8, 16, 32)
if (($classBits | Measure-Object -Sum).Sum -ne 63 -or $classBits[-1] -ne 32) {
    throw 'The six authored class bits no longer compose the default-all mask.'
}
foreach ($selectedBit in $classBits) {
    $accepted = @($classBits | Where-Object { ($_ -band $selectedBit) -ne 0 })
    if ($accepted.Count -ne 1 -or $accepted[0] -ne $selectedBit) {
        throw "A single-class isolation mask admitted another class for bit $selectedBit."
    }
}

Write-Host 'Smoke source-class isolation validation passed.'
