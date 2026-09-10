Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$cvars = Get-Content -Raw -LiteralPath (Join-Path $repo 'source/common/rendering/nri/renderer/nri_cvars.cpp')

# Approved HDR settings captured on 2026-09-10. This fixture deliberately does
# not read an untracked user INI, so it also runs on a clean checkout.
$hdrDefaults = [ordered]@{
    nri_pthdrtonemap = '1'
    nri_pthdrexposure = '2.01992'
    nri_pthdrcontrast = '1.00312'
    nri_pthdrsaturation = '1.33125'
    nri_pthdrshoulder = '0.828125'
    nri_pthdrtoe = '1.04688'
    nri_ptpaperwhite = '201'
    nri_pthdrautoexposure = 'true'
    nri_pthdrautoexposuretarget = '0.0353125'
    nri_pthdrautoexposurebias = '1.03555'
    nri_pthdrautoexposuremin = '1.30127'
    nri_pthdrautoexposuremax = '1.81836'
}

function Assert-Default([string]$Name, [string]$Expected) {
    $pattern = '(?m)^(?:CUSTOM_)?CVAR\(\s*(Int|Float|Bool),\s*' + [regex]::Escape($Name) + ',\s*([^,]+),\s*CVAR_ARCHIVE\s*\|\s*CVAR_GLOBALCONFIG\)'
    $matches = [regex]::Matches($cvars, $pattern)
    if ($matches.Count -ne 1) { throw "Expected exactly one archived global default for $Name" }
    $actual = $matches[0].Groups[2].Value.Trim()
    if ($matches[0].Groups[1].Value -eq 'Bool') {
        if ($actual -ne $Expected) { throw "$Name expected $Expected, found $actual" }
    } else {
        $parsed = [double]::Parse($actual.TrimEnd('f'), [Globalization.CultureInfo]::InvariantCulture)
        $wanted = [double]::Parse($Expected, [Globalization.CultureInfo]::InvariantCulture)
        if ($parsed -ne $wanted) { throw "$Name expected $Expected, found $actual" }
    }
}

foreach ($entry in $hdrDefaults.GetEnumerator()) { Assert-Default $entry.Key $entry.Value }
$hdrNames = @([regex]::Matches($cvars, '(?m)^(?:CUSTOM_)?CVAR\([^,]+,\s*(nri_pthdr\w+),') | ForEach-Object { $_.Groups[1].Value })
if ($hdrNames.Count -ne 11) { throw 'Review the HDR-defaults fixture when adding or removing HDR controls.' }
foreach ($name in $hdrNames) {
    if (-not $hdrDefaults.Contains($name)) { throw "Missing HDR default coverage for $name" }
}

# Shared auto-exposure controls already matched the requested settings; changing
# them would also affect SDR. Its separate grading/AE defaults stay protected.
$unchanged = [ordered]@{
    nri_ptoutputmode = '1'
    nri_pttonemap = '2'
    nri_ptexposure = '1.06016'
    nri_ptcontrast = '1.14688'
    nri_ptsaturation = '1.75'
    nri_ptshoulder = '1.5'
    nri_pttoe = '1.1'
    nri_ptautoexposure = 'true'
    nri_ptautoexposuretarget = '0.03225'
    nri_ptautoexposurebias = '0.469531'
    nri_ptautoexposuremin = '2.74561'
    nri_ptautoexposuremax = '4.00977'
    nri_ptautoexposuremetering = '1'
    nri_ptautoexposurebins = '256'
    nri_ptautoexposuresamplestep = '2'
    nri_ptautoexposurelowpercentile = '1.01563'
    nri_ptautoexposurehighpercentile = '98.9844'
    nri_ptautoexposureadaptup = '3'
    nri_ptautoexposureadaptdown = '1'
}
foreach ($entry in $unchanged.GetEnumerator()) { Assert-Default $entry.Key $entry.Value }

if ([double]$hdrDefaults.nri_pthdrautoexposuremin -ge [double]$hdrDefaults.nri_pthdrautoexposuremax) {
    throw 'Approved HDR auto-exposure interval must have nonzero ordered bounds.'
}
Write-Host "HDR defaults passed: $($hdrDefaults.Count) approved controls and $($unchanged.Count) unchanged SDR/shared controls."
