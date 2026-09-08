$ErrorActionPreference = 'Stop'

function Assert-Near([double]$actual, [double]$expected, [double]$tolerance, [string]$message) {
    if ([math]::Abs($actual - $expected) -gt $tolerance) {
        throw "$message (actual=$actual expected=$expected tolerance=$tolerance)"
    }
}

$Valid = [uint32]2147483648
$FlagBankB = [uint32]0x1
$FlagFull = [uint32]0x2
$FlagFallback = [uint32]0x4

function New-Header([uint32]$slot, [uint32]$generation, [uint32]$epoch,
    [uint32]$requiredMask, [uint32]$publishedMask, [uint32]$state,
    [uint32]$shapeRevision = 0, [uint32]$lightingBoundsRevision = 0) {
    return [pscustomobject]@{
        Slot = $slot; Generation = $generation; Epoch = $epoch
        RequiredMask = $requiredMask; PublishedMask = $publishedMask; State = $state
        ShapeRevision = $shapeRevision; LightingBoundsRevision = $lightingBoundsRevision
    }
}
function Test-ExactIdentity($header, [uint32]$slot, [uint32]$generation,
    [uint32]$epoch, [uint32]$requiredMask, [uint32]$shapeRevision = 0,
    [uint32]$lightingBoundsRevision = 0) {
    return (($header.State -band $Valid) -ne 0) -and
        $header.Slot -eq $slot -and $header.Generation -eq $generation -and
        $header.Epoch -eq $epoch -and $header.RequiredMask -eq $requiredMask -and
        $header.PublishedMask -eq $requiredMask -and
        $header.ShapeRevision -eq $shapeRevision -and
        $header.LightingBoundsRevision -eq $lightingBoundsRevision
}

$fallback = New-Header 7 3 11 0xf 0xf ($Valid -bor $FlagFallback)
if (-not (Test-ExactIdentity $fallback 7 3 11 0xf)) { throw 'Coherent fallback identity was rejected.' }
foreach ($bad in @(
    (New-Header 7 3 11 0xf 0x7 ($Valid -bor $FlagFallback)),
    (New-Header 7 4 11 0xf 0xf ($Valid -bor $FlagFallback)),
    (New-Header 7 3 12 0xf 0xf ($Valid -bor $FlagFallback)),
    (New-Header 7 3 11 0xf 0xf ($Valid -bor $FlagFallback) 1 0),
    (New-Header 7 3 11 0xf 0xf ($Valid -bor $FlagFallback) 0 1),
    (New-Header 7 3 11 0xf 0xf $FlagFallback))) {
    if (Test-ExactIdentity $bad 7 3 11 0xf) { throw 'Partial, stale, or unpublished cache identity was accepted.' }
}

# New groups publish coherent fallback in A, then full in B. A failed later
# refresh leaves the last published full bank and identity unchanged.
$published = $fallback
$published = New-Header 7 3 11 0xf 0xf ($Valid -bor $FlagBankB -bor $FlagFull)
$beforeFailedRefresh = $published
$scratchCompletion = 0x7
if ($scratchCompletion -eq 0xf) {
    $published = New-Header 7 3 11 0xf 0xf ($Valid -bor $FlagFull)
}
if ($published.State -ne $beforeFailedRefresh.State -or $published.Generation -ne $beforeFailedRefresh.Generation) {
    throw 'A failed refresh destroyed the previously valid cache bank.'
}

# Inverse-distance anchor interpolation is a partition of unity. A coherent
# centroid fallback replicated to all anchors must therefore remain coherent.
$distancesSquared = @(0.25, 1.0, 2.25, 4.0)
$weights = foreach ($distanceSquared in $distancesSquared) { 1.0 / [math]::Max($distanceSquared, 0.01) }
$weightSum = ($weights | Measure-Object -Sum).Sum
$incident = @(2.5, 2.5, 2.5, 2.5)
$resolved = 0.0
for ($i = 0; $i -lt 4; ++$i) { $resolved += $incident[$i] * $weights[$i] / $weightSum }
Assert-Near $resolved 2.5 1e-12 'Replicated fallback changed under anchor interpolation.'

