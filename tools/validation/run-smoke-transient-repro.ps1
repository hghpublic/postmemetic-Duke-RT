param(
    [ValidateSet('explosion', 'trail', 'fire', 'muzzle', 'impact')]
    [string]$Effect = 'explosion',
    [ValidateRange(0, 63)][int]$ClassMask = 63,
    [ValidateRange(0, 3)][int]$Profile = 2,
    [ValidateRange(0, 64)][int]$FroxelPixels = 0,
    [ValidateRange(0, 128)][int]$FroxelDepth = 0,
    [ValidateRange(1, 80)][int]$Burst = 1,
    [ValidateRange(0, 2)][int]$Representation = 1,
    [switch]$MixedGrid,
    [switch]$IncludeMapFog,
    [switch]$IncludeOtherSources,
    [switch]$Cold,
    [ValidateSet('e1l1', 'e3l6')][string]$Map = 'e1l1',
    [ValidateRange(1, 4096)][int]$Distance = 256,
    [ValidateSet('all', 'point', 'directional', 'emissive', 'none')][string]$Lighting = 'all',
    [switch]$TestPointLight,
    [switch]$ApiValidation,
    [string]$RazePath = 'build/terminal-ninja/raze.exe',
    [string]$File = 'build/smoke-content/full-voxel-overlay',
    [string]$GameGrp = 'C:/Program Files (x86)/Steam/steamapps/common/Duke Nukem 3D Twentieth Anniversary World Tour/DUKE3D.GRP',
    [string]$ConfigTemplate = 'C:/Users/min-spec-rt-desktop/Documents/My Games/duke-rt/duke-rt.ini',
    [string]$OutputDirectory,
    [int]$TimeoutSeconds = 180,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (($FroxelPixels -ne 0 -or $FroxelDepth -ne 0) -and $Profile -ne 0) {
    throw 'Explicit froxel resolution requires Reference profile 0; other profiles enforce their fixed table.'
}
$minimumSuppressedMapRules = if ($Map -eq 'e1l1') { 4 } else { 0 }
$classBits = @{ explosion = 1; trail = 2; fire = 4; muzzle = 8; impact = 16 }
$sourceClassMask = if ($IncludeOtherSources) { 63 } else { [int]$classBits[$Effect] }
$baseContent = (Resolve-Path -LiteralPath $File -ErrorAction Stop).Path
$releaseOverlay = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'release-overlay') -ErrorAction Stop).Path
$fixture = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'overlays/smoke-transient-fixtures') -ErrorAction Stop).Path
$resolvedGameGrp = (Resolve-Path -LiteralPath $GameGrp -ErrorAction Stop).Path
$resolvedConfigTemplate = (Resolve-Path -LiteralPath $ConfigTemplate -ErrorAction Stop).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot ('tools/logs/smoke-transient/{0}-{1}-{2}-mask{3}-p{4}-mapfog{5}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Map, $Effect, $ClassMask, $Profile, [int][bool]$IncludeMapFog)
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath (Join-Path $output 'scenario.json')) {
    throw "A capture already exists at $output; choose a fresh output directory."
}
$shots = Join-Path $output 'screenshots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$config = Join-Path $output 'isolated.ini'
Copy-Item -LiteralPath $resolvedConfigTemplate -Destination $config
# These values are read before most +set commands during window creation.
$configText = Get-Content -LiteralPath $config -Raw
foreach ($pair in @(@('vid_defwidth', '1280'), @('vid_defheight', '720'), @('win_w', '-1'), @('win_h', '-1'))) {
    $configText = [regex]::Replace($configText, ('(?m)^{0}=.*$' -f $pair[0]), ($pair[0] + '=' + $pair[1]))
}
$configText | Set-Content -LiteralPath $config -Encoding UTF8
# Preserve the actual fixture bytes for every cohort. Cold changes only local
# intrinsic emission; geometry, density, and all external light families remain.
$fixtureSnapshot = Join-Path $output 'fixture-snapshot'
New-Item -ItemType Directory -Path $fixtureSnapshot | Out-Null
$fixtureText = Get-Content -LiteralPath (Join-Path $fixture 'LIGHTOVR') -Raw
if ($Cold) { $fixtureText = [regex]::Replace($fixtureText, '(?m)^(\s*intrinsicemission\s+)\S+', '${1}0.0') }
$fixtureSnapshotFile = Join-Path $fixtureSnapshot 'LIGHTOVR'
$fixtureText | Set-Content -LiteralPath $fixtureSnapshotFile -Encoding UTF8
$contentHashes = [ordered]@{
    executable = (Get-FileHash -LiteralPath (Resolve-Path -LiteralPath $RazePath).Path -Algorithm SHA256).Hash
    fixture = (Get-FileHash -LiteralPath $fixtureSnapshotFile -Algorithm SHA256).Hash
    releaseLightovr = (Get-FileHash -LiteralPath (Join-Path $releaseOverlay 'LIGHTOVR') -Algorithm SHA256).Hash
    baseLightovr = (Get-FileHash -LiteralPath (Join-Path $baseContent 'LIGHTOVR') -Algorithm SHA256).Hash
    configTemplate = (Get-FileHash -LiteralPath $resolvedConfigTemplate -Algorithm SHA256).Hash
}
$shaderDirectory = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $RazePath).Path) 'shaders/nri'
$shaderHashes = [ordered]@{}
foreach ($shader in @(Get-ChildItem -LiteralPath $shaderDirectory -File | Where-Object { $_.Extension -in @('.dxil', '.spirv') } | Sort-Object Name)) {
    $shaderHashes[$shader.Name] = (Get-FileHash -LiteralPath $shader.FullName -Algorithm SHA256).Hash
}
$contentHashes['shaders'] = $shaderHashes
$extra = [Collections.Generic.List[string]]::new()
$extra.Add('-config'); $extra.Add($config)
$extra.Add('-width'); $extra.Add('1280'); $extra.Add('-height'); $extra.Add('720')
$extra.Add('-file'); $extra.Add($releaseOverlay)
$extra.Add('-file'); $extra.Add($fixtureSnapshot)
$settings = [ordered]@{
    vid_fullscreen = 'false'; vid_defwidth = '1280'; vid_defheight = '720'
    use_mouse = 'false'; use_joystick = 'false'; cl_viewbob = '0'; cl_dukepitchmode = '0'
    nri_upscaler = '0'; nri_upscalermode = '0'; nri_ptoutputmode = '0'; nri_renderscale = '1'
    nri_ptsmoke = 'true'; nri_ptsmokeworkprofile = [string]$Profile
    nri_ptsmoketransientmask = [string]$ClassMask
    nri_ptsmokesourceclassmask = [string]$sourceClassMask
    nri_ptsmoketransientselfshadow = 'true'
    nri_ptsmokemapemitters = ([string][bool]$IncludeMapFog).ToLowerInvariant()
    nri_ptsmokerepresentation = [string]$Representation
    nri_ptsmoketrace = '0'; nri_ptsmokereadback = 'true'
    nri_ptsmokedensityscale = '1'; nri_ptsmokeradiancescale = '1'
    nri_ptsmokepointlights = ([string]($Lighting -in @('all', 'point'))).ToLowerInvariant()
    nri_ptsmokedirectionallight = ([string]($Lighting -in @('all', 'directional'))).ToLowerInvariant()
    nri_ptsmokeemissivelights = ([string]($Lighting -in @('all', 'emissive'))).ToLowerInvariant()
    nri_ptsmokelightmode = $(if ($Lighting -eq 'none') { '0' } else { '2' })
    nri_ptsmokevolumehistory = 'false'; nri_ptsmokeindirect = 'false'
    nri_ptmapsmokeeditmode = 'false'; nri_ptloadingtrace = '0'
    nri_ptgputiming = 'true'; nri_ptwaitpresent = 'false'
    nri_validation = 'true'; nri_apivalidation = ([string][bool]$ApiValidation).ToLowerInvariant()
    screenshot_dir = $shots.Replace('\', '/'); screenshotname = $Effect
}
if ($FroxelPixels -gt 0) { $settings['nri_ptsmokefroxelpixels'] = [string]$FroxelPixels }
if ($FroxelDepth -gt 0) { $settings['nri_ptsmokefroxelz'] = [string]$FroxelDepth }
foreach ($setting in $settings.GetEnumerator()) {
    $extra.Add('+set'); $extra.Add([string]$setting.Key); $extra.Add([string]$setting.Value)
}
$emit = ((1..$Burst | ForEach-Object { "nri_ptsmoke_test transient.$Effect.fixture $Distance" }) -join '; ')
$grid = if ($MixedGrid) { 'nri_ptsmoke_test; ' } else { '' }
$testLight = if ($TestPointLight) { 'nri_ptlightspawn 1.0 0.8 0.6 5.0 512 128; wait 2; ' } else { '' }
$screenshotWaitUpdates = @(1, 5, 12, 24, 45)
$cumulativeWaitUpdates = 0
$screenshotGameplayAgesSeconds = @($screenshotWaitUpdates | ForEach-Object {
    $cumulativeWaitUpdates += $_
    [math]::Round(($cumulativeWaitUpdates + 1) / 30.0, 6)
})
$screenshotCommands = ($screenshotWaitUpdates | ForEach-Object { "wait $_; screenshot" }) -join '; '
# Move from the fence-side sector into E1L1's open roof sector 298 and aim west.
# The World Tour map has about 290 world units to the blocking fence/wall in this
# lane; use -Distance 160 for unobstructed art captures with room for growth.
$viewSetup = if ($Map -eq 'e1l1') { 'warptocoords -1616 760 -708 180 0; wait 2; +Move_Forward; wait 2; -Move_Forward; wait 20; ' } else { '' }
$viewpoint = if ($Map -eq 'e1l1') {
    [ordered]@{ position = @(-1616, 760, -708); yaw = 180; pitch = 0; sector = 298; recommendedEventDistanceWorldUnits = 160; blockingDistanceWorldUnits = 290 }
} else { $null }
$commands = "+wait 45; map $Map; wait 1; closemenu; wait 240; closemenu; god; ${viewSetup}centerview; wait 2; nri_ptautoexposurefreeze true; set nri_ptsmoketrace 2; nri_ptsmokereset; ${testLight}perf_looptraceframes 0; perf_compactframes 64; ${grid}${emit}; $screenshotCommands; nri_ptsmokestatus; wait 180; quit"
$scenario = [ordered]@{
    name = "smoke-transient-$Map-$Effect-mask$ClassMask-p$Profile-source$sourceClassMask-cold$([int][bool]$Cold)-mapfog$([int][bool]$IncludeMapFog)"
    backend = 'd3d12'
    description = 'Same-build transient/legacy A/B with test-isolated map fog by default; first-use and aging display-referred captures with joined GPU counters.'
    commands = $commands
    capture = [ordered]@{ loopTraceFrames = 0; runs = 1; timeoutSeconds = $TimeoutSeconds; stopWhenLoopTraceFramesCaptured = $false }
    launch = [ordered]@{ file = $baseContent; gameGrp = $resolvedGameGrp; extraArgs = $extra.ToArray() }
    requiredPrefixes = @('NRI PT smoke event test queued:', 'screenshot saved', 'PERF pt smoke route frame NRI:', 'PERF pt smoke transient NRI:', 'PERF pt gpu timing NRI:', 'PERF compact capture complete:')
    forbiddenPatterns = @('Device removed', 'device lost', 'NRI render failed', 'NRI error:', 'validation error', 'failed to create', 'assertion failed', 'fatal error', 'LIGHTOVR: Script error', 'LIGHTOVR parse error', 'no resolved smoke-event rule', 'Unknown command')
    transient = [ordered]@{ map = $Map; effect = $Effect; mask = $ClassMask; profile = $Profile; burst = $Burst; distance = $Distance; lighting = $Lighting; testPointLight = [bool]$TestPointLight; representation = $Representation; mixedGrid = [bool]$MixedGrid; includeMapFog = [bool]$IncludeMapFog; minimumSuppressedMapRules = $minimumSuppressedMapRules; delayedCommandUpdatesPerSecond = 30; playClockUnitsPerUpdate = 4; screenshotWaitUpdates = $screenshotWaitUpdates; screenshotGameplayAgesSeconds = $screenshotGameplayAgesSeconds; settings = $settings }
}
$scenario.transient['sourceClassMask'] = $sourceClassMask
$scenario.transient['cold'] = [bool]$Cold
$scenario.transient['includeOtherSources'] = [bool]$IncludeOtherSources
$scenario.transient['fixtureSnapshot'] = $fixtureSnapshot
$scenario.transient['viewSetup'] = $viewSetup
$scenario.transient['viewpoint'] = $viewpoint
$scenario.transient['sha256'] = $contentHashes
$scenarioPath = Join-Path $output 'scenario.json'
$scenario | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
if ($ValidateOnly) { Write-Host "Transient smoke preflight: $scenarioPath"; return }
& (Join-Path $PSScriptRoot 'run-nri-perf.ps1') -ScenarioPath $scenarioPath -RazePath $RazePath -Runs 1 -TimeoutSeconds $TimeoutSeconds -OutputDirectory (Join-Path $output 'run')
$runSummary = Get-Content -LiteralPath (Join-Path $output 'run/summary.json') -Raw | ConvertFrom-Json
if (-not $runSummary.ok) { throw "Transient capture failed; inspect $output/run/summary.json and run-1.log." }
$analysisParameters = @{
    LogPath = @(Join-Path $output 'run/run-1.log')
    SummaryOutput = Join-Path $output 'transient-summary.json'
    ExpectedSourceClassMask = $sourceClassMask
}
if ($ClassMask -eq 0) { $analysisParameters.AllowLegacyControl = $true }
if (-not $IncludeMapFog) {
    $analysisParameters.RequireMapEmittersDisabled = $true
    $analysisParameters.MinimumSuppressedMapRules = $minimumSuppressedMapRules
}
& (Join-Path $PSScriptRoot 'analyze-smoke-transient-repro.ps1') @analysisParameters | Out-Null
$transientSummary = Get-Content -LiteralPath $analysisParameters.SummaryOutput -Raw | ConvertFrom-Json
if (-not $transientSummary.passed) { throw "Strict transient analysis failed; inspect $($analysisParameters.SummaryOutput)." }
Write-Host "Transient analysis passed: $($analysisParameters.SummaryOutput)"
