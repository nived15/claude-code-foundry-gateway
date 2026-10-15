# Access catalog: validation, plan, per-user resolution and Desktop client keys - all offline.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$catalogPath = Join-Path $here 'claude-access-catalog.json'
$libraryPath = Join-Path $here 'ClaudeAccessCatalog.ps1'
$importPath = Join-Path $here 'Import-ClaudeAccessCatalog.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

if (-not (Test-Path -LiteralPath $libraryPath)) {
    Write-Host "  [FAIL] the catalog library exists - $libraryPath" -ForegroundColor Red
    exit 1
}
. $libraryPath

function Read-Catalog { Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json }

function New-FilledCatalog {
    $c = Read-Catalog
    $c.gateway.tenantId = '11111111-1111-1111-1111-111111111111'
    $c.gateway.subscriptionId = '22222222-2222-2222-2222-222222222222'
    $c.gateway.resourceGroup = 'rg-claude'
    $c.gateway.apimName = 'apim-claudegw'
    $c.gateway.foundryAccount = 'ai-contoso'
    $c.gateway.foundryResourceGroup = 'rg-ai'
    $c.projection.namePrefix = 'claudegw'
    $c.projection.alertEmail = @('ops@contoso.com')
    $c.deployments.haiku = 'claude-haiku-4-5'
    $c.deployments.sonnet = 'claude-sonnet-5'
    $c.deployments.opus = 'claude-opus-5'
    $c.deployments.fable = 'claude-fable-5'
    $c.clientSettings.m365.managedMcpServers[0].tenantId = $c.gateway.tenantId
    foreach ($p in $c.profiles) { $p.tokensPerMonth = $p.suggestedTokensPerMonth }
    foreach ($g in $c.groups) { $g.objectId = ('00000000-0000-0000-0000-{0:D12}' -f [int]$g.row) }
    return $c
}

function Get-Finding($findings, $severity, $code) {
    # The comma keeps a one-item result an array; Windows PowerShell 5.1 gives a lone PSCustomObject no Count.
    return , @($findings | Where-Object { $_.Severity -eq $severity -and $_.Code -eq $code })
}

Write-Host ''
Write-Host 'Shipped catalog' -ForegroundColor Cyan
$shipped = Read-Catalog
Assert '47 groups and 11 profiles' (@($shipped.groups).Count -eq 47 -and @($shipped.profiles).Count -eq 11)
$f = @(Test-ClaudeAccessCatalog -Catalog $shipped)
$placeholders = Get-Finding $f error placeholder
Assert 'every placeholder is an error' ($placeholders.Count -eq 13) "got $($placeholders.Count): $($placeholders.Path -join ', ')"
Assert 'every unapproved monthly figure is an error' ((Get-Finding $f error not-approved).Count -eq 11)
Assert 'every missing group object ID is an error' ((Get-Finding $f error object-id).Count -eq 47)
$other = @($f | Where-Object { $_.Severity -eq 'error' -and $_.Code -notin @('placeholder', 'not-approved', 'object-id') })
Assert 'no other error' ($other.Count -eq 0) (($other | ForEach-Object { "$($_.Code) $($_.Path)" }) -join '; ')
$designOnly = Get-Finding $f warning no-usable-capability
Assert 'the Design-only rows 8, 21 and 42 are flagged' (($designOnly.Path -join ',') -eq 'groups[row 8],groups[row 21],groups[row 42]') ($designOnly.Path -join ',')
$drift = Get-Finding $f warning name-drift
Assert 'every group name agrees with its entry' ($drift.Count -eq 0) ($drift.Message -join '; ')

Write-Host ''
Write-Host 'Filled catalog' -ForegroundColor Cyan
$errors = @(Test-ClaudeAccessCatalog -Catalog (New-FilledCatalog) | Where-Object Severity -eq 'error')
Assert 'a filled catalog has no error' ($errors.Count -eq 0) (($errors | ForEach-Object { "$($_.Code) $($_.Path)" }) -join '; ')

