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
$video = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\v_video.h') -Raw
$mainLoop = Get-Content -LiteralPath (Join-Path $repo 'source\core\mainloop.cpp') -Raw
$renderDevice = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_renderdevice.cpp') -Raw
$renderHeader = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_renderdevice.h') -Raw
$policy = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_low_latency_policy.cpp') -Raw
$policyHeader = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\system\nri_low_latency_policy.h') -Raw
$frameGeneration = Get-Content -LiteralPath (Join-Path $repo 'source\common\rendering\nri\framegen\nri_framegen.cpp') -Raw

Require-Match $cvars 'CUSTOM_CVAR\(Bool,\s*nri_lowlatency,\s*false,' `
	'Native low latency must remain opt-in until physical validation is complete.'
Require-Match $cvars 'RequestSwapChainRefresh\("low-latency-settings-change",\s*true\)' `
	'Toggling native low latency must request creation-time swapchain flag reconciliation.'
Require-Match $video 'virtual void BeginLatencySimulation\(uint64_t presentationGeneration\) \{\}[\s\S]*virtual void MarkLatencyInputSample\(uint64_t presentationGeneration\) \{\}[\s\S]*virtual void EndLatencySimulation\(uint64_t presentationGeneration\) \{\}' `
	'Non-NRI backends need harmless semantic no-op hooks.'
Require-Match $renderHeader 'NRILowLatencyPolicy\s+mLowLatencyPolicy;' `
	'The backend shell must own a focused low-latency policy service.'

if ($frameGeneration -match 'LatencySleep\s*\(|SetLatencyMarker\s*\(|LatencyMarker::INPUT_SAMPLE') {
	throw 'Frame generation must not own native NRI sleep or marker calls.'
}
Require-Match $policy 'request\.nativeRequested\s*=\s*!!nri_lowlatency' `
	'Native low-latency eligibility must have an independent request source.'
Require-Match $policy 'request\.frameGenerationRequested\s*=\s*!!nri_framegen\s*&&\s*!!nri_framegenlatency' `
	'The existing frame-generation request must remain a separate compatibility input.'
Require-Match $policy '!frameBuffer\.IsFrameGenerationPresentPathActive\(\)' `
	'The native NRI controller must fail closed when the proxy owns presentation.'
$beginPolicy = Get-FunctionBody $policy 'void NRILowLatencyPolicy::BeginSimulation('
if ($beginPolicy -match 'LatencySleep\s*\(|SetMarker\s*\(') {
	throw 'Arming a presentation must not pace or mark a frame that never gathers command input.'
}
$samplePolicy = Get-FunctionBody $policy 'void NRILowLatencyPolicy::MarkInputSample('
Require-Order $samplePolicy @(
	'LatencySleep(*frameBuffer.mSwapChain)',
	'nri::LatencyMarker::SIMULATION_START',
	'nri::LatencyMarker::INPUT_SAMPLE'
) 'Driver pacing and simulation/input markers must begin at the first actual command gather.'

$main = Get-FunctionBody $mainLoop 'void MainLoop ('
Require-Order $main @(
	'screen->BeginLatencySimulation(gPresentationGeneration);',
	'TryRunTics ();',
	'screen->MarkLatencyInputSample(gPresentationGeneration);',
	'I_StartTic();',
	'screen->EndLatencySimulation(gPresentationGeneration);',
	'Display();'
) 'Each presentation needs a real command gather or outer-pump fallback before the interval ends and rendering starts.'
Require-Match $main 'catch\s*\(\.\.\.\)[\s\S]*screen->EndLatencySimulation\(gPresentationGeneration\);[\s\S]*throw;' `
	'Exceptional simulation exits must close the semantic marker interval.'

$buildCommand = Get-FunctionBody $mainLoop 'void G_BuildTiccmd('
Require-Order $buildCommand @(
	'screen->MarkLatencyInputSample(gPresentationGeneration);',
	'gameInput.getInput(&cmd->ucmd);'
) 'The first real deterministic command gather must own INPUT_SAMPLE.'
$tryRun = Get-FunctionBody $mainLoop 'void TryRunTics ('
Require-Order $tryRun @(
	'screen->MarkLatencyInputSample(gPresentationGeneration);',
	'gameInput.getInput();'
) 'The uncapped zero-tic gather must use the same first-successful-sample marker.'
$display = Get-FunctionBody $mainLoop 'void Display()'
if ($display -match 'MarkLatencyInputSample') {
	throw 'The post-acquire render-only late latch must not emit the simulation INPUT_SAMPLE marker.'
}

$submitPresent = Get-FunctionBody $renderDevice 'void NRIRenderDevice::EndFrameAndPresent('
Require-Order $submitPresent @(
	'mLowLatencyPolicy.OnRenderSubmitStart(',
	'mCore.QueueSubmit(*mGraphicsQueue, submitDesc);',
	'mLowLatencyPolicy.OnRenderSubmitEnd(*this, submitResult);',
	'mLowLatencyPolicy.OnPresentStart(*this);',
	'mLowLatencyPolicy.OnPresentEnd(*this, presentResult);'
) 'Submit and present boundaries must delegate to the system-level owner in execution order.'
Require-Match $submitPresent 'submitDesc\.swapChain\s*=\s*lowLatencySwapChainEnabled\s*\?\s*mSwapChain\s*:\s*nullptr;' `
	'Native low-latency queue submissions must remain associated with the created swapchain.'

Require-Match $policy 'LatencySleep\(\*frameBuffer\.mSwapChain\)[\s\S]*LatencyMarker::SIMULATION_START' `
	'LatencySleep must precede SIMULATION_START.'
Require-Match $policy 'LatencyMarker::INPUT_SAMPLE' `
	'The focused owner must implement the previously missing INPUT_SAMPLE marker.'
Require-Match $policyHeader 'duplicateInputSampleCount' `
	'The once-per-presentation input-marker guard needs observable duplicate accounting.'
Require-Match $renderDevice 'NRI PT low-latency: schema=2[^"]*canonical_sample=first-input-gather[^"]*contract=%s[^"]*sleep_seq=%llu[^"]*sim_start_seq=%llu[^"]*input_seq=%llu[^"]*sim_end_seq=%llu[^"]*submit_start_seq=%llu[^"]*submit_end_seq=%llu[^"]*present_start_seq=%llu[^"]*present_end_seq=%llu' `
	'Runtime telemetry must expose canonical ownership and locally verifiable event order.'
Require-Match $policy 'void NRILowLatencyPolicy::SuppressRuntime[\s\S]*SetLatencySleepMode[\s\S]*disabledMode' `
	'Runtime API suppression must best-effort disable the configured low-latency mode.'
Require-Match $renderDevice 'report_scope=latest_available_unjoined[^"]*report_changed=%s[^"]*driver_us=%llu\.\.%llu[^"]*os_queue_us=%llu\.\.%llu' `
	'Asynchronous driver reports must be labeled honestly and expose driver/OS queue timestamps.'
Require-Match $renderDevice 'aborted=%llu abort_reason=%s[^"]*runtime_suppressed=%s runtime_failure=%s runtime_disable=%s' `
	'Failure and swapchain-reset diagnostics must retain classified abort/disable state.'

Require-Match $cvars 'CUSTOM_CVAR\(Int,\s*nri_ptframesinflight,\s*3,' `
	'Step 4 must not alter the throughput-oriented rendered-depth default.'

Write-Host 'NRI native low-latency structural contract tests passed.'
