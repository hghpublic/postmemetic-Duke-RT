param(
	[string]$SoundSourcePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw $Message }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if ([string]::IsNullOrWhiteSpace($SoundSourcePath)) {
	$SoundSourcePath = Join-Path $repoRoot 'source/games/duke/src/sounds.cpp'
}
$soundSourcePath = [System.IO.Path]::GetFullPath($SoundSourcePath)
$nativeTestPath = Join-Path $PSScriptRoot 'sounds_world_tour_mapping.tests.cpp'
$soundSource = Get-Content -Raw -LiteralPath $soundSourcePath

$functionStart = $soundSource.IndexOf('void S_WorldTourMappingsForOldSounds()', [StringComparison]::Ordinal)
$functionEnd = $soundSource.IndexOf('static TArray<FString> Commentaries;', $functionStart, [StringComparison]::Ordinal)
Assert-True ($functionStart -ge 0 -and $functionEnd -gt $functionStart) `
	'S_WorldTourMappingsForOldSounds could not be isolated for its lifetime contract check.'
$functionBody = $soundSource.Substring($functionStart, $functionEnd - $functionStart)

Assert-True ($functionBody -match 'unsigned\s+maxsnd\s*=\s*soundEngine->GetNumSounds\(\)\s*;[\s\S]*for\s*\(\s*unsigned\s+i\s*=\s*1\s*;\s*i\s*<\s*maxsnd\s*;') `
	'World Tour mapping must freeze the original sound count so appended replacements are not revisited.'

$allocate = [regex]::Match($functionBody, 'auto\s+newsfx\s*=\s*soundEngine->AllocateSound\(\)\s*;')
$allLookups = [regex]::Matches($functionBody, 'sfx\s*=\s*soundEngine->GetSfx\s*\(\s*FSoundID::fromInt\s*\(\s*i\s*\)\s*\)\s*;')
$reacquire = @($allLookups | Where-Object Index -gt $allocate.Index | Select-Object -First 1)
$copy = [regex]::Match($functionBody, '\*newsfx\s*=\s*\*sfx\s*;')
$backMapping = [regex]::Match($functionBody, 'sfx->UserData\s*\[\s*kWorldTourMapping\s*\]\s*=\s*soundEngine->GetNumSounds\(\)\s*-\s*1\s*;')

Assert-True $allocate.Success 'World Tour mapping no longer allocates its replacement through AllocateSound.'
Assert-True ($reacquire.Count -eq 1) `
	'AllocateSound may relocate S_sfx; reacquire the original sound by FSoundID(i) immediately after allocation.'
$reacquireMatch = $reacquire[0]
Assert-True ($allocate.Index -lt $reacquireMatch.Index -and $reacquireMatch.Index -lt $copy.Index) `
	'The original sound must be reacquired after AllocateSound and before dereferencing it for the copy.'
Assert-True ($copy.Success -and $copy.Index -lt $backMapping.Index) `
	'The replacement copy must precede the original sound back-mapping write.'

$allocationToReacquire = $functionBody.Substring(
	$allocate.Index + $allocate.Length,
	$reacquireMatch.Index - ($allocate.Index + $allocate.Length))
Assert-True ($allocationToReacquire -notmatch '\bsfx\s*->|\*\s*sfx\b') `
	'The potentially stale source pointer is dereferenced before it is reacquired.'
$reacquireToBackMapping = $functionBody.Substring(
	$reacquireMatch.Index,
	($backMapping.Index + $backMapping.Length) - $reacquireMatch.Index)
Assert-True ($reacquireToBackMapping -notmatch 'AllocateSound\s*\(') `
	'Another allocation invalidates the reacquired source/replacement pointers before back-mapping completes.'

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
$outputDir = Join-Path $repoRoot 'build/validation-tests/sounds-world-tour-mapping'
$testExe = Join-Path $outputDir 'sounds_world_tour_mapping.tests.exe'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$compile = 'call "{0}" -arch=x64 -host_arch=x64 >nul && cl /nologo /std:c++17 /EHsc /W4 /WX /permissive- "{1}" /Fo"{2}/" /Fe:"{3}"' -f `
	$vsDevCmd, $nativeTestPath, $outputDir, $testExe
$compileProcess = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/c', $compile `
	-PassThru -Wait -NoNewWindow
if ($compileProcess.ExitCode -ne 0) {
	throw "World Tour sound lifetime model compilation failed with exit code $($compileProcess.ExitCode)."
}
& $testExe
if ($LASTEXITCODE -ne 0) {
	throw "World Tour sound lifetime model failed with exit code $LASTEXITCODE."
}

Write-Host 'World Tour sound mapping lifetime tests passed.'
