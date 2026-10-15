# Access catalog: validation, plan, per-user resolution and Claude Desktop keys. No Azure or Graph calls, so all of it
# runs offline; Import-ClaudeAccessCatalog.ps1 does the reading and the writing.
. (Join-Path $PSScriptRoot 'scripts\ClaudeProjectionSchedule.ps1')

$script:CatalogCapabilities = @('Co', 'Cw', 'Ch', 'De')
$script:CatalogFamilies = @('haiku', 'sonnet', 'opus', 'fable')
$script:CatalogGuid = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
# Nothing cmd.exe re-reads when az is its .cmd shim on Windows.
$script:CatalogAzName = '^[A-Za-z0-9][A-Za-z0-9._-]{0,89}$'
$script:CatalogDeploymentName = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
$script:CatalogInt32Max = 2147483647
# The resolver refuses a catalog record whose profile is one of these (resolver/src/entitlement.mjs).
$script:CatalogReservedProfiles = @('standard', 'premium', 'catalog', 'denied', 'none', 'unknown')
$script:CatalogEmail = '^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$'

function Get-CatalogProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
}

function New-CatalogFinding {
    param(
        [ValidateSet('error', 'warning')][string]$Severity,
        [string]$Code,
        [string]$Path,
        [string]$Message
    )
    [pscustomobject]@{ Severity = $Severity; Code = $Code; Path = $Path; Message = $Message }
}

function Test-CatalogWholeNumber($Value) { return ($Value -is [int] -or $Value -is [long]) }

function Test-CatalogNumber($Value) { return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) }

function Test-CatalogText {
    param($Value, [string]$Path, [string]$Pattern, [string]$Code, [string]$Expect)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return New-CatalogFinding error $Code $Path "is empty; expected $Expect." }
    if ($text -match '^\s*<[^<>]*>\s*$') { return New-CatalogFinding error 'placeholder' $Path "still holds the placeholder '$text'; expected $Expect." }
    if ($text -notmatch $Pattern) { return New-CatalogFinding error $Code $Path "'$text' is not valid; expected $Expect." }
}

function Compare-CatalogGroupName {
    param([string]$Name, $ProfileEntry, [string[]]$Capabilities, [bool]$M365, [string]$Path)
    $m = [regex]::Match($Name, '\((?<level>[A-Za-z]+-L\d+)-\$(?<usd>\d+)\),\s*Cap\((?<cap>[^)]*)\),\s*Mod\((?<mod>[^)]*)\)(?<con>,\s*Con\([^)]*\))?\s*$')
    if (-not $m.Success) {
        return New-CatalogFinding warning 'name-pattern' $Path "'$Name' does not follow the sheet's naming pattern, so it was not compared with its entry."
    }
    $diff = @()
    if ($m.Groups['level'].Value -cne [string]$ProfileEntry.level) { $diff += "level $($m.Groups['level'].Value) vs profile $($ProfileEntry.level)" }
    if ([decimal]$m.Groups['usd'].Value -ne [decimal]$ProfileEntry.creditUsd) { $diff += "credit `$$($m.Groups['usd'].Value) vs profile `$$($ProfileEntry.creditUsd)" }
    if ($m.Groups['mod'].Value -cne [string]$ProfileEntry.modelSet) { $diff += "models $($m.Groups['mod'].Value) vs profile $($ProfileEntry.modelSet)" }
    $named = @($m.Groups['cap'].Value -split '-' | Where-Object { $_ } | Sort-Object)
    $listed = @($Capabilities | Sort-Object)
    if (($named -join ',') -cne ($listed -join ',')) { $diff += "capabilities $($named -join '-') vs listed $($listed -join '-')" }
    if ($m.Groups['con'].Success -ne $M365) { $diff += "connector in name $($m.Groups['con'].Success) vs m365 $M365" }
    if ($diff.Count) {
        return New-CatalogFinding warning 'name-drift' $Path ("'$Name' disagrees with its entry: " + ($diff -join '; ') + '. The entry, not the name, is what is applied.')
    }
}

