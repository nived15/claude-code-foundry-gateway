<#
.SYNOPSIS
    The one command for the Claude access catalog: checks claude-access-catalog.json and, with -Apply, sets up
    the existing gateway to enforce it.

.DESCRIPTION
    Stops on any error in the file before touching Azure. Without -Offline it then checks the file against the live
    tenant (subscription, API Management, every Foundry deployment and every Entra group) and reads each group's
    members to resolve one profile per user. It always writes review artifacts to -OutputPath, including one Claude
    Desktop policy per group for Intune.

    Before any write, it lists everyone who has access now and would not under the catalog, and stops unless
    -AcceptAccessRemoval is passed; with -Apply it also runs the projection preflight (providers, permissions,
    names, Graph). -Apply then, against the existing gateway:

      1. writes quota-org, calls-per-minute and entitlement-cache-seconds;
      2. applies infra/policy.xml, which reads each person's models and monthly and daily limits from their record;
      3. deploys or updates the entitlement projection (scripts/Deploy-ClaudeProjection.ps1 -InfrastructureOnly);
      4. stores the catalog and one record per person in the projection, through the in-VNet runner;
      5. switches the gateway to the projection after a clean comparison and the switch evidence, checks that the
         gateway answers, and switches back to named values if it does not;
      6. deploys the sync job that keeps the records in step with the groups (scripts/Deploy-ClaudeProjectionRenewal.ps1).

    Every step is safe to rerun: run it again after a failure, or after changing the catalog.

.EXAMPLE
    ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json -Offline

.EXAMPLE
    ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json

.EXAMPLE
    ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json -Apply
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    # Defaults to a temp folder: assignments.json holds user object IDs and should not land in the repository.
    [string]$OutputPath,
    [switch]$Offline,
    [switch]$Apply,
    [switch]$AcceptAccessRemoval
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAccessCatalog.ps1')

function Step($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Bad($m) { Write-Host "    [FAIL] $m" -ForegroundColor Red }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }

if ($Apply -and $Offline) { throw '-Apply writes to the live gateway and needs the live checks; remove -Offline. Nothing was written.' }
if ($Apply -and $PSVersionTable.PSVersion.Major -lt 7) { throw '-Apply runs the projection scripts, which need PowerShell 7: run it with pwsh. Nothing was written.' }
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Catalog '$Path' was not found. Nothing was written." }

Step 'Catalog'
try { $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
catch { throw "Catalog '$Path' is not valid JSON: $($_.Exception.Message) Nothing was written." }
$findings = @(Test-ClaudeAccessCatalog -Catalog $catalog)
foreach ($x in $findings) {
    if ($x.Severity -eq 'error') { Bad "$($x.Path): $($x.Message)" } else { Warn "$($x.Path): $($x.Message)" }
}
$errors = @($findings | Where-Object { $_.Severity -eq 'error' })
if ($errors.Count) { throw "$($errors.Count) error(s) in '$Path'. Nothing was read from Azure and nothing was written." }
Ok ('{0} groups, {1} profiles, {2} model sets; catalog {3}' -f @($catalog.groups).Count, @($catalog.profiles).Count,
    @($catalog.modelSets.PSObject.Properties).Count, $catalog.catalogVersion)

if (-not $OutputPath) {
    $OutputPath = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'claude-access-catalog') ([string]$catalog.catalogVersion)
}
$gw = $catalog.gateway
$pj = $catalog.projection
$families = @($catalog.modelSets.PSObject.Properties | ForEach-Object { @($_.Value) } | Select-Object -Unique)
$plannedIds = @('quota-org') + @((Get-ClaudeAccessCatalogPlan -Catalog $catalog).NamedValues.Keys | Where-Object { $_ -ne 'quota-org' })
$current = @{}
$assignment = $null
$membership = @{}
$removed = @()

