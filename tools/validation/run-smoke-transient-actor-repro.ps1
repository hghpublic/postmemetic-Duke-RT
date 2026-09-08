param(
    [ValidateSet('explosion', 'trail', 'fire')]
    [string]$Effect = 'trail',
    [int]$ClassMask = -1,
    [ValidateRange(0, 3)][int]$Profile = 2,
    [ValidateRange(64, 1024)][int]$CaptureFrames = 256,
    [ValidateRange(180, 1200)][int]$DrainTics = 300,
    [switch]$IncludeMapFog,
    [switch]$IncludeOtherSources,
    [switch]$Production,
    [switch]$Cold,
    [switch]$TrailSideView,
    [ValidateSet('all', 'point', 'directional', 'emissive', 'none')][string]$Lighting = 'all',
    [switch]$ApiValidation,
    [string]$RazePath = 'build/terminal-ninja/raze.exe',
    [string]$File = 'build/smoke-content/full-voxel-overlay',
    [string]$GameGrp = 'C:/Program Files (x86)/Steam/steamapps/common/Duke Nukem 3D Twentieth Anniversary World Tour/DUKE3D.GRP',
    [string]$ConfigTemplate = 'C:/Users/min-spec-rt-desktop/Documents/My Games/duke-rt/duke-rt.ini',
    [string]$RpgSaveDirectory = 'C:/repos/Duke-RT/tools/perf-saves/Duke.WorldTour',
    [string]$OutputDirectory,
    [int]$TimeoutSeconds = 240,
    [switch]$ValidateOnly,
    [switch]$SkipAnalyze
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$classBits = @{ explosion = 1; trail = 2; fire = 4 }
if ($ClassMask -lt 0) { $ClassMask = [int]$classBits[$Effect] }
if ($ClassMask -lt 0 -or $ClassMask -gt 63) { throw 'ClassMask must be in [0,63].' }
if ($Production -and $Cold) { throw '-Cold requires the candidate actor fixture; it cannot edit production authoring in place.' }
if ($TrailSideView -and $Effect -ne 'trail') { throw '-TrailSideView is only valid with -Effect trail.' }
$sourceClassMask = if ($IncludeOtherSources) { 63 } else { [int]$classBits[$Effect] }
$baseContent = (Resolve-Path -LiteralPath $File -ErrorAction Stop).Path
$releaseOverlay = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'release-overlay') -ErrorAction Stop).Path
$actorFixture = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'overlays/smoke-transient-actor-fixtures') -ErrorAction Stop).Path
$resolvedGameGrp = (Resolve-Path -LiteralPath $GameGrp -ErrorAction Stop).Path
$resolvedConfigTemplate = (Resolve-Path -LiteralPath $ConfigTemplate -ErrorAction Stop).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot ('tools/logs/smoke-transient-actor/{0}-{1}-mask{2}-p{3}-f{4}-side{5}-mapfog{6}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Effect, $ClassMask, $Profile, $CaptureFrames, [int][bool]$TrailSideView, [int][bool]$IncludeMapFog)
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath (Join-Path $output 'scenario.json')) {
    throw "A capture already exists at $output; choose a fresh output directory."
}
$shots = Join-Path $output 'screenshots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$config = Join-Path $output 'isolated.ini'
Copy-Item -LiteralPath $resolvedConfigTemplate -Destination $config
$configText = Get-Content -LiteralPath $config -Raw
foreach ($pair in @(@('vid_defwidth', '1280'), @('vid_defheight', '720'), @('win_w', '-1'), @('win_h', '-1'))) {
    $pattern = '(?m)^{0}=.*$' -f $pair[0]
    $replacement = $pair[0] + '=' + $pair[1]
    if ([regex]::IsMatch($configText, $pattern)) { $configText = [regex]::Replace($configText, $pattern, $replacement) }
    else { $configText += "`r`n$replacement" }
}
$configText | Set-Content -LiteralPath $config -Encoding UTF8