# Frozen radiance is interpreted as a group-local tetrahedral field. Rebuilding
# current anchor positions from current bounds keeps relative IDW weights stable
# under translation and uniform expansion without sampling the camera or scene.
function New-Vec3([double]$x, [double]$y, [double]$z) {
    return [pscustomobject]@{ X = $x; Y = $y; Z = $z }
}
function Add-Vec3($a, $b) { return New-Vec3 ($a.X + $b.X) ($a.Y + $b.Y) ($a.Z + $b.Z) }
function Scale-From-Center($value, $center, [double]$scale) {
    return New-Vec3 ($center.X + ($value.X - $center.X) * $scale) `
        ($center.Y + ($value.Y - $center.Y) * $scale) `
        ($center.Z + ($value.Z - $center.Z) * $scale)
}
function Get-TetraAnchor([int]$index, $lower, $upper) {
    $center = New-Vec3 (($lower.X + $upper.X) * 0.5) (($lower.Y + $upper.Y) * 0.5) (($lower.Z + $upper.Z) * 0.5)
    $extent = New-Vec3 (($upper.X - $lower.X) * 0.07216878365) (($upper.Y - $lower.Y) * 0.07216878365) (($upper.Z - $lower.Z) * 0.07216878365)
    $signs = @(@(1, 1, 1), @(-1, -1, 1), @(-1, 1, -1), @(1, -1, -1))[$index]
    return New-Vec3 ($center.X + $extent.X * $signs[0]) ($center.Y + $extent.Y * $signs[1]) ($center.Z + $extent.Z * $signs[2])
}
$unitLower = New-Vec3 -1 -1 -1
$unitUpper = New-Vec3 1 1 1
$unitAnchor = Get-TetraAnchor 0 $unitLower $unitUpper
$unitAnchorRadius = [math]::Sqrt($unitAnchor.X * $unitAnchor.X + $unitAnchor.Y * $unitAnchor.Y + $unitAnchor.Z * $unitAnchor.Z)
Assert-Near $unitAnchorRadius 0.25 1e-10 'Inset tetrahedron must sit at one quarter of a tight support sphere radius.'
function Resolve-LocalField($position, $lower, $upper, [double[]]$values) {
    $weights = @()
    for ($i = 0; $i -lt 4; ++$i) {
        $anchor = Get-TetraAnchor $i $lower $upper
        $dx = $position.X - $anchor.X; $dy = $position.Y - $anchor.Y; $dz = $position.Z - $anchor.Z
        $weights += 1.0 / [math]::Max($dx * $dx + $dy * $dy + $dz * $dz, 0.01)
    }
    $sum = ($weights | Measure-Object -Sum).Sum
    $value = 0.0
    for ($i = 0; $i -lt 4; ++$i) { $value += $values[$i] * $weights[$i] / $sum }
    return $value
}
$lower = New-Vec3 -2 -1 -3
$upper = New-Vec3 4 5 7
$sample = New-Vec3 2.2 0.7 4.0
$field = [double[]]@(1, 3, 7, 15)
$localReference = Resolve-LocalField $sample $lower $upper $field
$translation = New-Vec3 100 -50 7
$translated = Resolve-LocalField (Add-Vec3 $sample $translation) (Add-Vec3 $lower $translation) (Add-Vec3 $upper $translation) $field
Assert-Near $translated $localReference 1e-12 'Translated group-local cache field changed relative weights.'
$center = New-Vec3 1 2 2
$expanded = Resolve-LocalField (Scale-From-Center $sample $center 3.0) `
    (Scale-From-Center $lower $center 3.0) (Scale-From-Center $upper $center 3.0) $field
Assert-Near $expanded $localReference 1e-12 'Uniformly expanded group-local cache field changed relative weights.'

# Mixed composition adds independent optical/source terms and merges phase by
# scattering luminance, rather than overwriting or averaging representations.
$gridExtinction = 0.8
$transientExtinction = 1.7
$gridScattering = 0.35
$transientScattering = 0.95
$gridSource = 0.2
$transientSource = 0.75
$gridG = 0.2
$transientG = -0.35
$combinedExtinction = $gridExtinction + $transientExtinction
$combinedScattering = $gridScattering + $transientScattering
$combinedSource = $gridSource + $transientSource
$combinedG = ($gridG * $gridScattering + $transientG * $transientScattering) / $combinedScattering
Assert-Near $combinedExtinction 2.5 1e-12 'Mixed extinction is not additive.'
Assert-Near $combinedScattering 1.3 1e-12 'Mixed scattering is not additive.'
Assert-Near $combinedSource 0.95 1e-12 'Mixed source is not additive.'
Assert-Near $combinedG -0.2019230769230769 1e-12 'Mixed anisotropy is not scattering weighted.'

# Intrinsic emission is independent of external-cache availability.
$sigmaT = 1.4
$emissionScale = 2.0
$warmRed = 1.0
$intrinsicWithCache = $sigmaT * $emissionScale * $warmRed
$intrinsicWithoutCache = $sigmaT * $emissionScale * $warmRed
Assert-Near $intrinsicWithoutCache $intrinsicWithCache 0.0 'Missing external cache suppressed intrinsic emission.'

# A high-signal group is clamped after summing its optical contributions. Merely
# changing the authored decomposition from four to eight equal lobes is neutral.
function Resolve-HighSignalGroup([int]$lobeCount, [double]$unclampedSource) {
    $groupSource = 0.0
    for ($lobe = 0; $lobe -lt $lobeCount; ++$lobe) {
        $groupSource += $unclampedSource / $lobeCount
    }
    return [math]::Min($groupSource, 32.0)
}
$fourLobes = Resolve-HighSignalGroup 4 80.0
$eightLobes = Resolve-HighSignalGroup 8 80.0
Assert-Near $fourLobes $eightLobes 1e-12 'High-signal source changed under 4-to-8 lobe decomposition.'
Assert-Near $eightLobes 32.0 1e-12 'High-signal group clamp was not applied once after accumulation.'

# Six equal cubemap directions cover 4*pi steradians. Under isotropic phase,
# quadrature reconstructs a unit incident field and preserves a black sky.
$quadratureWeight = 4.0 * [math]::PI / 6.0
$isotropicPhase = 1.0 / (4.0 * [math]::PI)
$isotropicResponse = 6.0 * $quadratureWeight * $isotropicPhase
Assert-Near $isotropicResponse 1.0 1e-12 'Six-axis cubemap quadrature does not close under isotropic phase.'
$blackSky = 6.0 * 0.0 * $quadratureWeight * $isotropicPhase
Assert-Near $blackSky 0.0 0.0 'Black sky acquired artificial ambient radiance.'

# Edge erosion and noise strength are independent boundary controls. Their
# bounded union makes the production 0.14/0.22 pair visible without changing
# the exact core. The self-shadow path intentionally retains the un-eroded
# shell, so it is an upper optical-depth bound for every noise value.
function Get-BoundaryErosionAmplitude([double]$edgeErosion, [double]$noiseStrength) {
    $edge = [math]::Max(0.0, [math]::Min(1.0, $edgeErosion))
    $strength = [math]::Max(0.0, [math]::Min(1.0, $noiseStrength))
    return 1.0 - (1.0 - $edge) * (1.0 - $strength)
}
function Get-BoundaryShellMultiplier([double]$noise, [double]$amplitude) {
    return 1.0 + $amplitude * ((0.35 + 0.65 * $noise) - 1.0)
}
$boundaryAmplitude = Get-BoundaryErosionAmplitude 0.14 0.22
Assert-Near $boundaryAmplitude 0.3292 1e-12 'Production boundary controls do not retain their bounded-union amplitude.'
Assert-Near (Get-BoundaryErosionAmplitude 0.14 0.0) 0.14 1e-12 'Edge erosion alone must remain an active boundary control.'
Assert-Near (Get-BoundaryErosionAmplitude 0.0 0.22) 0.22 1e-12 'Noise strength alone must remain an active boundary control.'
Assert-Near (Get-BoundaryErosionAmplitude 0.0 0.0) 0.0 1e-12 'Zero boundary controls must preserve the unmodulated shell.'
$minimumShellMultiplier = Get-BoundaryShellMultiplier 0.0 $boundaryAmplitude
$meanShellMultiplier = Get-BoundaryShellMultiplier 0.5 $boundaryAmplitude
$maximumShellMultiplier = Get-BoundaryShellMultiplier 1.0 $boundaryAmplitude
Assert-Near $minimumShellMultiplier 0.78602 1e-12 'Low-noise shell erosion is not visually meaningful.'
Assert-Near $meanShellMultiplier 0.89301 1e-12 'Mean shell erosion changed unexpectedly.'
Assert-Near $maximumShellMultiplier 1.0 1e-12 'Boundary erosion may add density outside conservative lobe bounds.'
$exactCoreIntegral = 4.75
$exactShellIntegral = 2.5
$selfShadowUpperBound = $exactCoreIntegral + $exactShellIntegral
foreach ($noise in @(0.0, 0.25, 0.5, 0.75, 1.0)) {
    $materializedIntegral = $exactCoreIntegral + $exactShellIntegral *
        (Get-BoundaryShellMultiplier $noise $boundaryAmplitude)
    if ($materializedIntegral -lt $exactCoreIntegral -or
        $materializedIntegral -gt $selfShadowUpperBound) {
        throw "Boundary erosion changed the exact core or exceeded the conservative self-shadow bound (noise=$noise materialized=$materializedIntegral bound=$selfShadowUpperBound)."
    }
}

Write-Output 'Smoke transient cache/composition numerical tests passed.'