function Test-ClaudeAccessCatalog {
    <#
    .SYNOPSIS
        Every error and warning in a parsed catalog; an empty result means it can be imported.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog)

    $f = [System.Collections.Generic.List[object]]::new()
    $add = { param($x) foreach ($i in @($x)) { if ($i) { $f.Add($i) } } }

    if ((Get-CatalogProperty $Catalog 'schemaVersion') -ne 1) { & $add (New-CatalogFinding error 'schema' 'schemaVersion' 'must be 1.') }
    & $add (Test-CatalogText (Get-CatalogProperty $Catalog 'catalogVersion') 'catalogVersion' '^[A-Za-z0-9._-]{1,64}$' 'catalog-version' 'letters, digits, dot, underscore or hyphen')

    $gw = Get-CatalogProperty $Catalog 'gateway'
    & $add (Test-CatalogText (Get-CatalogProperty $gw 'tenantId') 'gateway.tenantId' $script:CatalogGuid 'guid' 'the Entra tenant ID, a GUID')
    & $add (Test-CatalogText (Get-CatalogProperty $gw 'subscriptionId') 'gateway.subscriptionId' $script:CatalogGuid 'guid' 'the subscription ID, a GUID')
    foreach ($name in 'resourceGroup', 'apimName', 'foundryAccount', 'foundryResourceGroup') {
        & $add (Test-CatalogText (Get-CatalogProperty $gw $name) "gateway.$name" $script:CatalogAzName 'azure-name' 'letters, digits, dot, underscore or hyphen')
    }

    $pj = Get-CatalogProperty $Catalog 'projection'
    & $add (Test-CatalogText (Get-CatalogProperty $pj 'namePrefix') 'projection.namePrefix' '^[a-z0-9][a-z0-9-]{1,22}[a-z0-9]$' 'name-prefix' '3-24 lower-case letters, digits or hyphens')
    if ((Get-CatalogProperty $pj 'resolverInboundAccess') -cnotin @('private', 'public')) {
        & $add (New-CatalogFinding error 'resolver-access' 'projection.resolverInboundAccess' 'must be private or public.')
    }
    $intervals = @(Get-ClaudeProjectionSyncIntervals) + 'none'
    if ((Get-CatalogProperty $pj 'syncInterval') -cnotin $intervals) {
        & $add (New-CatalogFinding error 'sync-interval' 'projection.syncInterval' "must be one of: $($intervals -join ', ').")
    }
    elseif ((Get-CatalogProperty $pj 'syncInterval') -cne 'none') {
        $emails = @(Get-CatalogProperty $pj 'alertEmail')
        if (-not $emails.Count) { & $add (New-CatalogFinding error 'alert-email' 'projection.alertEmail' 'lists no address; the sync job''s failure alerts would notify no one. Use syncInterval none for no job.') }
        $k = -1
        foreach ($email in $emails) { $k++; & $add (Test-CatalogText $email "projection.alertEmail[$k]" $script:CatalogEmail 'alert-email' 'an email address') }
    }
    $window = Get-CatalogProperty $pj 'revocationWindowSeconds'
    if (-not (Test-CatalogWholeNumber $window) -or $window -lt 3600 -or $window -gt 86400) {
        & $add (New-CatalogFinding error 'revocation-window' 'projection.revocationWindowSeconds' 'must be a whole number of seconds from 3600 to 86400, the installer''s 60-1440 minutes.')
    }
    $location = Get-CatalogProperty $pj 'location'
    if ($null -ne $location -and [string]$location -cnotmatch '^[a-z][a-z0-9]{2,39}$') {
        & $add (New-CatalogFinding error 'location' 'projection.location' "'$location' must be an Azure region name such as centralindia, or null for the gateway's region.")
    }

    $org = Get-CatalogProperty $Catalog 'organisation'
    $orgTokens = Get-CatalogProperty $org 'tokensPerMonth'
    if ($null -ne $orgTokens) {
        if (-not (Test-CatalogWholeNumber $orgTokens) -or $orgTokens -le 0) {
            & $add (New-CatalogFinding error 'org-tokens' 'organisation.tokensPerMonth' 'must be a positive whole number, or null to compute it from membership.')
        }
        elseif ($orgTokens -gt $script:CatalogInt32Max) {
            & $add (New-CatalogFinding warning 'int32' 'organisation.tokensPerMonth' "$orgTokens is above 2,147,483,647: Install-ClaudeGateway.ps1 -QuotaOrg is [int], and whether llm-token-limit accepts a token-quota that large is unverified.")
        }
    }
    $rpm = Get-CatalogProperty $org 'requestsPerMinutePerUser'
    if (-not (Test-CatalogWholeNumber $rpm) -or $rpm -lt 1 -or $rpm -gt 100000) {
        & $add (New-CatalogFinding error 'requests-per-minute' 'organisation.requestsPerMinutePerUser' 'must be a whole number from 1 to 100000.')
    }
    if ((Get-CatalogProperty $org 'multipleGroupRule') -cnotin @('highest-monthly', 'deny')) {
        & $add (New-CatalogFinding error 'multiple-group-rule' 'organisation.multipleGroupRule' 'must be highest-monthly or deny.')
    }

    $pct = Get-CatalogProperty (Get-CatalogProperty $Catalog 'limits') 'dailyGuardPercentOfMonthly'
    if (-not (Test-CatalogWholeNumber $pct) -or $pct -lt 1 -or $pct -gt 100) {
        & $add (New-CatalogFinding error 'daily-guard' 'limits.dailyGuardPercentOfMonthly' 'must be a whole number from 1 to 100.')
    }

    $sets = Get-CatalogProperty $Catalog 'modelSets'
    $setNames = @()
    $usedFamilies = [ordered]@{}
    if (-not $sets) { & $add (New-CatalogFinding error 'model-set' 'modelSets' 'is missing.') }
    else {
        foreach ($s in $sets.PSObject.Properties) {
            $setNames += $s.Name
            $path = "modelSets.$($s.Name)"
            if ($s.Name -cnotmatch '^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') { & $add (New-CatalogFinding error 'model-set' $path 'the name must be letters and digits joined by hyphens; it becomes a named value id.') }
            $families = @($s.Value | Where-Object { $null -ne $_ })
            if (-not $families.Count) { & $add (New-CatalogFinding error 'model-set' $path 'lists no model.') }
            foreach ($fam in $families) {
                if ($fam -cnotin $script:CatalogFamilies) { & $add (New-CatalogFinding error 'model-set' $path "'$fam' is not one of: $($script:CatalogFamilies -join ', ').") }
                else { $usedFamilies[$fam] = $true }
            }
            if (@($families | Select-Object -Unique).Count -ne $families.Count) { & $add (New-CatalogFinding error 'model-set' $path 'lists a model twice.') }
        }
    }
    $deployments = Get-CatalogProperty $Catalog 'deployments'
    foreach ($fam in $usedFamilies.Keys) {
        & $add (Test-CatalogText (Get-CatalogProperty $deployments $fam) "deployments.$fam" $script:CatalogDeploymentName 'deployment-name' 'the Foundry deployment name: letters, digits, dot, underscore or hyphen')
    }

    $profileById = @{}
    $i = -1
    foreach ($p in @(Get-CatalogProperty $Catalog 'profiles')) {
        $i++
        $path = "profiles[$i]"
        $id = [string](Get-CatalogProperty $p 'id')
        if ($id -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { & $add (New-CatalogFinding error 'profile-id' "$path.id" "'$id' must be lower-case letters and digits joined by hyphens."); continue }
        if ($id -cin $script:CatalogReservedProfiles) { & $add (New-CatalogFinding error 'profile-id' "$path.id" "'$id' is a tier name the gateway reserves; choose another id."); continue }
        if ($profileById.ContainsKey($id)) { & $add (New-CatalogFinding error 'duplicate-profile' "$path.id" "'$id' is defined twice."); continue }
        $profileById[$id] = $p
        $path = "profiles[$id]"
        if ((Get-CatalogProperty $p 'modelSet') -cnotin $setNames) { & $add (New-CatalogFinding error 'unknown-model-set' "$path.modelSet" "'$(Get-CatalogProperty $p 'modelSet')' is not in modelSets.") }
        $credit = Get-CatalogProperty $p 'creditUsd'
        if (-not (Test-CatalogNumber $credit) -or $credit -le 0) { & $add (New-CatalogFinding error 'credit' "$path.creditUsd" 'must be a positive number.') }
        $monthly = Get-CatalogProperty $p 'tokensPerMonth'
        if ($null -eq $monthly) {
            & $add (New-CatalogFinding error 'not-approved' "$path.tokensPerMonth" "has no approved monthly figure (suggestedTokensPerMonth is $(Get-CatalogProperty $p 'suggestedTokensPerMonth')).")
        }
        elseif (-not (Test-CatalogWholeNumber $monthly) -or $monthly -le 0) { & $add (New-CatalogFinding error 'tokens-per-month' "$path.tokensPerMonth" 'must be a positive whole number.') }
        elseif ($monthly -gt $script:CatalogInt32Max) {
            & $add (New-CatalogFinding warning 'int32' "$path.tokensPerMonth" "$monthly is above 2,147,483,647; whether llm-token-limit accepts a token-quota that large is unverified.")
        }
    }
    if (-not $profileById.Count) { & $add (New-CatalogFinding error 'profiles' 'profiles' 'defines no profile.') }

    $j = -1
    foreach ($server in @(Get-CatalogProperty (Get-CatalogProperty (Get-CatalogProperty $Catalog 'clientSettings') 'm365') 'managedMcpServers')) {
        $j++
        $path = "clientSettings.m365.managedMcpServers[$j].tenantId"
        $tenant = Get-CatalogProperty $server 'tenantId'
        $x = Test-CatalogText $tenant $path $script:CatalogGuid 'guid' 'the Entra tenant ID, a GUID'
        if ($x) { & $add $x }
        elseif ($tenant -ne (Get-CatalogProperty $gw 'tenantId')) { & $add (New-CatalogFinding error 'm365-tenant' $path 'differs from gateway.tenantId.') }
    }

    $rows = @{}
    $names = @{}
    $objectIds = @{}
    $usedProfiles = @{}
    $withDesign = 0
    $i = -1
    foreach ($g in @(Get-CatalogProperty $Catalog 'groups')) {
        $i++
        $row = Get-CatalogProperty $g 'row'
        $path = if (Test-CatalogWholeNumber $row) { "groups[row $row]" } else { "groups[$i]" }
        if (-not (Test-CatalogWholeNumber $row) -or $row -lt 1) { & $add (New-CatalogFinding error 'row' "$path.row" 'must be a positive whole number.') }
        elseif ($rows.ContainsKey([long]$row)) { & $add (New-CatalogFinding error 'duplicate-row' "$path.row" "row $row appears twice.") }
        else { $rows[[long]$row] = $true }

        $name = [string](Get-CatalogProperty $g 'displayName')
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256) { & $add (New-CatalogFinding error 'display-name' "$path.displayName" 'must be 1-256 characters, the Entra display name.') }
        elseif ($names.ContainsKey($name)) { & $add (New-CatalogFinding error 'duplicate-display-name' "$path.displayName" "'$name' appears twice.") }
        else { $names[$name] = $true }

        $oid = Get-CatalogProperty $g 'objectId'
        $x = Test-CatalogText $oid "$path.objectId" $script:CatalogGuid 'object-id' 'the Entra group object ID, a GUID'
        if ($x) { & $add $x }
        elseif ($objectIds.ContainsKey(([string]$oid).ToLowerInvariant())) { & $add (New-CatalogFinding error 'duplicate-object-id' "$path.objectId" "$oid is also used by another group.") }
        else { $objectIds[([string]$oid).ToLowerInvariant()] = $true }

        $profileId = [string](Get-CatalogProperty $g 'profile')
        $prof = if ($profileId) { $profileById[$profileId] } else { $null }
        if (-not $prof) { & $add (New-CatalogFinding error 'unknown-profile' "$path.profile" "'$profileId' is not in profiles.") }
        else { $usedProfiles[$profileId] = $true }

        $caps = @(Get-CatalogProperty $g 'capabilities')
        $capsValid = $caps.Count -gt 0
        if (-not $caps.Count) { & $add (New-CatalogFinding error 'capability' "$path.capabilities" 'lists no capability.') }
        foreach ($cap in $caps) {
            if ($cap -cnotin $script:CatalogCapabilities) { $capsValid = $false; & $add (New-CatalogFinding error 'capability' "$path.capabilities" "'$cap' is not one of: $($script:CatalogCapabilities -join ', ').") }
        }
        if (@($caps | Select-Object -Unique).Count -ne $caps.Count) { $capsValid = $false; & $add (New-CatalogFinding error 'capability' "$path.capabilities" 'lists a capability twice.') }
        if ($caps -ccontains 'De') { $withDesign++ }
        if ($capsValid -and -not @($caps | Where-Object { $_ -cne 'De' }).Count) {
            & $add (New-CatalogFinding warning 'no-usable-capability' $path "'$name' grants only Design, which Claude Desktop on third-party inference has no surface for; its members get no usable client.")
        }

        $m365 = Get-CatalogProperty $g 'm365'
        if ($m365 -isnot [bool]) { & $add (New-CatalogFinding error 'm365' "$path.m365" 'must be true or false.') }
        if ($prof -and $capsValid -and $name) { & $add (Compare-CatalogGroupName -Name $name -ProfileEntry $prof -Capabilities $caps -M365 ([bool]$m365) -Path $path) }
    }
    if (-not $rows.Count) { & $add (New-CatalogFinding error 'groups' 'groups' 'defines no group.') }
    foreach ($id in $profileById.Keys) {
        if (-not $usedProfiles.ContainsKey($id)) { & $add (New-CatalogFinding warning 'unused-profile' "profiles[$id]" 'no group uses it.') }
    }
    if ($withDesign) {
        & $add (New-CatalogFinding warning 'design-ignored' 'groups' "$withDesign group(s) list De (Design). The Claude Desktop third-party configuration reference has no Design surface, so it is ignored.")
    }
    return $f.ToArray()
}

