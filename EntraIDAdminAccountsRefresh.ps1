#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

<#
.SYNOPSIS
    Updates admin accounts with information from their corresponding standard accounts.
.DESCRIPTION
    This script finds all admin accounts (with "adm." or "ext.adm" in the UPN), identifies their 
    corresponding standard accounts, and copies job title, company name, office location, department, 
    and EmployeeId from the standard accounts to the admin accounts.
.PARAMETER DryRun
    If specified, the script will only show what would be updated without making any actual changes.
.PARAMETER AdminUPN
    If specified, the script will only process the admin account with this UPN. If not specified, all admin accounts will be processed.
.EXAMPLE
    .\EntraIDAdminAccountsRefresh.ps1
.EXAMPLE
    .\EntraIDAdminAccountsRefresh.ps1 -DryRun
.EXAMPLE
    .\EntraIDAdminAccountsRefresh.ps1 -AdminUPN "adm.john.doe@contoso.com"
.EXAMPLE
    .\EntraIDAdminAccountsRefresh.ps1 -AdminUPN "adm.john.doe@contoso.com" -DryRun
#>

[CmdletBinding()]
param (
    [Parameter()]
    [switch]$DryRun,
    
    [Parameter()]
    [string]$AdminUPN
)

# Azure AD App Registration details
#$clientId = "xxxx-xxx-xxx-xxx"
#$tenantId = "xxxx-xxx-xxx-xxx"
$clientId = "e8be624e-3836-4330-9222-6022aa6a7964"
$tenantId = "2e114308-14ec-4d77-b610-490324fa1844"

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
    elseif ($AdminUPN -match '^ext\.adm\.(.+)@(.+)$') {
        # Format: ext.adm.username@domain.com
        return "$($Matches[1])@$($Matches[2])"
    }
    else {
        # Not a recognized admin account format
        return $null
    }
}

# Function to get a user's manager email using the beta Graph API
function Get-ManagerEmail {
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserUPN
    )
    try {
        $apiUrl = "beta/users/$UserUPN/manager"
        $managerData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        if ($managerData -and $managerData.mail) {
            return $managerData.mail
        }
        return $null
    } catch {
        Write-Host "  Manager field empty" -ForegroundColor Red
        return $null
    }
}

# Function to get the AdminManagerMail extension attribute from an admin account
function Get-AdminManagerMail {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount
    )
    $adminManagerMailExtension = 'extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminManagerMail'
    try {
        $adminUPN = $AdminAccount.UserPrincipalName
        $apiUrl = "beta/users/$adminUPN"
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        if ($userData -and $userData.$adminManagerMailExtension) {
            return $userData.$adminManagerMailExtension
        }
        if ($userData.extensions) {
            foreach ($extension in $userData.extensions) {
                if ($extension.ContainsKey($adminManagerMailExtension)) {
                    return $extension.$adminManagerMailExtension
                }
            }
        }
        return $null
    } catch {
        Write-Host ("  Error retrieving AdminManagerMail extension for {0}: {1}" -f $adminUPN, $_) -ForegroundColor Red
        return $null
    }
}

