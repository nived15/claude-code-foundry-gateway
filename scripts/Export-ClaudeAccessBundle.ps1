<#
.SYNOPSIS
    Copies the gateway files the access-catalog import runs into scripts/new-scripts, or with -Check lists the copies that differ.

.DESCRIPTION
    scripts/new-scripts is published on its own, so Import-ClaudeAccessCatalog.ps1 runs from copies of the
    deployer, the policy, the templates and the resolver and sync packages. They keep this repository's layout
    (scripts/, infra/, resolver/, sync/) so each script finds the others as it does here. This repository stays
    the source: change a file here, then run this script. -Check changes nothing and exits 1 on any difference.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/Export-ClaudeAccessBundle.ps1 -Check
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination = (Join-Path $PSScriptRoot 'new-scripts'),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$files = @(
    'scripts/ApimNamedValue.ps1'
    'scripts/ClaudeBudgetModes.ps1'
    'scripts/ClaudeBusinessUnit.ps1'
    'scripts/ClaudeChoice.ps1'
    'scripts/ClaudeEntitlementGroups.ps1'
    'scripts/ClaudeGraphMembership.ps1'
    'scripts/ClaudeModelDeployment.ps1'
    'scripts/ClaudeModelPrices.ps1'
    'scripts/ClaudeNetwork.ps1'
    'scripts/ClaudeProjectionChecks.ps1'
    'scripts/ClaudeProjectionGraphGrant.ps1'
    'scripts/ClaudeProjectionPackage.ps1'
    'scripts/ClaudeProjectionSchedule.ps1'
    'scripts/ClaudeProjectionSwitch.ps1'
    'scripts/ClaudeRunner.ps1'
    'scripts/ClaudeRunnerTransferModel.ps1'
    'scripts/Compare-ClaudeEntitlement.ps1'
    'scripts/Deploy-ClaudeProjection.ps1'
    'scripts/Deploy-ClaudeProjectionRenewal.ps1'
    'scripts/Get-ClaudeGatewayTarget.ps1'
    'scripts/Get-ClaudeTelemetry.ps1'
    'scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1'
    'scripts/Set-GatewayPolicy.ps1'
    'scripts/Sync-ClaudeProjection.ps1'
    'scripts/flow/FlowContract.ps1'
    'scripts/flow/lib/LifecycleCommon.ps1'
    # Set-GatewayPolicy.ps1 reads the named-value defaults from main.bicep's text; nothing deploys it.
    'infra/main.bicep'
    'infra/policy.xml'
    'infra/content-safety-screening.xml'
    'infra/projection.bicep'
    'infra/projection-network.bicep'
    'infra/projection-registry.bicep'
    'infra/projection-renewal.bicep'
    'infra/projection-renewal-gateway-reader.bicep'
    'infra/resolver.bicep'
    'resolver/host.json'
    'resolver/package.json'
    'sync/Dockerfile'
    'sync/package.json'
    'sync/package-lock.json'
)
foreach ($folder in 'resolver/src', 'sync/src') {
    $base = (Resolve-Path -LiteralPath (Join-Path $root $folder)).Path
    $files += @(Get-ChildItem -LiteralPath $base -Recurse -File | ForEach-Object { "$folder/" + $_.FullName.Substring($base.Length + 1).Replace('\', '/') })
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$drift = [Collections.Generic.List[string]]::new()
foreach ($rel in $files) {
    $source = Join-Path $root $rel
    $target = Join-Path $Destination $rel
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source '$rel' does not exist; update the list in $PSCommandPath." }
    if ((Get-Sha256 $source) -eq (Get-Sha256 $target)) { continue }
    if ($Check) { $drift.Add($(if (Test-Path -LiteralPath $target) { "differs: $rel" } else { "missing: $rel" })); continue }
    if ($PSCmdlet.ShouldProcess($target, "copy $rel")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host "  copied $rel"
    }
}
# A copied folder holds the listed files only, so a file removed here is not left behind there.
$listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rel in $files) { [void]$listed.Add($rel) }
$destinationRoot = if (Test-Path -LiteralPath $Destination) { (Resolve-Path -LiteralPath $Destination).Path } else { '' }
foreach ($folder in 'scripts', 'infra', 'resolver', 'sync') {
    if (-not $destinationRoot -or -not (Test-Path -LiteralPath (Join-Path $destinationRoot $folder))) { continue }
    foreach ($extra in @(Get-ChildItem -LiteralPath (Join-Path $destinationRoot $folder) -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' })) {
        $rel = $extra.FullName.Substring($destinationRoot.Length + 1).Replace('\', '/')
        if ($listed.Contains($rel)) { continue }
        if ($Check) { $drift.Add("not in the list: $rel"); continue }
        if ($PSCmdlet.ShouldProcess($extra.FullName, 'remove a file the bundle no longer lists')) { Remove-Item -LiteralPath $extra.FullName -Force; Write-Host "  removed $rel" }
    }
}
if ($Check) {
    if ($drift.Count) {
        Write-Host "The bundle in $Destination differs from this repository ($($drift.Count)):" -ForegroundColor Red
        $drift | ForEach-Object { Write-Host "  $_" }
        Write-Host "Remedy: pwsh -NoProfile -File ./scripts/Export-ClaudeAccessBundle.ps1" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "The bundle matches this repository ($($files.Count) files)." -ForegroundColor Green
}