function Get-ClaudeAccessCatalogPlan {
    <#
    .SYNOPSIS
        Per-profile limits, model lists, the organisation ceiling and the named values to write.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog, $Assignment)

    $pct = [decimal]$Catalog.limits.dailyGuardPercentOfMonthly
    $sets = @(foreach ($s in $Catalog.modelSets.PSObject.Properties) {
        $families = @($s.Value)
        $names = @($families | ForEach-Object { [string](Get-CatalogProperty $Catalog.deployments $_) })
        [pscustomobject]@{
            Name = $s.Name
            Families = $families
            Deployments = $names
            # Sentinel commas make the policy's Contains() match whole names, as models-standard does.
            Value = ',' + ($names -join ',') + ','
        }
    })

    $profiles = @(foreach ($p in @($Catalog.profiles)) {
        $monthly = $null
        $daily = $null
        if ($null -ne $p.tokensPerMonth) {
            $monthly = [long]$p.tokensPerMonth
            $daily = [long][math]::Max([decimal]1, [math]::Floor([decimal]$monthly * $pct / 100))
        }
        [pscustomobject]@{
            Id = [string]$p.id
            Level = [string]$p.level
            CreditUsd = $p.creditUsd
            ModelSet = [string]$p.modelSet
            TokensPerMonth = $monthly
            TokensPerDay = $daily
        }
    })

    $org = $null
    $source = 'unknown'
    if ($null -ne $Catalog.organisation.tokensPerMonth) {
        $org = [long]$Catalog.organisation.tokensPerMonth
        $source = 'catalog'
    }
    elseif ($Assignment) {
        $org = [long]0
        foreach ($u in @($Assignment.Users)) { if (-not $u.Denied -and $null -ne $u.TokensPerMonth) { $org += [long]$u.TokensPerMonth } }
        $source = 'computed'
    }

    $namedValues = [ordered]@{}
    if ($null -ne $org) { $namedValues['quota-org'] = [string]$org }
    $namedValues['calls-per-minute'] = [string]$Catalog.organisation.requestsPerMinutePerUser
    $namedValues['entitlement-cache-seconds'] = [string]$Catalog.projection.revocationWindowSeconds

    [pscustomobject]@{
        Profiles = $profiles
        ModelSets = $sets
        DailyGuardPercent = $pct
        OrganisationTokensPerMonth = $org
        OrganisationSource = $source
        NamedValues = $namedValues
    }
}

