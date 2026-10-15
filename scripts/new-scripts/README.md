# Claude access catalog

Maps your Microsoft Entra ID groups to Claude access profiles on an existing Claude gateway in Azure API Management.
A profile sets the models a person may use and their monthly and daily token limits. The same run writes one
Claude Desktop policy per group, for Intune or another MDM.

You fill in one file, [claude-access-catalog.json](claude-access-catalog.json), and run one script,
[Import-ClaudeAccessCatalog.ps1](Import-ClaudeAccessCatalog.ps1).

## What is in this repository

| Path | Purpose |
| --- | --- |
| `claude-access-catalog.json` | The catalog you fill in: gateway, profiles, model sets and groups. |
| `Import-ClaudeAccessCatalog.ps1` | Checks the catalog and, with `-Apply`, sets up the gateway. |
| `ClaudeAccessCatalog.ps1` | The functions the import uses. |
| `Test-ClaudeAccessCatalog.ps1` | Offline tests for these scripts. |
| `scripts/` | The deployment scripts the import calls. |
| `infra/` | The gateway policy and the Bicep templates. |
| `resolver/` | The Function that serves each person's record to the gateway. |
| `sync/` | The job that keeps the records in step with group membership. |

## What `-Apply` changes

Against the existing gateway, in this order:

1. Writes the gateway named values `quota-org`, `calls-per-minute` and `entitlement-cache-seconds`.
2. **Replaces the whole policy of the `claude-foundry` API** with `infra/policy.xml`, which reads each person's
   models and limits from their record.
3. Deploys or updates the entitlement projection in the gateway's resource group.
4. Stores the catalog and one record per person in the projection.
5. Switches the gateway to the projection, sends one test request, and switches back if the gateway answers with a
   server error.
6. Deploys the sync job that keeps the records in step with the groups.

Before any write it lists everyone who has access now and would not under the catalog, and stops unless you pass
`-AcceptAccessRemoval`. Every step is safe to rerun.

It creates these billable resources in the gateway's resource group: a Cosmos DB account, a Function App with its
storage account and Application Insights, a virtual network with private endpoints and private DNS zones, a
container instance (the in-network runner), a container registry, a Container Apps environment and job, and alert
rules with an action group.

## Before you start

| Need | Detail |
| --- | --- |
| Operator machine | PowerShell 7, Azure CLI, Node.js 22 with npm, and git. `tar` ships with Windows 10 and later. |
| Outbound access | `management.azure.com`, `graph.microsoft.com`, `registry.npmjs.org`, `mcr.microsoft.com` and Docker Hub (the `node:22-bookworm-slim` image). |
| Azure role | Owner on the gateway's resource group, or Contributor plus User Access Administrator. Read access to the Foundry account. |
| Entra rights | The operator must be able to create an app registration: the script creates one for the resolver. A Global Administrator or Privileged Role Administrator is needed once, after the run, for the Microsoft Graph grant. |
| Decisions | An approved monthly token figure for each of the 11 profiles (`tokensPerMonth: null` is an error; `suggestedTokensPerMonth` is only a hint), an organisation ceiling, an alert e-mail address, and the four Foundry deployment names. |
| Fable | Every name under `deployments` must exist on your Foundry account. Without a Fable deployment, decide which deployment `fable` points at for now. |
| Telemetry | The gateway's Application Insights must be linked to a Log Analytics workspace. Without that the sync job is skipped with a warning. |

## Run it

### 1. Get the scripts and sign in

```powershell
git clone <repository-url>
cd <repository-folder>
az login --tenant <tenant-guid>
az account set --subscription <subscription-guid>
az bicep install
```

### 2. Register the resource providers

Once per subscription. The import's preflight checks most of these, but not `Microsoft.ContainerRegistry`, which
the sync job needs.

```powershell
'Microsoft.App','Microsoft.ContainerInstance','Microsoft.ContainerRegistry','Microsoft.DocumentDB','Microsoft.Web',
'Microsoft.Network','Microsoft.Storage','Microsoft.OperationalInsights','Microsoft.Insights' |
  ForEach-Object { az provider register --namespace $_ --wait }
```

### 3. Check the gateway and back up its policy

`-Apply` replaces the whole API policy and does not keep a copy. Keep the output folder outside this repository:
the run writes user object IDs to it.

```powershell
az apim show -g <gateway-resource-group> -n <apim-name> --query "{sku:sku.name, vnet:virtualNetworkType, region:location}" -o table

New-Item -ItemType Directory -Force C:\claude-catalog-out | Out-Null
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$url = 'https://management.azure.com/subscriptions/<subscription-guid>/resourceGroups/<gateway-resource-group>/providers/Microsoft.ApiManagement/service/<apim-name>/apis/claude-foundry/policies/policy?api-version=2024-05-01&format=rawxml'
(Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $token" }).properties.value |
  Set-Content C:\claude-catalog-out\policy-before-catalog.xml -Encoding utf8
```

### 4. Fill in `claude-access-catalog.json`

| Field | What to enter |
| --- | --- |
| `catalogVersion` | Any label; raise it every time you change the catalog. |
| `gateway.*` | Tenant, subscription, gateway resource group, API Management name, Foundry account and its resource group. |
| `projection.namePrefix` | 3 to 24 lower-case letters, digits or hyphens. Must be unique in Azure: the Cosmos DB account is named `cosmos-<prefix>`. |
| `projection.location` | `null` puts the projection in the gateway's region, which is what you normally want. |
| `projection.resolverInboundAccess` | **`"public"`**. `private` works only when the gateway has outbound VNet integration into the projection's network, which this script does not set up; without it the test request fails and the script switches back. A public resolver still accepts only the gateway's token. |
| `projection.alertEmail` | Who is told when the sync job fails. |
| `organisation.tokensPerMonth` | **Set it explicitly, at most 2,147,483,647.** Left `null`, it becomes the sum of every user's allowance, which will pass that limit, and a larger value has not been verified on API Management. |
| `deployments.*` | Your Foundry deployment names. |
| `profiles[].tokensPerMonth` | The approved monthly figure for each profile. The daily limit is `limits.dailyGuardPercentOfMonthly` of it. |
| `clientSettings.m365...tenantId` | Your tenant ID, if any group has `"m365": true`. |
| `groups[].objectId` | The Entra object ID of each group. The helper below fills them in. |

This helper fills in each group's object ID when exactly one group has that display name, and warns otherwise. It
rewrites the file's layout, not its content.

```powershell
$path = './claude-access-catalog.json'
$c = Get-Content $path -Raw | ConvertFrom-Json
foreach ($g in $c.groups) {
    $ids = @(az ad group list --filter "displayName eq '$($g.displayName -replace "'", "''")'" --query "[].id" -o tsv)
    if ($ids.Count -eq 1) { $g.objectId = $ids[0] } else { Write-Warning "row $($g.row): $($ids.Count) match(es) for '$($g.displayName)'" }
}
$c | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding utf8
```

Display names must match Entra exactly, including case and punctuation.

### 5. Check the file alone

No Azure access needed. Fix every error it lists.

```powershell
pwsh ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json -Offline
```

### 6. Check against the tenant

Reads the subscription, the gateway, the Foundry deployments and every group's members. Writes nothing to Azure.

```powershell
pwsh ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json -OutputPath C:\claude-catalog-out
```

Review in `C:\claude-catalog-out`:

| File | What it shows |
| --- | --- |
| `named-values.json` | Each gateway setting: its current and planned value. |
| `assignments.json` | The profile each user gets, and anyone in more than one group. |
| `access-removed.json` | People who have access now and would lose it. |
| `clients\client-assignments.csv` | Which Desktop policy goes to which group, and which groups get the Claude Code CLI. |

### 7. Apply

```powershell
pwsh ./Import-ClaudeAccessCatalog.ps1 -Path ./claude-access-catalog.json -OutputPath C:\claude-catalog-out -Apply
```

- Add `-AcceptAccessRemoval` only if everyone in `access-removed.json` is meant to lose access.
- If it stops part-way, fix the cause it prints and run the same command again.
- Keep `C:\claude-catalog-out`: it holds the switch backup (`projection-switch-*.json`) and the sync job receipt
  (`projection-renewal-<prefix>.json`).

## After the run

### 8. Microsoft Graph grant

A Global Administrator or Privileged Role Administrator runs this once. `-Apply` prints the principal ID, and the
receipt `projection-renewal-<prefix>.json` records it. The grant can take up to about 24 hours to take effect;
until then the sync job cannot read group changes, and the records stay as the import wrote them.

```powershell
pwsh ./scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId <printed-principal-id>
```

### 9. Claude Desktop policies

Deploy each `clients\group-NN.reg` (or the same keys in `group-NN.desktop.json`) to its group through Intune or
your MDM. They set the visible tabs and the model list under `HKLM\SOFTWARE\Policies\Claude`, and add to the
gateway connection settings your developers already have rather than replace them.

The generated policies do not yet set `modelDiscoveryEnabled`. The gateway does not serve `/v1/models`, so add
this line to each `.reg` file before you deploy it:

```text
"modelDiscoveryEnabled"="false"
```

### 10. Check it works

- A user whose profile has no Opus asks for Opus and gets HTTP 403.
- A user on a profile with Opus gets an answer (HTTP 200).
- A user past their monthly or daily limit gets HTTP 429.

## Changing access later

Edit `claude-access-catalog.json`, raise `catalogVersion`, and repeat steps 5 to 7. Group membership changes need
no rerun: the sync job picks them up on its schedule (`projection.syncInterval`).

## If something goes wrong

- **The test request fails after the switch.** The script sets `entitlement-source` back to its previous value
  itself, so access is as before. Check the resolver Function App (`func-resolver-<prefix>`) and rerun.
- **You need the previous gateway policy back.** Set `entitlement-source` to the value recorded in
  `projection-switch-*.json`, then restore the policy you saved in step 3:

  ```powershell
  az apim nv update -g <gateway-resource-group> --service-name <apim-name> --named-value-id entitlement-source --value <previous-value>
  pwsh ./scripts/Set-GatewayPolicy.ps1 -ApimName <apim-name> -ResourceGroup <gateway-resource-group> -SubscriptionId <subscription-guid> -PolicyFile C:\claude-catalog-out\policy-before-catalog.xml
  ```

- **The sync job step warns and is skipped.** Access is in force. Fix the cause it prints (often the Application
  Insights workspace or the `Microsoft.ContainerRegistry` provider) and rerun step 7.

## Testing these scripts

```powershell
pwsh ./Test-ClaudeAccessCatalog.ps1
```

Offline; needs Node.js.