$c = New-FilledCatalog; $c.groups[1].objectId = $c.groups[0].objectId
Assert 'a duplicate group object ID is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error duplicate-object-id).Count -eq 1)
$c = New-FilledCatalog; $c.groups[0].capabilities = @('Co', 'Xx')
Assert 'an unknown capability is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error capability).Count -eq 1)
$c = New-FilledCatalog; $c.groups[0].profile = 'standard-l9'
Assert 'an unknown profile is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error unknown-profile).Count -eq 1)
$c = New-FilledCatalog; $c.clientSettings.m365.managedMcpServers[0].tenantId = '99999999-9999-9999-9999-999999999999'
Assert 'an M365 connector for another tenant is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error m365-tenant).Count -eq 1)
$c = New-FilledCatalog; $c.projection.syncInterval = '5m'
Assert 'a sync interval the job cannot run is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error sync-interval).Count -eq 1)
$c = New-FilledCatalog; $c.deployments.opus = 'claude&calc'
Assert 'a deployment name cmd.exe would re-read is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error deployment-name).Count -eq 1)
$c = New-FilledCatalog; $c.organisation.multipleGroupRule = 'first'
Assert 'an unknown multiple-group rule is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error multiple-group-rule).Count -eq 1)
$c = New-FilledCatalog; $c.projection.alertEmail = @()
Assert 'a sync job with no alert address is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error alert-email).Count -eq 1)
$c = New-FilledCatalog; $c.projection.alertEmail = @('ops at contoso')
Assert 'an alert address that is not one is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error alert-email).Count -eq 1)
$c = New-FilledCatalog; $c.projection | Add-Member -NotePropertyName location -NotePropertyValue 'Central India' -Force
Assert 'a region written as a display name is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error location).Count -eq 1)
$c = New-FilledCatalog; $c.projection | Add-Member -NotePropertyName location -NotePropertyValue 'centralindia' -Force
Assert 'a region name is accepted' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error location).Count -eq 0)
Assert 'the shipped catalog leaves the region to the gateway' ((Read-Catalog).projection.PSObject.Properties.Name -contains 'location' -and $null -eq (Read-Catalog).projection.location)
$c = New-FilledCatalog; $c.projection.alertEmail = @(); $c.projection.syncInterval = 'none'
Assert 'no sync job needs no alert address' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error alert-email).Count -eq 0)
$c = New-FilledCatalog; $c.profiles[0].id = 'premium'
Assert 'a profile named like a gateway tier is an error' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) error profile-id).Count -eq 1)
$c = New-FilledCatalog; $c.organisation.tokensPerMonth = [long]3000000000
Assert 'an org figure above Int32 is warned about' ((Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) warning int32).Count -eq 1)
$c = New-FilledCatalog; $c.groups[0].profile = 'advanced-l2-ha-so-op'
$drift = Get-Finding @(Test-ClaudeAccessCatalog -Catalog $c) warning name-drift
Assert 'a group mapped against its own name is reported' ($drift.Count -eq 1 -and $drift[0].Path -eq 'groups[row 1]') ($drift.Path -join ',')

Write-Host ''
Write-Host 'Plan' -ForegroundColor Cyan
$c = New-FilledCatalog
$plan = Get-ClaudeAccessCatalogPlan -Catalog $c
$std1 = @($plan.Profiles | Where-Object { $_.Id -eq 'standard-l1-ha-so' })[0]
Assert 'the daily guard is 10% of the month, rounded down' ($std1.TokensPerDay -eq 1388888) "got $($std1.TokensPerDay)"
$set = @($plan.ModelSets | Where-Object { $_.Name -eq 'Ha-So-Op' })[0]
Assert 'a model set becomes a sentinel-comma list' ($set.Value -eq ',claude-haiku-4-5,claude-sonnet-5,claude-opus-5,') $set.Value
Assert 'models travel in the records, not in named values' (-not @($plan.NamedValues.Keys | Where-Object { $_ -like 'models-*' }).Count) (@($plan.NamedValues.Keys) -join ', ')
Assert 'with no figure and no membership the org ceiling is unknown' ($null -eq $plan.OrganisationTokensPerMonth -and $plan.OrganisationSource -eq 'unknown' -and -not $plan.NamedValues.Contains('quota-org'))
Assert 'the request ceiling and revocation window become named values' ($plan.NamedValues['calls-per-minute'] -eq '120' -and $plan.NamedValues['entitlement-cache-seconds'] -eq '3600')
$c.organisation.tokensPerMonth = 123456789
$plan = Get-ClaudeAccessCatalogPlan -Catalog $c
Assert 'an approved org figure is used as given' ($plan.OrganisationTokensPerMonth -eq 123456789 -and $plan.OrganisationSource -eq 'catalog' -and $plan.NamedValues['quota-org'] -eq '123456789')

