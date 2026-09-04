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
$gameInputHeader = Get-Content -LiteralPath (Join-Path $repo 'source\core\gameinput.h') -Raw
$gameInput = Get-Content -LiteralPath (Join-Path $repo 'source\core\gameinput.cpp') -Raw
$mainLoop = Get-Content -LiteralPath (Join-Path $repo 'source\core\mainloop.cpp') -Raw
$lineageHeader = Get-Content -LiteralPath (Join-Path $repo 'source\common\engine\input_lineage.h') -Raw
$lineage = Get-Content -LiteralPath (Join-Path $repo 'source\common\engine\input_lineage.cpp') -Raw
$eventOwner = Get-Content -LiteralPath (Join-Path $repo 'source\common\engine\d_event.cpp') -Raw
$gameControl = Get-Content -LiteralPath (Join-Path $repo 'source\core\gamecontrol.cpp') -Raw
$platformInputHeader = Get-Content -LiteralPath (Join-Path $repo 'source\common\engine\g_input.h') -Raw
$win32Input = Get-Content -LiteralPath (Join-Path $repo 'source\common\platform\win32\i_input.cpp') -Raw

# The deterministic command accumulator and provisional render cursor must be
# distinct state. Late rendering is not allowed to consume or clear mouseInput.
Require-Match $gameInputHeader 'FVector2\s+mouseInput;[\s\S]*DRotator\s+lateAppliedMouseAngles;' `
	'The late camera cursor must remain separate from the deterministic mouse accumulator.'
Require-Match $gameInputHeader 'bool\s+ApplyLateMouseLook\(\);[\s\S]*void\s+CancelLateMouseLook\(\);' `
	'The late-latch apply/cancel boundary is missing.'

$lateApply = Get-FunctionBody $gameInput 'bool GameInput::ApplyLateMouseLook()'
if ($lateApply -match 'mouseInput\s*=|mouseInput\.Zero|inputBuffer\s*=|processInputBits|getInput\s*\(') {
	throw 'Render-only late latch must not consume deterministic input, build a packet, or duplicate held-input processing.'
}
Require-Match $lateApply 'desired\s*-\s*lateAppliedMouseAngles[\s\S]*lateAppliedMouseAngles\s*=\s*desired' `
	'Late rendering must advance provisionally by a delta, not replay the full pending mouse aggregate.'

# Command construction retains the established equations. The only camera-side
# change is reconciliation against the already displayed provisional angle.
$movement = Get-FunctionBody $gameInput 'void GameInput::processMovement('
Require-Match $movement 'thisInput\.ang\.Yaw\s*\+=\s*MOUSE_SCALE\s*\*\s*mouseInput\.X\s*\*\s*m_yaw;' `
	'On-foot ticcmd mouse-yaw construction changed.'
Require-Order $movement @(
	'thisInput.ang.Yaw += MOUSE_SCALE * mouseInput.X * m_yaw;',
	'mouseAngles.Yaw = thisInput.ang.Yaw;',
	'thisInput.ang.Yaw -= hidspeed * joyAxes[JOYAXIS_Yaw] * scaleAdjust;',
	'thisInput.ang.Yaw *= turnscale;',
	'mouseAngles.Yaw *= turnscale;'
) 'On-foot mouse yaw must be source-separated before joystick/keyboard contributions without changing command math.'
Require-Order $movement @(
	'thisInput.ang.Pitch -= MOUSE_SCALE * mouseInput.Y * m_pitch;',
	'mouseAngles.Pitch = thisInput.ang.Pitch;',
	'thisInput.ang.Pitch -= hidspeed * joyAxes[JOYAXIS_Pitch] * scaleAdjust;',
	'thisInput.ang.Pitch *= turnscale;',
	'mouseAngles.Pitch *= turnscale;'
) 'On-foot mouse pitch must be source-separated before joystick contributions without changing command math.'
Require-Match $movement 'inputBuffer\.vel\s*\+=\s*thisInput\.vel;[\s\S]*inputBuffer\.ang\s*\+=\s*thisInput\.ang;' `
	'On-foot deterministic input accumulation changed.'
Require-Match $movement 'reconcileLocalCamera\(thisInput\.ang,\s*mouseAngles,' `
	'On-foot input must reconcile the provisional render cursor exactly once.'

$vehicle = Get-FunctionBody $gameInput 'void GameInput::processVehicle('
Require-Match $vehicle 'mouseVel\s*=\s*abs\(turnVel\s*\*\s*mouseInput\.X\s*\*\s*m_yaw\)[\s\S]*g_sqrt\(mouseVel\)' `
	'Vehicle ticcmd turning must retain its nonlinear mouse transform.'
Require-Order $vehicle @(
	'thisInput.ang.Yaw += DAngle::fromDeg(',
	'mouseAngles.Yaw = thisInput.ang.Yaw;',
	'thisInput.ang.Yaw -= DAngle::fromDeg(',
	'thisInput.ang.Yaw *= scaleAdjust;',
	'mouseAngles.Yaw *= scaleAdjust;',
	'inputBuffer.ang.Yaw += thisInput.ang.Yaw;'
) 'Vehicle mouse turning must be separated before keyboard/joystick contributions and retain the original command order.'
Require-Match $vehicle 'inputBuffer\.ang\.Yaw\s*\+=\s*thisInput\.ang\.Yaw;' `
	'Vehicle deterministic angular accumulation changed.'
Require-Match $vehicle 'reconcileLocalCamera\(thisInput\.ang,\s*mouseAngles,' `
	'Vehicle input must reconcile the provisional render cursor exactly once.'

$reconcile = Get-FunctionBody $gameInput 'void GameInput::reconcileLocalCamera('
Require-Match $reconcile 'if\s*\(SyncInput\(\)\)[\s\S]*applyLocalCameraDelta\(-provisional\)' `
	'Synchronized input must remove, rather than retain, provisional render-only motion.'
Require-Match $reconcile 'applyLocalCameraDelta\(commandAngles\s*-\s*provisional\)' `
	'Unsynchronized command sampling must subtract motion already shown by the late latch.'
Require-Match $reconcile 'lateAppliedMouseAngles\s*=\s*\{\};' `
	'Command reconciliation must advance/clear the provisional cursor.'

$desiredLate = Get-FunctionBody $gameInput 'DRotator GameInput::getDesiredLateMouseAngles()'
Require-Match $desiredLate 'MOUSE_SCALE\s*\*\s*mouseInput\.X\s*\*\s*m_yaw\s*\*\s*lateMouseRoute\.turnscale' `
	'Late on-foot yaw must use the same mouse sensitivity and game turn scale as ticcmd construction.'
Require-Match $desiredLate '-MOUSE_SCALE\s*\*\s*mouseInput\.Y\s*\*\s*m_pitch\s*\*\s*lateMouseRoute\.turnscale' `
	'Late on-foot pitch must use the same inversion/sensitivity and game turn scale as ticcmd construction.'
Require-Match $desiredLate 'mouseVel\s*=\s*abs\(turnVel\s*\*\s*mouseInput\.X\s*\*\s*m_yaw\)\s*\*\s*\(45\.\s*/\s*2048\.\)\s*/\s*scaleAdjust[\s\S]*g_sqrt\(mouseVel\)[\s\S]*\*\s*scaleAdjust' `
	'Late vehicle yaw must use the same nonlinear transform and final scale as ticcmd construction.'

# The latch belongs after the *level branch's second* BeginFrame, which is the
# explicit post-acquire boundary, and before any scene target/view capture. Do
# not let a future hook beside the earlier setup BeginFrame satisfy this test.
$display = Get-FunctionBody $mainLoop 'void Display()'
$beginFrameMatches = [regex]::Matches($display, 'screen->BeginFrame\(\);')
if ($beginFrameMatches.Count -ne 2) {
	throw "Display's two-stage frame contract changed: expected exactly two BeginFrame calls, found $($beginFrameMatches.Count)."
}
$switchStart = $display.IndexOf('switch (gamestate)', [StringComparison]::Ordinal)
$levelStart = $display.IndexOf('case GS_LEVEL:', $switchStart, [StringComparison]::Ordinal)
$levelEnd = $display.IndexOf('[[fallthrough]]', $levelStart, [StringComparison]::Ordinal)
if ($switchStart -lt 0 -or $levelStart -lt 0 -or $levelEnd -lt 0) {
	throw 'Could not isolate Display GS_LEVEL for the post-acquire late-latch contract.'
}
$levelBlock = $display.Substring($levelStart, $levelEnd - $levelStart)
if ($beginFrameMatches[0].Index -ge $switchStart -or
	$beginFrameMatches[1].Index -le $levelStart -or
	$beginFrameMatches[1].Index -ge $levelEnd) {
	throw 'The first BeginFrame must precede the state switch and the second must remain inside GS_LEVEL.'
}
Require-Order $levelBlock @(
	'screen->BeginFrame();',
	'screen->HasActiveSceneFrame()',
	'I_GetLateMouseMotion();',
	'gameInput.ApplyLateMouseLook()',
	'screen->SetSceneRenderTarget',
	'gi->Render();'
) 'GS_LEVEL post-acquire late input/view ordering contract failed.'
$levelLatePumps = [regex]::Matches($levelBlock, 'I_GetLateMouseMotion\(\);').Count
$levelLateApplies = [regex]::Matches($levelBlock, 'gameInput\.ApplyLateMouseLook\(\)').Count
if ($levelLatePumps -ne 1 -or $levelLateApplies -ne 1) {
	throw "GS_LEVEL must contain one late pump and one late-latch call; found pumps=$levelLatePumps applies=$levelLateApplies."
}
Require-Match $levelBlock '!paused[\s\S]*!M_Active\(\)[\s\S]*!System_WantGuiCapture\(\)[\s\S]*!gameInput\.SyncInput\(\)' `
	'Late latch must remain disabled for pause, GUI capture, and synchronized input.'
Require-Match $levelBlock 'latePumpSafe\s*=\s*I_GetLateMouseMotion\(\)[\s\S]*!latePumpSafe[\s\S]*!screen->HasActiveSceneFrame\(\)' `
	'Late pumping must reject a blocked ordered-prefix pump or invalidated active frame.'
Require-Match $levelBlock 'routingInvalidated[\s\S]*!routingInvalidated\s*&&\s*gameInput\.ApplyLateMouseLook\(\)' `
	'Late camera application must be conditional on the post-pump event-routing decision.'
Require-Match $levelBlock 'catch\s*\(\.\.\.\)[\s\S]*screen->Update\(\);[\s\S]*std::rethrow_exception' `
	'An exception after frame acquisition must close the active frame before propagating.'

# The acquired-frame pump may remove only a queue-head WM_INPUT packet proven
# to contain mouse motion without button/wheel flags. It must leave every
# arbitrary window, focus, keyboard, button, wheel, and quit message queued.
Require-Match $platformInputHeader 'bool\s+I_GetLateMouseMotion\(\);' `
	'The platform-independent late mouse-motion pump contract is missing.'
$latePump = Get-FunctionBody $win32Input 'bool I_GetLateMouseMotion()'
Require-Match $latePump 'PeekMessage\(&mess,\s*NULL,\s*0,\s*0,\s*PM_NOREMOVE\)' `
	'The Win32 late pump must inspect the queue head without removing it first.'
Require-Match $latePump 'mess\.message\s*!=\s*WM_INPUT[\s\S]*return false' `
	'The Win32 late pump must stop before every non-raw-input message.'
Require-Match $latePump 'copied\s*==\s*UINT\(-1\)[\s\S]*copied\s*<\s*sizeof\(RAWINPUTHEADER\)\s*\+\s*sizeof\(RAWMOUSE\)[\s\S]*raw\.header\.dwSize\s*!=\s*copied' `
	'The Win32 late pump must reject failed, truncated, or size-mismatched raw input.'
Require-Match $latePump 'dwType\s*!=\s*RIM_TYPEMOUSE\s*\|\|\s*raw\.data\.mouse\.usButtonFlags\s*!=\s*0' `
	'The Win32 late pump must stop before keyboard, mouse-button, or wheel input.'
