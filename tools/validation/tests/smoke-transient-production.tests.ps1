Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$release = Get-Content -LiteralPath (Join-Path $root 'release-overlay/LIGHTOVR') -Raw

# Add a rule only after its isolated candidate/rollback and production capture.
# The class mask remains the runtime rollback; a new spelling must not silently
# bypass this source allowlist (the scanner requires quoted transient-cloud).
$cutovers = @{
    duke_explosion_cloud = @{ Class = 'explosion'; Lobes = 12; Legacy = 'grid' }
    duke_rpg_trail_continuous = @{ Class = 'trail'; Lobes = 4; Legacy = 'grid' }
}

# Canonical field hashes at 64e8366e7a. Strip only the explicitly transient-only
# fields below and restore the old representation before comparing. This proves
# that cutovers retain legacy counts, optics, cadence, admission/freshness and
# analytic carrier counts. Map emitters and the fog style are compared verbatim.
$baseline = @{
    duke_explosion_smoke = '90BE33C99481CCF797A60B768C54DB7C658308146720BAF4FBAC1F6B23DDD2E8'
    duke_fire_smoke = '7F6FE521D62FA81B2717C321C18A5E48540D22D5DA403D46C93D7F13F44B49FE'
    duke_impact_smoke = 'C9A2EE27585731B6E58F81ECD710EF09F87BFCBA88AFE1F53A7AA82CEB38B36B'
    duke_muzzle_smoke = 'D553C915F6EA6D09FA477D5B8F49A2BC8B5FB05826626B839E0358919B233B64'
    duke_trail_smoke = 'E3D7AF097F22DE7AAD41DD77F0F45132133D0F0BCDB4867B921256B30E099F00'
    ground_mood_smoke = '77764C5CEEBE0E5B9E2FAE6242F550943A26DCE04351E1883912B5B13E48D53C'
    duke_explosion_cloud = '9A0D88EDAD9FAD5556059B6287610CEFE4C969D20ABA81E28B15A74438906E75'
    duke_fire_sustained = '5FF713B931BCA5DDAC1F51CFA5186D17264AA9263A92296CBE73CBC7693564ED'
    duke_rpg_trail_continuous = '02989707A0E02C2F1FE8DDD1995B4B69F6A1B5942066B1529B787852245CB949'
    'duke.chaingun.primary' = 'E72E10945C231DD97AE5214414239D6F654D0DF831670D7E0C8F1CBF7D9F5565'
    'duke.hitscan.impact.plane' = '4CB9ABA36F0BC695BBA9098EA280A9B24EF0A9929032365B4D2405B967788848'
    'duke.hitscan.impact.wall' = 'FE6938044EF6BE0A9F16BDAB04DB48939676246AE6A7FD93636529B15AB6375C'
    'duke.pistol.primary' = 'BE9E2AAE7447EE75931CCD627B3E01A5883B32DB0C5E9328A78C9407044504DC'
    'duke.shotgun.primary' = 'A734DEF20F19254C46814FF5B98247A75BDBA938E5562979B2E560702BDD6366'
    'nri.smoke.test' = '180817D8414F6133515B04123BF1DEB053E5868007473976EB69401DBD92D0D6'
    FarWindow = '33DCC433BC5E78B3F39F94C52AAC73D73A56DA71723A5A6C7FA8A9E31314499B'
    NearWindow = 'BB580632963FCF6CBC1D7411E118557F8D2E782D7897F60A152B6F9D5E59B76B'
    RoofLong = '70AC8FAD4A642AE1A41491AFFE036B2973991E20E4AA95E331F166729EEB953E'
    RoofSquare = '96E3B9D99626419EF33BE5A8E3D4F3C3D5E844E9A3C6EACF15AC1E8C40081817'
}
$transientStyleFields = @(
    'opticalamountscale', 'transientlifetimeseconds', 'densityattackseconds',
    'densitysustainseconds', 'densityreleaseseconds', 'radiusexponent',
    'intrinsicemission', 'emissionhalflife', 'clusterspread', 'loberadiusrandom',
    'curlvelocity', 'coreplateau', 'edgeerosion', 'noisescale', 'noisestrength')
$seen = @{}
$blocks = [regex]::Matches($release, '(?s)(smokestyle|smokeactorrule|smokeeventrule|smokeemitter)\s+"([^"]+)"\s*\{([^{}]*)\}')
foreach ($block in $blocks) {
    $kind = $block.Groups[1].Value
    $name = $block.Groups[2].Value
    $body = $block.Groups[3].Value
    if (-not $baseline.ContainsKey($name) -or $seen.ContainsKey($name)) {
        throw "Unexpected or duplicated production smoke block: $kind $name"
    }
    $seen[$name] = $true
    $isTransient = $body -match 'representation\s+"?transient-cloud"?'
    if ($cutovers.ContainsKey($name)) {
        $cutover = $cutovers[$name]
        if (-not $isTransient -or $body -notmatch ('effectclass\s+' + $cutover.Class + '\b') -or
            $body -notmatch ('lobecount\s+' + $cutover.Lobes + '\b')) {
            throw "Production $name does not match its explicitly validated class/lobe route."
        }
        $body = [regex]::Replace($body, 'representation\s+"?transient-cloud"?', 'representation ' + $cutover.Legacy)
        $body = [regex]::Replace($body, '(?m)^\s*(effectclass|lobecount)\s+[^\r\n]+', '')
    }
    elseif ($isTransient) { throw "Production $name has no accepted cutover entry." }

    if ($kind -eq 'smokestyle' -and $name -ne 'ground_mood_smoke') {
        $body = [regex]::Replace($body, '(?m)^\s*(' + ($transientStyleFields -join '|') + ')\s+[^\r\n]+', '')
    }
    $canonical = (($body -split "`n" | ForEach-Object {
        (($_ -replace '//.*$', '').Trim() -replace '\s+', ' ')
    } | Where-Object { $_ }) -join "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '') }
    finally { $sha.Dispose() }
    if ($digest -cne $baseline[$name]) {
        throw "Production $name changed a legacy field outside its explicit transient cutover ($digest)."
    }
}
if ($seen.Count -ne $baseline.Count) { throw 'Production smoke authoring lost a baseline block.' }
Write-Host "Transient production authoring passed: $($cutovers.Count) explicit routes; $($baseline.Count) preserved legacy blocks."