Write-Host ''
Write-Host 'Per-user resolution' -ForegroundColor Cyan
$c = New-FilledCatalog
$byRow = @{}; foreach ($g in $c.groups) { $byRow[[int]$g.row] = $g.objectId }
$u1 = 'aaaaaaaa-0000-0000-0000-000000000001'
$u2 = 'aaaaaaaa-0000-0000-0000-000000000002'
$u3 = 'aaaaaaaa-0000-0000-0000-000000000003'
$membership = @{ $byRow[1] = @($u1, $u2); $byRow[22] = @($u2); $byRow[43] = @($u3); $byRow[46] = @($u3) }
$r = Resolve-ClaudeAccessAssignment -Catalog $c -Membership $membership
$byOid = @{}; foreach ($u in $r.Users) { $byOid[$u.Oid] = $u }
Assert 'three distinct users' (@($r.Users).Count -eq 3)
Assert 'a user in one group gets that group' ($byOid[$u1].Row -eq 1 -and $byOid[$u1].Profile -eq 'standard-l1-ha-so' -and -not $byOid[$u1].Conflict)
Assert 'highest-monthly picks the larger allowance' ($byOid[$u2].Row -eq 22 -and $byOid[$u2].Conflict)
Assert 'a tie goes to the lower row' ($byOid[$u3].Row -eq 43 -and -not $byOid[$u3].M365)
$plan = Get-ClaudeAccessCatalogPlan -Catalog $c -Assignment $r
Assert 'a null org ceiling is the sum of each user''s allowance' ($plan.OrganisationTokensPerMonth -eq 374999998 -and $plan.OrganisationSource -eq 'computed') "got $($plan.OrganisationTokensPerMonth)"
$c.organisation.multipleGroupRule = 'deny'
$r = Resolve-ClaudeAccessAssignment -Catalog $c -Membership $membership
Assert 'deny refuses users in two groups' ((@($r.Denied | ForEach-Object { $_.Oid } | Sort-Object) -join ',') -eq "$u2,$u3")
$plan = Get-ClaudeAccessCatalogPlan -Catalog $c -Assignment $r
Assert 'refused users add nothing to the org ceiling' ($plan.OrganisationTokensPerMonth -eq 13888888) "got $($plan.OrganisationTokensPerMonth)"

$c = New-FilledCatalog
$r = Resolve-ClaudeAccessAssignment -Catalog $c -Membership $membership
$gone = Get-ClaudeAccessRemoval -Assignment $r -Current @(",$u1,$($u2.ToUpperInvariant()),", ',aaaaaaaa-0000-0000-0000-000000000009,')
Assert 'access removal lists only who holds access now and would not under the catalog' ((@($gone) -join ',') -eq 'aaaaaaaa-0000-0000-0000-000000000009') (@($gone) -join ',')
Assert 'empty lists remove nobody' ((Get-ClaudeAccessRemoval -Assignment $r -Current @(',,', '')).Count -eq 0)