function Resolve-ClaudeAccessAssignment {
    <#
    .SYNOPSIS
        One profile per user from group membership, applying the catalog's multiple-group rule.

    .PARAMETER Membership
        Group object ID to the object IDs of its members.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)][hashtable]$Membership)

    $plan = Get-ClaudeAccessCatalogPlan -Catalog $Catalog
    $byProfile = @{}
    foreach ($p in $plan.Profiles) { $byProfile[$p.Id] = $p }

    $byUser = @{}
    $counts = [ordered]@{}
    foreach ($g in @($Catalog.groups | Sort-Object { [long]$_.row })) {
        $key = ([string]$g.objectId).ToLowerInvariant()
        $members = if ($Membership.ContainsKey($key)) { @($Membership[$key] | Where-Object { $_ }) } else { @() }
        $counts[[string]$g.row] = $members.Count
        foreach ($m in $members) {
            $oid = ([string]$m).ToLowerInvariant()
            if (-not $byUser.ContainsKey($oid)) { $byUser[$oid] = [System.Collections.Generic.List[object]]::new() }
            if (-not $byUser[$oid].Contains($g)) { $byUser[$oid].Add($g) }
        }
    }

    $deny = [string]$Catalog.organisation.multipleGroupRule -ceq 'deny'
    $users = @(foreach ($oid in @($byUser.Keys | Sort-Object)) {
        $groups = @($byUser[$oid])
        $conflict = $groups.Count -gt 1
        $rows = @($groups | ForEach-Object { [long]$_.row })
        if ($conflict -and $deny) {
            [pscustomobject]@{
                Oid = $oid; Rows = $rows; Row = $null; GroupObjectId = $null; Profile = $null; ModelSet = $null
                TokensPerMonth = $null; TokensPerDay = $null; Capabilities = @(); M365 = $false; Conflict = $true; Denied = $true
            }
            continue
        }
        $chosen = $groups | Sort-Object @{ Expression = { [long]$byProfile[[string]$_.profile].TokensPerMonth }; Descending = $true }, @{ Expression = { [long]$_.row } } |
            Select-Object -First 1
        $p = $byProfile[[string]$chosen.profile]
        [pscustomobject]@{
            Oid = $oid; Rows = $rows; Row = [long]$chosen.row; GroupObjectId = ([string]$chosen.objectId).ToLowerInvariant()
            Profile = $p.Id; ModelSet = $p.ModelSet; TokensPerMonth = $p.TokensPerMonth; TokensPerDay = $p.TokensPerDay
            Capabilities = @($chosen.capabilities); M365 = [bool]$chosen.m365; Conflict = $conflict; Denied = $false
        }
    })

    [pscustomobject]@{
        Users = $users
        Conflicts = @($users | Where-Object { $_.Conflict })
        Denied = @($users | Where-Object { $_.Denied })
        GroupCounts = $counts
    }
}

