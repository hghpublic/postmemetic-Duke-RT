param(
	[string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$systemDir = Join-Path $repoRoot 'source\common\rendering\nri\system'
$testSource = Join-Path $PSScriptRoot 'nri_rendered_frame_budget.tests.cpp'
$outputDir = if ($OutputDirectory) { $OutputDirectory } else {
	Join-Path $repoRoot 'build\planner-tests\rendered-frame-budget'
}
$testExe = Join-Path $outputDir 'nri_rendered_frame_budget.tests.exe'

$vsCandidates = @(
	'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat',
	'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat'
)
$vsDevCmd = $vsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $vsDevCmd) {
	throw 'Visual Studio developer command prompt was not found.'
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$compile = 'call "{0}" -arch=x64 -host_arch=x64 -vcvars_ver=14.44 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- /MT /I"{1}" /Fo"{4}/" "{2}" /Fe:"{3}"' -f `
	$vsDevCmd, $systemDir, $testSource, $testExe, $outputDir
cmd /c $compile
if ($LASTEXITCODE -ne 0) {
	throw "Rendered-frame budget test compilation failed with exit code $LASTEXITCODE."
}

& $testExe
if ($LASTEXITCODE -ne 0) {
	throw "Rendered-frame budget tests failed with exit code $LASTEXITCODE."
}
