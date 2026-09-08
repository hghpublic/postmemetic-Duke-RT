$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$header = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.h') -Raw
$source = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_emitters.cpp') -Raw
$transientHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_transient_clouds.h') -Raw
$cvarsHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_cvars.h') -Raw
$cvarsSource = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_cvars.cpp') -Raw
$settings = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_renderer_settings.cpp') -Raw
$interestHeader = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_interest.h') -Raw
$interestSource = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_interest.cpp') -Raw
$smokeOwner = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke.cpp') -Raw
$eventRunner = Get-Content (Join-Path $root 'tools\validation\run-smoke-transient-repro.ps1') -Raw
$actorRunner = Get-Content (Join-Path $root 'tools\validation\run-smoke-transient-actor-repro.ps1') -Raw
$trailChunks = Get-Content (Join-Path $root 'source\common\rendering\nri\renderer\nri_smoke_transient_trail_chunks.h') -Raw
$fixture = Get-Content (Join-Path $root 'tools\validation\overlays\smoke-transient-fixtures\LIGHTOVR') -Raw
$actorFixture = Get-Content (Join-Path $root 'tools\validation\overlays\smoke-transient-actor-fixtures\LIGHTOVR') -Raw
$release = Get-Content (Join-Path $root 'release-overlay\LIGHTOVR') -Raw

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