function New-ClaudeAccessCatalogDocument {
    <#
    .SYNOPSIS
        The document the projection stores in Cosmos: each profile's models and limits, and each group's profile.
        Its id and partition key are access-catalog::<tenant>, as sync/src/plan.mjs validateAccessCatalog expects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)]$Plan)

    $tenant = ([string]$Catalog.gateway.tenantId).ToLowerInvariant()
    $id = "access-catalog::$tenant"
    $models = @{}
    foreach ($s in $Plan.ModelSets) { $models[$s.Name] = $s.Value }
    [ordered]@{
        id = $id
        oid = $id
        type = 'access-catalog'
        catalogVersion = [string]$Catalog.catalogVersion
        tenantId = $tenant
        multipleGroupRule = [string]$Catalog.organisation.multipleGroupRule
        dailyGuardPercentOfMonthly = [int]$Plan.DailyGuardPercent
        profiles = @($Plan.Profiles | ForEach-Object {
            [ordered]@{ id = $_.Id; models = $models[$_.ModelSet]; tokensPerMonth = $_.TokensPerMonth; tokensPerDay = $_.TokensPerDay
                level = $_.Level; creditUsd = $_.CreditUsd; modelSet = $_.ModelSet }
        })
        groups = @($Catalog.groups | Sort-Object { [long]$_.row } | ForEach-Object {
            [ordered]@{ objectId = ([string]$_.objectId).ToLowerInvariant(); row = [long]$_.row; profile = [string]$_.profile; capabilities = @($_.capabilities); m365 = [bool]$_.m365 }
        })
    }
}