Write-Host ''
Write-Host 'Catalog document and snapshot, checked by the bundled sync code' -ForegroundColor Cyan
$checkDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-catalog-node-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $checkDir | Out-Null
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $checker = Join-Path $checkDir 'check.mjs'
    [IO.File]::WriteAllText($checker, @'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [planPath, catalogFile, snapshotFile, membersFile, tenant] = process.argv.slice(2);
const plan = await import(pathToFileURL(planPath).href);
const read = (f) => JSON.parse(readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const catalog = read(catalogFile);
const snapshot = read(snapshotFile);
const { records } = plan.resolveCatalogRecords(catalog, read(membersFile));
console.log(JSON.stringify({
  catalog: plan.validateAccessCatalog(catalog, { tenantId: tenant }),
  snapshot: plan.validateSnapshot(snapshot, { tenantId: tenant }),
  resolved: records.map((x) => `${x.oid}=${x.profile}`).sort(),
}));
'@, $utf8)
    $plan = Get-ClaudeAccessCatalogPlan -Catalog $c -Assignment $r
    $doc = New-ClaudeAccessCatalogDocument -Catalog $c -Plan $plan
    $snap = New-ClaudeAccessSnapshot -Catalog $c -Plan $plan -Assignment $r -VerifiedAt ([DateTimeOffset]::UtcNow.AddMinutes(-1))
    Assert 'the catalog document is keyed to its tenant' ($doc.id -eq "access-catalog::$($c.gateway.tenantId)" -and $doc.oid -eq $doc.id -and $doc.type -eq 'access-catalog')
    Assert 'each profile carries its model list' (@($doc.profiles | Where-Object { $_.id -eq 'advanced-l2-ha-so-op' })[0].models -eq ',claude-haiku-4-5,claude-sonnet-5,claude-opus-5,')
    $members = [ordered]@{}
    foreach ($k in $membership.Keys) { $members[$k] = @($membership[$k] | ForEach-Object { [ordered]@{ oid = $_ } }) }
    $files = @('catalog', 'snapshot', 'members') | ForEach-Object { Join-Path $checkDir "$_.json" }
    [IO.File]::WriteAllText($files[0], (ConvertTo-Json -InputObject $doc -Depth 10), $utf8)
    [IO.File]::WriteAllText($files[1], (ConvertTo-Json -InputObject $snap -Depth 10), $utf8)
    [IO.File]::WriteAllText($files[2], (ConvertTo-Json -InputObject $members -Depth 10), $utf8)
    $out = & node $checker (Join-Path $here 'sync\src\plan.mjs') $files[0] $files[1] $files[2] ([string]$c.gateway.tenantId) 2>&1 | Out-String
    $verdict = $null
    try { $verdict = $out.Trim() | ConvertFrom-Json } catch { }
    Assert 'the sync code accepts the catalog document' ($verdict -and @($verdict.catalog).Count -eq 0) $out.Trim()
    Assert 'the sync code accepts the snapshot' ($verdict -and @($verdict.snapshot).Count -eq 0) $out.Trim()
    $mine = @($r.Users | Where-Object { -not $_.Denied } | ForEach-Object { "$($_.Oid)=$($_.Profile)" } | Sort-Object)
    Assert 'the scheduled sync resolves every user to the profile this script does' ($verdict -and (@($verdict.resolved) -join ';') -eq ($mine -join ';')) "node: $(@($verdict.resolved) -join ';') | ps: $($mine -join ';')"
}
finally { Remove-Item -LiteralPath $checkDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Desktop keys' -ForegroundColor Cyan
$c = New-FilledCatalog
function Get-Row($n) { @($c.groups | Where-Object { [int]$_.row -eq $n })[0] }
$k6 = Get-ClaudeDesktopGroupKeys -Catalog $c -Group (Get-Row 6)
Assert 'Cowork only: Cowork on, Chat and Code off' ($k6.coworkTabEnabled -eq $true -and $k6.chatTabEnabled -eq $false -and $k6.isClaudeCodeForDesktopEnabled -eq $false)
Assert 'Sonnet is the default model' ((@($k6.inferenceModels | ForEach-Object { $_.name }) -join ',') -eq 'claude-sonnet-5,claude-haiku-4-5')
Assert 'no connector without M365' (-not $k6.Contains('managedMcpServers'))
$k47 = Get-ClaudeDesktopGroupKeys -Catalog $c -Group (Get-Row 47)
$m365 = @($k47.managedMcpServers)
Assert 'an M365 group gets the connector for its tenant' ($m365.Count -eq 1 -and $m365[0].server -eq 'microsoft365' -and $m365[0].tenantId -eq $c.gateway.tenantId)
Assert 'Fable is offered to Ha-So-Op-Fa' (@($k47.inferenceModels | ForEach-Object { $_.name }) -contains 'claude-fable-5')
$k8 = Get-ClaudeDesktopGroupKeys -Catalog $c -Group (Get-Row 8)
Assert 'Design only: every surface off' (-not $k8.chatTabEnabled -and -not $k8.coworkTabEnabled -and -not $k8.isClaudeCodeForDesktopEnabled)
$reg = ConvertTo-ClaudeDesktopRegistry -Keys $k47
Assert 'the .reg file targets the machine policy key' ($reg -match '(?m)^\[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Claude\]\r?$')
Assert 'booleans are written as strings' ($reg -match '(?m)^"chatTabEnabled"="true"\r?$')
Assert 'JSON values are escaped' ($reg -match '"inferenceModels"="\[\{\\"name\\":\\"claude-sonnet-5\\"')

Write-Host ''
Write-Host 'Gateway policy: catalog records' -ForegroundColor Cyan
$policyPath = Join-Path $here 'infra\policy.xml'
$policy = if (Test-Path -LiteralPath $policyPath) { [IO.File]::ReadAllText($policyPath) } else { '' }
$init = $policy.IndexOf('<set-variable name="entCatalog" value="@(false)" />')
Assert 'every request starts as not a catalog record' ($init -ge 0 -and $init -lt $policy.IndexOf('{{entitlement-source}}'))
Assert 'a catalog record is recognised by its tier' ($policy -match '(?s)<set-variable name="entCatalog" value="@\(true\)" />')
Assert 'its profile becomes the tier the caller is reported under' ($policy -match '(?s)t == "catalog".{0,200}rec\["profile"\]')
foreach ($name in 'catalogModels', 'catalogMonthly', 'catalogDaily') {
    Assert "$name is read from the record" ($policy -match "<set-variable name=""$name""")
}
$modelGate = [regex]::Match($policy, '<set-variable name="modelAllowed".*?/>', 'Singleline').Value
Assert 'the model gate uses the record''s list for a catalog record' ($modelGate -match 'catalogModels' -and $modelGate -match 'entCatalog')
Assert 'an empty catalog list allows nothing' ($modelGate -match '!catalog &amp;&amp; \(allowed == null')
$minute = [regex]::Match($policy, '(?s)<!-- 7\. Per-minute.*?(?=<!-- 7a\.)').Value
Assert 'the per-minute limits apply only to tier records' (([regex]::Matches($minute, 'tokens-per-minute=')).Count -eq 2 -and
    ([regex]::Matches($minute, '<when condition="@\(!\(bool\)context\.Variables\["entCatalog"\]')).Count -eq 2 -and $minute -notmatch '<otherwise>')
$monthly = [regex]::Match($policy, '<llm-token-limit(?:(?!/>).)*?":monthly"(?:(?!/>).)*?/>', 'Singleline').Value
Assert 'a catalog record has a monthly allowance per person' ($monthly -match 'token-quota-period="Monthly"' -and $monthly -match 'catalogMonthly' -and $monthly -match 'userId')
Assert 'the monthly limit reports the tokens consumed' ($monthly -match 'tokens-consumed-header-name="x-tokens-consumed"')
$monthlyAt = $policy.IndexOf('":monthly"')
Assert 'the monthly allowance applies only to catalog records' ($monthlyAt -gt 0 -and $policy.LastIndexOf('<when condition="@((bool)context.Variables["entCatalog"])">', $monthlyAt) -gt $policy.LastIndexOf('</when>', $monthlyAt))
Assert 'the month is checked before the day' ($monthlyAt -gt 0 -and $monthlyAt -lt $policy.IndexOf('":daily"'))
Assert 'the daily guard comes from the record' ([regex]::Match($policy, '<set-variable name="effectiveQuota".*?/>', 'Singleline').Value -match 'catalogDaily')

Write-Host ''
Write-Host 'Bundle: everything the import runs is in this folder' -ForegroundColor Cyan
foreach ($rel in 'scripts\Deploy-ClaudeProjection.ps1', 'scripts\Deploy-ClaudeProjectionRenewal.ps1', 'scripts\Set-GatewayPolicy.ps1',
    'scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1', 'infra\policy.xml', 'infra\main.bicep', 'resolver\host.json', 'resolver\src\index.mjs',
    'sync\Dockerfile', 'sync\package-lock.json', 'sync\src\apply-projection.mjs') {
    Assert "the bundle holds $rel" (Test-Path -LiteralPath (Join-Path $here $rel))
}
$unresolved = foreach ($f in @(Get-ChildItem -LiteralPath $here -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -ne $PSCommandPath })) {
    $text = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($text, "Join-Path\s+\`$PSScriptRoot\s+'([^']+\.ps1)'")) {
        if (-not (Test-Path -LiteralPath (Join-Path $f.DirectoryName $m.Groups[1].Value))) { "$($f.Name) loads $($m.Groups[1].Value)" }
    }
    foreach ($m in [regex]::Matches($text, "'((?:infra|resolver|sync)[\\/][^'*{}\s]+)'")) {
        if (-not (Test-Path -LiteralPath (Join-Path $here $m.Groups[1].Value))) { "$($f.Name) reads $($m.Groups[1].Value)" }
    }
    if ($f.DirectoryName -eq $here) {
        foreach ($m in [regex]::Matches($text, "Join-Path \`$PSScriptRoot '([^']+)'\)")) {
            if (-not (Test-Path -LiteralPath (Join-Path $here $m.Groups[1].Value))) { "$($f.Name) runs $($m.Groups[1].Value)" }
        }
    }
}
Assert 'every file a bundled script loads or deploys is in the bundle' (-not @($unresolved).Count) (@($unresolved) -join '; ')

