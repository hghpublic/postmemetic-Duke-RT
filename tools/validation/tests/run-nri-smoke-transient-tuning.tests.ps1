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
    duke_explosion_smoke = 0.075
    duke_fire_smoke = 0.05
    duke_trail_smoke = 0.125
    duke_impact_smoke = 0.25
    duke_muzzle_smoke = 0.25
}
foreach ($entry in $expectedOptics.GetEnumerator()) {
    $body = Block 'smokestyle' $entry.Key
    Require ((Scalar $body 'opticalamountscale') -eq $entry.Value) `
        "$($entry.Key) must retain the requested quarter transient optical scale $($entry.Value)."
}

$fireStyle = Block 'smokestyle' 'duke_fire_smoke'
$fireRule = Block 'smokeactorrule' 'duke_fire_sustained'
$unchangedStyle = [ordered]@{
    density = 3.0; radius = 7.0; expansionvelocity = 10.0; densityhalflife = 6.0
    densityattackseconds = 0.08; radiusexponent = 0.90; intrinsicemission = 0.5
    emissionhalflife = 0.18; curlvelocity = 4.0; coreplateau = 0.60
    edgeerosion = 0.16; noisescale = 0.035; noisestrength = 0.20
}
foreach ($entry in $unchangedStyle.GetEnumerator()) {
    Require ((Scalar $fireStyle $entry.Key) -eq $entry.Value) `
        "Production fire $($entry.Key) drifted from the validated non-tuning field $($entry.Value)."
}
$radiusRandom = [regex]::Match($fireStyle, '(?m)^\s*loberadiusrandom\s+0\.40\s+0\.70\s*$')
Require $radiusRandom.Success 'Production fire lobe-radius range must remain 0.40..0.70.'
foreach ($requiredRuleText in @(
    'representation\s+"transient-cloud"', 'effectclass\s+fire', 'lobecount\s+5',
    'style\s+"duke_fire_smoke"', 'count\s+9', 'spawnradius\s+4\.0',
    'densityscale\s+3\.0', 'radiusscale\s+3\.0')) {
    Require ($fireRule -match $requiredRuleText) "Production fire rule lost $requiredRuleText."
}

$optical = Scalar $fireStyle 'opticalamountscale'
$lifetime = Scalar $fireStyle 'transientlifetimeseconds'
$rise = Scalar $fireStyle 'risevelocity'
$sustain = Scalar $fireStyle 'densitysustainseconds'
$densityRelease = Scalar $fireStyle 'densityreleaseseconds'
$spread = Scalar $fireStyle 'clusterspread'
$cadence = Scalar $fireRule 'intervalseconds'
Require ($optical -eq 0.05) "Production fire optical scale must remain 0.05; found $optical."
Require ($lifetime -eq 5.5) "Production fire lifetime must remain 5.5; found $lifetime."
Require ($rise -eq 120.0) "Production fire rise must remain 120.0; found $rise."
Require ($sustain -eq 2.75) "Production fire sustain must remain 2.75; found $sustain."
Require ($densityRelease -eq 2.75) "Production fire release must remain 2.75; found $densityRelease."
Require ($spread -eq 1.30) "Production fire spread must remain 1.30; found $spread."
Require ($cadence -eq 0.5) "Production fire cadence must remain 0.5; found $cadence."

$emitterSource = Get-Content -LiteralPath (Join-Path $root 'source/common/rendering/nri/renderer/nri_smoke_emitters.cpp') -Raw
Require ($emitterSource -match 'shape\.deterministicSeed\s*=\s*HashAnalyticCarrier\(sourceEventSerial,\s*0u\)') `
    'Production fire seed handoff drifted from the deterministic shape fixture.'
Require ($emitterSource -match '(?s)uint32_t HashAnalyticCarrier\(uint64_t eventSerial, uint32_t carrierIndex\).*?0x9e3779b9u.*?0x7feb352du.*?0x846ca68bu') `
    'Production shape seed transform drifted from the native mirror.'

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

$arguments = @($optical, $lifetime, $rise, $sustain, $densityRelease, $spread, $cadence) |
    ForEach-Object { $_.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
& $testExe @arguments
if ($LASTEXITCODE -ne 0) { throw "transient tuning tests failed with exit code $LASTEXITCODE" }
Write-Host "Production fire fields exercised: optical=$optical life=$lifetime rise=$rise sustain=$sustain release=$densityRelease spread=$spread cadence=$cadence"