# Function to get the AdminEmployeeId from an admin account
function Get-AdminEmployeeId {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount
    )
    $adminEmployeeIdExtension = 'extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId'
    try {
        $adminUPN = $AdminAccount.UserPrincipalName
        $apiUrl = "beta/users/$adminUPN"
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        if ($userData -and $userData.$adminEmployeeIdExtension) {
            return $userData.$adminEmployeeIdExtension
        }
        if ($userData.extensions) {
            foreach ($extension in $userData.extensions) {
                if ($extension.ContainsKey($adminEmployeeIdExtension)) {
                    return $extension.$adminEmployeeIdExtension
                }
            }
        }
        return $null
    } catch {
        Write-Host "  Error retrieving AdminEmployeeId extension: $_" -ForegroundColor Red
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
    Write-Host "RUNNING IN DRY RUN MODE - No changes will be made" -ForegroundColor Yellow -BackgroundColor Black
}
try {
    if ([string]::IsNullOrEmpty($AdminUPN)) {
        # Get all users with "adm." or "ext.adm" in their UPN
        $filter = "startsWith(userPrincipalName, 'adm.') or startsWith(userPrincipalName, 'ext.adm.')"
        $adminAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,JobTitle,CompanyName,OfficeLocation,Department,AdditionalProperties,OnPremisesSyncEnabled" -All
        
        Write-Host "Found $($adminAccounts.Count) admin accounts." -ForegroundColor Green
    } else {
        # Get the specific admin account
        if (-not ($AdminUPN -match '^(adm\.|ext\.adm\.)')) {
            Write-Error "The specified UPN '$AdminUPN' does not appear to be an admin account (should start with 'adm.' or 'ext.adm.'). Exiting script."
            Disconnect-FromMgGraph
            exit 1
        }
        
        try {
            $adminAccounts = @(Get-MgUser -UserId $AdminUPN -Property "UserPrincipalName,JobTitle,CompanyName,OfficeLocation,Department,AdditionalProperties,OnPremisesSyncEnabled" -ErrorAction Stop)
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
            StandardAccountUPN = "N/A"
            StandardAccountExists = "N/A"
            CurrentAdminAccountJobTitle = $adminAccount.JobTitle
            StandardAccountJobTitle = $null
            CurrentAdminAccountCompanyName = $adminAccount.CompanyName
            StandardAccountCompanyName = $null
            CurrentAdminAccountOfficeLocation = $adminAccount.OfficeLocation
            StandardAccountOfficeLocation = $null
            CurrentAdminAccountDepartment = $adminAccount.Department
            StandardAccountDepartment = $null
            CurrentAdminAccountEmployeeId = $null
            StandardAccountEmployeeId = $null
            StandardAccountManagerEmail = $null
            CurrentAdminAccountManagerMail = $null
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
            StandardAccountUPN = "Unknown"
            StandardAccountExists = "Unknown"
            CurrentAdminAccountJobTitle = $adminAccount.JobTitle
            StandardAccountTitle = $null
            CurrentAdminAccountCompanyName = $adminAccount.CompanyName
            StandardAccountCompanyName = $null
            CurrentAdminAccountOfficeLocation = $adminAccount.OfficeLocation
            StandardAccountOfficeLocation = $null
            CurrentAdminAccountDepartment = $adminAccount.Department
            StandardAccountDepartment = $null
            CurrentAdminAccountEmployeeId = $null
            StandardAccountEmployeeId = $null
            StandardAccountManagerEmail = $null
            CurrentAdminAccountManagerMail = $null
            Status = "Error: Could not determine standard UPN"
        }
        
        $results += $result
        continue
    }
    
    Write-Host "  Looking for standard account: $standardUPN" -ForegroundColor Yellow
    
    try {
        # Get standard account
        $standardAccount = Get-MgUser -UserId $standardUPN -Property "UserPrincipalName,JobTitle,CompanyName,OfficeLocation,Department,EmployeeId" -ErrorAction Stop
        $standardAccountExists = "Yes"
        
        Write-Host "  Found standard account. Copying attributes..." -ForegroundColor Green
        
        # Prepare update parameters
        $updateParams = @{}
        
        # Get current extension attribute value using robust helper function
        $currentAdminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount

        # Get manager email for the standard account
        $managerEmail = Get-ManagerEmail -UserUPN $standardUPN
        if ([string]::IsNullOrEmpty($managerEmail)) {
            $managerEmail = '<empty>'
        }

        # Get AdminManagerMail extension value from admin account
        $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount

        Write-Host "  Comparing admin and standard account values:" -ForegroundColor Cyan

        function Show-Compare {
            param (
                [string]$Label,
                $AdminValue,
                $StandardValue
            )
            if ($AdminValue -ne $StandardValue) {
                Write-Host "    ${Label}: ${AdminValue} -> ${StandardValue}" -ForegroundColor Yellow
                return $true
            } else {
                Write-Host "    ${Label}: ${AdminValue} (no change)" -ForegroundColor Gray
                return $false
            }
        }

        $fieldsToCompare = @(
            @{Label="JobTitle"; Admin=$adminAccount.JobTitle; Standard=$standardAccount.JobTitle; Param="JobTitle"},
            @{Label="CompanyName"; Admin=$adminAccount.CompanyName; Standard=$standardAccount.CompanyName; Param="CompanyName"},
            @{Label="OfficeLocation"; Admin=$adminAccount.OfficeLocation; Standard=$standardAccount.OfficeLocation; Param="OfficeLocation"},
            @{Label="Department"; Admin=$adminAccount.Department; Standard=$standardAccount.Department; Param="Department"},
            @{Label="EmployeeId"; Admin=$currentAdminEmployeeId; Standard=$standardAccount.EmployeeId; Param="extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"},
            @{Label="ManagerMail"; Admin=$adminManagerMail; Standard=$managerEmail; Param="extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminManagerMail"}
        )

        foreach ($field in $fieldsToCompare) {
            $needsUpdate = Show-Compare -Label $field.Label -AdminValue $field.Admin -StandardValue $field.Standard
            if ($needsUpdate) {
                if ($field.Param -eq "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId") {
                    $global:needsEmployeeIdUpdate = $true
                    $global:newEmployeeIdValue = $field.Standard
                } elseif ($field.Param -eq "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminManagerMail") {
                    $updateParams[$field.Param] = $field.Standard
                } else {
                    $updateParams[$field.Param] = $field.Standard
                }
            }
        }


        # Update admin account with standard account attributes and extension attributes if not in dry run mode
        if (-not $DryRun) {
            try {
                # Only update if there are properties to update
                if ($updateParams.Count -gt 0) {
                    # Update all attributes, including extension attributes (AdminManagerMail, AdminEmployeeId, etc.)
                    Update-MgUser -UserId $adminUPN -BodyParameter $updateParams
                    Write-Host "  Successfully updated admin account with standard and extension attributes." -ForegroundColor Green
                } else {
                    Write-Host "  No attributes to update." -ForegroundColor Yellow
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "  Error updating admin account: $errorMessage" -ForegroundColor Red
                $result.Status = "Error: $errorMessage"
                $failureCount++
                $successCount--  # Adjust the success count since this was counted as success earlier
            }
        } else {
            Write-Host "  [DRY RUN] Would update admin account with standard account attributes." -ForegroundColor Yellow
        }
        


        # Determine status based on whether any updates are actually needed
        if ($updateParams.Count -gt 0 -or $needsEmployeeIdUpdate -or $needsManagerMailUpdate) {
            $status = if ($DryRun) { "Would Update" } else { "Updated" }
        } else {
            $status = "No Change"
        }
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            StandardAccountUPN = $standardUPN
            StandardAccountExists = $standardAccountExists
            CurrentAdminJobTitle = $adminAccount.JobTitle
            StandardAccountJobTitle = $standardAccount.JobTitle
            CurrentAdminCompanyName = $adminAccount.CompanyName
            StandardAccountCompanyName = $standardAccount.CompanyName
            CurrentAdminOfficeLocation = $adminAccount.OfficeLocation
            StandardAccountOfficeLocation = $standardAccount.OfficeLocation
            CurrentAdminDepartment = $adminAccount.Department
            StandardAccountDepartment = $standardAccount.Department
            CurrentAdminEmployeeId = $currentAdminEmployeeId
            StandardAccountEmployeeId = $standardAccount.EmployeeId
            CurrentAdminManagerMail = $adminManagerMail
            StandardAccountManagerMail = if ([string]::IsNullOrEmpty($managerEmail)) { '<empty>' } else { $managerEmail }
            Status = $status
        }

        $successCount++
        $results += $result
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.Exception.Response.StatusCode -eq 404 -or $errorMessage -like '*ResourceNotFound*') {
            Write-Host "  Standard account does not exist for $standardUPN. Skipping." -ForegroundColor Yellow
            $standardAccountExists = "No"
            $currentAdminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount
            $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                StandardAccountUPN = $standardUPN
                StandardAccountExists = $standardAccountExists
                CurrentAdminJobTitle = $adminAccount.JobTitle
                StandardAccountJobTitle = $null
                CurrentAdminCompanyName = $adminAccount.CompanyName
                StandardAccountCompanyName = $null
                CurrentAdminOfficeLocation = $adminAccount.OfficeLocation
                StandardAccountOfficeLocation = $null
                CurrentAdminDepartment = $adminAccount.Department
                StandardAccountDepartment = $null
                CurrentAdminEmployeeId = $currentAdminEmployeeId
                StandardAccountEmployeeId = $null
                CurrentAdminManagerMail = $adminManagerMail
                StandardAccountManagerMail = '<empty>'
                Status = "Standard account does not exist"
            }
            $results += $result
            $failureCount++
            continue
        } else {
            Write-Host "  Error retrieving standard account: $errorMessage" -ForegroundColor Red
            $standardAccountExists = "No"
            $currentAdminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount
            $managerEmail = Get-ManagerEmail -UserUPN $standardUPN
            $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                StandardAccountUPN = $standardUPN
                StandardAccountExists = $standardAccountExists
                CurrentAdminJobTitle = $adminAccount.JobTitle
                StandardAccountJobTitle = $null
                CurrentAdminCompanyName = $adminAccount.CompanyName
                StandardAccountCompanyName = $null
                CurrentAdminOfficeLocation = $adminAccount.OfficeLocation
                StandardAccountOfficeLocation = $null
                CurrentAdminDepartment = $adminAccount.Department
                StandardAccountDepartment = $null
                CurrentAdminEmployeeId = $currentAdminEmployeeId
                StandardAccountEmployeeId = $null
                CurrentAdminManagerMail = $adminManagerMail
                StandardAccountManagerMail = if ([string]::IsNullOrEmpty($managerEmail)) { '<empty>' } else { $managerEmail }
                Status = "Error: $errorMessage"
            }
            $failureCount++
            $results += $result
        }
    }
}

