$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$analyzer = Join-Path $root 'tools\validation\analyze-smoke-transient-repro.ps1'
$fixtures = Join-Path $root 'tools\validation\fixtures\smoke-transient-analyzer'
$shell = (Get-Command powershell.exe -ErrorAction Stop).Source
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('smoke-transient-analyzer-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

function Quote-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-Analyzer([string[]]$Paths, [bool]$AllowLegacy, [string]$SummaryName,
        [bool]$RequireMapIsolation = $false, [int]$MinimumSuppressedMapRules = 0,
        [int]$ExpectedSourceClassMask = -1, [bool]$RequireActorIsolation = $false) {
    $summaryPath = Join-Path $scratch $SummaryName
    $pathExpression = '@(' + (($Paths | ForEach-Object { Quote-PsLiteral $_ }) -join ',') + ')'
    $command = "& $(Quote-PsLiteral $analyzer) -LogPath $pathExpression -SummaryOutput $(Quote-PsLiteral $summaryPath)"
    if ($AllowLegacy) { $command += ' -AllowLegacyControl' }
    if ($ExpectedSourceClassMask -ge 0) { $command += " -ExpectedSourceClassMask $ExpectedSourceClassMask" }
    if ($RequireActorIsolation) { $command += ' -RequireActorEmittersDisabled' }
    if ($RequireMapIsolation) {
        $command += " -RequireMapEmittersDisabled -MinimumSuppressedMapRules $MinimumSuppressedMapRules"
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & $shell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded *> $null
    $exitCode = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        throw "Analyzer did not write $summaryPath (exit=$exitCode)."
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
    }
}

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $transientPath = Join-Path $fixtures 'transient-pass.log'
    $legacyPath = Join-Path $fixtures 'legacy-pass.log'
    $invariantPath = Join-Path $fixtures 'invariant-fail.log'
    $joinPath = Join-Path $fixtures 'join-fail.log'
    $runtimeFailurePath = Join-Path $fixtures 'runtime-fail.log'
    $duplicatePath = Join-Path $fixtures 'duplicate-pass.log'
    $aggregatePath = Join-Path $fixtures 'aggregate-pass.log'
    $aggregateIncompletePath = Join-Path $fixtures 'aggregate-incomplete.log'

    $transient = Invoke-Analyzer @($transientPath) $false 'transient.json'
    Require ($transient.exitCode -eq 0) 'A valid transient capture failed analysis.'
    Require ([bool]$transient.summary.passed) 'Valid transient summary was not marked passed.'
    $run = $transient.summary.runs[0]
    Require ($run.mode -eq 'transient') 'Transient route mask was misclassified.'
    Require ($run.firstPositive.rendererFrame -eq 100) 'First positive froxel frame was not joined exactly.'
    Require ($run.firstPositive.observedFallback -eq 1 -and $run.firstPositive.observedFull -eq 0) 'First positive readiness was not reported.'
    Require ($run.invariants.validTransientRows -eq 3 -and $run.invariants.validTimingRows -eq 3) 'Valid telemetry-row totals are incorrect.'
    Require ($run.invariants.overflow -eq 0 -and $run.invariants.missing -eq 0 -and $run.invariants.identityRejects -eq 0 -and $run.invariants.applyVisibilityRays -eq 0) 'Passing invariant totals are incorrect.'
    Require ($run.invariants.observed -eq ($run.invariants.observedFull + $run.invariants.observedFallback) -and $run.invariants.observedClosureFailures -eq 0) 'Observed full/fallback closure summary is incorrect.'
    Require ($run.settled.frames -eq 1 -and $run.settled.rebuildRays.max -eq 0) 'Settled rebuild-ray reporting is incorrect.'
    Require ($run.timingMs.bins.p50 -eq 0.11 -and $run.timingMs.bins.p95 -eq 0.12) 'Transient timing percentiles are incorrect.'
    Require ($run.timingMs.cache.p50 -eq 0.2 -and $run.timingMs.materialize.p95 -eq 0.32) 'Cache/materialize percentile reporting is incorrect.'
    Require ($run.population.profiles[0] -eq 2 -and $run.population.groupsMax -eq 1 -and $run.population.lobesMax -eq 6) 'Population/profile reporting is incorrect.'
    Require ($run.sources[0].gathers -eq 3 -and $run.sources[0].transientGroups -eq 3) 'Per-source route aggregation is incorrect.'

    $isolatedPath = Join-Path $scratch 'isolated-pass.log'
    $isolatedText = (Get-Content -LiteralPath $transientPath -Raw) -replace
        '(PERF pt smoke route frame NRI:[^\r\n]*? mask=\d+)',
        '$1 map_emitters=0 map_rules_suppressed=4 ambient_map_commands=0 preview_map_commands=0'
    Set-Content -LiteralPath $isolatedPath -Value $isolatedText -Encoding UTF8
    $isolated = Invoke-Analyzer @($isolatedPath) $false 'isolated.json' $true 4
    Require ($isolated.exitCode -eq 0 -and $isolated.summary.passed) 'A valid map-isolated capture failed analysis.'
    Require ($isolated.summary.runs[0].mapEmitterIsolation.maximumSuppressedRules -eq 4 -and
        $isolated.summary.runs[0].mapEmitterIsolation.ambientCommands -eq 0) 'Map-isolation evidence was not summarized.'

    $sourceIsolatedPath = Join-Path $scratch 'source-isolated.log'
    Set-Content -LiteralPath $sourceIsolatedPath -Value ($isolatedText -replace 'map_emitters=0', 'source_mask=1 map_emitters=0') -Encoding UTF8
    $sourceIsolated = Invoke-Analyzer @($sourceIsolatedPath) $false 'source-isolated.json' $true 4 1
    Require ($sourceIsolated.exitCode -eq 0 -and $sourceIsolated.summary.runs[0].expectedSourceClassMask -eq 1) 'Valid producer source isolation failed.'
    $wrongSourceMask = Invoke-Analyzer @($sourceIsolatedPath) $false 'wrong-source-mask.json' $true 4 2
    Require ($wrongSourceMask.exitCode -ne 0 -and (@($wrongSourceMask.summary.errors) -join "`n") -match 'source_mask=1 expected=2') 'Wrong source mask passed isolation validation.'
    $missingSourceMask = Invoke-Analyzer @($isolatedPath) $false 'missing-source-mask.json' $true 4 1
    Require ($missingSourceMask.exitCode -ne 0 -and (@($missingSourceMask.summary.errors) -join "`n") -match "missing 'source_mask'") 'Missing source-mask telemetry passed isolation validation.'

    $actorIsolatedPath = Join-Path $scratch 'actor-isolated.log'
    Set-Content -LiteralPath $actorIsolatedPath -Value ($isolatedText -replace 'map_emitters=0', 'actor_emitters=0 suppressed_actor_rules=3 map_emitters=0') -Encoding UTF8
    $actorIsolated = Invoke-Analyzer @($actorIsolatedPath) $false 'actor-isolated.json' $true 4 -1 $true
    Require ($actorIsolated.exitCode -eq 0 -and $actorIsolated.summary.runs[0].actorEmitterIsolation.maximumSuppressedRules -eq 3) 'Valid actor-emitter isolation failed or was not summarized.'
    $actorLeakPath = Join-Path $scratch 'actor-leak.log'
    Set-Content -LiteralPath $actorLeakPath -Value ((Get-Content -LiteralPath $actorIsolatedPath -Raw) -replace 'actor_emitters=0', 'actor_emitters=1') -Encoding UTF8
    $actorLeak = Invoke-Analyzer @($actorLeakPath) $false 'actor-leak.json' $true 4 -1 $true
    Require ($actorLeak.exitCode -ne 0 -and (@($actorLeak.summary.errors) -join "`n") -match 'actor_emitters=1') 'An actor-emitter leak passed isolation validation.'

    $leakingPath = Join-Path $scratch 'isolated-leak.log'
    Set-Content -LiteralPath $leakingPath -Value ($isolatedText -replace 'ambient_map_commands=0', 'ambient_map_commands=1') -Encoding UTF8
    $leaking = Invoke-Analyzer @($leakingPath) $false 'isolated-leak.json' $true 4
    Require ($leaking.exitCode -ne 0) 'An isolated capture with ambient map work passed analysis.'
    Require ((@($leaking.summary.errors) -join "`n") -match 'emitted ambient=1') 'Map-emitter leakage was not diagnosed.'

    $ab = Invoke-Analyzer @($transientPath, $legacyPath) $true 'ab.json'
    Require ($ab.exitCode -eq 0 -and $ab.summary.logsAnalyzed -eq 2) 'A/B transient plus explicit legacy control failed.'
    Require ($ab.summary.runs[1].mode -eq 'legacy-control') 'Legacy route mask was not identified.'
    Require ($ab.summary.runs[1].positiveFroxelRows -eq 0) 'Legacy control was confused with a transient pass.'
    Require ($ab.summary.runs[1].timingMs.cohort -eq 'timing-control' -and $ab.summary.runs[1].timingMs.total.samples -eq 1) 'Legacy timing-only cohort was not reported.'

    $legacyRejected = Invoke-Analyzer @($legacyPath) $false 'legacy-rejected.json'
    Require ($legacyRejected.exitCode -ne 0) 'Legacy mask=0 passed without explicit permission.'
    Require ((@($legacyRejected.summary.errors) -join "`n") -match 'requires -AllowLegacyControl') 'Legacy rejection did not explain the opt-in.'

    $invariant = Invoke-Analyzer @($invariantPath) $false 'invariant.json'
    Require ($invariant.exitCode -ne 0) 'Broken transient invariants passed analysis.'
    $invariantErrors = @($invariant.summary.errors) -join "`n"
    foreach ($failure in @('overflow=1', 'missing=1', 'identity_rejects=1', 'apply_visibility_rays=2', 'does not close', 'invalid=1', 'dropped=1', 'build_rays=3')) {
        Require ($invariantErrors -match [regex]::Escape($failure)) "Invariant failure '$failure' was not reported."
    }

    $join = Invoke-Analyzer @($joinPath) $false 'join.json'
    Require ($join.exitCode -ne 0) 'A positive froxel row without its timing frame passed analysis.'
    Require ((@($join.summary.errors) -join "`n") -match 'positive froxels have no exact renderer-frame timing row') 'Exact frame-join failure was not reported.'
    Require ($join.summary.runs[0].positiveFroxelRows -eq 1 -and $join.summary.runs[0].firstPositive.rendererFrame -eq 400) 'Positive telemetry was hidden when its timing row was missing.'

    $duplicate = Invoke-Analyzer @($duplicatePath) $false 'duplicate.json'
    Require ($duplicate.exitCode -eq 0) 'An exact repeated status/readback row failed analysis.'
    Require ($duplicate.summary.runs[0].transientRows -eq 1 -and $duplicate.summary.runs[0].positiveFroxelRows -eq 1) 'An exact repeated status/readback row was double-counted.'

    $aggregate = Invoke-Analyzer @($aggregatePath) $false 'aggregate.json'
    Require ($aggregate.exitCode -eq 0) 'A compact aggregate-only GPU timing capture failed analysis.'
    Require ($aggregate.summary.runs[0].timingRows -eq 1 -and $aggregate.summary.runs[0].joinedRows -eq 1 -and $aggregate.summary.runs[0].firstPositive.rendererFrame -eq 700) 'Aggregate timing did not replace the differently framed per-smoke timing cohort or joined with `frame` instead of `nri_frame`.'
    Require ($aggregate.summary.runs[0].timingMs.bins.p50 -eq 0.011 -and $aggregate.summary.runs[0].timingMs.cache.p50 -eq 0.022 -and $aggregate.summary.runs[0].timingMs.materialize.p50 -eq 0.033 -and $aggregate.summary.runs[0].timingMs.total.p50 -eq 1.234) 'Aggregate timing fields were not normalized.'

    $aggregateIncomplete = Invoke-Analyzer @($aggregateIncompletePath) $false 'aggregate-incomplete.json'
    Require ($aggregateIncomplete.exitCode -ne 0) 'An incompletely resolved compact GPU timing row passed analysis.'
    Require ((@($aggregateIncomplete.summary.errors) -join "`n") -match 'resolved=1 expected=2') 'Incomplete compact GPU timing did not report resolved/expected.'

    $runtimeFailure = Invoke-Analyzer @($runtimeFailurePath) $true 'runtime-fail.json'
    Require ($runtimeFailure.exitCode -ne 0) 'Exact NRI/LIGHTOVR runtime failures passed analysis.'
    Require ((@($runtimeFailure.summary.errors) -join "`n") -match 'runtime failure strings=2') 'Exact NRI/LIGHTOVR runtime failures were not both counted.'
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedScratch)).StartsWith('smoke-transient-analyzer-')) {
        throw "Refusing to remove an unexpected test directory: $resolvedScratch"
    }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}

Write-Output 'Smoke transient repro analyzer tests passed.'
