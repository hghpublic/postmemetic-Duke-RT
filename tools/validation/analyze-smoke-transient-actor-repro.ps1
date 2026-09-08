param(
    [Parameter(Mandatory = $true)][string]$LogDirectory,
    [Parameter(Mandatory = $true)][ValidateSet('explosion', 'trail', 'fire')][string]$Effect,
    [Parameter(Mandatory = $true)][ValidateRange(0, 63)][int]$ClassMask,
    [ValidateRange(1, 4096)][int]$MinimumCompactFrames = 64,
    [string]$SummaryOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rules = @{ explosion = 'duke_explosion_cloud'; trail = 'duke_rpg_trail_continuous'; fire = 'duke_fire_sustained' }
$classValues = @{ explosion = 0; trail = 1; fire = 2 }
$classBits = @{ explosion = 1; trail = 2; fire = 4 }
$rule = [string]$rules[$Effect]
$classValue = [int]$classValues[$Effect]
$enabled = ($ClassMask -band [int]$classBits[$Effect]) -ne 0
$expectedEffective = if ($enabled) { 2 } else { 0 }

function Read-Pairs([string]$Line) {
    $pairs = @{}
    foreach ($match in [regex]::Matches($Line, '(?<key>[A-Za-z_]+)=(?<value>[^\s]+)')) {
        $pairs[$match.Groups['key'].Value] = $match.Groups['value'].Value.TrimEnd(',')
    }
    return $pairs
}

function UInt([hashtable]$Pairs, [string]$Name, [string]$Context) {
    if (-not $Pairs.ContainsKey($Name)) { throw "$Context is missing $Name" }
    return [uint64]::Parse([string]$Pairs[$Name], [Globalization.CultureInfo]::InvariantCulture)
}

$errors = [Collections.Generic.List[string]]::new()
$results = [Collections.Generic.List[object]]::new()
$logs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*.log' -File -Recurse)
if ($logs.Count -eq 0) { $errors.Add("No logs found under $LogDirectory") }
foreach ($log in $logs) {
    $sourceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $routeRows = [Collections.Generic.List[hashtable]]::new()
    $routeFrameByGather = @{}
    $transientFrames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $timingFrames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $frameSummaryRows = 0
    $maximumGroups = [uint64]0
    $maximumLobes = [uint64]0
    $maximumGroupDrops = [uint64]0
    $maximumLobeDrops = [uint64]0
    $maximumReducedGroups = [uint64]0
    $validGpuRows = 0
    $compactCompletionRows = 0
    foreach ($line in [IO.File]::ReadLines($log.FullName)) {
        if ($line.StartsWith('NRI PT smoke emitter: event=')) {
            $pairs = Read-Pairs $line
            if ($pairs.ContainsKey('rule') -and $pairs['rule'] -eq $rule) {
                if ($pairs.ContainsKey('source_id')) { [void]$sourceIds.Add([string]$pairs['source_id']) }
                if ($pairs.ContainsKey('event') -and $pairs['event'] -eq 'frame-summary') { $frameSummaryRows++ }
            }
        }
        elseif ($line.StartsWith('NRI PT smoke routing: event=source ')) {
            $routeRows.Add((Read-Pairs $line))
        }
        elseif ($line.StartsWith('PERF pt smoke route frame NRI:')) {
            $pairs = Read-Pairs $line
            if ($pairs.ContainsKey('gather') -and $pairs.ContainsKey('renderer_frame')) {
                $routeFrameByGather[[string]$pairs['gather']] = [string]$pairs['renderer_frame']
            }
        }
        elseif ($line.StartsWith('PERF pt gpu timing NRI:')) {
            $pairs = Read-Pairs $line
            if ($pairs.ContainsKey('nri_frame')) { [void]$timingFrames.Add([string]$pairs['nri_frame']) }
        }
        elseif ($line.StartsWith('PERF pt smoke transient NRI:')) {
            $pairs = Read-Pairs $line
            try {
                $groups = UInt $pairs 'groups' $log.Name
                $lobes = UInt $pairs 'lobes' $log.Name
                $groupDrops = UInt $pairs 'group_drop' $log.Name
                $lobeDrops = UInt $pairs 'lobe_drop' $log.Name
                $reducedGroups = UInt $pairs 'reduced' $log.Name
                if ($groups -gt $maximumGroups) { $maximumGroups = $groups }
                if ($lobes -gt $maximumLobes) { $maximumLobes = $lobes }
                if ($groupDrops -gt $maximumGroupDrops) { $maximumGroupDrops = $groupDrops }
                if ($lobeDrops -gt $maximumLobeDrops) { $maximumLobeDrops = $lobeDrops }
                if ($reducedGroups -gt $maximumReducedGroups) { $maximumReducedGroups = $reducedGroups }
                if ((UInt $pairs 'valid' $log.Name) -eq [uint64]1) { $validGpuRows++ }
                if ($pairs.ContainsKey('renderer_frame')) { [void]$transientFrames.Add([string]$pairs['renderer_frame']) }
            }
            catch { $errors.Add($_.Exception.Message) }
        }
        elseif ($line.StartsWith('PERF compact capture complete:')) {
            $pairs = Read-Pairs $line
            try {
                $complete = $pairs.ContainsKey('status') -and $pairs['status'] -eq 'complete'
                $requested = UInt $pairs 'requested' $log.Name
                $eligible = UInt $pairs 'eligible' $log.Name
                $observed = UInt $pairs 'observed' $log.Name
                $pending = UInt $pairs 'pending_gpu' $log.Name
                $dropped = UInt $pairs 'dropped' $log.Name
                if ($complete -and $requested -ge [uint64]$MinimumCompactFrames -and
                    $eligible -ge [uint64]$MinimumCompactFrames -and $observed -ge [uint64]$MinimumCompactFrames -and
                    $pending -eq [uint64]0 -and $dropped -eq [uint64]0) {
                    $compactCompletionRows++
                }
            }
            catch { $errors.Add($_.Exception.Message) }
        }
    }

    if ($frameSummaryRows -eq 0) { $errors.Add("$($log.Name): no frame summary for $rule") }
    if ($sourceIds.Count -eq 0) { $errors.Add("$($log.Name): no emitted actor source id for $rule") }
    $matchedRoutes = @($routeRows | Where-Object {
        $_.ContainsKey('source_id') -and $sourceIds.Contains([string]$_['source_id']) -and
        $_.ContainsKey('class') -and [int]$_['class'] -eq $classValue
    })
    if ($matchedRoutes.Count -eq 0) { $errors.Add("$($log.Name): no route attribution joined to $rule source id") }
    $completedActorRoutes = 0
    foreach ($route in $matchedRoutes) {
        try {
            if ((UInt $route 'authored' $log.Name) -ne [uint64]2) { $errors.Add("$($log.Name): $rule was not authored transient") }
            if ((UInt $route 'effective' $log.Name) -ne [uint64]$expectedEffective) { $errors.Add("$($log.Name): $rule effective route did not match mask $ClassMask") }
            $grid = UInt $route 'grid_commands' $log.Name
            $analytic = UInt $route 'analytic_carriers' $log.Name
            $groups = UInt $route 'transient_groups' $log.Name
            $lobes = UInt $route 'transient_lobes' $log.Name
            $gather = [string](UInt $route 'gather' $log.Name)
            if ($routeFrameByGather.ContainsKey($gather)) {
                $rendererFrame = [string]$routeFrameByGather[$gather]
                if ($transientFrames.Contains($rendererFrame) -and $timingFrames.Contains($rendererFrame)) {
                    $completedActorRoutes++
                }
            }
            if ($enabled -and ($grid -ne [uint64]0 -or $analytic -ne [uint64]0 -or $groups -eq [uint64]0 -or $lobes -eq [uint64]0)) {
                $errors.Add("$($log.Name): enabled $rule was not transient-only")
            }
            if (-not $enabled -and ($grid -eq [uint64]0 -or $analytic -ne [uint64]0 -or $groups -ne [uint64]0 -or $lobes -ne [uint64]0)) {
                $errors.Add("$($log.Name): disabled $rule did not return exclusively to Grid")
            }
        }
        catch { $errors.Add($_.Exception.Message) }
    }
    if ($completedActorRoutes -eq 0) { $errors.Add("$($log.Name): no $rule route reached a joined completed-GPU frame") }
    if ($compactCompletionRows -eq 0) { $errors.Add("$($log.Name): compact capture did not complete at least $MinimumCompactFrames accepted frames") }
    if ($enabled -and $maximumGroups -eq [uint64]0) { $errors.Add("$($log.Name): no admitted transient group became visible") }
    if ($enabled -and $maximumLobes -eq [uint64]0) { $errors.Add("$($log.Name): no admitted transient lobe became visible") }
    if ($validGpuRows -eq 0) { $errors.Add("$($log.Name): no valid completed-GPU transient telemetry") }
    $results.Add([pscustomobject]@{
        log = $log.FullName; rule = $rule; sourceIds = @($sourceIds)
        routeRows = $matchedRoutes.Count; frameSummaryRows = $frameSummaryRows
        maximumGroups = $maximumGroups; maximumLobes = $maximumLobes
        maximumGroupDrops = $maximumGroupDrops; maximumLobeDrops = $maximumLobeDrops
        maximumReducedGroups = $maximumReducedGroups; validGpuRows = $validGpuRows
        completedActorRoutes = $completedActorRoutes; compactCompletionRows = $compactCompletionRows
    })
}

$summary = [pscustomobject]@{
    ok = $errors.Count -eq 0; effect = $Effect; rule = $rule; mask = $ClassMask
    minimumCompactFrames = $MinimumCompactFrames
    enabled = $enabled; expectedEffectiveRepresentation = $expectedEffective
    runs = $results.ToArray(); errors = $errors.ToArray()
}
if (-not $SummaryOutput) { $SummaryOutput = Join-Path $LogDirectory "actor-$Effect-mask$ClassMask.summary.json" }
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryOutput -Encoding UTF8
if (-not $summary.ok) {
    foreach ($message in $errors) { Write-Error $message -ErrorAction Continue }
    exit 1
}
Write-Host "Transient actor repro passed: effect=$Effect mask=$ClassMask summary=$SummaryOutput"
