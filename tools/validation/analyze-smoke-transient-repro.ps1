[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$LogPath,
    [switch]$AllowLegacyControl,
    [switch]$RequireMapEmittersDisabled,
    [ValidateRange(0, 65535)][int]$MinimumSuppressedMapRules = 0,
    [ValidateRange(-1, 63)][int]$ExpectedSourceClassMask = -1,
    [string]$SummaryOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-CompactLine([string]$Line) {
    $pairs = @{}
    foreach ($match in [regex]::Matches($Line, '([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)')) {
        $pairs[$match.Groups[1].Value] = $match.Groups[2].Value
    }
    return $pairs
}

function Get-UInt64([hashtable]$Row, [string]$Name, [string]$Context, [Nullable[uint64]]$Default = $null) {
    if (-not $Row.ContainsKey($Name)) {
        if ($null -ne $Default) { return [uint64]$Default.Value }
        throw "$Context is missing '$Name'"
    }
    $value = [uint64]0
    if (-not [uint64]::TryParse([string]$Row[$Name], [ref]$value)) {
        throw "$Context has nonnumeric '$Name=$($Row[$Name])'"
    }
    return $value
}

function Get-Double([hashtable]$Row, [string]$Name, [string]$Context, [Nullable[double]]$Default = $null) {
    if (-not $Row.ContainsKey($Name)) {
        if ($null -ne $Default) { return [double]$Default.Value }
        throw "$Context is missing '$Name'"
    }
    $value = 0.0
    if (-not [double]::TryParse([string]$Row[$Name],
        [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture,
        [ref]$value)) {
        throw "$Context has nonnumeric '$Name=$($Row[$Name])'"
    }
    return $value
}

function Get-Distribution([double[]]$Values) {
    if ($Values.Count -eq 0) {
        return [ordered]@{ samples = 0; min = $null; p50 = $null; p95 = $null; max = $null }
    }
    $sorted = @($Values | Sort-Object)
    function Pick([double]$fraction) {
        $index = [Math]::Ceiling($fraction * $sorted.Count) - 1
        $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, $index))
        return [Math]::Round([double]$sorted[$index], 6)
    }
    return [ordered]@{
        samples = $sorted.Count
        min = [Math]::Round([double]$sorted[0], 6)
        p50 = Pick 0.50
        p95 = Pick 0.95
        max = [Math]::Round([double]$sorted[-1], 6)
    }
}

function Add-UniqueFrameRow([hashtable]$Table, [hashtable]$Row, [string]$Kind,
    [string]$Path, [System.Collections.Generic.List[string]]$Errors) {
    try { $frame = Get-UInt64 $Row 'renderer_frame' "$Path $Kind row" }
    catch { $Errors.Add($_.Exception.Message); return }
    $key = [string]$frame
    if ($Table.ContainsKey($key)) {
        $existing = $Table[$key]
        $identical = $existing.Count -eq $Row.Count
        if ($identical) {
            foreach ($field in $existing.Keys) {
                if (-not $Row.ContainsKey($field) -or [string]$existing[$field] -cne [string]$Row[$field]) {
                    $identical = $false
                    break
                }
            }
        }
        # An explicit status dump can repeat the most recently retired readback.
        # Accept that exact duplicate, but keep conflicting same-frame rows fatal.
        if (-not $identical) {
            $Errors.Add("${Path}: conflicting duplicate $Kind row for renderer_frame=$frame")
        }
        return
    }
    $Table[$key] = $Row
}

$failurePattern = 'Device removed|DRED page fault|DRED breadcrumbs|DXGI_ERROR_DEVICE|device lost|QueueSubmit failed|NRI error:|NRI render failed|validation error|failed to create|assertion failed|Fatal error|NRI render crash|Unknown command|LIGHTOVR: Script error'
$allErrors = [System.Collections.Generic.List[string]]::new()
$runSummaries = [System.Collections.Generic.List[object]]::new()

