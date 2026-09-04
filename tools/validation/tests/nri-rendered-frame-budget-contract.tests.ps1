Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Match([string]$Text, [string]$Pattern, [string]$Message) {
	if ($Text -notmatch $Pattern) { throw $Message }
}

function Require-Order([string]$Text, [string[]]$Needles, [string]$Message) {
	$cursor = 0
	foreach ($needle in $Needles) {
		$next = $Text.IndexOf($needle, $cursor, [StringComparison]::Ordinal)
		if ($next -lt 0) { throw "$Message Missing or out of order: $needle" }
		$cursor = $next + $needle.Length
	}
}

function Get-FunctionBody([string]$Text, [string]$Signature) {
	$start = $Text.IndexOf($Signature, [StringComparison]::Ordinal)
	if ($start -lt 0) { throw "Function signature not found: $Signature" }
	$open = $Text.IndexOf('{', $start)
	if ($open -lt 0) { throw "Function body not found: $Signature" }
	$depth = 0
	for ($index = $open; $index -lt $Text.Length; ++$index) {
		switch ($Text[$index]) {
			'{' { ++$depth }
			'}' {
				--$depth
				if ($depth -eq 0) { return $Text.Substring($open, $index - $open + 1) }
			}
		}
	}
	throw "Unterminated function body: $Signature"
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$cvars = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\renderer\nri_cvars.cpp') -Raw
$frameShell = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_frame_shell.h') -Raw
$renderHeader = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_renderdevice.h') -Raw
$renderDevice = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_renderdevice.cpp') -Raw

Require-Match $cvars 'CUSTOM_CVAR\(Int,\s*nri_ptframesinflight,\s*3,' `
	'nri_ptframesinflight must default to the existing throughput depth of three.'
$framesInFlightCvar = Get-FunctionBody $cvars 'CUSTOM_CVAR(Int, nri_ptframesinflight'
$cvarUsesPolicyClamp = $framesInFlightCvar -match 'self\s*=\s*nri_frame_budget::ClampLimit\('
$cvarUsesExplicitClamp = $framesInFlightCvar -match 'self\s*<\s*1[\s\S]*?self\s*=\s*1[\s\S]*?self\s*>\s*3[\s\S]*?self\s*=\s*3'
if (-not $cvarUsesPolicyClamp -and -not $cvarUsesExplicitClamp) {
	throw 'nri_ptframesinflight must clamp every assignment to 1..3.'
}
Require-Match $frameShell 'QueuedFrameCount\s*=\s*3' `
	'Physical queued-frame resources must remain three slots, independent of rendered admission.'
Require-Match $renderHeader 'WaitForRenderedFrameAdmission\s*\(' `
	'The backend shell is missing a focused rendered-frame admission owner.'

$beginFrame = Get-FunctionBody $renderDevice 'void NRIRenderDevice::BeginFrame('
Require-Order $beginFrame @(
	'WaitForCommands(false);',
	'WaitForRenderedFrameAdmission(',
	'EnsureSwapChainSize()',
	'AcquireNextTexture('
) 'BeginFrame must recycle its physical slot, enforce rendered admission, then acquire.'

$preload = Get-FunctionBody $renderDevice 'bool NRIRenderDevice::BeginPreloadCommandContext('
if ($preload -match 'WaitForRenderedFrameAdmission') {
	throw 'Offscreen preload command contexts must not consume the rendered-frame latency budget.'
}
Require-Match $preload 'WaitForCommands\(false\);' `
	'Preload must retain ordinary physical queued-slot reuse protection.'

$admission = Get-FunctionBody $renderDevice 'bool NRIRenderDevice::WaitForRenderedFrameAdmission()'
Require-Match $admission 'hasSubmittedWork[\s\S]*lastSubmittedFenceValue' `
	'Admission must be derived from actually successful queued-frame fence ownership.'
Require-Match $admission 'CountOutstanding\s*\(' `
	'Admission telemetry must count actual successful unretired submissions.'
Require-Match $admission 'SelectAdmissionFence\s*\(' `
	'Admission must select a successful fence rather than derive one from frame-index arithmetic.'
Require-Match $admission 'WaitForFenceValue\s*\([\s\S]*admission' `
	'Admission must wait for the selected successful submission fence.'

$physicalRecycle = Get-FunctionBody $renderDevice 'void NRIRenderDevice::WaitForCommands('
Require-Match $physicalRecycle 'mQueuedFrames\[GetQueuedFrameIndex\(mFrameIndex\)\][\s\S]*hasSubmittedWork[\s\S]*lastSubmittedFenceValue' `
	'Physical slot recycling must wait on the selected slot last successful submission.'
if ($physicalRecycle -match '1\s*\+\s*mFrameIndex\s*-\s*mQueuedFrames\.size\(\)') {
	throw 'Physical slot recycling must not derive a potentially unsignaled fence from frame index arithmetic.'
}

Require-Order $beginFrame @(
	'WaitForRenderedFrameAdmission(',
	'mFrameGeneration.BeginFrame(*this);',
	'EnsureSwapChainSize()'
) 'Frame admission must precede frame-generation lifecycle work and swapchain acquisition.'

# The physical resource/streamer/swapchain contract remains overallocated at
# three; changing latency policy must not force resource or swapchain rebuilds.
Require-Match $renderDevice 'streamerDesc\.queuedFrameNum\s*=\s*QueuedFrameCount;' `
	'NRI streamer sizing must remain tied to physical queued-frame slots.'
Require-Match $renderDevice 'swapChainDesc\.queuedFrameNum\s*=\s*QueuedFrameCount;' `
	'NRI swapchain queue sizing must remain separate from rendered admission.'
Require-Match $renderDevice 'mQueuedFrames\.resize\(QueuedFrameCount\);' `
	'Command allocator/buffer storage must retain all three physical slots.'

Require-Match $renderDevice 'NRI PT frame boundary:[^\n]*rendered_limit=%u[^\n]*physical_qframes=%u[^\n]*admission_target=%llu[^\n]*outstanding_before=%u[^\n]*outstanding_after=%u' `
	'Frame-boundary telemetry must expose effective limit, physical slots, admission target, and before/after depth.'

Write-Host 'NRI rendered-frame budget structural contract tests passed.'
