<#
================================================================================
 Get-MIServiceTierDetail.ps1

 Purpose:
   Answers the one question this project's T-SQL scripts explicitly CANNOT
   answer for themselves: whether an Azure SQL Managed Instance running the
   General Purpose service tier is on classic General Purpose or has the
   Next-gen General Purpose upgrade enabled.

   Precheck_RequiredSpaceForSetup.sql and Check_DiskAndTempdbHeadroom.sql
   both detect ServiceTier = 'GeneralPurpose' via sys.server_resource_stats,
   and both say so in their header comments/warnings: a Next-gen GP instance
   still reports sku = 'GeneralPurpose' and can even report the SAME
   hardware_generation as classic GP - this is confirmed against Microsoft's
   own documentation as an ARM/control-plane-only distinction, invisible to
   any DMV. When those scripts flag a material GP-tier storage/tempdb
   shortfall, their recommendation text tells you to "check whether
   Next-gen General Purpose is available/enabled... verify in the Azure
   portal" - this script automates that verification instead of requiring a
   manual portal check, and can do it for every MI in a subscription (or
   tenant) at once instead of one at a time.

   The distinguishing property is `properties.isGeneralPurposeV2` (boolean)
   on the Microsoft.Sql/managedInstances ARM resource - confirmed via the
   official REST API reference (Managed Instances - Create Or Update,
   api-version 2023-08-01-preview and later):
     https://learn.microsoft.com/en-us/rest/api/sql/managed-instances/create-or-update
   This property is not exposed anywhere in T-SQL/DMVs, only via the ARM
   control plane (Azure Resource Graph, ARM REST API, Az PowerShell, or the
   Azure portal's "Compute + storage" pane) - hence a PowerShell script
   instead of a T-SQL one.

 Requires:
   - Az.Accounts module only (no Az.ResourceGraph / Az.Sql dependency -
     queries Azure Resource Graph directly via Invoke-AzRestMethod, which
     Az.Accounts already provides, to keep the dependency footprint small).
     Install if needed: Install-Module Az.Accounts -Scope CurrentUser
   - An interactive or existing Az PowerShell login with at least Reader
     access on the subscription(s)/managed instance(s) being queried:
     Connect-AzAccount
   - Reader is sufficient - this script is READ-ONLY (a single Resource
     Graph query); it makes no changes to any resource.

 Usage:
   # All Managed Instances in every subscription the current login can see:
   .\Get-MIServiceTierDetail.ps1

   # Restrict to specific subscription(s):
   .\Get-MIServiceTierDetail.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000'

   # Export for handing to someone else / attaching to a capacity-planning ticket:
   .\Get-MIServiceTierDetail.ps1 | Export-Csv -Path .\mi-service-tiers.csv -NoTypeInformation

 Cross-referencing with the T-SQL scripts:
   Match this script's InstanceName column against SELECT SERVERPROPERTY
   ('ServerName') run on the instance in question (or the InstanceName
   column already present in Precheck_RequiredSpaceForSetup.sql's result
   set 2) to know which row applies to which MI.

 Author:  Generated with GitHub Copilot CLI assistance
 Updated: 2026-09-26
================================================================================
#>

[CmdletBinding()]
param(
    # One or more subscription IDs to restrict the search to. Omit to search
    # every subscription the current Az login has at least Reader access to.
    [string[]] $SubscriptionId
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module not found. Install it first: Install-Module Az.Accounts -Scope CurrentUser"
}
Import-Module Az.Accounts -ErrorAction Stop | Out-Null

$context = Get-AzContext
if (-not $context -or -not $context.Account) {
    Write-Host "No active Az PowerShell login found - launching Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}

# Resource Graph query: pull every Managed Instance visible to this login,
# projecting both the reported SKU tier (what T-SQL/DMVs can already see)
# and isGeneralPurposeV2 (the ARM-only field T-SQL cannot see).
$query = @"
resources
| where type =~ 'microsoft.sql/managedinstances'
| project
    SubscriptionId      = subscriptionId,
    ResourceGroup       = resourceGroup,
    InstanceName        = name,
    Location            = location,
    ReportedSkuTier     = tostring(properties.sku.tier),
    ReportedSkuName     = tostring(properties.sku.name),
    VCores              = toint(properties.vCores),
    StorageSizeGB       = toint(properties.storageSizeInGB),
    IsGeneralPurposeV2  = properties.isGeneralPurposeV2,
    ProvisioningState   = tostring(properties.provisioningState)
| order by InstanceName asc
"@

$body = @{ query = $query }
if ($SubscriptionId) { $body.subscriptions = $SubscriptionId }

$response = Invoke-AzRestMethod `
    -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
    -Method POST `
    -Payload ($body | ConvertTo-Json -Depth 5)

if ($response.StatusCode -ne 200) {
    throw "Resource Graph query failed (HTTP $($response.StatusCode)): $($response.Content)"
}

$rows = ($response.Content | ConvertFrom-Json).data

if (-not $rows -or $rows.Count -eq 0) {
    Write-Host "No Managed Instances found for the current login / specified subscription(s)." -ForegroundColor Yellow
    return
}

$results = foreach ($row in $rows) {
    # isGeneralPurposeV2 is $null (not a plain boolean) for Business Critical
    # instances and for older GP instances created before this property
    # existed - treat $null the same as $false rather than erroring.
    $isGPv2 = [bool]($row.IsGeneralPurposeV2 -eq $true)

    $effectiveTier =
        if ($row.ReportedSkuTier -eq 'GeneralPurpose' -and $isGPv2) { 'Next-gen General Purpose (GPv2)' }
        elseif ($row.ReportedSkuTier -eq 'GeneralPurpose') { 'General Purpose (classic)' }
        elseif ($row.ReportedSkuTier -eq 'BusinessCritical') { 'Business Critical' }
        else { $row.ReportedSkuTier }

    [PSCustomObject]@{
        InstanceName      = $row.InstanceName
        ResourceGroup     = $row.ResourceGroup
        SubscriptionId    = $row.SubscriptionId
        Location          = $row.Location
        EffectiveTier     = $effectiveTier
        IsGeneralPurposeV2 = $isGPv2
        VCores            = $row.VCores
        StorageSizeGB     = $row.StorageSizeGB
        ProvisioningState = $row.ProvisioningState
    }
}

$results | Format-Table -AutoSize | Out-Host
$results