function Read-CatalogMembership([switch]$Quiet) {
    $token = Get-GraphToken
    # The runner refuses a snapshot two hours after the read began, not after it ended.
    $verifiedAt = [DateTimeOffset]::UtcNow
    $members = @{}
    $bad = 0
    foreach ($g in @($catalog.groups | Sort-Object { [long]$_.row })) {
        $oid = ([string]$g.objectId).ToLowerInvariant()
        try { $found = Invoke-ClaudeGraphRead -Uri "https://graph.microsoft.com/v1.0/groups/${oid}?`$select=id,displayName,securityEnabled" -Token $token }
        catch { Bad "row $($g.row): group $oid could not be read. $($_.Exception.Message)"; $bad++; continue }
        if ([string]$found.displayName -cne [string]$g.displayName) { Bad "row $($g.row): $oid is '$($found.displayName)' in Entra, not '$($g.displayName)'."; $bad++; continue }
        if (-not $found.securityEnabled) { Bad "row $($g.row): '$($g.displayName)' is not a security group."; $bad++; continue }
        $members[$oid] = @(Get-GroupMemberOids -GroupName $oid -Token $token | ForEach-Object { ([string]$_.Oid).ToLowerInvariant() })
        if (-not $Quiet) { Note ('row {0,2}: {1,5} member(s)  {2}' -f $g.row, $members[$oid].Count, $g.displayName) }
    }
    if ($bad) { throw "$bad group(s) failed the check. Correct the object IDs or the groups, then rerun. Nothing was written." }
    return [pscustomobject]@{ Membership = $members; VerifiedAt = $verifiedAt }
}