# Preserve the exact candidate bytes selected for this cohort. Cold changes only
# intrinsic emission in this capture-local copy; it never mutates source content.
$fixtureSnapshot = Join-Path $output 'fixture-snapshot'
New-Item -ItemType Directory -Path $fixtureSnapshot | Out-Null
$fixtureText = Get-Content -LiteralPath (Join-Path $actorFixture 'LIGHTOVR') -Raw
if ($Cold) { $fixtureText = [regex]::Replace($fixtureText, '(?m)^(\s*intrinsicemission\s+)\S+', '${1}0.0') }
$fixtureSnapshotFile = Join-Path $fixtureSnapshot 'LIGHTOVR'
$fixtureText | Set-Content -LiteralPath $fixtureSnapshotFile -Encoding UTF8
$resolvedRazePath = (Resolve-Path -LiteralPath $RazePath -ErrorAction Stop).Path
$contentHashes = [ordered]@{
    executable = (Get-FileHash -LiteralPath $resolvedRazePath -Algorithm SHA256).Hash
    fixture = (Get-FileHash -LiteralPath $fixtureSnapshotFile -Algorithm SHA256).Hash
    releaseLightovr = (Get-FileHash -LiteralPath (Join-Path $releaseOverlay 'LIGHTOVR') -Algorithm SHA256).Hash
    baseLightovr = (Get-FileHash -LiteralPath (Join-Path $baseContent 'LIGHTOVR') -Algorithm SHA256).Hash
    configTemplate = (Get-FileHash -LiteralPath $resolvedConfigTemplate -Algorithm SHA256).Hash
    effectiveConfig = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
}
$shaderDirectory = Join-Path (Split-Path -Parent $resolvedRazePath) 'shaders/nri'
$shaderHashes = [ordered]@{}
foreach ($shader in @(Get-ChildItem -LiteralPath $shaderDirectory -File | Where-Object { $_.Extension -in @('.dxil', '.spirv') } | Sort-Object Name)) {
    $shaderHashes[$shader.Name] = (Get-FileHash -LiteralPath $shader.FullName -Algorithm SHA256).Hash
}
$contentHashes['shaders'] = $shaderHashes

