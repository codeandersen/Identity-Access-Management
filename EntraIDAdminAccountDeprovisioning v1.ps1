#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

<#
.SYNOPSIS
    Identifies and deprovisions admin accounts without corresponding standard accounts.
.DESCRIPTION
    This script finds all admin accounts (with "adm." or "adm.ext." in the UPN), identifies their 
    corresponding standard accounts, and deletes admin accounts if the standard accounts don't exist.
.PARAMETER DryRun
    If specified, the script will only show what would be deleted without making any actual changes.
.PARAMETER AdminUPN
    If specified, the script will only process the admin account with this UPN. If not specified, all admin accounts will be processed.
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -DryRun
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -AdminUPN "adm.john.doe@contoso.com"
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -AdminUPN "adm.john.doe@contoso.com" -DryRun
#>

[CmdletBinding()]
param (
    [Parameter()]
    [switch]$DryRun,
    
    [Parameter()]
    [string]$AdminUPN
)

# Azure AD App Registration details
$clientId = "xxxx-xxx-xx-xx"
$tenantId = "xxxx-xxx-xx-xx"

# Function to authenticate user
function Connect-ToMgGraph {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        return $true
    } catch {
        Write-Host "Failed to connect to Microsoft Graph: $_" -ForegroundColor Red
        return $false
    }
}

function Disconnect-FromMgGraph {
    Disconnect-MgGraph
    Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Cyan
}

# Function to get standard UPN from admin UPN
function Get-StandardUPN {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AdminUPN
    )

    # Handle different admin account formats
    if ($AdminUPN -match '^adm\.(.+)@(.+)$') {
        # Format: adm.username@domain.com
        return "$($Matches[1])@$($Matches[2])"
    }
    elseif ($AdminUPN -match '^adm\.ext\.(.+)@(.+)$') {
        # Format: adm.ext.username@domain.com
        return "$($Matches[1])@$($Matches[2])"
    }
    else {
        # Not a recognized admin account format
        return $null
    }
}

# Create output array
$results = @()

# Set encoding to UTF-8 for proper Unicode support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$PSDefaultParameterValues['Export-Csv:Encoding'] = 'utf8'

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
$connected = Connect-ToMgGraph
if (-not $connected) {
    Write-Error "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Find all admin accounts
Write-Host "Finding admin accounts..." -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "RUNNING IN DRY RUN MODE - No accounts will be deleted" -ForegroundColor Yellow -BackgroundColor Black
}
try {
    if ([string]::IsNullOrEmpty($AdminUPN)) {
        # Get all users with "adm." in their UPN
        $filter = "startsWith(userPrincipalName, 'adm.')"
        $adminAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,Id,OnPremisesSyncEnabled" -All
        
        Write-Host "Found $($adminAccounts.Count) admin accounts." -ForegroundColor Green
    } else {
        # Get the specific admin account
        if (-not ($AdminUPN -match '^adm\.')) {
            Write-Error "The specified UPN '$AdminUPN' does not appear to be an admin account (should start with 'adm.'). Exiting script."
            Disconnect-FromMgGraph
            exit 1
        }
        
        try {
            $adminAccounts = @(Get-MgUser -UserId $AdminUPN -Property "UserPrincipalName,DisplayName,Id,OnPremisesSyncEnabled" -ErrorAction Stop)
            Write-Host "Processing single admin account: $AdminUPN" -ForegroundColor Green
        } catch {
            Write-Error "Admin account '$AdminUPN' not found in Entra ID. Exiting script."
            Disconnect-FromMgGraph
            exit 1
        }
    }
}
catch {
    Write-Error "Failed to retrieve admin accounts: $_"
    Disconnect-FromMgGraph
    exit 1
}

# Process each admin account
$successCount = 0
$failureCount = 0
$skippedCount = 0

foreach ($adminAccount in $adminAccounts) {
    $adminUPN = $adminAccount.UserPrincipalName
    Write-Host "Processing admin account: $adminUPN" -ForegroundColor Yellow
    
    # Skip on-premises synced accounts
    if ($adminAccount.OnPremisesSyncEnabled -eq $true) {
        Write-Host "  Account is on-premises synced. Skipping." -ForegroundColor Yellow
        $skippedCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminAccount.DisplayName
            StandardUPN = "N/A"
            StandardAccountExists = "N/A"
            Action = "None"
            Status = "Skipped: On-premises synced account"
        }
        
        $results += $result
        continue
    }
    
    # Get corresponding standard UPN
    $standardUPN = Get-StandardUPN -AdminUPN $adminUPN
    
    if (-not $standardUPN) {
        Write-Host "  Could not determine standard UPN for admin account. Skipping." -ForegroundColor Red
        $failureCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminAccount.DisplayName
            StandardUPN = "Unknown"
            StandardAccountExists = "Unknown"
            Action = "None"
            Status = "Error: Could not determine standard UPN"
        }
        
        $results += $result
        continue
    }
    
    Write-Host "  Looking for standard account: $standardUPN" -ForegroundColor Yellow
    
    try {
        # Check if standard account exists
        $standardAccount = Get-MgUser -UserId $standardUPN -Property "UserPrincipalName,DisplayName" -ErrorAction Stop
        $standardAccountExists = $true
        
        Write-Host "  Standard account found. Admin account will be kept." -ForegroundColor Green
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminAccount.DisplayName
            StandardUPN = $standardUPN
            StandardAccountExists = "Yes"
            Action = "Keep"
            Status = "Standard account exists"
        }
        
        $skippedCount++
    }
    catch {
        # Standard account doesn't exist
        $standardAccountExists = $false
        
        Write-Host "  Standard account not found. Admin account will be deleted." -ForegroundColor Red
        
        if (-not $DryRun) {
            try {
                # Delete the admin account
                Remove-MgUser -UserId $adminAccount.Id -ErrorAction Stop
                Write-Host "  Admin account deleted successfully." -ForegroundColor Green
                $successCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    AdminDisplayName = $adminAccount.DisplayName
                    StandardUPN = $standardUPN
                    StandardAccountExists = "No"
                    Action = "Deleted"
                    Status = "Success: Admin account deleted"
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "  Error deleting admin account: $errorMessage" -ForegroundColor Red
                $failureCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    AdminDisplayName = $adminAccount.DisplayName
                    StandardUPN = $standardUPN
                    StandardAccountExists = "No"
                    Action = "Delete Failed"
                    Status = "Error: $errorMessage"
                }
            }
        }
        else {
            # Dry run mode
            Write-Host "  [DRY RUN] Admin account would be deleted." -ForegroundColor Yellow
            $successCount++
            
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                AdminDisplayName = $adminAccount.DisplayName
                StandardUPN = $standardUPN
                StandardAccountExists = "No"
                Action = "Would Delete"
                Status = "Dry Run: Admin account would be deleted"
            }
        }
    }
    
    $results += $result
}

# Display summary
Write-Host "`nSummary:" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "DRY RUN MODE - No accounts were actually deleted" -ForegroundColor Yellow
}
Write-Host "Total admin accounts processed: $($adminAccounts.Count)" -ForegroundColor White
Write-Host "Admin accounts that would be/were deleted: $successCount" -ForegroundColor $(if ($successCount -gt 0) { "Red" } else { "Green" })
Write-Host "Admin accounts skipped: $skippedCount" -ForegroundColor Yellow
Write-Host "Admin accounts with errors: $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Green" })

# Export results to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = ".\EntraIDAdminAccountDeprovisioning-$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`nResults exported to: $csvPath" -ForegroundColor Cyan

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
