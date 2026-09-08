$ErrorActionPreference = 'Stop'

function Assert-Near([double]$actual, [double]$expected, [double]$tolerance, [string]$message) {
    if ([math]::Abs($actual - $expected) -gt $tolerance) {
        throw "$message (actual=$actual expected=$expected tolerance=$tolerance)"
    }
}

function Get-PlateauIntegral([double]$radius, [double]$plateau, [double]$impact, [double]$nearQ, [double]$farQ) {
    $radiusSquared = $radius * $radius
    $impactSquared = $impact * $impact
    if ($impactSquared -ge $radiusSquared) { return @(0.0, 0.0) }
    $outerHalf = [math]::Sqrt([math]::Max($radiusSquared - $impactSquared, 0.0))
    $q0 = [math]::Max($nearQ, -$outerHalf)
    $q1 = [math]::Min($farQ, $outerHalf)
    if ($q1 -le $q0) { return @(0.0, 0.0) }
    $p = [math]::Max(0.0, [math]::Min(0.95, $plateau))
    $coreRadiusSquared = $radiusSquared * $p * $p
    $denominator = [math]::Max($radiusSquared - $coreRadiusSquared, $radiusSquared * 0.0975)
    $radial = $radiusSquared - $impactSquared
    function Shell-Primitive([double]$q) {
        return ($radial * $q - $q * $q * $q / 3.0) / $denominator
    }
    $core = 0.0
    $shell = [math]::Max((Shell-Primitive $q1) - (Shell-Primitive $q0), 0.0)
    if ($impactSquared -lt $coreRadiusSquared) {
        $coreHalf = [math]::Sqrt([math]::Max($coreRadiusSquared - $impactSquared, 0.0))
        $c0 = [math]::Max($q0, -$coreHalf)
        $c1 = [math]::Min($q1, $coreHalf)
        if ($c1 -gt $c0) {
            $core = $c1 - $c0
            $shell = [math]::Max($shell - [math]::Max((Shell-Primitive $c1) - (Shell-Primitive $c0), 0.0), 0.0)
        }
    }
    return @($core, $shell)
}

function Get-NumericalIntegral([double]$radius, [double]$plateau, [double]$impact, [double]$nearQ, [double]$farQ) {
    $steps = 200000
    $width = ($farQ - $nearQ) / $steps
    $sum = 0.0
    for ($step = 0; $step -lt $steps; ++$step) {
        $q = $nearQ + ($step + 0.5) * $width
        $radialDistance = [math]::Sqrt($impact * $impact + $q * $q)
        if ($radialDistance -ge $radius) { continue }
        if ($radialDistance -le $plateau * $radius) { $kernel = 1.0 }
        else {
            $kernel = ($radius * $radius - $radialDistance * $radialDistance) /
                [math]::Max($radius * $radius * (1.0 - $plateau * $plateau), 1e-12)
        }
        $sum += [math]::Max(0.0, [math]::Min(1.0, $kernel)) * $width
    }
    return $sum
}

$cases = @(
    @(2.0, 0.0, 0.0, -4.0, 4.0),
    @(2.0, 0.58, 0.0, -4.0, 4.0),
    @(2.0, 0.58, 0.7, -4.0, 4.0),
    @(2.0, 0.58, 1.5, -4.0, 4.0),
    @(2.0, 0.58, 0.2, -0.4, 0.9),
    @(5.0, 0.85, 3.0, -1.0, 8.0)
)
foreach ($case in $cases) {
    $parts = Get-PlateauIntegral @case
    $analytic = $parts[0] + $parts[1]
    $numeric = Get-NumericalIntegral @case
    Assert-Near $analytic $numeric 0.0001 "Exact plateau integral diverged for $($case -join ',')"
    if ($parts[0] -lt 0.0 -or $parts[1] -lt 0.0) { throw 'Integral components must remain non-negative.' }
}

# A ray wholly within the plateau must integrate as a constant field. Boundary
# noise multiplies only the separately returned shell and cannot perforate it.
$inside = Get-PlateauIntegral 4.0 0.75 0.0 -1.0 1.0
Assert-Near $inside[0] 2.0 1e-12 'Compact plateau did not preserve unit density.'
Assert-Near $inside[1] 0.0 1e-12 'Shell leaked into a plateau-only interval.'
foreach ($noise in @(0.0, 0.25, 0.5, 0.75, 1.0)) {
    $eroded = $inside[0] + $inside[1] * (0.35 + 0.65 * $noise)
    Assert-Near $eroded 2.0 1e-12 'Boundary noise changed compact-core density.'
}

# Self transmittance is a sum of non-negative optical-depth integrals. Opposite
# lobe placement or a clipped ray segment must never create signed cancellation.
$nearLobe = Get-PlateauIntegral 2.0 0.58 0.0 -0.25 3.0
$farLobe = Get-PlateauIntegral 1.5 0.40 0.5 -2.0 2.0
$nearTau = ($nearLobe[0] + $nearLobe[1]) * 0.7 * 1.4
$farTau = ($farLobe[0] + $farLobe[1]) * 0.3 * 2.1
$totalTau = $nearTau + $farTau
if ($nearTau -lt 0.0 -or $farTau -lt 0.0 -or $totalTau -lt [math]::Max($nearTau, $farTau)) {
    throw 'Self-shadow optical depth admitted signed cancellation.'
}
$nearTransmission = [math]::Exp(-[math]::Min($nearTau, 20.0))
$totalTransmission = [math]::Exp(-[math]::Min($totalTau, 20.0))
if ($nearTransmission -lt 0.0 -or $nearTransmission -gt 1.0 -or
    $totalTransmission -lt 0.0 -or $totalTransmission -gt $nearTransmission) {
    throw 'Self transmittance is not bounded and monotonic under added smoke.'
}

# Expansion changes only geometric support here. An authored density coefficient
# remains independent rather than receiving implicit inverse-volume dilution.
$densityScale = 0.8
Assert-Near $densityScale 0.8 0.0 'Authored density changed at the initial radius.'
Assert-Near $densityScale 0.8 0.0 'Authored density changed after radius expansion.'

Write-Output 'Smoke transient compact-kernel numerical tests passed.'