Require-Order $latePump @(
	'PM_NOREMOVE',
	'GetRawInputData',
	'WM_INPUT, WM_INPUT, PM_REMOVE',
	'DispatchMessage'
) 'The Win32 late pump must classify the queue head before removing and dispatching it.'
Require-Match $latePump 'removed\.message\s*==\s*WM_QUIT[\s\S]*PostQuitMessage[\s\S]*return false' `
	'The filtered Win32 late pump must preserve WM_QUIT for the normal pump.'
Require-Match $latePump 'removed\.message\s*==\s*WM_INPUT[\s\S]*removed\.lParam\s*==\s*mess\.lParam[\s\S]*!inspectedMessageRemoved[\s\S]*return false' `
	'The Win32 late pump must reject a removed raw-input message that differs from the inspected queue head.'
if ($latePump -match 'I_GetEvent\s*\(') {
	throw 'The acquired-frame late pump must not call the unrestricted platform event pump.'
}

# D_PostEvent calls the gameplay dispatcher before touching its ring. In-game
# EV_Mouse takes the true-return fast path and therefore reaches mouseInput
# without waiting for deterministic event-queue processing.
$dispatch = Get-FunctionBody $gameControl 'bool System_DispatchEvent('
Require-Order $dispatch @(
	'ev->type == EV_Mouse && !System_WantGuiCapture()',
	'gameInput.MouseAddToPos(ev->x, ev->y);',
	'return true;',
	'inputState.AddEvent(ev);',
	'return false;'
) 'Gameplay mouse must bypass routed event queuing while non-gameplay events fall through.'
Require-Match $dispatch 'if\s*\(ev->type\s*==\s*EV_Mouse\)[\s\S]*PerfInputLineageNoteMouseExcluded' `
	'GUI-captured mouse must be excluded from gameplay lineage before falling through to routing.'
$postEvent = Get-FunctionBody $eventOwner 'void D_PostEvent('
Require-Order $postEvent @(
	'if (sysCallbacks.DispatchEvent && sysCallbacks.DispatchEvent(ev))',
	'return;',
	'events[eventhead] = *ev;',
	'eventhead = (eventhead + 1) & (MAXEVENTS - 1);'
) 'D_PostEvent must return before ring insertion only when direct gameplay dispatch consumed the event.'

# Menu/non-level and reset paths must not replay either cursor after returning to
# gameplay. The command accumulator is explicitly cleared on the excluded path.
$getInput = Get-FunctionBody $gameInput 'void GameInput::getInput('
Require-Match $getInput 'M_Active\(\)\s*\|\|\s*gamestate\s*!=\s*GS_LEVEL[\s\S]*CancelLateMouseLook\(\);[\s\S]*mouseInput\.Zero\(\);[\s\S]*lateMouseRoute\s*=\s*\{\};' `
	'Menu/non-level transitions must discard both deterministic pending mouse and provisional render state.'
Require-Match $gameInputHeader 'void\s+Clear\(\)[\s\S]*CancelLateMouseLook\(\);[\s\S]*PerfInputLineageDiscardPendingMouse\(\);[\s\S]*memset' `
	'GameInput reset must cancel provisional camera motion before clearing state.'

# Step-2 traces must distinguish ordinary command-time camera consumption from
# post-acquire late consumption. Generic non-mouse camera updates must stay out.
Require-Match $lineageHeader 'PerfInputLineageNoteRenderMouseSample\([\s\S]*bool\s+lateLatch\)' `
	'Input lineage lacks explicit early/late render-mouse phase attribution.'
Require-Match $lineage 'schema=2[\s\S]*render_early=%u\s+render_late=%u[\s\S]*late_pump_calls=%u[\s\S]*late_pump_invalidations=%u' `
	'Step-2 frame rows lack the late-pump and early/late consumption evidence needed for the breakpoint.'
$genericFastApply = Get-FunctionBody $eventOwner 'void PerfLoopTraceNoteFastCameraApply('
if ($genericFastApply -match 'PerfInputLineageNoteRenderMouseSample|PerfInputLineageNoteFastCameraApply') {
	throw 'Generic camera application must not be attributed as mouse-cursor consumption.'
}

Write-Host 'Input late-latch structural contract tests passed.'