# Display summary
Write-Host "`nSummary:" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  DRY RUN MODE - No changes were made" -ForegroundColor Yellow -BackgroundColor Black
}
Write-Host "  Total admin accounts processed: $($adminAccounts.Count)" -ForegroundColor Cyan
Write-Host "  Successfully processed: $successCount" -ForegroundColor Green
Write-Host "  Failed to process: $failureCount" -ForegroundColor $(if ($failureCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped (on-premises synced): $skippedCount" -ForegroundColor Yellow

# Display all results as list for full details
Write-Host "`nFull details for each account:" -ForegroundColor Cyan
$results | Format-List *

# Group results by status for better reporting
$resultsByStatus = $results | Group-Object -Property Status

Write-Host "`nResults by Status:" -ForegroundColor Cyan
foreach ($statusGroup in $resultsByStatus) {
    $color = switch -Wildcard ($statusGroup.Name) {
        "Updated" { "Green" }
        "Would Update" { "Yellow" }
        "Skipped: *" { "Yellow" }
        "Error: *" { "Red" }
        default { "White" }
    }
    
    Write-Host "  $($statusGroup.Name): $($statusGroup.Count) accounts" -ForegroundColor $color
}

# Export results to CSV
$outputPath = if ($DryRun) {
    "EntraIDAdminAccountsRefresh_DryRun_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
} else {
    "EntraIDAdminAccountsRefresh_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
}
$results | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UNICODE


Write-Host "Results exported to: $outputPath" -ForegroundColor Cyan

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph