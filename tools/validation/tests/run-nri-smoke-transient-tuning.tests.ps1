Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$releasePath = Join-Path $root 'release-overlay/LIGHTOVR'
$release = Get-Content -LiteralPath $releasePath -Raw

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Block([string]$Kind, [string]$Name) {
    $escaped = [regex]::Escape($Name)
    $matches = [regex]::Matches($release, '(?s)' + $Kind + '\s+"' + $escaped + '"\s*\{([^{}]*)\}')
    Require ($matches.Count -eq 1) "Expected exactly one $Kind block for $Name."
    return $matches[0].Groups[1].Value
}

function Scalar([string]$Body, [string]$Field) {
    $matches = [regex]::Matches($Body, '(?m)^\s*' + [regex]::Escape($Field) + '\s+([-+]?[0-9]*\.?[0-9]+)\s*(?://.*)?$')
    Require ($matches.Count -eq 1) "Expected exactly one numeric $Field field."
    return [double]::Parse($matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

$expectedOptics = [ordered]@{
    duke_explosion_smoke = 0.05
    duke_trail_smoke = 0.125
    duke_impact_smoke = 0.25
    duke_muzzle_smoke = 0.25
}
foreach ($entry in $expectedOptics.GetEnumerator()) {
    $body = Block 'smokestyle' $entry.Key
    Require ((Scalar $body 'opticalamountscale') -eq $entry.Value) `
        "$($entry.Key) must retain its protected transient optical scale $($entry.Value)."
}

$fireStyle = Block 'smokestyle' 'duke_fire_smoke'
$fireRule = Block 'smokeactorrule' 'duke_fire_sustained'
$unchangedStyle = [ordered]@{
    density = 3.0; extinction = 0.008; radius = 7.0; expansionvelocity = 10.0; densityhalflife = 6.0
    intrinsicemission = 0.5; curlvelocity = 4.0; coreplateau = 0.60
    edgeerosion = 0.16; noisescale = 0.035; noisestrength = 0.20
}
foreach ($entry in $unchangedStyle.GetEnumerator()) {
    Require ((Scalar $fireStyle $entry.Key) -eq $entry.Value) `
        "Production fire $($entry.Key) drifted from the validated non-tuning field $($entry.Value)."
}
$radiusRanges = [regex]::Matches($fireStyle, '(?m)^\s*loberadiusrandom\s+([-+]?[0-9]*\.?[0-9]+)\s+([-+]?[0-9]*\.?[0-9]+)\s*$')
Require ($radiusRanges.Count -eq 1) 'Production fire must retain exactly one two-value lobe-radius range.'
$radiusRandom = $radiusRanges[0]
$radiusMin = [double]::Parse($radiusRandom.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
$radiusMax = [double]::Parse($radiusRandom.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
foreach ($requiredRuleText in @(
    'representation\s+"transient-cloud"', 'effectclass\s+fire', 'lobecount\s+5',
    'style\s+"duke_fire_smoke"', 'count\s+9', 'spawnradius\s+4\.0',
    'densityscale\s+3\.0', 'radiusscale\s+3\.0', 'velocitycone\s+0\.0',
    'velocityscale\s+0\.0', 'offset\s+0\.0\s+0\.0\s+-32\.0')) {
    Require ($fireRule -match $requiredRuleText) "Production fire rule lost $requiredRuleText."
}
Require ($fireRule -match '(?m)^\s*emitterforeground\s+off\s*$') `
    'Production fire must keep emitterforeground off so its sprite does not cut out smoke resolve.'

$optical = Scalar $fireStyle 'opticalamountscale'
$lifetime = Scalar $fireStyle 'transientlifetimeseconds'
$rise = Scalar $fireStyle 'risevelocity'
$sustain = Scalar $fireStyle 'densitysustainseconds'
$densityRelease = Scalar $fireStyle 'densityreleaseseconds'
$spread = Scalar $fireStyle 'clusterspread'
$cadence = Scalar $fireRule 'intervalseconds'
$pulse = Scalar $fireRule 'pulseamount'
$attack = Scalar $fireStyle 'densityattackseconds'
$emissionHalfLife = Scalar $fireStyle 'emissionhalflife'
$expansion = Scalar $fireStyle 'expansionvelocity'
$radiusExponent = Scalar $fireStyle 'radiusexponent'
Require ($radiusExponent -eq 0.60) "Production fire must front-load growth with exponent 0.60; found $radiusExponent."
$explosionExpansion = Scalar (Block 'smokestyle' 'duke_explosion_smoke') 'expansionvelocity'
Require ([math]::Abs($explosionExpansion / 18.0 - 2.0 / 3.0) -lt 1.0e-6) `
    "Production explosion expansion must be two-thirds of the previous 18; found $explosionExpansion."
Require ($optical -eq 0.25) "Production fire optical scale must remain 0.25; found $optical."
Require ($lifetime -eq 5.5) "Production fire lifetime must remain 5.5; found $lifetime."
Require ($rise -eq 120.0) "Production fire rise must remain 120.0; found $rise."
Require ($sustain -eq 1.5) "Production fire sustain must remain 1.5; found $sustain."
Require ($densityRelease -eq 4.0) "Production fire release must remain 4.0; found $densityRelease."
Require ($spread -eq 0.20) "Production fire spread must remain 0.20; found $spread."
Require ($cadence -eq 0.5) "Production fire cadence must remain 0.5; found $cadence."
Require ($radiusMin -eq 0.30 -and $radiusMax -eq 0.45) `
    "Production fire lobe-radius range must remain 0.30..0.45; found $radiusMin..$radiusMax."
Require ($pulse -eq 0.15) "Production fire pulse amount must remain 0.15; found $pulse."
Require ($attack -eq 0.20) "Production fire attack must remain 0.20; found $attack."
Require ($emissionHalfLife -eq 0.40) `
    "Production fire emission half-life must remain 0.40; found $emissionHalfLife."
Require ($fireRule -match '(?m)^\s*pulseperiodcadences\s+12\s*$' -and
    $fireRule -match '(?m)^\s*pulsephase\s+0\.7916667\s*$') `
    'Production fire pulse period/phase must remain 12 / 0.7916667.'

$emitterSource = Get-Content -LiteralPath (Join-Path $root 'source/common/rendering/nri/renderer/nri_smoke_emitters.cpp') -Raw
Require ($emitterSource -match 'shape\.deterministicSeed\s*=\s*HashAnalyticCarrier\(sourceEventSerial,\s*0u\)') `
    'Production fire seed handoff drifted from the deterministic shape fixture.'
Require ($emitterSource -match '(?s)uint32_t HashAnalyticCarrier\(uint64_t eventSerial, uint32_t carrierIndex\).*?0x9e3779b9u.*?0x7feb352du.*?0x846ca68bu') `
    'Production shape seed transform drifted from the native mirror.'
Require ($emitterSource -match '(?s)shape\.transientClass\s*==\s*NRISmokeTransientClass::FirePacket.*?shape\.lobeDelayStepSeconds\s*=\s*transientEmissionSpanSeconds\s*/\s*static_cast<float>\(shape\.requestedLobeCount\)') `
    'Production fire must divide the actor cadence across its requested lobe births.'
Require ($emitterSource -match '(?s)rule\.trigger\s*==\s*LightOverlaySmokeTrigger::Interval\s*\?\s*rule\.intervalSeconds\s*:\s*0\.0f') `
    'The interval-rule cadence must remain the transient fire emission span.'

$outputDir = Join-Path $root 'build/smoke-transient-tuning-tests'
$testExe = Join-Path $outputDir 'nri_smoke_transient_tuning.tests.exe'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$include = Join-Path $root 'source/common/rendering/nri/renderer'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe is required to locate the C++ toolchain.' }
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) { throw 'No Visual Studio C++ installation was found.' }
$vsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
$sources = @(
    (Join-Path $PSScriptRoot 'nri_smoke_transient_tuning.tests.cpp'),
    (Join-Path $include 'nri_smoke_transient_clouds.cpp')
)
$quotedSources = ($sources | ForEach-Object { '"' + $_ + '"' }) -join ' '
$compile = 'call "' + $vsDevCmd + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /I"' +
    $include + '" /Fo"' + $outputDir + '/" ' + $quotedSources + ' /Fe:"' + $testExe + '"'
& cmd.exe /d /c $compile
if ($LASTEXITCODE -ne 0) { throw "transient tuning test compilation failed with exit code $LASTEXITCODE" }

$arguments = @($optical, $lifetime, $rise, $sustain, $densityRelease, $spread, $cadence,
    $radiusMin, $radiusMax, $pulse, $attack, $emissionHalfLife, $expansion, $radiusExponent) |
    ForEach-Object { $_.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
& $testExe @arguments
if ($LASTEXITCODE -ne 0) { throw "transient tuning tests failed with exit code $LASTEXITCODE" }
Write-Host "Production fire fields exercised: optical=$optical life=$lifetime rise=$rise sustain=$sustain release=$densityRelease spread=$spread cadence=$cadence radii=$radiusMin..$radiusMax pulse=$pulse attack=$attack emission_half=$emissionHalfLife expansion=$expansion exponent=$radiusExponent; explosion expansion=$explosionExpansion"
