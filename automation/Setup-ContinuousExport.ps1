<#
.SYNOPSIS
    Sets up Continuous Export from Defender for Cloud to a Log Analytics workspace.

.DESCRIPTION
    Configures Defender for Cloud to continuously export Security Assessments and
    Sub-Assessments to a Log Analytics workspace — required for aging & reoccurrence analysis.

    This script:
      1. Validates the target Log Analytics workspace exists
      2. Creates or updates the Continuous Export (auto-provisioning) setting
      3. Verifies data is flowing after a brief wait

.PARAMETER SubscriptionId
    Azure Subscription ID to configure.

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Name of the target Log Analytics workspace.

.PARAMETER ExportScope
    Subscription IDs to export from. Defaults to the current subscription.

.EXAMPLE
    .\Setup-ContinuousExport.ps1 -SubscriptionId "xxxx-xxxx" -ResourceGroupName "rg-security" -WorkspaceName "law-security"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Cyan" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
$requiredModules = @("Az.Accounts", "Az.Security", "Az.OperationalInsights")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Log "Installing module: $mod" "WARN"
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $mod -ErrorAction Stop
}

# Login check
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Log "Logging into Azure..." "WARN"
    Connect-AzAccount
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Log "Subscription set: $SubscriptionId"

# ─────────────────────────────────────────────────────────────────────────────
# Validate workspace
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "Validating Log Analytics workspace: $WorkspaceName"
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
$workspaceId = $workspace.ResourceId
Write-Log "Workspace found: $workspaceId" "SUCCESS"

# Check retention
$retentionDays = $workspace.RetentionInDays
Write-Log "Current retention: $retentionDays days"
if ($retentionDays -lt 365) {
    Write-Log "Retention is less than 365 days. For 12-month analysis, consider increasing it." "WARN"
    $increase = Read-Host "Increase retention to 365 days? (y/n)"
    if ($increase -eq 'y') {
        Set-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -RetentionInDays 365 | Out-Null
        Write-Log "Retention updated to 365 days." "SUCCESS"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Ensure SecurityCenterFree solution is installed on the workspace
# (Required prerequisite: https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export)
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "Checking SecurityCenterFree solution on workspace..."
$solutionName = "SecurityCenterFree($WorkspaceName)"
$solutionUri  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationsManagement/solutions/$($solutionName)?api-version=2015-11-01-preview"
$solutionCheck = Invoke-AzRestMethod -Method GET -Path $solutionUri

if ($solutionCheck.StatusCode -ne 200) {
    Write-Log "Installing SecurityCenterFree solution (required for CE data to appear)..." "WARN"
    $solutionBody = @{
        location   = $workspace.Location
        plan       = @{
            name        = "SecurityCenterFree"
            publisher   = "Microsoft"
            product     = "OMSGallery/SecurityCenterFree"
            promotionCode = ""
        }
        properties = @{
            workspaceResourceId = $workspaceId
        }
    } | ConvertTo-Json -Depth 5

    $solutionResult = Invoke-AzRestMethod -Method PUT -Path $solutionUri -Payload $solutionBody
    if ($solutionResult.StatusCode -in 200, 201) {
        Write-Log "SecurityCenterFree solution installed successfully!" "SUCCESS"
    }
    else {
        $errMsg = ($solutionResult.Content | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
        Write-Log "Failed to install SecurityCenterFree solution: $errMsg" "ERROR"
        Write-Log "Install it manually: Portal → Log Analytics workspace → Solutions → Add → SecurityCenterFree" "WARN"
    }
}
else {
    Write-Log "SecurityCenterFree solution already installed." "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
# Configure Continuous Export via ARM REST API (Invoke-AzRestMethod)
# Per official docs, omitting ruleSets exports ALL events for each source.
# https://learn.microsoft.com/en-us/rest/api/defenderforcloud/automations/create-or-update
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "Configuring Continuous Export..."

# Build the automation rule body — empty ruleSets = export all (per official docs)
$automationBody = @{
    location   = $workspace.Location
    properties = @{
        description = "Continuous export of security assessments and sub-assessments to Log Analytics"
        isEnabled   = $true
        scopes      = @(
            @{
                description = "Subscription scope"
                scopePath   = "/subscriptions/$SubscriptionId"
            }
        )
        sources     = @(
            @{ eventSource = "Assessments" },
            @{ eventSource = "AssessmentsSnapshot" },
            @{ eventSource = "SubAssessments" },
            @{ eventSource = "SubAssessmentsSnapshot" }
        )
        actions     = @(
            @{
                actionType          = "Workspace"
                workspaceResourceId = $workspaceId
            }
        )
    }
} | ConvertTo-Json -Depth 10

$automationName = "ExportToWorkspace"
$apiVersion = "2023-12-01-preview"
# Automation resource must be scoped to a resource group
$armPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Security/automations/${automationName}?api-version=$apiVersion"

Write-Log "Creating/updating continuous export automation..."
try {
    $result = Invoke-AzRestMethod -Method PUT -Path $armPath -Payload $automationBody
    if ($result.StatusCode -in 200, 201) {
        $response = $result.Content | ConvertFrom-Json
        Write-Log "Continuous Export configured successfully!" "SUCCESS"
        Write-Log "  Name    : $($response.name)"
        Write-Log "  Status  : $($response.properties.isEnabled)"
        Write-Log "  Location: $($response.location)"
    }
    else {
        $errContent = $result.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $errMsg = if ($errContent.error) { $errContent.error.message } else { "HTTP $($result.StatusCode)" }
        throw "API returned $($result.StatusCode): $errMsg"
    }
}
catch {
    Write-Log "Failed to configure Continuous Export: $($_.Exception.Message)" "ERROR"
    Write-Log "You can also configure this manually:" "WARN"
    Write-Log "  Azure Portal → Defender for Cloud → Environment Settings → [subscription]" "WARN"
    Write-Log "  → Continuous Export → Log Analytics workspace tab" "WARN"
    Write-Log "  → Enable 'Security assessments' and 'Security sub-assessments'" "WARN"
    throw
}

# ─────────────────────────────────────────────────────────────────────────────
# Verify data flow
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "Waiting 60 seconds for initial data to flow..."
Start-Sleep -Seconds 60

$workspaceGuid = $workspace.CustomerId
$verifyQuery = "SecurityNestedRecommendation | summarize Count = count(), LatestRecord = max(TimeGenerated)"

try {
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceGuid -Query $verifyQuery -ErrorAction Stop
    $row = $result.Results[0]
    if ([int]$row.Count -gt 0) {
        Write-Log "Data is flowing! Found $($row.Count) records. Latest: $($row.LatestRecord)" "SUCCESS"
    }
    else {
        Write-Log "No data yet in SecurityNestedRecommendation. This is normal if just enabled — data typically appears within 4-24 hours." "WARN"
        Write-Log "First snapshot export can take up to 24 hours." "WARN"
    }
}
catch {
    Write-Log "Could not verify data flow yet. Check back in a few hours." "WARN"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "  SETUP COMPLETE" "SUCCESS"
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "Workspace     : $WorkspaceName ($workspaceGuid)"
Write-Log "Retention     : $((Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName).RetentionInDays) days"
Write-Log "Export Status : Enabled"
Write-Log ""
Write-Log "Next Steps:"
Write-Log "  1. Wait 4-24 hours for initial data snapshot"
Write-Log "  2. Run the analysis script:"
Write-Log "     .\Run-DefenderAnalysis.ps1 -WorkspaceId '$workspaceGuid' -GenerateHtmlReport"
