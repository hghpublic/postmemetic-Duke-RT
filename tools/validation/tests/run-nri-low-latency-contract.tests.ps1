param()

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$sourcePath = Join-Path $PSScriptRoot 'nri_low_latency_contract.tests.cpp'
$outputDir = Join-Path $repoRoot 'build\validation-tests'
$outputPath = Join-Path $outputDir 'nri_low_latency_contract.tests.exe'
$objectPath = Join-Path $outputDir 'nri_low_latency_contract.tests.obj'

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$vsDevCmdCandidates = @(
	'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat',
	'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat',
	'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat'
)
$vsDevCmd = $vsDevCmdCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($null -eq $vsDevCmd)
{
	throw 'Unable to locate VsDevCmd.bat.'
}

$compileCommand = 'call "{0}" -arch=x64 -host_arch=x64 && cl /nologo /std:c++17 /EHsc "{1}" /Fo:"{2}" /Fe:"{3}"' -f $vsDevCmd, $sourcePath, $objectPath, $outputPath
cmd /c $compileCommand
if ($LASTEXITCODE -ne 0)
{
	throw "Low-latency contract test compilation failed with exit code $LASTEXITCODE."
}

& $outputPath
if ($LASTEXITCODE -ne 0)
{
	throw "Low-latency contract tests failed with exit code $LASTEXITCODE."
}
