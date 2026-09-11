Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$schema = Get-Content -LiteralPath (Join-Path $root 'source/core/lightoverlay.h') -Raw
$parser = Get-Content -LiteralPath (Join-Path $root 'source/core/lightoverlay.cpp') -Raw
$emitters = Get-Content -LiteralPath (Join-Path $root 'source/common/rendering/nri/renderer/nri_smoke_emitters.cpp') -Raw
$clouds = Get-Content -LiteralPath (Join-Path $root 'source/common/rendering/nri/renderer/nri_smoke_transient_clouds.cpp') -Raw
$owner = Get-Content -LiteralPath (Join-Path $root 'source/common/rendering/nri/renderer/nri_smoke_transient_residency.cpp') -Raw
$release = Get-Content -LiteralPath (Join-Path $root 'release-overlay/LIGHTOVR') -Raw
$guide = Get-Content -LiteralPath (Join-Path $root 'LIGHTOVR-AUTHORING.md') -Raw
$native = Get-Content -LiteralPath (Join-Path $root 'tools/validation/tests/nri_smoke_transient_residency.tests.cpp') -Raw
$checks = 0
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
Require ([regex]::Matches($schema, 'bool burstBorrow = false;').Count -eq 2) 'Actor and event schema must default borrowing off.'
Require ([regex]::Matches($parser, 'sc\.Compare\("burstborrow"\)').Count -eq 2) 'Both rule parsers must recognize burstborrow.'
Require ([regex]::Matches($parser, 'ParseOnOffToken\(sc\.String, rule\.burstBorrow\)').Count -eq 2) 'Both parsers must reuse strict on/off token handling.'
Require ([regex]::Matches($parser, 'Invalid smoke burst borrowing value').Count -eq 2) 'Both parsers must report invalid borrowing values.'
Require ([regex]::Matches($parser, 'FStringf\("burstborrow %s", rule\.burstBorrow \? "on" : "off"\)').Count -eq 2) 'Normalized actor/event serializers must retain on and off, not silently lose the policy.'
Require ([regex]::Matches($parser, 'burstborrow=%s').Count -eq 4) 'Parsed and resolved actor/event diagnostics must expose borrowing.'
Require ($emitters -match 'shape\.burstBorrow = burstBorrow &&\s*transientClass == LightOverlaySmokeTransientClass::Explosion') 'Non-explosion rules must not borrow even when the authored flag is on.'
Require ($emitters -match 'rule\.analyticCarrierCount, rule\.transientLobeCount, rule\.transientClass,\s*rule\.burstBorrow') 'Actor flag must be plumbed into route construction.'
Require ($emitters -match 'rule\.transientClass, rule\.burstBorrow, true, command\.count') 'Event flag must be plumbed into route construction.'
Require ($clouds -match 'request\.burstBorrow = input\.burstBorrow;') 'Builder must retain semantic opt-in on every original descriptor.'
Require ($clouds -match 'request\.burstBorrow != first\.burstBorrow') 'Contradictory per-lobe policy must fail group identity validation.'
Require ($owner -match 'return request\.burstBorrow && request\.transientClass == NRISmokeTransientClass::Explosion;') 'Residency must independently enforce explosion-only authority.'
Require ($owner -match 'StampExplosionEpisodes\(\)[\s\S]*ra\.authoredGameplaySeconds < rb\.authoredGameplaySeconds') 'Episode classification must use deterministic authored-time ordering.'
Require ($owner -match 'authored - mLastExplosionAuthoredSeconds <= 0\.35') 'Rapid episode threshold must be explicit and simulation-time based.'
Require ($owner -match 'entry\.borrowDetail = follower \? std::min\(entry\.count, 3u\) : entry\.count') 'Isolated first explosions must retain art; only rapid followers compact.'
Require ($owner -match 'newFireWindowBlocked[\s\S]*MaximumFireCohortsPerSource') 'Outstanding loans must not allow new sources to spend promised ongoing Fire cadences.'
Require ([regex]::Matches($release, '(?m)^\s*burstborrow\s+on\s*$').Count -eq 1) 'Production borrowing must remain a single explicit rule opt-in.'
Require ($release -match 'smokeactorrule\s+"duke_explosion_cloud"\s*\{[^{}]*effectclass\s+explosion[^{}]*burstborrow\s+on') 'Production explosion actor is the authorized opt-in.'
Require ($guide.Contains('`burstborrow <on\|off>`')) 'Outward-facing authoring reference must document the field.'
Require ($guide -match '52 births every four 30 Hz actor ticks') 'Authoring reference must state the actual bounded acceptance load.'
Require ($guide -match 'ordinary immediate four-Fire guarantee does not apply during those loans') 'Authoring reference must not promise incompatible future capacity.'
Require ($native -match 'births == 52u && presented\.size\(\) == 52u') 'Native acceptance must require every authored birth to actually present.'
Require ($native -match 'group\.ageSeconds <= 1\.0f / 30\.0f') 'Native acceptance must reject stale-tail presentation disguised as successful admission.'
Write-Host "Explosion borrowing schema/routing contracts passed: $checks checks (static parser/serializer contracts, not an engine parser execution)."
