[CmdletBinding()]
param(
    [switch]$RunRuntime,
    [string]$RazePath,
    [string]$GameGrp,
    [string]$OutputDirectory,
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$cvars = Get-Content -Raw -LiteralPath (Join-Path $repo 'source/common/rendering/nri/renderer/nri_cvars.cpp')
$settings = Get-Content -Raw -LiteralPath (Join-Path $repo 'source/common/rendering/nri/renderer/nri_renderer_settings.h')
$config = Get-Content -Raw -LiteralPath (Join-Path $repo 'source/core/gameconfigfile.cpp')

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-BracedBlock([string]$Source, [string]$Anchor) {
    $start = $Source.IndexOf($Anchor, [StringComparison]::Ordinal)
    Require ($start -ge 0) "Missing block: $Anchor"
    $open = $Source.IndexOf('{', $start)
    Require ($open -ge 0) "Missing opening brace: $Anchor"
    $depth = 0
    for ($index = $open; $index -lt $Source.Length; ++$index) {
        if ($Source[$index] -eq '{') { ++$depth }
        if ($Source[$index] -eq '}') {
            --$depth
            if ($depth -eq 0) { return $Source.Substring($open + 1, $index - $open - 1) }
        }
    }
    throw "Unterminated block: $Anchor"
}

$expected = [ordered]@{
    nri_ptsmokedensityscale = @{ type = 'Float'; value = 1; member = 'densityScale'; memberType = 'float' }
    nri_ptsmokelightmode = @{ type = 'Int'; value = 2; member = 'lightMode'; memberType = 'uint32_t' }
}
$smokeSettings = Get-BracedBlock $settings 'struct NRISmokeSettings'
foreach ($entry in $expected.GetEnumerator()) {
    $pattern = '(?m)^CVAR\(' + $entry.Value.type + ',\s*' + $entry.Key + ',\s*([^,]+),\s*CVAR_ARCHIVE\s*\|\s*CVAR_GLOBALCONFIG\)'
    $definitions = [regex]::Matches($cvars, $pattern)
    Require ($definitions.Count -eq 1) "Expected one archived global definition for $($entry.Key)"
    $value = [double]::Parse($definitions[0].Groups[1].Value.Trim().TrimEnd('f'), [Globalization.CultureInfo]::InvariantCulture)
    Require ($value -eq $entry.Value.value) "Incorrect compiled default for $($entry.Key)"
    $memberPattern = '\b' + $entry.Value.memberType + '\s+' + $entry.Value.member + '\s*=\s*([^;]+);'
    $member = [regex]::Match($smokeSettings, $memberPattern)
    Require $member.Success "Missing NRISmokeSettings fallback: $($entry.Value.member)"
    $fallback = [double]::Parse($member.Groups[1].Value.Trim().TrimEnd('f'), [Globalization.CultureInfo]::InvariantCulture)
    Require ($fallback -eq $entry.Value.value) "Fallback and CVar disagree: $($entry.Key)"
}

$version = [regex]::Match($config, '#define\s+LASTRUNVERSION\s+"(\d+)"')
Require ($version.Success -and [int]$version.Groups[1].Value -ge 11) 'The smoke-default migration requires archived config version 11 or newer.'
$currentVersion = [int]$version.Groups[1].Value
$globalSetup = Get-BracedBlock $config 'void FGameConfigFile::DoGlobalSetup'
Require ($globalSetup -match 'double\s+last\s*=\s*0\s*;\s*if\s*\(SetSection\s*\("LastRun"\)\)') 'Unversioned configs must start at legacy version zero.'
Require ($globalSetup -match '\blast\s*=\s*atof\s*\(lastver\)') 'Read the stored version without shadowing the unversioned fallback.'
Require ([regex]::Matches($globalSetup, '\bdouble\s+last\b').Count -eq 1) 'The migration version must not be shadowed inside LastRun handling.'
$migration = Get-BracedBlock $globalSetup 'if (last < 11)'
$targets = @([regex]::Matches($migration, '"(nri_\w+)"') | ForEach-Object { $_.Groups[1].Value })
Require ($targets.Count -eq 2) 'The version 11 migration must target exactly two settings.'
foreach ($name in $expected.Keys) { Require ($targets -contains $name) "Missing migration target: $name" }
Require ($migration -match 'for\s*\([^)]*:\s*\{[\s\S]*FindCVar\(name,\s*nullptr\)[\s\S]*var->ResetToDefault\(\)') 'The legacy migration must reset the two CVars to their compiled defaults.'
$lastRunBlock = Get-BracedBlock $globalSetup 'if (SetSection ("LastRun"))'
Require (-not $lastRunBlock.Contains('if (last < 11)')) 'The new migration must also handle a missing LastRun section or Version key.'
Require ($globalSetup.IndexOf('ReadCVars (CVAR_GLOBALCONFIG);') -lt $globalSetup.IndexOf('if (last < 11)')) 'Migrate after loading archived globals.'
$archive = Get-BracedBlock $config 'void FGameConfigFile::ArchiveGlobalData'
Require ($archive -match 'SetValueForKey\s*\("Version",\s*LASTRUNVERSION\)') 'Normal saves must persist the migration version.'
Require ($archive -match 'C_ArchiveCVars\s*\(this,\s*CVAR_ARCHIVE\|CVAR_GLOBALCONFIG\)') 'Normal saves must persist migrated global values.'
$readConfig = Get-BracedBlock $config 'void G_ReadConfig'
Require ($readConfig -match 'C_ParseCmdLineParams\(exec\)[\s\S]*exec->ExecCommands\(\)') 'Explicit command-line settings must remain supported after config loading.'
Write-Host 'Smoke defaults and migration static contracts passed.'

if (-not $RunRuntime) { return }

# Runtime fixtures are isolated from the user's settings, autoexec, saves and
# overlays. OpenGL startup is sufficient: these are CPU config/CVar tests, not
# smoke-rendering tests. No map or NRI shader compilation is needed.
if (-not $RazePath) { $RazePath = Join-Path $repo 'build/terminal-ninja/raze.exe' }
if (-not $GameGrp) { throw '-GameGrp is required with -RunRuntime.' }
$RazePath = (Resolve-Path -LiteralPath $RazePath).Path
$GameGrp = (Resolve-Path -LiteralPath $GameGrp).Path
Require (@(Get-Process -Name raze, duke-rt -ErrorAction SilentlyContinue).Count -eq 0) 'Close existing game processes before running isolated migration tests.'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repo ('tools/logs/validation/smoke-defaults-migration-' + [guid]::NewGuid().ToString('N'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
Require (-not (Test-Path -LiteralPath $OutputDirectory)) "Refusing to overwrite existing output directory: $OutputDirectory"
$null = New-Item -ItemType Directory -Path $OutputDirectory
$results = [Collections.Generic.List[object]]::new()

function Quote-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW/MSVC quoting, including trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Write-Fixture([string]$Path, [string]$Version, [string]$Density, [string]$LightMode) {
    $lines = [Collections.Generic.List[string]]::new()
    if ($Version -ne '') {
        $lines.Add('[LastRun]')
        $lines.Add('Version=' + $Version)
    }
    $lines.Add('[GlobalSettings]')
    $lines.Add('vid_preferbackend=0')
    $lines.Add('fullscreen=false')
    $lines.Add('vid_defwidth=640')
    $lines.Add('vid_defheight=480')
    $lines.Add('nri_ptsmoketimescale=0.75')
    if ($Density -ne '') { $lines.Add('nri_ptsmokedensityscale=' + $Density) }
    if ($LightMode -ne '') { $lines.Add('nri_ptsmokelightmode=' + $LightMode) }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Read-IniSection([string]$Text, [string]$Section) {
    $match = [regex]::Match($Text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*\r?\n(.*?)(?=^\[|\z)')
    Require $match.Success "Missing archived section: $Section"
    return $match.Groups[1].Value
}

function Assert-ArchivedNumber([string]$Section, [string]$Name, [double]$ExpectedValue) {
    $matches = [regex]::Matches($Section, '(?m)^' + [regex]::Escape($Name) + '=([^\r\n]+)')
    Require ($matches.Count -eq 1) "Expected exactly one archived $Name"
    $actual = [double]::Parse($matches[0].Groups[1].Value.Trim(), [Globalization.CultureInfo]::InvariantCulture)
    Require ($actual -eq $ExpectedValue) "Archived $Name expected $ExpectedValue, got $actual"
}

function Invoke-Fixture([string]$Name, [string]$ConfigPath, [double]$Density, [int]$LightMode, [string[]]$Overrides = @()) {
    $logPath = Join-Path $OutputDirectory ($Name + '.log')
    $savePath = Join-Path $OutputDirectory ($Name + '-saves')
    $null = New-Item -ItemType Directory -Path $savePath
    $arguments = @('-config', $ConfigPath, '-noautoexec', '-savedir', $savePath,
        '-gamegrp', $GameGrp, '-nosound', '-nologo', '-width', '640', '-height', '480',
        '+set', 'vid_preferbackend', '0', '+set', 'fullscreen', 'false',
        '+logfile', $logPath.Replace('\', '/')) + $Overrides +
        @('+wait 20; echo SMOKE_DEFAULTS_QUERY; nri_ptsmokedensityscale; nri_ptsmokelightmode; echo SMOKE_DEFAULTS_DONE; quit')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $RazePath
    $start.Arguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $start.WorkingDirectory = Split-Path -Parent $RazePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Require ($process.Start()) "Failed to start runtime fixture: $Name"
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw "Runtime fixture timed out after $TimeoutSeconds seconds: $Name (owned PID $($process.Id))"
        }
        Require ($process.ExitCode -eq 0) "Runtime fixture exited $($process.ExitCode): $Name"
    }
    finally { $process.Dispose() }
    Require (Test-Path -LiteralPath $logPath) "No query log for runtime fixture: $Name"
    $log = Get-Content -Raw -LiteralPath $logPath
    Require ($log.Contains('SMOKE_DEFAULTS_QUERY') -and $log.Contains('SMOKE_DEFAULTS_DONE')) "Incomplete query markers: $Name"
    foreach ($entry in @(@{ name = 'nri_ptsmokedensityscale'; value = $Density }, @{ name = 'nri_ptsmokelightmode'; value = $LightMode })) {
        $query = [regex]::Match($log, '"' + $entry.name + '"\s+is\s+"([^"\r\n]+)"')
        Require $query.Success "Missing live $($entry.name) query in $Name"
        $actual = [double]::Parse($query.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        Require ($actual -eq $entry.value) "Live $($entry.name) expected $($entry.value), got $actual in $Name"
    }
    $saved = Get-Content -Raw -LiteralPath $ConfigPath
    Assert-ArchivedNumber (Read-IniSection $saved 'LastRun') 'Version' $currentVersion
    $globals = Read-IniSection $saved 'GlobalSettings'
    Assert-ArchivedNumber $globals 'nri_ptsmokedensityscale' $Density
    Assert-ArchivedNumber $globals 'nri_ptsmokelightmode' $LightMode
    Assert-ArchivedNumber $globals 'nri_ptsmoketimescale' 0.75
    $results.Add([pscustomobject]@{ case = $Name; density = $Density; lightMode = $LightMode; version = $currentVersion; passed = $true; config = $ConfigPath; log = $logPath })
    Write-Host "Smoke migration runtime passed: $Name"
}

$cases = @(
    @{ name = 'fresh'; version = ''; density = ''; light = ''; expectedDensity = 1; expectedLight = 2 },
    @{ name = 'legacy-defaults'; version = '10'; density = '5'; light = '3'; expectedDensity = 1; expectedLight = 2 },
    @{ name = 'legacy-custom'; version = '10'; density = '7.5'; light = '1'; expectedDensity = 1; expectedLight = 2 },
    @{ name = 'unversioned-legacy'; version = ''; density = '5'; light = '3'; expectedDensity = 1; expectedLight = 2 },
    @{ name = 'current-custom'; version = '11'; density = '7.5'; light = '1'; expectedDensity = 7.5; expectedLight = 1 }
)
foreach ($case in $cases) {
    $path = Join-Path $OutputDirectory ($case.name + '.ini')
    Write-Fixture $path $case.version $case.density $case.light
    Invoke-Fixture $case.name $path $case.expectedDensity $case.expectedLight
}

# Retest the config actually saved by the migration, after a user's later edit.
$migratedPath = Join-Path $OutputDirectory 'legacy-defaults.ini'
$migrated = Get-Content -Raw -LiteralPath $migratedPath
$migrated = [regex]::Replace($migrated, '(?m)^nri_ptsmokedensityscale=[^\r\n]+', 'nri_ptsmokedensityscale=7.5')
$migrated = [regex]::Replace($migrated, '(?m)^nri_ptsmokelightmode=[^\r\n]+', 'nri_ptsmokelightmode=1')
[IO.File]::WriteAllText($migratedPath, $migrated, [Text.UTF8Encoding]::new($false))
Invoke-Fixture 'migrated-second-launch' $migratedPath 7.5 1

$overridePath = Join-Path $OutputDirectory 'explicit-override.ini'
Write-Fixture $overridePath '10' '5' '3'
Invoke-Fixture 'explicit-override' $overridePath 2.5 0 @('+set', 'nri_ptsmokedensityscale', '2.5', '+set', 'nri_ptsmokelightmode', '0')
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
Write-Host "All $($results.Count) isolated smoke-default migration runtime cases passed: $OutputDirectory"