foreach ($inputPath in $LogPath) {
    $resolved = (Resolve-Path -LiteralPath $inputPath -ErrorAction Stop).Path
    $transientByFrame = @{}
    $timingByFrame = @{}
    $aggregateTimingByFrame = @{}
    $routeByFrame = @{}
    $routeByGather = @{}
    $sourceRows = [System.Collections.Generic.List[hashtable]]::new()
    $runtimeFailureCount = 0
    [uint64]$validTransientRows = 0
    [uint64]$overflowTotal = 0
    [uint64]$missingTotal = 0
    [uint64]$identityRejectTotal = 0
    [uint64]$applyVisibilityRayTotal = 0
    [uint64]$observedTotal = 0
    [uint64]$observedFullTotal = 0
    [uint64]$observedFallbackTotal = 0
    [uint64]$observedClosureFailures = 0
    [uint64]$validTimingRows = 0
    [uint64]$invalidTimingTotal = 0
    [uint64]$droppedTimingTotal = 0
    [uint64]$maximumSuppressedMapRules = 0
    [uint64]$ambientMapCommandTotal = 0
    [uint64]$previewMapCommandTotal = 0

    foreach ($line in [IO.File]::ReadLines($resolved)) {
        if ($line -match $failurePattern) { $runtimeFailureCount++ }
        if ($line.StartsWith('PERF pt smoke transient NRI:')) {
            Add-UniqueFrameRow $transientByFrame (ConvertFrom-CompactLine $line) 'transient' $resolved $allErrors
        }
        elseif ($line.StartsWith('PERF pt smoke gpu timing NRI:')) {
            Add-UniqueFrameRow $timingByFrame (ConvertFrom-CompactLine $line) 'smoke timing' $resolved $allErrors
        }
        elseif ($line.StartsWith('PERF pt gpu timing NRI:')) {
            $aggregate = ConvertFrom-CompactLine $line
            try {
                # The compact aggregate uses the NRI/device frame as `nri_frame`;
                # its `frame` field is not the route/readback join domain.
                $canonical = @{
                    renderer_frame = [string](Get-UInt64 $aggregate 'nri_frame' "$resolved aggregate GPU timing")
                    transient_bins = [string](Get-Double $aggregate 'smoke_transient_bins' "$resolved aggregate GPU timing")
                    transient_light_build = [string](Get-Double $aggregate 'smoke_transient_light_build' "$resolved aggregate GPU timing")
                    transient_materialize = [string](Get-Double $aggregate 'smoke_transient_materialize' "$resolved aggregate GPU timing")
                    total = [string](Get-Double $aggregate 'smoke_total' "$resolved aggregate GPU timing")
                    valid = [string](Get-UInt64 $aggregate 'resolved' "$resolved aggregate GPU timing")
                    expected = [string](Get-UInt64 $aggregate 'expected' "$resolved aggregate GPU timing")
                    invalid = [string](Get-UInt64 $aggregate 'invalid' "$resolved aggregate GPU timing")
                    dropped = [string](Get-UInt64 $aggregate 'dropped' "$resolved aggregate GPU timing")
                }
                Add-UniqueFrameRow $aggregateTimingByFrame $canonical 'aggregate GPU timing' $resolved $allErrors
            }
            catch { $allErrors.Add($_.Exception.Message) }
        }
        elseif ($line.StartsWith('PERF pt smoke route frame NRI:')) {
            $row = ConvertFrom-CompactLine $line
            Add-UniqueFrameRow $routeByFrame $row 'route frame' $resolved $allErrors
            try {
                $gather = [string](Get-UInt64 $row 'gather' "$resolved route frame")
                if ($routeByGather.ContainsKey($gather)) {
                    $allErrors.Add("${resolved}: duplicate route gather=$gather")
                }
                else { $routeByGather[$gather] = $row }
            }
            catch { $allErrors.Add($_.Exception.Message) }
        }
        elseif ($line.StartsWith('NRI PT smoke routing: event=source ')) {
            $sourceRows.Add((ConvertFrom-CompactLine $line))
        }
    }

    # The compact capture's public timing cohort is authoritative when present.
    # The per-smoke readback line remains supported for older/synthetic logs, but
    # it is emitted in a different frame domain and must not be mixed into this
    # cohort (doing so creates a spurious 65th sample in a 64-frame capture).
    if ($aggregateTimingByFrame.Count -ne 0) {
        $timingByFrame = $aggregateTimingByFrame
    }

    if ($runtimeFailureCount -ne 0) {
        $allErrors.Add("${resolved}: runtime failure strings=$runtimeFailureCount")
    }
    if ($routeByFrame.Count -eq 0) {
        $allErrors.Add("${resolved}: no compact route frame rows")
    }
    if ($RequireMapEmittersDisabled) {
        foreach ($row in $routeByFrame.Values) {
            try {
                $mapEmitters = Get-UInt64 $row 'map_emitters' "$resolved isolated route frame"
                $suppressed = Get-UInt64 $row 'map_rules_suppressed' "$resolved isolated route frame"
                $ambientCommands = Get-UInt64 $row 'ambient_map_commands' "$resolved isolated route frame"
                $previewCommands = Get-UInt64 $row 'preview_map_commands' "$resolved isolated route frame"
                if ($mapEmitters -ne 0) { $allErrors.Add("${resolved}: isolated route frame has map_emitters=$mapEmitters") }
                if ($suppressed -gt $maximumSuppressedMapRules) { $maximumSuppressedMapRules = $suppressed }
                $ambientMapCommandTotal += $ambientCommands
                $previewMapCommandTotal += $previewCommands
                if ($ambientCommands -ne 0 -or $previewCommands -ne 0) {
                    $allErrors.Add("${resolved}: isolated route frame emitted ambient=$ambientCommands preview=$previewCommands map commands")
                }
            }
            catch { $allErrors.Add($_.Exception.Message) }
        }
        if ($maximumSuppressedMapRules -lt [uint64]$MinimumSuppressedMapRules) {
            $allErrors.Add("${resolved}: isolated capture suppressed at most $maximumSuppressedMapRules map rules; expected at least $MinimumSuppressedMapRules")
        }
    }
    if ($timingByFrame.Count -eq 0) {
        $allErrors.Add("${resolved}: no compact smoke GPU timing rows")
    }
    foreach ($frameKey in $timingByFrame.Keys) {
        $timing = $timingByFrame[$frameKey]
        $context = "$resolved timing renderer_frame=$frameKey"
        try {
            $timingValid = Get-UInt64 $timing 'valid' $context
            # Per-smoke rows report the number of valid scopes (typically >1),
            # while aggregate rows normalize their resolved count into `valid`.
            if ($timingValid -gt 0) { $validTimingRows++ }
            else {
                $allErrors.Add("${context}: timing row is not valid")
            }
            if ($timing.ContainsKey('expected')) {
                $expected = Get-UInt64 $timing 'expected' $context
                if ($expected -eq 0 -or $timingValid -ne $expected) {
                    $allErrors.Add("${context}: resolved=$timingValid expected=$expected")
                }
            }
            foreach ($field in @('invalid', 'dropped')) {
                $value = Get-UInt64 $timing $field $context
                if ($field -eq 'invalid') { $invalidTimingTotal += $value }
                else { $droppedTimingTotal += $value }
                if ($value -ne 0) { $allErrors.Add("${context}: $field=$value") }
            }
        }
        catch { $allErrors.Add($_.Exception.Message) }
    }

    $routeMasks = [System.Collections.Generic.HashSet[uint64]]::new()
    foreach ($row in $routeByFrame.Values) {
        try { [void]$routeMasks.Add((Get-UInt64 $row 'mask' "$resolved route frame")) }
        catch { $allErrors.Add($_.Exception.Message) }
        if ($ExpectedSourceClassMask -ge 0) {
            try {
                $sourceMask = Get-UInt64 $row 'source_mask' "$resolved source isolation"
                if ($sourceMask -ne [uint64]$ExpectedSourceClassMask) {
                    $allErrors.Add("${resolved}: source_mask=$sourceMask expected=$ExpectedSourceClassMask")
                }
            }
            catch { $allErrors.Add($_.Exception.Message) }
        }
    }
    $legacyControl = $routeMasks.Count -gt 0 -and @($routeMasks | Where-Object { $_ -ne 0 }).Count -eq 0
    if ($legacyControl -and -not $AllowLegacyControl) {
        $allErrors.Add("${resolved}: mask=0 legacy control requires -AllowLegacyControl")
    }

    $joined = [System.Collections.Generic.List[object]]::new()
    $positiveTelemetry = [System.Collections.Generic.List[object]]::new()
    $positiveJoined = [System.Collections.Generic.List[object]]::new()
    foreach ($frameKey in @($transientByFrame.Keys | Sort-Object { [uint64]$_ })) {
        $transient = $transientByFrame[$frameKey]
        $context = "$resolved transient renderer_frame=$frameKey"
        try {
            $transientValid = Get-UInt64 $transient 'valid' $context
            if ($transientValid -eq 1) { $validTransientRows++ }
            else {
                $allErrors.Add("${context}: readback is not valid")
            }
            foreach ($field in @('overflow', 'missing', 'identity_rejects', 'apply_visibility_rays')) {
                $value = Get-UInt64 $transient $field $context
                switch ($field) {
                    'overflow' { $overflowTotal += $value }
                    'missing' { $missingTotal += $value }
                    'identity_rejects' { $identityRejectTotal += $value }
                    'apply_visibility_rays' { $applyVisibilityRayTotal += $value }
                }
                if ($value -ne 0) { $allErrors.Add("${context}: $field=$value") }
            }
            $observed = Get-UInt64 $transient 'observed' $context
            $observedFull = Get-UInt64 $transient 'observed_full' $context
            $observedFallback = Get-UInt64 $transient 'observed_fallback' $context
            $observedTotal += $observed
            $observedFullTotal += $observedFull
            $observedFallbackTotal += $observedFallback
            if ($observed -ne $observedFull + $observedFallback) {
                $observedClosureFailures++
                $allErrors.Add("${context}: observed=$observed does not close to full+fallback=$($observedFull + $observedFallback)")
            }
            $froxels = Get-UInt64 $transient 'froxels_applied' $context
            if ($froxels -ne 0) {
                $positiveTelemetry.Add([pscustomobject]@{
                    rendererFrame = [uint64]$frameKey
                    transient = $transient
                    froxels = $froxels
                })
            }
            if ($froxels -ne 0 -and -not $routeByFrame.ContainsKey($frameKey)) {
                $allErrors.Add("${context}: positive froxels have no exact renderer-frame route row")
            }
            if (-not $timingByFrame.ContainsKey($frameKey)) {
                continue
            }
            $timing = $timingByFrame[$frameKey]
            $entry = [pscustomobject]@{
                rendererFrame = [uint64]$frameKey
                transient = $transient
                timing = $timing
                froxels = $froxels
            }
            $joined.Add($entry)
            if ($froxels -ne 0) { $positiveJoined.Add($entry) }
        }
        catch { $allErrors.Add($_.Exception.Message) }
    }

    if (-not $legacyControl -and $transientByFrame.Count -eq 0) {
        $allErrors.Add("${resolved}: transient capture has no transient telemetry rows")
    }
    if (-not $legacyControl -and $positiveTelemetry.Count -eq 0) {
        $allErrors.Add("${resolved}: transient capture never produced an actual transient froxel")
    }
    elseif (-not $legacyControl -and $positiveJoined.Count -eq 0) {
        # Compact GPU timing is intentionally a bounded window. Telemetry outside
        # that window need not join, but the measured window must include smoke.
        $allErrors.Add("${resolved}: positive froxels have no exact renderer-frame timing row")
    }
    if ($legacyControl -and $positiveTelemetry.Count -ne 0) {
        $allErrors.Add("${resolved}: mask=0 legacy control produced transient froxels")
    }
    if ($legacyControl) {
        foreach ($route in $routeByFrame.Values) {
            try {
                foreach ($field in @('transient_groups', 'transient_lobes')) {
                    $value = Get-UInt64 $route $field "$resolved legacy route frame"
                    if ($value -ne 0) { $allErrors.Add("${resolved}: mask=0 legacy route has $field=$value") }
                }
            }
            catch { $allErrors.Add($_.Exception.Message) }
        }
    }

    $firstPositive = $null
    if ($positiveTelemetry.Count -ne 0) {
        $firstPositive = @($positiveTelemetry | Sort-Object rendererFrame)[0]
        try {
            if ((Get-UInt64 $firstPositive.transient 'observed' "$resolved first positive frame") -eq 0) {
                $allErrors.Add("${resolved}: first positive transient frame did not GPU-observe a full or fallback cache")
            }
        }
        catch { $allErrors.Add($_.Exception.Message) }
    }

    $settled = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $firstPositive) {
        foreach ($entry in $positiveTelemetry) {
            if ($entry.rendererFrame -lt $firstPositive.rendererFrame) { continue }
            $row = $entry.transient
            try {
                $builds = (Get-UInt64 $row 'full_builds' 'settled row') +
                    (Get-UInt64 $row 'fallback_builds' 'settled row') +
                    (Get-UInt64 $row 'full_published' 'settled row') +
                    (Get-UInt64 $row 'fallback_published' 'settled row')
                if ($builds -eq 0) {
                    $rays = Get-UInt64 $row 'build_rays' 'settled row'
                    $settled.Add([pscustomobject]@{ rendererFrame = $entry.rendererFrame; buildRays = $rays })
                    if ($rays -ne 0) {
                        $allErrors.Add("${resolved}: settled renderer_frame=$($entry.rendererFrame) has build_rays=$rays without a build/publication")
                    }
                }
            }
            catch { $allErrors.Add("${resolved}: $($_.Exception.Message)") }
        }
    }

    $sourceAggregates = @{}
    foreach ($source in $sourceRows) {
        try {
            $gather = [string](Get-UInt64 $source 'gather' "$resolved source route")
            if (-not $routeByGather.ContainsKey($gather)) {
                $allErrors.Add("${resolved}: source route gather=$gather has no frame-summary join")
                continue
            }
            $sourceId = [string]$source.source_id
            if (-not $sourceAggregates.ContainsKey($sourceId)) {
                $sourceAggregates[$sourceId] = [ordered]@{
                    sourceId = $sourceId
                    authored = [System.Collections.Generic.HashSet[uint64]]::new()
                    effective = [System.Collections.Generic.HashSet[uint64]]::new()
                    classes = [System.Collections.Generic.HashSet[uint64]]::new()
                    gathers = [System.Collections.Generic.HashSet[uint64]]::new()
                    sourceQuantity = [uint64]0
                    gridCommands = [uint64]0
                    analyticCarriers = [uint64]0
                    transientGroups = [uint64]0
                    transientLobes = [uint64]0
                }
            }
            $aggregate = $sourceAggregates[$sourceId]
            [void]$aggregate.authored.Add((Get-UInt64 $source 'authored' 'source route'))
            [void]$aggregate.effective.Add((Get-UInt64 $source 'effective' 'source route'))
            [void]$aggregate.classes.Add((Get-UInt64 $source 'class' 'source route'))
            [void]$aggregate.gathers.Add([uint64]$gather)
            $aggregate.sourceQuantity += Get-UInt64 $source 'source_quantity' 'source route'
            $aggregate.gridCommands += Get-UInt64 $source 'grid_commands' 'source route'
            $aggregate.analyticCarriers += Get-UInt64 $source 'analytic_carriers' 'source route'
            $aggregate.transientGroups += Get-UInt64 $source 'transient_groups' 'source route'
            $aggregate.transientLobes += Get-UInt64 $source 'transient_lobes' 'source route'
            if ($legacyControl -and
                ((Get-UInt64 $source 'transient_groups' 'legacy source route') -ne 0 -or
                 (Get-UInt64 $source 'transient_lobes' 'legacy source route') -ne 0)) {
                $allErrors.Add("${resolved}: mask=0 source route source_id=$sourceId contains transient work")
            }
        }
        catch { $allErrors.Add("${resolved}: $($_.Exception.Message)") }
    }
    $sourceSummary = @($sourceAggregates.Values | Sort-Object sourceId | ForEach-Object {
        [ordered]@{
            sourceId = $_.sourceId
            gathers = $_.gathers.Count
            authoredRepresentations = @($_.authored | Sort-Object)
            effectiveRepresentations = @($_.effective | Sort-Object)
            transientClasses = @($_.classes | Sort-Object)
            sourceQuantity = $_.sourceQuantity
            gridCommands = $_.gridCommands
            analyticCarriers = $_.analyticCarriers
            transientGroups = $_.transientGroups
            transientLobes = $_.transientLobes
        }
    })

    $timingCohort = if ($positiveJoined.Count -ne 0) {
        @($positiveJoined)
    }
    elseif ($joined.Count -ne 0) {
        @($joined)
    }
    else {
        @($timingByFrame.Keys | Sort-Object { [uint64]$_ } | ForEach-Object {
            [pscustomobject]@{ timing = $timingByFrame[$_] }
        })
    }
    $populationRows = if ($positiveTelemetry.Count -ne 0) { @($positiveTelemetry | ForEach-Object transient) } else { @($transientByFrame.Values) }
    $profiles = @($populationRows | ForEach-Object {
        try { Get-UInt64 $_ 'profile' 'profile row' } catch { $allErrors.Add("${resolved}: $($_.Exception.Message)") }
    } | Sort-Object -Unique)
    $groups = @($populationRows | ForEach-Object { Get-UInt64 $_ 'groups' 'population row' })
    $lobes = @($populationRows | ForEach-Object { Get-UInt64 $_ 'lobes' 'population row' })
    $bytes = @($populationRows | ForEach-Object { Get-UInt64 $_ 'resident_bytes' 'population row' })

    $firstSummary = $null
    if ($null -ne $firstPositive) {
        $firstSummary = [ordered]@{
            rendererFrame = $firstPositive.rendererFrame
            froxelsApplied = Get-UInt64 $firstPositive.transient 'froxels_applied' 'first positive row'
            observed = Get-UInt64 $firstPositive.transient 'observed' 'first positive row'
            observedFull = Get-UInt64 $firstPositive.transient 'observed_full' 'first positive row'
            observedFallback = Get-UInt64 $firstPositive.transient 'observed_fallback' 'first positive row'
            fullPublished = Get-UInt64 $firstPositive.transient 'full_published' 'first positive row'
            fallbackPublished = Get-UInt64 $firstPositive.transient 'fallback_published' 'first positive row'
        }
    }

    $runSummaries.Add([ordered]@{
        logPath = $resolved
        mode = if ($legacyControl) { 'legacy-control' } else { 'transient' }
        routeMasks = @($routeMasks | Sort-Object)
        expectedSourceClassMask = $ExpectedSourceClassMask
        routeFrames = $routeByFrame.Count
        routeGathers = $routeByGather.Count
        mapEmitterIsolation = [ordered]@{
            required = [bool]$RequireMapEmittersDisabled
            minimumSuppressedRules = $MinimumSuppressedMapRules
            maximumSuppressedRules = $maximumSuppressedMapRules
            ambientCommands = $ambientMapCommandTotal
            previewCommands = $previewMapCommandTotal
        }
        sourceRoutes = $sourceRows.Count
        transientRows = $transientByFrame.Count
        timingRows = $timingByFrame.Count
        joinedRows = $joined.Count
        positiveFroxelRows = $positiveTelemetry.Count
        invariants = [ordered]@{
            validTransientRows = $validTransientRows
            validTimingRows = $validTimingRows
            overflow = $overflowTotal
            missing = $missingTotal
            identityRejects = $identityRejectTotal
            applyVisibilityRays = $applyVisibilityRayTotal
            observed = $observedTotal
            observedFull = $observedFullTotal
            observedFallback = $observedFallbackTotal
            observedClosureFailures = $observedClosureFailures
            timingInvalid = $invalidTimingTotal
            timingDropped = $droppedTimingTotal
        }
        firstPositive = $firstSummary
        settled = [ordered]@{
            frames = $settled.Count
            rebuildRays = Get-Distribution ([double[]]@($settled | ForEach-Object buildRays))
        }
        timingMs = [ordered]@{
            cohort = if ($positiveJoined.Count -ne 0) { 'positive-transient-froxels' }
                elseif ($positiveTelemetry.Count -ne 0) { 'missing-positive-timing' }
                elseif ($joined.Count -ne 0) { 'joined-control' }
                else { 'timing-control' }
            bins = Get-Distribution ([double[]]@($timingCohort | ForEach-Object { Get-Double $_.timing 'transient_bins' 'timing row' }))
            cache = Get-Distribution ([double[]]@($timingCohort | ForEach-Object { Get-Double $_.timing 'transient_light_build' 'timing row' }))
            materialize = Get-Distribution ([double[]]@($timingCohort | ForEach-Object { Get-Double $_.timing 'transient_materialize' 'timing row' }))
            total = Get-Distribution ([double[]]@($timingCohort | ForEach-Object { Get-Double $_.timing 'total' 'timing row' }))
        }
        population = [ordered]@{
            profiles = $profiles
            groupSamples = $groups.Count
            groupsMin = if ($groups.Count) { ($groups | Measure-Object -Minimum).Minimum } else { $null }
            groupsMax = if ($groups.Count) { ($groups | Measure-Object -Maximum).Maximum } else { $null }
            lobesMin = if ($lobes.Count) { ($lobes | Measure-Object -Minimum).Minimum } else { $null }
            lobesMax = if ($lobes.Count) { ($lobes | Measure-Object -Maximum).Maximum } else { $null }
            residentBytesMin = if ($bytes.Count) { ($bytes | Measure-Object -Minimum).Minimum } else { $null }
            residentBytesMax = if ($bytes.Count) { ($bytes | Measure-Object -Maximum).Maximum } else { $null }
        }
        sources = $sourceSummary
        runtimeFailureMatches = $runtimeFailureCount
    })
}

$summary = [ordered]@{
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    logsRequested = $LogPath.Count
    logsAnalyzed = $runSummaries.Count
    allowLegacyControl = [bool]$AllowLegacyControl
    requireMapEmittersDisabled = [bool]$RequireMapEmittersDisabled
    minimumSuppressedMapRules = $MinimumSuppressedMapRules
    runs = @($runSummaries)
    errors = @($allErrors)
    passed = $allErrors.Count -eq 0 -and $runSummaries.Count -eq $LogPath.Count
}
if ($SummaryOutput) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($SummaryOutput))
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $SummaryOutput -Encoding UTF8
}
$summary | ConvertTo-Json -Depth 10
if (-not $summary.passed) { exit 1 }