Assert-Match $header 'vector<NRISmokeAnalyticCarrierRequest>& analyticRequests,[\s\S]*vector<NRISmokeTransientLobeRequest>& transientRequests' 'Legacy analytic and transient requests must use separate output streams.'
Assert-Match $header 'SetTransientClassMask\(uint32_t mask\)' 'The per-class session rollback mask is missing.'
Assert-Match $cvarsHeader 'EXTERN_CVAR\(Bool, nri_ptsmokemapemitters\)' 'The map-emitter isolation CVar declaration is missing.'
Assert-Match $cvarsSource 'CVAR\(Bool, nri_ptsmokemapemitters, true, 0\)' 'Map emitters must stay default-on and session-only.'
Assert-Match $settings 'settings\.mapEmitters\s*=\s*nri_ptsmokemapemitters' 'Immutable smoke settings must capture map-emitter isolation.'
Assert-Match $header 'SetMapEmittersEnabled\(bool enabled\)[\s\S]*mMapEmittersEnabled = true' 'The emitter owner must expose a default-on map-emitter switch.'
Assert-Match $source 'SetMapEmittersEnabled\(bool enabled\)[\s\S]*mMapEmitterStates\.clear\(\)[\s\S]*mEditorPreviewState = \{\}' 'A map-emitter mode transition must clear cadence and preview state.'
Assert-Match $source 'if \(!mMapEmittersEnabled\)[\s\S]*suppressedMapRules\+\+[\s\S]*continue;[\s\S]*emitMapRule' 'Disabled map rules must be counted and skipped before cadence emission.'
Assert-Match $source 'hasEditorPreview && mMapEmittersEnabled[\s\S]*suppressedMapPreviews = 1u' 'Editor previews must obey the same isolation switch.'
Assert-Match $interestHeader 'bool mapEmittersEnabled = true' 'Map source interest must stay default-on outside isolated captures.'
Assert-Match $interestSource 'if \(input\.mapEmittersEnabled\)[\s\S]*mapSmokeEmitterRules[\s\S]*!it->second\.observed \? mSourceStates\.erase' 'Disabled map emitters must also disappear from retained interest state.'
Assert-Match $smokeOwner 'interestInput\.mapEmittersEnabled = mSettings\.mapEmitters[\s\S]*SetMapEmittersEnabled\(mSettings\.mapEmitters\)' 'Frame orchestration must apply one settings snapshot to interest and emission owners.'
Assert-Match $smokeOwner 'map_emitters=%u map_rules_suppressed=%u[\s\S]*ambient_map_commands=%u preview_map_commands=%u' 'Route telemetry must prove map isolation and zero ambient/preview commands.'
foreach ($runner in @($eventRunner, $actorRunner)) {
    Assert-Match $runner '\[switch\]\$IncludeMapFog' 'Transient harnesses must expose an explicit mixed map-fog opt-in.'
    Assert-Match $runner 'nri_ptsmokemapemitters = \(\[string\]\[bool\]\$IncludeMapFog\)\.ToLowerInvariant\(\)' 'Transient harnesses must disable map emitters by default.'
}
Assert-Match $eventRunner '\[ValidateSet\(''e1l1'', ''e3l6''\)\]\[string\]\$Map = ''e1l1''' 'Event captures must offer only the validated E1L1 and E3L6 map cohorts.'
foreach ($productionEventRule in @(
    'duke.pistol.primary',
    'duke.chaingun.primary',
    'duke.shotgun.primary',
    'duke.hitscan.impact.wall',
    'duke.hitscan.impact.plane')) {
    Assert-Match $eventRunner ("'" + [regex]::Escape($productionEventRule) + "'") "The event harness production whitelist is missing $productionEventRule."
}
foreach ($muzzleEventRule in @('duke.pistol.primary', 'duke.chaingun.primary', 'duke.shotgun.primary')) {
    Assert-Match $eventRunner ("'" + [regex]::Escape($muzzleEventRule) + "'\s*=\s*'muzzle'") "$muzzleEventRule must be classified as a muzzle event."
}
foreach ($impactEventRule in @('duke.hitscan.impact.wall', 'duke.hitscan.impact.plane')) {
    Assert-Match $eventRunner ("'" + [regex]::Escape($impactEventRule) + "'\s*=\s*'impact'") "$impactEventRule must be classified as an impact event."
}
Assert-Match $eventRunner '\[switch\]\$Production[\s\S]*\[string\]\$EventRule' 'Event captures must expose explicit production-authoring and production-rule selection.'
Assert-Match $eventRunner '\$Cold -and \$Production[\s\S]*cannot edit production authoring in place' 'Cold capture must not mutate or masquerade as production authoring.'
Assert-Match $eventRunner 'if \(\$EventRule\)[\s\S]*requires -Production[\s\S]*-ccontains \$EventRule[\s\S]*belongs to Effect[\s\S]*elseif \(\$Production\)[\s\S]*require -EventRule' 'Production event selection must be exact, explicit, and class-compatible.'
Assert-Match $eventRunner '\$selectedEventRule = if \(\$EventRule\) \{ \$EventRule \} else \{ "transient\.\$Effect\.fixture" \}' 'Candidate and production captures must resolve one explicit emitted event rule.'
Assert-Match $eventRunner 'if \(-not \$Production\) \{ \$extra\.Add\(''-file''\); \$extra\.Add\(\$fixtureSnapshot\) \}' 'Production event captures must skip the candidate fixture mount.'
Assert-Match $eventRunner 'nri_ptsmoke_test \$selectedEventRule \$Distance[\s\S]*requiredPrefixes = @\("NRI PT smoke event test queued: event=\$selectedEventRule "' 'The emitted event and required log attribution must use the same resolved rule.'
Assert-Match $eventRunner 'eventRule = \$selectedEventRule[\s\S]*\[''production''\] = \[bool\]\$Production[\s\S]*fixtureMounted = -not \[bool\]\$Production' 'Scenario metadata must preserve the actual event rule, content mode, and fixture mount decision.'
Assert-Match $eventRunner "use_mouse = 'false'; use_joystick = 'false'; cl_viewbob = '0'; cl_dukepitchmode = '0'" 'Event captures must disable live input, view bob, and automatic pitch changes like actor captures.'
Assert-Match $eventRunner '\$screenshotWaitUpdates = @\(1, 5, 12, 24, 45\)[\s\S]*god; \$\{viewSetup\}centerview; wait 2; nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset' 'Event captures must settle the selected deterministic view, freeze its meter, then start route tracing and reset immediately before emission.'
Assert-Match $eventRunner "nri_ptsmoketrace = '0'" 'Event startup must exclude pre-warm map activity from capture route attribution.'
Assert-Match $eventRunner '\(\$cumulativeWaitUpdates \+ 1\) / 30\.0[\s\S]*delayedCommandUpdatesPerSecond = 30[\s\S]*playClockUnitsPerUpdate = 4' 'Event metadata must include the post-command gameplay update in screenshot ages.'
Assert-Match $eventRunner '\$minimumSuppressedMapRules = if \(\$Map -eq ''e1l1''\) \{ 4 \} else \{ 0 \}' 'Event isolation must expect four E1L1 map rules and zero E3L6 map rules.'
Assert-Match $eventRunner 'map \$Map; wait 1; closemenu; wait 240[\s\S]*map = \$Map[\s\S]*MinimumSuppressedMapRules = \$minimumSuppressedMapRules' 'The selected event map must drive launch, metadata, and isolation analysis.'
Assert-Match $eventRunner 'warptocoords -1616 760 -708 180 0[\s\S]*position = @\(-1616, 760, -708\); yaw = 180; pitch = 0; sector = 298; recommendedEventDistanceWorldUnits = 160; blockingDistanceWorldUnits = 290' 'E1L1 event captures must record the verified open-roof camera and safe smoke distance.'
Assert-Match $actorRunner 'RequireMapEmittersDisabled[\s\S]*MinimumSuppressedMapRules = 4' 'Actor E1L1 captures must enforce the four-rule suppression gate.'
Assert-Match $header 'NRISmokeEmitterRouteSnapshot[\s\S]*gatherId[\s\S]*gridCommands[\s\S]*analyticCarriers[\s\S]*transientGroups[\s\S]*transientLobes' 'Measured per-gather routing attribution is incomplete.'
Assert-Match $source 'EffectiveSmokeRepresentation[\s\S]*TransientClassBit' 'Transient class masking must resolve one effective representation.'
Assert-Match $source 'case LightOverlaySmokeTransientClass::Explosion:[\s\S]*case LightOverlaySmokeTransientClass::TrailChunk:[\s\S]*case LightOverlaySmokeTransientClass::FirePacket:[\s\S]*return LightOverlaySmokeRepresentation::Grid' 'Explosion, trail, and fire rollback must select their original grid route.'
Assert-Match $source 'case LightOverlaySmokeTransientClass::Muzzle:[\s\S]*case LightOverlaySmokeTransientClass::Impact:[\s\S]*return LightOverlaySmokeRepresentation::Analytic' 'Muzzle and impact rollback must select the legacy analytic route.'
Assert-Match $source 'if \(representation == LightOverlaySmokeRepresentation::Grid\)[\s\S]*if \(representation == LightOverlaySmokeRepresentation::TransientCloud\)[\s\S]*Keep the original comparison carrier behavior' 'Command routing must remain an explicit grid/transient/legacy-analytic split.'
Assert-Match $source 'NRIBuildSmokeTransientLobes\(shape, lobes, 16u\)' 'Emitter code must use the transient owner shaping helper.'
Assert-Match $source 'shape\.requestedLobeCount = std::clamp\(transientLobeCount, 1u, 16u\)' 'Transient spatial complexity must come from lobecount.'
Assert-Match $source 'shape\.opticalAmount = static_cast<float>\(command\.count\)' 'Authored source quantity must remain independent from lobe count.'
Assert-Match $source 'shape\.opticalAmount = static_cast<float>\(command\.count\) \* authoredStyle->opticalAmountScale' 'Transient optical amount must apply the authored transient-only scale to source count.'
Assert-Match $source 'shape\.lobeLifetimeSeconds = authoredStyle->transientLifetimeSeconds > 0\.0f\s*\? authoredStyle->transientLifetimeSeconds : std::max\(style\.lifetime, 0\.001f\);\s*shape\.groupLifetimeSeconds = shape\.lobeLifetimeSeconds' 'Transient lifetime must override when positive and otherwise inherit the unchanged style lifetime.'
Assert-Match $source 'outPosition\[1\] = \(float\)-worldPosition\.Z[\s\S]*if \(representation == LightOverlaySmokeRepresentation::TransientCloud\)[\s\S]*shape\.up\[1\] = 1\.0f' 'Transient buoyancy must use path-tracing +Y, matching the world-Z-to-render-Y coordinate transform.'
Assert-Match $transientHeader 'float up\[3\] = \{ 0\.0f, 1\.0f, 0\.0f \}' 'The semantic transient builder input must default to path-tracing +Y.'
$gridRouteOffset = $source.IndexOf('if (representation == LightOverlaySmokeRepresentation::Grid)', [StringComparison]::Ordinal)
$transientRouteOffset = $source.IndexOf('if (representation == LightOverlaySmokeRepresentation::TransientCloud)', $gridRouteOffset + 1, [StringComparison]::Ordinal)
$opticalScaleOffset = $source.IndexOf('shape.opticalAmount = static_cast<float>(command.count) * authoredStyle->opticalAmountScale;', $transientRouteOffset, [StringComparison]::Ordinal)
if ($gridRouteOffset -lt 0 -or $transientRouteOffset -le $gridRouteOffset -or $opticalScaleOffset -le $transientRouteOffset) {
    throw 'Optical amount scaling must remain inside the transient route after the legacy Grid branch.'
}
Assert-Match $source 'transientRequests\.insert' 'Transient batches must not be appended to the legacy analytic request stream.'
Assert-Match $source 'effectiveRepresentation ==[\s\S]*LightOverlaySmokeRepresentation::TransientCloud[\s\S]*TrailChunk[\s\S]*support-sized trail chunks covers every logical' 'Trail hitches must become bounded spatial chunks instead of dropping an old prefix.'
Assert-Match $source 'if \(transientTrail[\s\S]*NRIPlanSmokeTransientTrailChunkCount' 'Only the effective transient trail route may coalesce authored crossings.'
Assert-Match $source 'const uint32_t skipped = candidateCount - emitCount;[\s\S]*if \(transientTrail\)[\s\S]*NRIGetSmokeTransientTrailChunkRange' 'Grid rollback must retain the original newest-maxsegments selection while transient chunks retain full coverage.'
Assert-Match $source 'const double emissionTime = transientTrail \? gameplayTimeSeconds' 'Compressed trail support must be fresh at current presentation instead of replaying stale hitch work.'
Assert-Match $source 'WorldToPathTracingDirection\(emission\.trailDirection, transientTrailAxis\)[\s\S]*transientTrailAxisPointer, emission\.trailSpan' 'Trail shape orientation and covered span must be independent of source velocity magnitude.'
Assert-Match $source 'shape\.clusterSpread = authoredStyle->clusterSpread;[\s\S]*shape\.trailAxis[\s\S]*shape\.trailSpan = transientTrailSpan' 'Trail span must not inflate class radial spread.'
Assert-Match $source 'NRISumSmokeSourceEnvelope\(sourceEnvelope,[\s\S]*emission\.firstCadenceOrdinal,[\s\S]*emission\.lastCadenceOrdinal' 'Compressed trail chunks must preserve the logical cadence envelope.'
Assert-Match $source '\(uint64_t\)command\.count \* \(emission\.lastCadenceOrdinal -[\s\S]*emission\.firstCadenceOrdinal \+ 1u\)' 'Compressed trail route attribution must preserve the complete logical source quantity.'
Assert-Match $source 'effectiveRepresentation == LightOverlaySmokeRepresentation::Grid[\s\S]*queuePolicy == LightOverlaySmokeQueuePolicy::Latest' 'Grid bridge classification must use the effective route.'
Assert-Match $source 'event=frame-summary gather=%llu[\s\S]*event=source gather=%llu' 'Routing diagnostics must report measured frame and per-source attribution.'
Assert-Match $trailChunks 'LowProfileLobeCeiling = 4u[\s\S]*NormalTickShoulderAllowance = 1\.1f' 'Trail chunk sizing must retain connected Low-profile support while allowing one normal RPG tick.'

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
if ($fixture -match 'smokeactorrule') {
    throw 'The event fixture mount must not add actor rules to normal map captures.'
}
foreach ($canonicalActorRule in @('duke_explosion_cloud', 'duke_rpg_trail_continuous', 'duke_fire_sustained')) {
    Assert-Match $actorFixture ('smokeactorrule\s+"' + [regex]::Escape($canonicalActorRule) + '"') "Actor fixture must override canonical rule $canonicalActorRule instead of adding a duplicate actor source."
}
Assert-Match $actorFixture 'smokeactorrule\s+"duke_fire_sustained"[\s\S]*offset\s+0\.0\s+0\.0\s+-32\.0' 'The candidate fire packet must start inside the floor-anchored FIRE/FIRE2 volume before rising.'
& (Join-Path $PSScriptRoot 'smoke-transient-production.tests.ps1')

Write-Host 'Smoke transient routing static validation passed.'