function New-ClaudeAccessSnapshot {
    <#
    .SYNOPSIS
        A full entitlement snapshot of catalog records, as sync/src/apply-projection.mjs --snapshot applies it.

    .PARAMETER VerifiedAt
        When the membership read began. The runner refuses the snapshot two hours after it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)]$Assignment,
        [Parameter(Mandatory = $true)][DateTimeOffset]$VerifiedAt)

    $models = @{}
    foreach ($s in $Plan.ModelSets) { $models[$s.Name] = $s.Value }
    $start = $VerifiedAt.ToUniversalTime()
    $iso = 'yyyy-MM-ddTHH:mm:ss.fffZ'
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    [ordered]@{
        kind = 'claude-entitlement-snapshot'
        tenantId = ([string]$Catalog.gateway.tenantId).ToLowerInvariant()
        generatedAt = [DateTimeOffset]::UtcNow.ToString($iso, $invariant)
        reconciliationGeneration = [guid]::NewGuid().ToString()
        lastVerifiedAt = $start.ToString($iso, $invariant)
        expiresAt = $start.ToUnixTimeSeconds() + 7200
        mappingVersion = $start.ToUnixTimeSeconds()
        scope = 'full'
        records = @($Assignment.Users | Where-Object { -not $_.Denied } | ForEach-Object {
            [ordered]@{ oid = $_.Oid; tier = 'catalog'; businessUnit = ''; profile = $_.Profile; models = $models[$_.ModelSet]
                tokensPerMonth = [long]$_.TokensPerMonth; tokensPerDay = [long]$_.TokensPerDay }
        })
    }
}