if (-not $Offline) {
    . (Join-Path $PSScriptRoot 'scripts\ClaudeGraphMembership.ps1')
    . (Join-Path $PSScriptRoot 'scripts\ApimNamedValue.ps1')
    . (Join-Path $PSScriptRoot 'scripts\ClaudeModelDeployment.ps1')

    Step 'Azure subscription'
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is not on PATH. Install it and run az login, or pass -Offline to check the file alone.' }
    $account = Invoke-ClaudeNetworkAz @('account', 'show')
    if ([string]$account.tenantId -ne [string]$gw.tenantId) {
        throw "The Azure CLI is signed in to tenant $($account.tenantId), not $($gw.tenantId). Run az login --tenant $($gw.tenantId), then rerun. Nothing was written."
    }
    if ([string]$account.id -ne [string]$gw.subscriptionId) {
        throw "The Azure CLI is on subscription $($account.id), not $($gw.subscriptionId). Run az account set --subscription $($gw.subscriptionId), then rerun. Nothing was written."
    }
    Ok "$($account.name) ($($account.id))"

    Step 'API Management'
    $apim = Invoke-ClaudeNetworkAz @('apim', 'show', '-g', $gw.resourceGroup, '-n', $gw.apimName)
    if ([string]$apim.sku.name -notmatch 'V2$') {
        throw "$($gw.apimName) is $($apim.sku.name); only the v2 tiers meter Anthropic tokens, so token limits would read zero. Nothing was written."
    }
    Ok "$($gw.apimName) ($($apim.sku.name))"
    if ([string]$apim.sku.name -eq 'BasicV2' -and [string]$pj.resolverInboundAccess -eq 'private') {
        throw 'projection.resolverInboundAccess is private, but Basic v2 has no outbound VNet integration to reach a private resolver. Set it to public (the resolver still requires the gateway''s token), then rerun. Nothing was written.'
    }
    # The resolver answers every uncached request, so by default it sits beside the gateway.
    $projectionLocation = if ($pj.location) { [string]$pj.location } else { ([string]$apim.location -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
    Note "projection region: $projectionLocation$(if (-not $pj.location) { ' (the gateway''s)' })"
    foreach ($id in $plannedIds + @('entitlement-source', 'entitlement-projection-prefix', 'allow-standard', 'allow-premium', 'bu-unassigned')) {
        $current[$id] = Get-ApimNamedValue -ResourceGroup $gw.resourceGroup -ApimName $gw.apimName -Id $id -FailOnError -SubscriptionId $gw.subscriptionId
    }
    $source = if ($current['entitlement-source']) { [string]$current['entitlement-source'] } else { 'named-value' }
    Note "entitlement-source is $source"
    $recordedPrefix = [string]$current['entitlement-projection-prefix']
    if ($recordedPrefix -and $recordedPrefix -cne [string]$pj.namePrefix) {
        if ($source -eq 'projection') {
            throw "The gateway serves from projection '$recordedPrefix', not projection.namePrefix '$($pj.namePrefix)'. Set namePrefix to $recordedPrefix, then rerun. Nothing was written."
        }
        Warn "The gateway records projection '$recordedPrefix'; this run deploys '$($pj.namePrefix)' and points the gateway at it. Use $recordedPrefix to reuse that one."
    }
    if ([string]$current['bu-unassigned'] -eq 'deny') {
        throw 'bu-unassigned is deny: catalog records carry no business unit, so the gateway would refuse every catalog user. Set bu-unassigned to allow, then rerun. Nothing was written.'
    }

    Step 'Foundry deployments'
    $deployed = @(Get-ClaudeDeployment -Account $gw.foundryAccount -ResourceGroup $gw.foundryResourceGroup)
    $missing = 0
    foreach ($fam in $families) {
        $name = [string](Get-CatalogProperty $catalog.deployments $fam)
        $d = @($deployed | Where-Object { $_.name -ceq $name })[0]
        if (-not $d) { Bad "deployments.${fam}: '$name' is not a Claude deployment on $($gw.foundryAccount)."; $missing++; continue }
        if ([string]$d.model -notlike "*$fam*") { Warn "deployments.${fam}: '$name' serves $($d.model), which does not look like $fam." }
        Ok (Format-ClaudeDeployment $d)
    }
    if ($missing) { throw "$missing deployment(s) were not found. Create them or correct the names, then rerun. Nothing was written." }

    Step 'Entra groups'
    $read = Read-CatalogMembership
    $membership = $read.Membership

    $assignment = Resolve-ClaudeAccessAssignment -Catalog $catalog -Membership $membership
    $entitled = @($assignment.Users | Where-Object { -not $_.Denied }).Count
    Ok ('{0} user(s) entitled; {1} in more than one group; {2} refused by the deny rule' -f $entitled, $assignment.Conflicts.Count, $assignment.Denied.Count)
    if ($assignment.Conflicts.Count) {
        Warn "Users in more than one group are listed in assignments.json (conflictRows). The rule applied is $($catalog.organisation.multipleGroupRule)."
    }
}

$plan = Get-ClaudeAccessCatalogPlan -Catalog $catalog -Assignment $assignment

Step 'Profiles'
foreach ($p in $plan.Profiles) {
    $users = if ($assignment) { @($assignment.Users | Where-Object { -not $_.Denied -and $_.Profile -ceq $p.Id }).Count } else { '-' }
    Note ('{0,-22} {1,-12} {2,-12} {3,15:N0}/month {4,13:N0}/day  users {5}' -f $p.Id, $p.Level, $p.ModelSet, $p.TokensPerMonth, $p.TokensPerDay, $users)
}
switch ($plan.OrganisationSource) {
    'catalog' { Note ('organisation ceiling {0:N0} tokens/month, from the catalog' -f $plan.OrganisationTokensPerMonth) }
    'computed' {
        Note ('organisation ceiling {0:N0} tokens/month, the sum of every entitled user''s monthly allowance' -f $plan.OrganisationTokensPerMonth)
        if ($plan.OrganisationTokensPerMonth -gt $script:CatalogInt32Max) {
            Warn 'The computed ceiling is above 2,147,483,647: Install-ClaudeGateway.ps1 -QuotaOrg is [int], and whether llm-token-limit accepts a token-quota that large is unverified.'
        }
    }
    'unknown' { Warn 'organisation.tokensPerMonth is null and membership was not read (-Offline), so quota-org is left out of the plan.' }
}

Step 'Review artifacts'
$clients = Join-Path $OutputPath 'clients'
New-Item -ItemType Directory -Force -Path $clients -WhatIf:$false | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutputPath 'catalog-document.json'),
    (ConvertTo-Json -InputObject (New-ClaudeAccessCatalogDocument -Catalog $catalog -Plan $plan) -Depth 10), $utf8)
