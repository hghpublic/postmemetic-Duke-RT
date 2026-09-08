Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$outputDir = Join-Path $root 'build/smoke-transient-trail-chunk-tests'
$testExe = Join-Path $outputDir 'nri_smoke_transient_trail_chunks.tests.exe'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$include = Join-Path $root 'source/common/rendering/nri/renderer'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe is required to locate the C++ toolchain.' }
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) { throw 'No Visual Studio C++ installation was found.' }
$vsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
$source = Join-Path $PSScriptRoot 'nri_smoke_transient_trail_chunks.tests.cpp'
$compile = 'call "' + $vsDevCmd + '" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /I"' +
    $include + '" /Fo"' + $outputDir + '/" "' + $source + '" /Fe:"' + $testExe + '"'
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/c', $compile -PassThru -Wait -NoNewWindow
if ($process.ExitCode -ne 0) { throw "transient trail chunk test compilation failed with exit code $($process.ExitCode)" }
& $testExe
if ($LASTEXITCODE -ne 0) { throw "transient trail chunk tests failed with exit code $LASTEXITCODE" }