$import = [IO.File]::ReadAllText($importPath)
$at = [ordered]@{
    gate = $import.IndexOf('-not $AcceptAccessRemoval) {')
    preflight = $import.IndexOf('-PreflightOnly')
    namedValues = $import.IndexOf('Set-ApimNamedValue -ResourceGroup $gw.resourceGroup')
    policy = $import.IndexOf("scripts\Set-GatewayPolicy.ps1')")
    infrastructure = $import.IndexOf('-InfrastructureOnly -Confirm:$false')
    load = $import.IndexOf('--snapshot /work/snapshot.json --catalog /work/catalog.json')
    switch = $import.IndexOf("-Id 'entitlement-source' -Value 'projection'")
    probe = $import.IndexOf('$probe = Invoke-GatewayProbe')
    rollback = $import.IndexOf("-Id 'entitlement-source' -Value `$source")
}
$order = @($at.Values)
Assert 'the import runs gate, named values, policy, projection, load, switch, check and rollback in that order' (
    -not @($order | Where-Object { $_ -lt 0 }).Count -and (($order | Sort-Object) -join ',') -eq ($order -join ',')) (($at.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
Assert 'the projection is deployed infrastructure-only' ($import -match "Deploy-ClaudeProjection\.ps1'\)[^\r\n]*[\s\S]{0,400}?-InfrastructureOnly")
Assert 'the projection is deployed in the catalog''s region, or else the gateway''s' ($import -match "Deploy-ClaudeProjection\.ps1'\)[^\r\n]*[\s\S]{0,400}?-Location \`$projectionLocation" -and
    $import -match '\$projectionLocation = if \(\$pj\.location\) \{[^}]+\} else \{[^}]*\$apim\.location')
Assert 'the switch waits for a clean comparison and the switch evidence' ($import -match '(?s)\$after = & \$compare.*?differences -ne 0.*?Assert-ClaudeProjectionAdmission.*?Save-ClaudeProjectionSwitchBackup.*?-Value ''projection''')
Assert 'a sync job already running is moved to the new code before the catalog is stored' ($import.IndexOf('if ($existingRenewal) {') -gt 0 -and $import.IndexOf('if ($existingRenewal) {') -lt $at.load)

$deployerPath = Join-Path $here 'scripts\Deploy-ClaudeProjection.ps1'
$deployer = if (Test-Path -LiteralPath $deployerPath) { [IO.File]::ReadAllText($deployerPath) } else { '' }
Assert 'the deployer has an infrastructure-only mode' ($deployer -match '\[switch\]\$InfrastructureOnly')
$infraReturn = [regex]::Match($deployer, '(?s)if \(\$InfrastructureOnly\) \{[^{}]*return\s*\}').Index
Assert 'it returns after the gateway points at the resolver and the runner can write the projection' ($infraReturn -gt 0 -and
    $infraReturn -gt $deployer.IndexOf('Set-ClaudeProjectionGatewayResolver') -and $infraReturn -gt $deployer.IndexOf('cosmosdb sql role assignment create'))
Assert 'and before it populates or compares from the tier groups' ($infraReturn -gt 0 -and $infraReturn -lt $deployer.IndexOf('Sync-ClaudeProjection.ps1') -and
    $infraReturn -lt $deployer.IndexOf('Invoke-ClaudeProjectionDeployerCompare -'))
if ($deployer) {
    $refusal = ''
    try { & $deployerPath -ResourceGroup rg -ApimName apim -NamePrefix p -InfrastructureOnly -FlipAfterCleanCompare 6>$null | Out-Null } catch { $refusal = $_.Exception.Message }
    Assert 'it refuses to deploy and switch in one run' ($refusal -match '-InfrastructureOnly' -and $refusal -match '-FlipAfterCleanCompare') $refusal
}

Write-Host ''
Write-Host 'Import, offline' -ForegroundColor Cyan
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-catalog-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $refused = $false
    try { & $importPath -Path $catalogPath -Offline -OutputPath (Join-Path $work 'shipped') 6>$null | Out-Null }
    catch { $refused = $_.Exception.Message -match 'error\(s\)' }
    Assert 'the shipped file is refused before anything is written' ($refused -and -not (Test-Path (Join-Path $work 'shipped')))

    $filledPath = Join-Path $work 'filled.json'
    [IO.File]::WriteAllText($filledPath, (New-FilledCatalog | ConvertTo-Json -Depth 20))
    $out = Join-Path $work 'out'
    & $importPath -Path $filledPath -Offline -OutputPath $out 6>$null | Out-Null
    $clients = Join-Path $out 'clients'
    Assert 'the catalog document is written' (Test-Path (Join-Path $out 'catalog-document.json'))
    Assert 'the named-value plan is written' (Test-Path (Join-Path $out 'named-values.json'))
    Assert 'one .reg file per group' (@(Get-ChildItem -LiteralPath $clients -Filter '*.reg').Count -eq 47)
    Assert 'one Desktop JSON per group' (@(Get-ChildItem -LiteralPath $clients -Filter '*.desktop.json').Count -eq 47)
    Assert 'a client assignment list is written' (Test-Path (Join-Path $clients 'client-assignments.csv'))
    $doc = Get-Content -LiteralPath (Join-Path $out 'catalog-document.json') -Raw | ConvertFrom-Json
    Assert 'the catalog document carries daily figures' (@($doc.profiles | Where-Object { $_.id -eq 'standard-l1-ha-so' })[0].tokensPerDay -eq 1388888)

    $refused = $false
    try { & $importPath -Path $filledPath -Offline -Apply -OutputPath (Join-Path $work 'apply') 6>$null | Out-Null } catch { $refused = $true }
    Assert '-Apply refuses to run offline' ($refused -and -not (Test-Path (Join-Path $work 'apply')))
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All assertions passed.' -ForegroundColor Green
exit 0
