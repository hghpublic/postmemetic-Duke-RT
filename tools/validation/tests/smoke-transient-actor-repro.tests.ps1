Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$runner = Get-Content (Join-Path $root 'tools/validation/run-smoke-transient-actor-repro.ps1') -Raw
$analyzer = Get-Content (Join-Path $root 'tools/validation/analyze-smoke-transient-actor-repro.ps1') -Raw
$fixture = Get-Content (Join-Path $root 'tools/validation/overlays/smoke-transient-actor-fixtures/LIGHTOVR') -Raw

foreach ($path in @(
    (Join-Path $root 'tools/validation/run-smoke-transient-actor-repro.ps1'),
    (Join-Path $root 'tools/validation/analyze-smoke-transient-actor-repro.ps1')
)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw "$path has PowerShell parse errors: $($parseErrors[0].Message)"
    }
}

function Require-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

Require-Match $runner "map e1l1; wait 1; closemenu; wait 240; god; give weapons; give ammo; slot 5; warptocoords -1616 760 -708 180 8; wait 2; \+Move_Forward; wait 2; -Move_Forward; wait 20'[\s\S]*\+Fire; wait 8; -Fire" 'RPG/explosion capture must preserve its shallow floor-target pitch instead of centering back to a skyward shot.'
if ($runner -match "warptocoords -1616 760 -708 180 8[^'`r`n]*centerview") {
    throw 'The floor-target actor setup must not erase its authored pitch with centerview.'
}
Require-Match $runner 'smoke-offscreen\.dsave[\s\S]*Test-Path[\s\S]*if \(\$hasRpgSave\)[\s\S]*load smoke-offscreen' 'The optional RPG save path must only activate when smoke-offscreen.dsave actually exists.'
Require-Match $runner 'map e1l1; wait 1; closemenu; wait 240; god; warptocoords 800 3584 -96 180 10[\s\S]*\+Move_Forward[\s\S]*nri_ptsmokereset' 'Fire actor capture must use the farther valid sector-325 view of E1L1 FIRE/FIRE2 sprites 195/196.'
Require-Match $runner 'targetActors = @\(195, 196\)' 'Actor metadata must preserve the map-derived fire target contract.'
Require-Match $runner "pitch = 8; sector = 298; target = 'roof floor before fence'; autoAim = \`$false; requireRuntimeImpactLogValidation = \`$true" 'Actor metadata must mark the floor-target contract as requiring runtime impact-log validation instead of claiming an exact range.'
Require-Match $runner '\[string\]\$File = ''build/smoke-content/full-voxel-overlay''' 'Actor capture must default to the frozen full-content copy.'
Require-Match $runner 'fixtureSnapshot[\s\S]*Get-Content[\s\S]*actorFixture[\s\S]*fixtureSnapshotFile[\s\S]*Set-Content' 'Actor captures must snapshot candidate LIGHTOVR bytes before launch.'
Require-Match $runner '\[switch\]\$Cold[\s\S]*intrinsicemission[\s\S]*\$\{1\}0\.0' 'Cold actor captures must zero only intrinsic emission in the local fixture snapshot.'
Require-Match $runner 'extra\.Add\(''-file''\); \$extra\.Add\(\$releaseOverlay\)[\s\S]*extra\.Add\(''-file''\); \$extra\.Add\(\$fixtureSnapshot\)' 'Production authoring and immutable actor overrides must mount after base content, in that order.'
Require-Match $runner '\[switch\]\$Production[\s\S]*if \(-not \$Production\) \{ \$extra\.Add\(''-file''\); \$extra\.Add\(\$fixtureSnapshot\) \}[\s\S]*production = \[bool\]\$Production' 'Production actor captures must skip only the candidate fixture snapshot and record that selection.'
Require-Match $runner '\$Production -and \$Cold[\s\S]*cannot edit production authoring in place' 'The harness must reject a misleading production-cold combination.'
Require-Match $runner 'contentHashes = \[ordered\]@\{[\s\S]*executable[\s\S]*fixture[\s\S]*releaseLightovr[\s\S]*baseLightovr[\s\S]*configTemplate[\s\S]*effectiveConfig[\s\S]*Get-ChildItem[\s\S]*\.dxil'', ''\.spirv''[\s\S]*sha256 = \$contentHashes' 'Actor metadata must hash executable, shaders, fixture, content, and both template/effective config.'
Require-Match $runner '@\(''vid_defwidth'', ''1280''\)[\s\S]*@\(''win_w'', ''-1''\)[\s\S]*extra\.Add\(''-width''\); \$extra\.Add\(''1280''\)' 'Actor capture must override early INI window state and process dimensions.'
Require-Match $runner 'launch = \[ordered\]@\{ file = \$baseContent; gameGrp = \$resolvedGameGrp' 'Preflight must resolve the base content and game archive before writing the scenario.'
Require-Match $runner 'nri_ptsmoketransientmask[\s\S]*nri_ptsmoketrace[\s\S]*nri_ptsmokereadback' 'Actor capture must explicitly enable mask/routing/completed-GPU evidence.'
Require-Match $runner "nri_ptsmoketrace = '0'" 'Actor startup must not attribute pre-warm map activity to the capture cohort.'
if (([regex]::Matches($runner, 'nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset')).Count -ne 2) {
    throw 'Both actor paths must enable route tracing only after warmup and immediately before capture reset.'
}
Require-Match $runner '\[switch\]\$IncludeOtherSources[\s\S]*nri_ptsmokesourceclassmask = \[string\]\$sourceClassMask' 'Actor capture must isolate the selected authored source class unless explicitly widened.'
Require-Match $runner 'ExpectedSourceClassMask = \$sourceClassMask' 'Strict generic analysis must verify the actor capture source-class mask.'
Require-Match $runner '\[ValidateRange\(64, 1024\)\]\[int\]\$CaptureFrames = 256[\s\S]*\[ValidateRange\(180, 1200\)\]\[int\]\$DrainTics = 300' 'Actor capture must cover delayed impact/start-time smoke and allow an adequate compact drain.'
Require-Match $runner '\[switch\]\$IncludeMapFog[\s\S]*nri_ptsmokemapemitters = \(\[string\]\[bool\]\$IncludeMapFog\)\.ToLowerInvariant\(\)' 'Actor captures must isolate production map fog unless explicitly requested.'
Require-Match $runner "nri_upscaler = '0'; nri_upscalermode = '0'; nri_ptoutputmode = '0'; nri_renderscale = '1'" 'Actor capture must force native SDR output before renderer startup.'
Require-Match $runner "cl_autoaim = '0'" 'RPG capture must disable gameplay autoaim so the deterministic floor-target pitch controls projectile z velocity.'
Require-Match $runner "cl_dukepitchmode = '0'" 'Actor capture must disable landing recenter so the floor-target pitch survives warp settling.'
Require-Match $runner "\[ValidateSet\('all', 'point', 'directional', 'emissive', 'none'\)\][\s\S]*nri_ptsmokepointlights[\s\S]*nri_ptsmokedirectionallight[\s\S]*nri_ptsmokeemissivelights[\s\S]*nri_ptsmokelightmode" 'Actor captures must expose the same isolated light-family matrix as event captures.'
Require-Match $runner '\[switch\]\$ApiValidation[\s\S]*nri_apivalidation = \(\[string\]\[bool\]\$ApiValidation\)\.ToLowerInvariant\(\)' 'Actor captures must expose optional API validation without changing its default.'
if (([regex]::Matches($runner, 'nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset')).Count -ne 2) {
    throw 'Both fire and RPG actor capture paths must freeze their per-run meter immediately before smoke reset/capture.'
}
Require-Match $runner 'per-run meter at capture start; not a common calibrated exposure across runs' 'Actor metadata must state the limits of frozen auto exposure across separate runs.'
Require-Match $runner 'perf_looptraceframes 0; perf_compactframes \$CaptureFrames[\s\S]*nri_ptsmokestatus; wait \$DrainTics; quit' 'Actor smoke must be emitted during the configurable compact capture with enough drain time to complete.'
foreach ($prefix in @('PERF pt gpu timing NRI:', 'PERF compact capture complete:')) {
    Require-Match $runner ([regex]::Escape($prefix)) "Actor capture must require $prefix"
}
Require-Match $runner 'NRI error:[\s\S]*LIGHTOVR: Script error' 'Actor capture must reject generic NRI and LIGHTOVR scanner errors.'
Require-Match $runner 'run/summary\.json[\s\S]*if \(-not \$runSummary\.ok\)' 'Actor runner must fail when the aggregate perf summary fails.'
Require-Match $runner 'analyze-smoke-transient-repro\.ps1[\s\S]*analyze-smoke-transient-actor-repro\.ps1' 'Strict transient analysis must succeed before actor-specific analysis runs.'
Require-Match $runner 'MinimumCompactFrames \$CaptureFrames[\s\S]*\| Out-Null[\s\S]*Actor analysis passed' 'Actor analysis must enforce the requested compact cohort without dumping analyzer JSON.'
Require-Match $runner 'if \(\$ClassMask -eq 0\)[\s\S]*AllowLegacyControl' 'Only mask-zero actor controls may opt into legacy transient analysis.'
Require-Match $analyzer "sourceIds[\s\S]*event=source[\s\S]*source_id[\s\S]*expectedEffective" 'Actor analyzer must join actual actor source IDs to route attribution.'
Require-Match $analyzer 'enabled \$rule was not transient-only[\s\S]*disabled \$rule did not return exclusively to Grid' 'Actor analyzer must enforce both candidate and rollback exclusivity.'
Require-Match $analyzer 'completedActorRoutes[\s\S]*joined completed-GPU frame[\s\S]*compact capture did not complete at least \$MinimumCompactFrames accepted frames' 'Actor analyzer must prove actor smoke chronology and the requested compact timing cohort.'
Require-Match $analyzer 'lobe_drop[\s\S]*reduced[\s\S]*maximumLobeDrops[\s\S]*maximumReducedGroups' 'Actor summaries must report cumulative lobe-cap drops and reduced batches without universally failing overload.'
foreach ($rule in @('duke_explosion_cloud', 'duke_rpg_trail_continuous', 'duke_fire_sustained')) {
    Require-Match $fixture ('smokeactorrule\s+"' + $rule + '"') "Actor fixture is missing canonical override $rule."
}
Require-Match $fixture 'smokestyle\s+"transient_explosion"[\s\S]*?opticalamountscale\s+0\.30[\s\S]*?lifetime\s+5\.0[\s\S]*?intrinsicemission\s+0\.8' 'Explosion tuning must explicitly scale transient optical amount without changing its legacy lifetime.'
Require-Match $fixture 'smokestyle\s+"transient_trail"[\s\S]*?opticalamountscale\s+0\.5[\s\S]*?lifetime\s+4\.0[\s\S]*?transientlifetimeseconds\s+0\.75' 'Trail tuning must preserve the four-second grid rollback while shortening only transient lobes.'
Require-Match $fixture 'smokestyle\s+"transient_fire"[\s\S]*?opticalamountscale\s+0\.2[\s\S]*?lifetime\s+18\.0[\s\S]*?transientlifetimeseconds\s+3\.0' 'Fire tuning must preserve the eighteen-second grid rollback while shortening only transient lobes.'
if (([regex]::Matches($fixture, 'smokeactorrule\s+"duke_')).Count -ne 3) {
    throw 'Actor fixture must contain exactly the three canonical lifecycle overrides.'
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('smoke-transient-actor-analyzer-' + [Guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $fixtureRoot)
    $cases = @(
        @{
            Name = 'enabled'; Mask = 2
            Log = @'
NRI PT smoke emitter: event=actor-authority rule=duke_rpg_trail_continuous class=RPG actor=7 source_id=00abc123
NRI PT smoke emitter: event=frame-summary rule=duke_rpg_trail_continuous class=RPG observed=1 emitted=1 particles=8
NRI PT smoke routing: event=source gather=42 source_id=00abc123 authored=2 effective=2 class=1 source_quantity=11 grid_commands=0 analytic_carriers=0 transient_groups=1 transient_lobes=8
PERF pt smoke route frame NRI: renderer_frame=100 gather=42 mask=2 transient_groups=1 transient_lobes=8
PERF pt smoke transient NRI: renderer_frame=100 epoch=7 profile=2 valid=1 groups=1 lobes=8 group_drop=0 lobe_drop=3 reduced=2
PERF pt gpu timing NRI: frame=100 nri_frame=100 valid=1 smoke_transient_bins=0.01 smoke_transient_light_build=0.02 smoke_transient_materialize=0.03
PERF compact capture complete: status=complete requested=64 eligible=64 observed=64 pending_gpu=0 dropped=0
'@
        },
        @{
            Name = 'rollback'; Mask = 0
            Log = @'
NRI PT smoke emitter: event=actor-authority rule=duke_rpg_trail_continuous class=RPG actor=7 source_id=00abc123
NRI PT smoke emitter: event=frame-summary rule=duke_rpg_trail_continuous class=RPG observed=1 emitted=1 particles=8
NRI PT smoke routing: event=source gather=42 source_id=00abc123 authored=2 effective=0 class=1 source_quantity=11 grid_commands=8 analytic_carriers=0 transient_groups=0 transient_lobes=0
PERF pt smoke route frame NRI: renderer_frame=100 gather=42 mask=0 transient_groups=0 transient_lobes=0
PERF pt smoke transient NRI: renderer_frame=100 epoch=7 profile=2 valid=1 groups=0 lobes=0 group_drop=0 lobe_drop=0 reduced=0
PERF pt gpu timing NRI: frame=100 nri_frame=100 valid=1 smoke_transient_bins=0.00 smoke_transient_light_build=0.00 smoke_transient_materialize=0.00
PERF compact capture complete: status=complete requested=64 eligible=64 observed=64 pending_gpu=0 dropped=0
'@
        }
    )
    foreach ($case in $cases) {
        $caseRoot = Join-Path $fixtureRoot $case.Name
        [void](New-Item -ItemType Directory -Path $caseRoot)
        Set-Content -LiteralPath (Join-Path $caseRoot 'capture.log') -Value $case.Log -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools/validation/analyze-smoke-transient-actor-repro.ps1') `
            -LogDirectory $caseRoot -Effect trail -ClassMask $case.Mask | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Actor analyzer rejected $($case.Name) fixture." }
    }
    $failureCases = @(
        @{
            Name = 'disconnected-chronology'; Mask = 2
            Log = $cases[0].Log.Replace(
                'PERF pt smoke route frame NRI: renderer_frame=100 gather=42',
                'PERF pt smoke route frame NRI: renderer_frame=100 gather=41')
        },
        @{
            Name = 'short-compact-capture'; Mask = 2
            Log = $cases[0].Log.Replace(
                'requested=64 eligible=64 observed=64',
                'requested=64 eligible=63 observed=63')
        }
    )
    foreach ($case in $failureCases) {
        $caseRoot = Join-Path $fixtureRoot $case.Name
        [void](New-Item -ItemType Directory -Path $caseRoot)
        Set-Content -LiteralPath (Join-Path $caseRoot 'capture.log') -Value $case.Log -Encoding UTF8
        $failureProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $root 'tools/validation/analyze-smoke-transient-actor-repro.ps1'),
            '-LogDirectory', $caseRoot, '-Effect', 'trail', '-ClassMask', [string]$case.Mask
        ) -PassThru -Wait -WindowStyle Hidden
        if ($failureProcess.ExitCode -eq 0) { throw "Actor analyzer accepted invalid $($case.Name) fixture." }
    }
}
finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedFixtureRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host 'Smoke transient actor repro structural validation passed.'
