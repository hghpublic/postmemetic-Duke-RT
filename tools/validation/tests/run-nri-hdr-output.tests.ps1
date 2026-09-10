Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$outputDir = Join-Path $root 'build/nri-hdr-output-tests'
$testExe = Join-Path $outputDir 'nri_hdr_output.tests.exe'
$includeDir = Join-Path $root 'source/common/rendering/nri'
$testSource = Join-Path $PSScriptRoot 'nri_hdr_output.tests.cpp'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

# Keep compiler side products out of the checkout root. No renderer or GPU launch.
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe is required to locate the C++ toolchain.' }
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) { throw 'No Visual Studio C++ installation was found.' }
$vsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
$compile = 'call "' + $vsDevCmd + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- /I"' +
    $includeDir + '" /Fo"' + $outputDir + '/" "' + $testSource + '" /Fe:"' + $testExe + '"'
Push-Location $outputDir
try {
    & cmd.exe /d /c $compile
    if ($LASTEXITCODE -ne 0) { throw "HDR output test compilation failed with exit code $LASTEXITCODE" }
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "HDR output tests failed with exit code $LASTEXITCODE" }
}
finally { Pop-Location }

# Golden source guard: these shared/SDR functions must remain exactly unchanged by
# the HDR correction. Normalize CRLF only so Git line-ending policy is immaterial.
$mappingPath = Join-Path $includeDir 'shaders/Include/DisplayMapping.hlsli'
$mapping = Get-Content -Raw -LiteralPath $mappingPath
$names = @(
    'ApplyPresentSceneContrast', 'ApplyDisplayToe', 'ApplyDisplayShoulder',
    'ApplyDisplayToeAndShoulder', 'ApplyDisplaySaturation', 'ApplyDisplayCalibration',
    'TonemapHable', 'TonemapAcesFitted', 'TonemapReinhard', 'ApplySdrTonemap',
    'LinearToSrgbChannel', 'LinearToSrgb', 'ApplySdrTransferAndDither'
)
$bodies = foreach ($name in $names) {
    $match = [regex]::Match($mapping, '(?m)^float(?:3)?\s+' + [regex]::Escape($name) + '\s*\(')
    if (-not $match.Success) { throw "Missing unchanged SDR/shared function: $name" }
    $begin = $mapping.IndexOf('{', $match.Index)
    if ($begin -lt 0) { throw "Missing function body: $name" }
    $depth = 1
    $end = $begin + 1
    while ($depth -gt 0 -and $end -lt $mapping.Length) {
        if ($mapping[$end] -eq '{') { $depth++ }
        if ($mapping[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unbalanced function body: $name" }
    $mapping.Substring($match.Index, $end - $match.Index).Replace("`r`n", "`n")
}
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $actualHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($bodies -join "`n`n")))).Replace('-', '').ToLowerInvariant()
}
finally { $sha.Dispose() }
$expectedHash = '0bf0fbc94271502d03f4fd3b29c0b96f27ea97fa06a88f724bc38b3192193f53'
if ($actualHash -ne $expectedHash) { throw "SDR/shared mapping functions changed: expected $expectedHash, actual $actualHash" }
if ($mapping -notmatch '#include\s+"HdrOutputMath\.hlsli"' -or $mapping -notmatch 'NriHdrTonemapChannel\s*\(' -or $mapping -notmatch 'NriHdrSaturationScale\s*\(') {
    throw 'HDR shader must consume the tested production scalar tone-map and saturation functions.'
}
$renderState = Get-Content -Raw -LiteralPath (Join-Path $includeDir 'renderer/nri_renderstate.cpp')
$frameGen = Get-Content -Raw -LiteralPath (Join-Path $includeDir 'framegen/nri_framegen.cpp')
if ($renderState -notmatch 'OutputInfo\[0\]\s*=\s*GetNRIPTHdrUiWhiteScale\(outputPolicy\)' -or
    $frameGen -notmatch 'contract\.hdrPaperWhiteScale\s*=\s*GetNRIPTHdrUiWhiteScale\(outputPolicy\)') {
    throw '2D UI and frame-generation UI metadata must use their dedicated legacy-compatible white scale.'
}
Write-Host 'HDR output wiring passed; all 13 shared/SDR mapping functions are unchanged.'