$nvReport = @(foreach ($k in $plan.NamedValues.Keys) {
    $was = if ($Offline) { $null } else { $current[$k] }
    [ordered]@{ id = $k; planned = $plan.NamedValues[$k]; current = $was }
})
[IO.File]::WriteAllText((Join-Path $OutputPath 'named-values.json'), (ConvertTo-Json -InputObject $nvReport -Depth 5), $utf8)
if ($assignment) {
    $userReport = @($assignment.Users | ForEach-Object {
        [ordered]@{ oid = $_.Oid; row = $_.Row; profile = $_.Profile; modelSet = $_.ModelSet; tokensPerMonth = $_.TokensPerMonth
            tokensPerDay = $_.TokensPerDay; conflictRows = $(if ($_.Conflict) { @($_.Rows) } else { @() }); denied = $_.Denied }
    })
    [IO.File]::WriteAllText((Join-Path $OutputPath 'assignments.json'), (ConvertTo-Json -InputObject $userReport -Depth 5), $utf8)
}
$clientRows = foreach ($g in @($catalog.groups | Sort-Object { [long]$_.row })) {
    $keys = Get-ClaudeDesktopGroupKeys -Catalog $catalog -Group $g
    $stem = 'group-{0:D2}' -f [int]$g.row
    [IO.File]::WriteAllText((Join-Path $clients "$stem.desktop.json"), (ConvertTo-Json -InputObject $keys -Depth 10), $utf8)
    # regedit reads a "Version 5.00" file as UTF-16.
    [IO.File]::WriteAllText((Join-Path $clients "$stem.reg"), (ConvertTo-ClaudeDesktopRegistry -Keys $keys), [Text.Encoding]::Unicode)
    $oid = ([string]$g.objectId).ToLowerInvariant()
    [pscustomobject]@{
        Row = $g.row; DisplayName = $g.displayName; ObjectId = $oid; Profile = $g.profile
        Capabilities = (@($g.capabilities) -join '-'); M365 = $g.m365; DeployClaudeCodeCli = (@($g.capabilities) -ccontains 'Co')
        DesktopPolicy = "$stem.reg"; Members = $(if ($membership.ContainsKey($oid)) { $membership[$oid].Count } else { '' })
    }
}
$clientRows | Export-Csv -LiteralPath (Join-Path $clients 'client-assignments.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
Ok "written to $OutputPath"
Note 'catalog-document.json, named-values.json and clients\ (one Desktop policy per group, as .desktop.json and .reg, plus client-assignments.csv)'

$writing = $Apply -and -not $WhatIfPreference
if (-not $Offline) {
    Step 'Who would lose access'
    if ($source -eq 'projection') {
        Note 'The gateway serves from the projection: the runner compares it with the catalog before it writes anything.'
    }
    else {
        $removed = Get-ClaudeAccessRemoval -Assignment $assignment -Current @([string]$current['allow-standard'], [string]$current['allow-premium'])
        [IO.File]::WriteAllText((Join-Path $OutputPath 'access-removed.json'), (ConvertTo-Json -InputObject @($removed) -Depth 2), $utf8)
        if ($removed.Count) { Warn "$($removed.Count) user(s) in allow-standard or allow-premium are in no catalog group, or are refused by the deny rule; they are listed in access-removed.json." }
        else { Ok 'everyone in allow-standard and allow-premium keeps access' }
    }
    if ($writing -and $removed.Count -and -not $AcceptAccessRemoval) {
        throw "$($removed.Count) user(s) would lose access (access-removed.json in $OutputPath). Add them to a catalog group, or rerun with -AcceptAccessRemoval. Nothing was written."
    }
}

$firstGroup = ([string]@($catalog.groups | Sort-Object { [long]$_.row })[0].objectId).ToLowerInvariant()
if ($writing) {
    Step 'Projection preflight (no writes)'
    & (Join-Path $PSScriptRoot 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup $gw.resourceGroup -ApimName $gw.apimName -NamePrefix ([string]$pj.namePrefix) `
        -SubscriptionId $gw.subscriptionId -Location $projectionLocation -Sku ([string]$apim.sku.name) -ResolverInboundAccess ([string]$pj.resolverInboundAccess) `
        -StandardGroup $firstGroup -PremiumGroup none -PreflightOnly | Out-Host
}

Step $(if ($writing) { 'Gateway named values' } else { 'Gateway named values (plan only; -Apply writes them)' })
if ($writing -and $plan.NamedValues.Contains('quota-org') -and [long]$plan.NamedValues['quota-org'] -le 0) {
    throw 'The organisation ceiling is 0 because no user is entitled; quota-org 0 would refuse everyone. Set organisation.tokensPerMonth or add members. Nothing was written.'
}
$changed = 0
foreach ($k in $plan.NamedValues.Keys) {
    $new = [string]$plan.NamedValues[$k]
    $old = if ($Offline) { $null } else { $current[$k] }
    $label = if ($Offline) { "${k} = $new" }
             elseif ($null -eq $old) { "${k}: (absent) -> $new" }
             elseif ([string]$old -ceq $new) { "${k}: $new (unchanged)" }
             else { "${k}: $old -> $new" }
    if (-not $writing -or [string]$old -ceq $new) { Note $label; continue }
    Set-ApimNamedValue -ResourceGroup $gw.resourceGroup -ApimName $gw.apimName -Id $k -Value $new -SubscriptionId $gw.subscriptionId
    Ok $label
    $changed++
}
if ($changed) {
    Warn 'Re-running Install-ClaudeGateway.ps1 rewrites quota-org and calls-per-minute from its own prompts; pass -QuotaOrg and -CallsPerMinute with these values.'
}

if (-not $writing) {
    Step 'Next'
    if ($Offline) { Note 'Run without -Offline to check the file against the tenant and read every group.' }
    else { Note 'Review the artifacts, then run again with -Apply to set up the gateway.' }
    Note 'The client policies take effect once each group''s .reg or .desktop.json is deployed to that group through Intune or MDM.'
    return
}

# ---- -Apply: everything below writes to Azure. Each step is safe to rerun.
. (Join-Path $PSScriptRoot 'scripts\ClaudeProjectionSwitch.ps1')
$rg = [string]$gw.resourceGroup
$prefix = [string]$pj.namePrefix
$tenant = ([string]$gw.tenantId).ToLowerInvariant()

function Get-Deployment([string]$Name) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $out = @(az deployment group show -g $rg -n $Name --subscription $gw.subscriptionId --query properties -o json 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -eq 0) { return ($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | Out-String) | ConvertFrom-Json }
    if ($text -match 'DeploymentNotFound') { return $null }
    throw "Could not read deployment $Name in ${rg} (az exit $code): $text"
}

function Invoke-SyncJobDeployment([string]$Standard, [string]$Premium) {
    $receipt = Join-Path $OutputPath "projection-renewal-$prefix.json"
    & (Join-Path $PSScriptRoot 'scripts\Deploy-ClaudeProjectionRenewal.ps1') -ResourceGroup $rg -ApimName $gw.apimName -NamePrefix $prefix `
        -SubscriptionId $gw.subscriptionId -AlertEmail @($pj.alertEmail) -SyncInterval ([string]$pj.syncInterval) `
        -StandardGroup $Standard -PremiumGroup $Premium -ReceiptPath $receipt -Confirm:$false | Out-Host
}

function Invoke-GatewayProbe {
    $model = [string](Get-CatalogProperty $catalog.deployments 'sonnet')
    if (-not $model) { $model = [string](Get-CatalogProperty $catalog.deployments $families[0]) }
    $body = @{ model = $model; max_tokens = 1; messages = @(@{ role = 'user'; content = 'ping' }) } | ConvertTo-Json -Depth 5
    $uri = ([string]$apim.gatewayUrl).TrimEnd('/') + '/claude/v1/messages'
    # A named value reaches every gateway unit within seconds; a request sent at once can still see the old source.
    Start-Sleep -Seconds 20
    $status = 0
    foreach ($attempt in 1..3) {
        $token = (az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
        try {
            $r = Invoke-WebRequest -Uri $uri -Method Post -Body $body -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 60 `
                -Headers @{ Authorization = 'Bearer ' + ([string]$token).Trim(); 'anthropic-version' = '2023-06-01' }
            $status = [int]$r.StatusCode
        }
        catch { return [pscustomobject]@{ Status = 0; Detail = $_.Exception.Message } }
        if ($status -lt 500) { break }
        Start-Sleep -Seconds 10
    }
    return [pscustomobject]@{ Status = $status; Detail = '' }
}

Step 'Gateway policy'
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'scripts\Set-GatewayPolicy.ps1') -ApimName $gw.apimName -ResourceGroup $rg -PolicyFile (Join-Path $PSScriptRoot 'infra\policy.xml') -SubscriptionId $gw.subscriptionId
if ($LASTEXITCODE) { throw 'The gateway policy was not applied (see above). The named values above are written; nothing else changed. Rerun after fixing the cause.' }
Note 'Tier records and named-value lists behave as before; catalog records get their own models and limits.'

Step 'Entitlement projection'
$existingRenewal = Get-Deployment "projection-renewal-$prefix"
if ($existingRenewal -and [string]$pj.syncInterval -eq 'none') {
    throw "A sync job (projection-renewal-$prefix) already runs on code that does not know the catalog and would overwrite its records. Set projection.syncInterval to an interval or manual, then rerun."
}
& (Join-Path $PSScriptRoot 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup $rg -ApimName $gw.apimName -NamePrefix $prefix -SubscriptionId $gw.subscriptionId `
    -Location $projectionLocation -Sku ([string]$apim.sku.name) -ResolverInboundAccess ([string]$pj.resolverInboundAccess) -StandardGroup $firstGroup -PremiumGroup none `
    -InfrastructureOnly -Confirm:$false | Out-Host
$network = Get-Deployment "projection-network-$prefix"
$projection = Get-Deployment "projection-$prefix"
$runner = [string]$network.outputs.runnerName.value
$cosmos = if ($projection.outputs.accountName.value) { [string]$projection.outputs.accountName.value } else { "cosmos-$prefix" }
if (-not $runner) { throw "projection-network-$prefix returned no runner. Rerun; if it persists, redeploy with scripts/Deploy-ClaudeProjection.ps1." }
$accountResourceId = "/subscriptions/$($gw.subscriptionId)/resourceGroups/$rg/providers/Microsoft.DocumentDB/databaseAccounts/$cosmos"
$cosmosArgs = "--cosmos https://$cosmos.documents.azure.com:443/ --tenant $tenant --account-resource-id $accountResourceId"

if ($existingRenewal) {
    # Before the catalog is stored: the job's old image would otherwise rewrite the catalog records from the tier groups.
    Step 'Sync job: new code first, still on its current groups'
    Invoke-SyncJobDeployment ([string]$existingRenewal.parameters.standardGroupId.value) ([string]$existingRenewal.parameters.premiumGroupId.value)
}

Step 'Load the catalog into the projection'
$fresh = Read-CatalogMembership -Quiet
$assignment = Resolve-ClaudeAccessAssignment -Catalog $catalog -Membership $fresh.Membership
$snapshot = New-ClaudeAccessSnapshot -Catalog $catalog -Plan $plan -Assignment $assignment -VerifiedAt $fresh.VerifiedAt
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-access-catalog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $snapshotPath = Join-Path $work 'snapshot.json'
    [IO.File]::WriteAllText($snapshotPath, (ConvertTo-Json -InputObject $snapshot -Depth 10), $utf8)
    $archive = New-ClaudeProjectionSyncArchive -Path (Join-Path $work 'sync.tar.gz') -Root $PSScriptRoot
    Start-ClaudeProjectionRunner -ResourceGroup $rg -Name $runner -SubscriptionId $gw.subscriptionId | Out-Null
    Send-RunnerFile -ResourceGroup $rg -Name $runner -Path $archive -Destination /work/sync-source.tar.gz | Out-Null
    Send-RunnerFile -ResourceGroup $rg -Name $runner -Path $snapshotPath -Destination /work/snapshot.json -Deadline (Get-RunnerFileDeadline -Path $snapshotPath) | Out-Null
    Send-RunnerFile -ResourceGroup $rg -Name $runner -Path (Join-Path $OutputPath 'catalog-document.json') -Destination /work/catalog.json | Out-Null
    Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work' | Out-Null
    Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' | Out-Null

    $compare = {
        $raw = Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command "node /work/sync/src/apply-projection.mjs $cosmosArgs --compare-snapshot /work/snapshot.json"
        $result = try { @(([string]$raw).TrimEnd("`r", "`n") -split '\r?\n')[-1] | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        if (-not ($result -and $result.mode -eq 'compare-snapshot' -and $null -ne $result.differences)) {
            Write-ClaudeRunnerOutput -RawOutput ([string]$raw) -Step 'Projection compare'
            throw 'The runner could not compare the projection with the catalog; its sanitized output is shown above. entitlement-source is unchanged.'
        }
        return $result
    }
    if ($source -eq 'projection') {
        $before = & $compare
        $lose = [int]$before.byKind.'would-delete-record'
        if ($lose -and -not $AcceptAccessRemoval) {
            throw "$lose user(s) served by the projection now are in no catalog group and would lose access. Add them to a catalog group, or rerun with -AcceptAccessRemoval. The projection was not changed."
        }
    }
    $applyRaw = Invoke-RunnerCommand -ResourceGroup $rg -Name $runner -Command "node /work/sync/src/apply-projection.mjs $cosmosArgs --snapshot /work/snapshot.json --catalog /work/catalog.json"
    $applied = ConvertFrom-ClaudeRunnerResult -RawOutput $applyRaw -Step 'Catalog apply'
    Ok ('catalog {0}: {1} record(s) written, {2} removed, {3} unchanged' -f $catalog.catalogVersion, $applied.written, $applied.deleted, $applied.unchanged)

    Step 'Switch the gateway to the projection'
    $switched = $false
    if ($source -ne 'projection') {
        $after = & $compare
        if ($after.differences -ne 0) { throw "The projection differs from the catalog in $($after.differences) record(s) after the apply; entitlement-source is unchanged. Rerun." }
        $null = Assert-ClaudeProjectionAdmission -ResourceGroup $rg -RunnerName $runner -CosmosAccount $cosmos -TenantId $tenant -AccountResourceId $accountResourceId
        $backup = Save-ClaudeProjectionSwitchBackup -ResourceGroup $rg -ApimName $gw.apimName -GatewayResourceId ([string]$apim.id) -Directory $OutputPath
        Set-ApimNamedValue -ResourceGroup $rg -ApimName $gw.apimName -Id 'entitlement-source' -Value 'projection' -SubscriptionId $gw.subscriptionId
        $switched = $true
        Ok "entitlement-source is projection; the values before the switch are in $backup"
    }
    else { Ok 'the gateway already serves from the projection; its records now follow the catalog' }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$probe = Invoke-GatewayProbe
if ($probe.Status -ge 500) {
    if ($switched) {
        Set-ApimNamedValue -ResourceGroup $rg -ApimName $gw.apimName -Id 'entitlement-source' -Value $source -SubscriptionId $gw.subscriptionId
        throw "The gateway answered HTTP $($probe.Status) through the projection, so entitlement-source is back to $source and access is as before. Check the resolver (func-resolver-$prefix) and rerun."
    }
    throw "The gateway answered HTTP $($probe.Status) through the projection. Check the resolver (func-resolver-$prefix); the previous entitlement-source values are in the switch backup, if one was written."
}
elseif ($probe.Status -in 200, 400, 403, 429) { Ok "the gateway answered HTTP $($probe.Status) for the signed-in account through the projection" }
else { Warn "Could not confirm the gateway from this machine ($(if ($probe.Status) { "HTTP $($probe.Status)" } else { $probe.Detail })). Send one request from a developer machine to confirm." }

if ([string]$pj.syncInterval -ne 'none' -and -not $existingRenewal) {
    Step 'Sync job'
    try { Invoke-SyncJobDeployment $firstGroup 'none' }
    catch { Warn "The sync job was not deployed: $($_.Exception.Message) Access is in force; records follow group changes only once the job runs. Rerun this script to retry." }
}

Step 'Done'
Ok 'each person''s models and monthly and daily token limits now come from the catalog'
Note 'If the sync job printed a Microsoft Graph grant, a tenant administrator runs it once (scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1).'
Note 'The client policies take effect once each group''s .reg or .desktop.json is deployed to that group through Intune or MDM.'
Note "To change limits, models or groups: edit the catalog, raise catalogVersion, and run this script again."