function Get-ClaudeAccessRemoval {
    <#
    .SYNOPSIS
        The object IDs that hold access now and would not under the catalog, sorted.

    .PARAMETER Current
        Named-value lists as the gateway stores them (',oid,oid,'), or object IDs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Assignment, [AllowEmptyString()][AllowEmptyCollection()][string[]]$Current)

    $entitled = @{}
    foreach ($u in @($Assignment.Users)) { if (-not $u.Denied) { $entitled[([string]$u.Oid).ToLowerInvariant()] = $true } }
    $now = @(foreach ($value in @($Current)) {
        [regex]::Matches([string]$value, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() }
    })
    return , @($now | Sort-Object -Unique | Where-Object { -not $entitled.ContainsKey($_) })
}

function Get-ClaudeDesktopGroupKeys {
    <#
    .SYNOPSIS
        The Claude Desktop third-party keys for one group: surfaces, model list and, for M365 groups, the connector.

    .DESCRIPTION
        An overlay: the gateway connection and sign-in keys come from the existing onboarding, not from here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)]$Group)

    $caps = @($Group.capabilities)
    $prof = @($Catalog.profiles | Where-Object { $_.id -ceq [string]$Group.profile })[0]
    $families = @(Get-CatalogProperty $Catalog.modelSets ([string]$prof.modelSet))
    # The first entry is Desktop's default model; Sonnet first keeps the default off the most expensive model.
    $ordered = @($families | Where-Object { $_ -ceq 'sonnet' }) + @($families | Where-Object { $_ -cne 'sonnet' })
    $keys = [ordered]@{
        chatTabEnabled = [bool]($caps -ccontains 'Ch')
        coworkTabEnabled = [bool]($caps -ccontains 'Cw')
        isClaudeCodeForDesktopEnabled = [bool]($caps -ccontains 'Co')
        inferenceModels = @($ordered | ForEach-Object { [ordered]@{ name = [string](Get-CatalogProperty $Catalog.deployments $_); anthropicFamilyTier = $_ } })
    }
    if ($Group.m365) {
        $keys['managedMcpServers'] = @(Get-CatalogProperty (Get-CatalogProperty $Catalog.clientSettings 'm365') 'managedMcpServers')
    }
    return $keys
}

function ConvertTo-ClaudeDesktopRegistry {
    <#
    .SYNOPSIS
        A .reg file for HKLM\SOFTWARE\Policies\Claude, where Desktop reads every value as a REG_SZ string.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Keys)

    $lines = @('Windows Registry Editor Version 5.00', '', '[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Claude]')
    foreach ($name in $Keys.Keys) {
        $value = $Keys[$name]
        $text = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() }
                elseif ($value -is [string]) { $value }
                else { ConvertTo-Json -InputObject $value -Compress -Depth 10 }
        $lines += ('"{0}"="{1}"' -f $name, $text.Replace('\', '\\').Replace('"', '\"'))
    }
    return ($lines -join "`r`n") + "`r`n"
}