$extra = [Collections.Generic.List[string]]::new()
$extra.Add('-config'); $extra.Add($config)
$extra.Add('-width'); $extra.Add('1280'); $extra.Add('-height'); $extra.Add('720')
# The base content is scenario.launch.file. Production authoring follows it,
# then this fixture replaces only the three canonical candidate actor rules.
$extra.Add('-file'); $extra.Add($releaseOverlay)
if (-not $Production) { $extra.Add('-file'); $extra.Add($fixtureSnapshot) }
$settings = [ordered]@{
    vid_fullscreen = 'false'; vid_defwidth = '1280'; vid_defheight = '720'
    use_mouse = 'false'; use_joystick = 'false'; cl_viewbob = '0'; cl_autoaim = '0'; cl_dukepitchmode = '0'
    nri_upscaler = '0'; nri_upscalermode = '0'; nri_ptoutputmode = '0'; nri_renderscale = '1'
    nri_ptsmoke = 'true'; nri_ptsmokeworkprofile = [string]$Profile
    nri_ptsmoketransientmask = [string]$ClassMask
    nri_ptsmokesourceclassmask = [string]$sourceClassMask
    nri_ptsmoketransientselfshadow = 'true'
    nri_ptsmokemapemitters = ([string][bool]$IncludeMapFog).ToLowerInvariant()
    nri_ptsmokerepresentation = '1'; nri_ptsmoketrace = '0'
    nri_ptsmokereadback = 'true'; nri_ptsmokedensityscale = '1'
    nri_ptsmokeradiancescale = '1'
    nri_ptsmokepointlights = ([string]($Lighting -in @('all', 'point'))).ToLowerInvariant()
    nri_ptsmokedirectionallight = ([string]($Lighting -in @('all', 'directional'))).ToLowerInvariant()
    nri_ptsmokeemissivelights = ([string]($Lighting -in @('all', 'emissive'))).ToLowerInvariant()
    nri_ptsmokelightmode = $(if ($Lighting -eq 'none') { '0' } else { '2' })
    nri_ptsmokevolumehistory = 'false'
    nri_ptsmokeindirect = 'false'; nri_ptmapsmokeeditmode = 'false'
    nri_ptloadingtrace = '0'; nri_ptgputiming = 'true'
    nri_ptwaitpresent = 'false'; nri_validation = 'true'
    nri_apivalidation = ([string][bool]$ApiValidation).ToLowerInvariant()
    screenshot_dir = $shots.Replace('\', '/')
    screenshotname = "actor-$Effect-mask$ClassMask"
}
foreach ($setting in $settings.GetEnumerator()) {
    $extra.Add('+set'); $extra.Add([string]$setting.Key); $extra.Add([string]$setting.Value)
}

$commonCapture = "perf_looptraceframes 0; perf_compactframes $CaptureFrames; wait 1; screenshot; wait 5; screenshot; wait 12; screenshot; wait 24; screenshot; wait 45; screenshot; nri_ptsmokestatus; wait $DrainTics; quit"
$hasRpgSave = $false
if ($Effect -eq 'fire') {
    # E1L1 sprites 195/196 are the adjacent FIRE2/FIRE pair at
    # (548,3584,32)/(574,3598,32). This camera is in open sector 325 and
    # looks through the 202/179 portal rings into their sector 178. Moving
    # east from x=700 to x=800 retains sector 325 (east boundary x=816) while
    # increasing target distance from about 126 to 226 units so the rising
    # crown remains in frame. The old
    # (1040,3432,-6) camera put z=-6 below sector 285's floor at -92.
    # The two-tic movement remains the best available player-sector relink.
    $commands = "+wait 45; map e1l1; wait 1; closemenu; wait 240; god; warptocoords 800 3584 -96 180 10; wait 2; +Move_Forward; wait 2; -Move_Forward; wait 60; nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset; $commonCapture"
}
else {
    $rpgSavePath = if ($RpgSaveDirectory) { Join-Path $RpgSaveDirectory 'smoke-offscreen.dsave' } else { '' }
    $hasRpgSave = $rpgSavePath -and (Test-Path -LiteralPath $rpgSavePath -PathType Leaf)
    $postFire = if ($Effect -eq 'explosion') { 'wait 60; ' } else { '' }
    $validatedFloorViewSetup = 'warptocoords -1616 760 -708 180 8; wait 2; +Move_Forward; wait 2; -Move_Forward; wait 20'
    $trailSideLaunchSetup = 'warptocoords -1616 760 -708 180 0; wait 2; +Move_Forward; wait 2; -Move_Forward; wait 20'
    $rpgViewSetup = if ($TrailSideView) { $trailSideLaunchSetup } else { $validatedFloorViewSetup }
    if ($hasRpgSave) {
        $setup = 'load smoke-offscreen; wait 35; closemenu; wait 240; god; slot 5; ' + $rpgViewSetup
    }
    else {
        # Core's `give` CCMD accepts both WEAPONS and AMMO, and Duke binds the
        # RPG to slot 5. This is the portable path when smoke-offscreen.dsave is
        # absent; the projectile and impact remain real gameplay actors.
        $setup = 'map e1l1; wait 1; closemenu; wait 240; god; give weapons; give ammo; slot 5; ' + $rpgViewSetup
    }
    $observationTransition = if ($TrailSideView) { 'warptocoords -1800 560 -708 153 0; ' } else { '' }
    $commands = "+wait 45; $setup; nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset; perf_looptraceframes 0; perf_compactframes $CaptureFrames; +Fire; wait 8; -Fire; ${observationTransition}${postFire}wait 1; screenshot; wait 5; screenshot; wait 12; screenshot; wait 24; screenshot; wait 45; screenshot; nri_ptsmokestatus; wait $DrainTics; quit"
}

$ruleIds = @{ explosion = 'duke_explosion_cloud'; trail = 'duke_rpg_trail_continuous'; fire = 'duke_fire_sustained' }
$captureViewpoint = if ($Effect -eq 'fire') {
    [ordered]@{ targetActors = @(195, 196); position = @(800, 3584, -96); yaw = 180; pitch = 10; sector = 325; targetDistanceWorldUnits = 226 }
}
elseif ($TrailSideView) {
    [ordered]@{
        mode = 'trail-side-view'
        launch = [ordered]@{ position = @(-1616, 760, -708); yaw = 180; pitch = 0; sector = 298 }
        observation = [ordered]@{ position = @(-1800, 560, -708); yaw = 153; pitch = 0; firstScreenshotWaitUpdates = 1 }
        cameraValidation = 'unverified camera candidate; screenshot review is required before acceptance'
    }
}
else {
    [ordered]@{ position = @(-1616, 760, -708); yaw = 180; pitch = 8; sector = 298; target = 'roof floor before fence'; autoAim = $false; requireRuntimeImpactLogValidation = $true }
}
$scenario = [ordered]@{
    name = "smoke-transient-actor-$Effect-mask$ClassMask-p$Profile-f$CaptureFrames-light$Lighting-side$([int][bool]$TrailSideView)-cold$([int][bool]$Cold)-mapfog$([int][bool]$IncludeMapFog)-production$([int][bool]$Production)"
    backend = 'd3d12'
    description = 'Real-actor transient/rollback routing, lifecycle, lighting, capacity, and display-referred age captures.'
    commands = $commands
    capture = [ordered]@{ loopTraceFrames = 0; runs = 1; timeoutSeconds = $TimeoutSeconds; stopWhenLoopTraceFramesCaptured = $false }
    launch = [ordered]@{ file = $baseContent; gameGrp = $resolvedGameGrp; extraArgs = $extra.ToArray() }
    requiredPrefixes = @(
        "NRI PT smoke emitter: event=frame-summary rule=$($ruleIds[$Effect]) ",
        'NRI PT smoke routing: event=source ', 'PERF pt smoke route frame NRI:',
        'PERF pt smoke transient NRI:', 'PERF pt gpu timing NRI:',
        'PERF compact capture complete:', 'screenshot saved')
    forbiddenPatterns = @('Device removed', 'device lost', 'NRI render failed', 'NRI error:', 'validation error', 'failed to create', 'assertion failed', 'fatal error', 'LIGHTOVR parse error', 'LIGHTOVR: Script error', 'Unknown command', 'Failed to open savegame')
    transientActor = [ordered]@{
        effect = $Effect; rule = $ruleIds[$Effect]; classBit = $classBits[$Effect]
        mask = $ClassMask; profile = $Profile; captureFrames = $CaptureFrames
        sourceClassMask = $sourceClassMask; includeOtherSources = [bool]$IncludeOtherSources
        production = [bool]$Production; cold = [bool]$Cold; lighting = $Lighting
        apiValidation = [bool]$ApiValidation
        drainTics = $DrainTics; includeMapFog = [bool]$IncludeMapFog; usedRpgSave = [bool]$hasRpgSave
        trailSideView = [bool]$TrailSideView
        viewpoint = $captureViewpoint
        baseContent = $baseContent; releaseOverlay = $releaseOverlay
        actorFixtureSource = $actorFixture; actorFixtureSnapshot = $fixtureSnapshot
        actorFixtureMounted = -not [bool]$Production
        exposure = [ordered]@{ frozenDuringCapture = $true; basis = 'per-run meter at capture start; not a common calibrated exposure across runs' }
        sha256 = $contentHashes
        settings = $settings
    }
}
if ($Effect -ne 'fire' -and $hasRpgSave) {
    $scenario.save = [ordered]@{ dir = $RpgSaveDirectory; name = 'smoke-offscreen' }
}
$scenarioPath = Join-Path $output 'scenario.json'
$scenario | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
if ($ValidateOnly) { Write-Host "Transient actor preflight: $scenarioPath"; return }

& (Join-Path $PSScriptRoot 'run-nri-perf.ps1') -ScenarioPath $scenarioPath -RazePath $RazePath -Runs 1 -TimeoutSeconds $TimeoutSeconds -OutputDirectory (Join-Path $output 'run')
$runSummaryPath = Join-Path $output 'run/summary.json'
if (-not (Test-Path -LiteralPath $runSummaryPath -PathType Leaf)) { throw "Actor capture did not produce $runSummaryPath." }
$runSummary = Get-Content -LiteralPath $runSummaryPath -Raw | ConvertFrom-Json
if (-not $runSummary.ok) { throw "Actor capture failed; inspect $runSummaryPath and run-1.log." }
if (-not $SkipAnalyze) {
    $runLogPath = Join-Path $output 'run/run-1.log'
    $transientSummaryPath = Join-Path $output 'transient-summary.json'
    $transientParameters = @{
        LogPath = @($runLogPath)
        SummaryOutput = $transientSummaryPath
        ExpectedSourceClassMask = $sourceClassMask
    }
    if ($ClassMask -eq 0) { $transientParameters.AllowLegacyControl = $true }
    if (-not $IncludeMapFog) {
        $transientParameters.RequireMapEmittersDisabled = $true
        $transientParameters.MinimumSuppressedMapRules = 4
    }
    & (Join-Path $PSScriptRoot 'analyze-smoke-transient-repro.ps1') @transientParameters | Out-Null
    $transientSummary = Get-Content -LiteralPath $transientSummaryPath -Raw | ConvertFrom-Json
    if (-not $transientSummary.passed) { throw "Strict transient analysis failed; inspect $transientSummaryPath." }

    $actorSummaryPath = Join-Path $output 'actor-summary.json'
    & (Join-Path $PSScriptRoot 'analyze-smoke-transient-actor-repro.ps1') -LogDirectory (Join-Path $output 'run') -Effect $Effect -ClassMask $ClassMask -MinimumCompactFrames $CaptureFrames -SummaryOutput $actorSummaryPath | Out-Null
    $actorSummary = Get-Content -LiteralPath $actorSummaryPath -Raw | ConvertFrom-Json
    if (-not $actorSummary.ok) { throw "Strict actor analysis failed; inspect $actorSummaryPath." }
    Write-Host "Transient analysis passed: $transientSummaryPath"
    Write-Host "Actor analysis passed: $actorSummaryPath"
}
