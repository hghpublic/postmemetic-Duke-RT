param(
	[string]$ContextSourcePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if ([string]::IsNullOrWhiteSpace($ContextSourcePath)) {
	$ContextSourcePath = Join-Path $repoRoot 'source/common/rendering/nri/renderer/nri_pass_dispatch_context.cpp'
}
$contextSourcePath = [System.IO.Path]::GetFullPath($ContextSourcePath)
$testTemplatePath = Join-Path $PSScriptRoot 'nri_smoke_service_slot_boundary.tests.cpp'
$outputDir = Join-Path $repoRoot 'build/validation-tests/nri-smoke-service-slot-boundary'
$generatedSourcePath = Join-Path $outputDir 'nri_smoke_service_slot_boundary.generated.cpp'
$testExe = Join-Path $outputDir 'nri_smoke_service_slot_boundary.tests.exe'

$contextSource = Get-Content -Raw -LiteralPath $contextSourcePath
$signature = 'NRIPassDispatchContext::FrameTextureSlot NRIPassDispatchContext::SmokeService::GetVolumeSlot(bool metadata) const'
$methodStart = $contextSource.IndexOf($signature, [StringComparison]::Ordinal)
if ($methodStart -lt 0) {
	throw 'The actual SmokeService::GetVolumeSlot implementation could not be found.'
}
$openingBrace = $contextSource.IndexOf('{', $methodStart)
if ($openingBrace -lt 0) {
	throw 'The actual SmokeService::GetVolumeSlot opening brace could not be found.'
}
$depth = 0
$methodEnd = -1
for ($index = $openingBrace; $index -lt $contextSource.Length; ++$index) {
	switch ($contextSource[$index]) {
		'{' { ++$depth }
		'}' {
			--$depth
			if ($depth -eq 0) {
				$methodEnd = $index + 1
				break
			}
		}
	}
	if ($methodEnd -ge 0) { break }
}
if ($methodEnd -le $methodStart) {
	throw 'The actual SmokeService::GetVolumeSlot closing brace could not be found.'
}
$actualImplementation = $contextSource.Substring($methodStart, $methodEnd - $methodStart)

$template = Get-Content -Raw -LiteralPath $testTemplatePath
$marker = '// ACTUAL_GET_VOLUME_SLOT_IMPLEMENTATION'
if (($template.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) -or
	($template.IndexOf($marker, $template.IndexOf($marker) + $marker.Length, [StringComparison]::Ordinal) -ge 0)) {
	throw 'The native test template must contain exactly one implementation marker.'
}
$generatedSource = $template.Replace($marker, $actualImplementation)
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($generatedSourcePath, $generatedSource, $utf8NoBom)

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
	throw 'vswhere.exe is required to locate the C++ toolchain.'
}
$installation = & $vswhere -latest -products * `
	-requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($installation)) {
	throw 'No Visual Studio C++ installation was found.'
}
$vsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
$compile = 'call "{0}" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- "{1}" /Fo"{2}/" /Fe:"{3}"' -f `
	$vsDevCmd, $generatedSourcePath, $outputDir, $testExe
$compileProcess = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/c', $compile `
	-PassThru -Wait -NoNewWindow
if ($compileProcess.ExitCode -ne 0) {
	throw "SmokeService slot-boundary test compilation failed with exit code $($compileProcess.ExitCode)."
}

& $testExe
if ($LASTEXITCODE -ne 0) {
	throw "SmokeService slot-boundary tests failed with exit code $LASTEXITCODE."
}
