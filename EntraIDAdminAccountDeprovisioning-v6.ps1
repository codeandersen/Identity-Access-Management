#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Beta.Users

<#
.SYNOPSIS
    Identifies and deprovisions admin accounts without corresponding standard accounts.
.DESCRIPTION
    This script finds all admin accounts (with "adm." or "ext.adm." in the UPN), identifies their 
    corresponding standard accounts using the employeeID attribute, and deletes admin accounts if the standard accounts don't exist.
.PARAMETER DryRun
    If specified, the script will only show what would be deleted without making any actual changes.
.PARAMETER AdminUPN
    If specified, the script will only process the admin account with this UPN. If not specified, all admin accounts will be processed.
.PARAMETER CheckOnly
    If specified along with AdminUPN, the script will only check if the admin account has a corresponding standard account without performing any actions.
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning-v5.ps1
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning-v5.ps1 -DryRun
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning-v5.ps1 -AdminUPN "adm.john.doe@contoso.com"
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning-v5.ps1 -AdminUPN "adm.john.doe@contoso.com" -DryRun
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning-v5.ps1 -AdminUPN "adm.john.doe@contoso.com" -CheckOnly
.NOTES
    Author Links:
    - LinkedIn: https://www.linkedin.com/in/hanschrandersen/
    - GitHub: https://github.com/codeandersen
    - Twitter: https://x.com/dk_hcandersen
    - Homepage: https://www.hcandersen.net
#>

[CmdletBinding()]
param (
    [Parameter()]
    [switch]$DryRun,
    
    [Parameter()]
    [string]$AdminUPN,
    
    [Parameter()]
    [switch]$CheckOnly
)

# Azure AD App Registration details
$clientId = "xxxxxxxxx"
$tenantId = "xxxxxxxxx"


# Extension attribute name for AdminEmployeeId
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"

# Function to authenticate user
function Connect-ToMgGraph {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # Connect to Microsoft Graph
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        
        Write-Host "Connected to Microsoft Graph using beta API version" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        return $false
    }
}

# Function to disconnect from Microsoft Graph
function Disconnect-FromMgGraph {
    try {
        Disconnect-MgGraph
        Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Cyan
    }
    catch {
        Write-Error "Error disconnecting from Microsoft Graph: $_"
    }
}

# Function to get all admin accounts
function Get-AdminAccounts {
    try {
        # Get all admin accounts first with a simple filter
        $filter = "startsWith(userPrincipalName, 'adm.') or startsWith(userPrincipalName, 'ext.adm.')"
        $allAdminAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,Id,OnPremisesSyncEnabled" -All
        
        # Filter out AD synchronized accounts - cloud-only accounts have OnPremisesSyncEnabled as null or false
        $cloudOnlyAdminAccounts = $allAdminAccounts | Where-Object { $_.OnPremisesSyncEnabled -ne $true }
        
        Write-Host "Found $($cloudOnlyAdminAccounts.Count) cloud-only admin accounts out of $($allAdminAccounts.Count) total admin accounts" -ForegroundColor Yellow
        return $cloudOnlyAdminAccounts
    }
    catch {
        Write-Error "Error getting admin accounts: $_"
        return @()
    }
}

# Function to get all normal accounts
function Get-NormalAccounts {
    try {
        # Get all users that don't have UPN starting with "adm." or "ext.adm."
        # Using ConsistencyLevel:eventual header for advanced query operators like 'not'
        $filter = "not(startsWith(userPrincipalName, 'adm.')) and not(startsWith(userPrincipalName, 'ext.adm.'))"
        $normalAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All -ConsistencyLevel "eventual" -Count userCount
        
        Write-Host "Found $($normalAccounts.Count) normal accounts" -ForegroundColor Yellow
        return $normalAccounts
    }
    catch {
        Write-Error "Error getting normal accounts: $_"
        # Alternative approach if the not operator still fails
        try {
            Write-Host "Trying alternative method to get normal accounts..." -ForegroundColor Yellow
            # Get all users and filter client-side
            $allUsers = Get-MgUser -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            $normalAccounts = $allUsers | Where-Object { 
                -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*')
            }
            
            Write-Host "Found $($normalAccounts.Count) normal accounts using alternative method" -ForegroundColor Yellow
            return $normalAccounts
        }
        catch {
            Write-Error "Error getting normal accounts using alternative method: $_"
            return @()
        }
    }
}

# Function to get a specific admin account
function Get-SpecificAdminAccount {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AdminUPN
    )
    
    try {
        # Use beta endpoint to get all properties including extension attributes
        $apiUrl = "beta/users/$AdminUPN"
        $adminAccount = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        
        # Create a PSObject to match the format of Get-MgUser output
        $adminObject = [PSCustomObject]@{
            Id = $adminAccount.id
            DisplayName = $adminAccount.displayName
            UserPrincipalName = $adminAccount.userPrincipalName
            OnPremisesSyncEnabled = $adminAccount.onPremisesSyncEnabled
            # Include any other properties you need
        }
        
        return $adminObject
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Error "Error getting admin account '$AdminUPN': $errorMessage"
        return $null
    }
}

# Function to get the AdminEmployeeId from an admin account
function Get-AdminEmployeeId {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount
    )
    
    $adminUPN = $AdminAccount.UserPrincipalName
    
    try {
        Write-Host "  Getting AdminEmployeeId for account: $adminUPN" -ForegroundColor Yellow
        
        # Use beta endpoint to get extension attributes
        $apiUrl = "beta/users/$adminUPN"
        Write-Host "  Making Graph API call using beta endpoint" -ForegroundColor Yellow
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        
        # Check if the extension attribute exists directly
        if ($userData -and $userData.$adminEmployeeIdExtension) {
            Write-Host "  Found AdminEmployeeId: $($userData.$adminEmployeeIdExtension)" -ForegroundColor Green
            return $userData.$adminEmployeeIdExtension
        }
        
        # If not found directly, check in the extension attributes collection
        if ($userData.extensions) {
            foreach ($extension in $userData.extensions) {
                if ($extension.ContainsKey($adminEmployeeIdExtension)) {
                    Write-Host "  Found AdminEmployeeId in extensions: $($extension.$adminEmployeeIdExtension)" -ForegroundColor Green
                    return $extension.$adminEmployeeIdExtension
                }
            }
        }
        
        Write-Host "  No AdminEmployeeId found for account: $adminUPN" -ForegroundColor Yellow
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "  Error getting AdminEmployeeId for account '$adminUPN': $errorMessage" -ForegroundColor Red
        return $null
    }
}

# Function to find a normal account matching an admin account
function Find-MatchingNormalAccount {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount,
        
        [Parameter()]
        [array]$NormalAccounts
    )
    
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $AdminAccount
    $adminUPN = $AdminAccount.UserPrincipalName
    
    # Extract the normalized UPN from the admin UPN
    $normalizedUPN = $null
    
    # For pattern like ext.username@domain.com
    if ($adminUPN -match '^ext\.(.*?)@(.*)$') {
        # Pattern: ext.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    # For pattern like ext.adm.username@domain.com
    elseif ($adminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
        # Pattern: ext.adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    # For pattern like adm.username@domain.com
    elseif ($adminUPN -match '^adm\.(.*?)@(.*)$') {
        # Pattern: adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    
    # First, if we have a normalized UPN, check that account directly in the beta API
    if ($normalizedUPN) {
        Write-Host "  Checking specific normal account in beta API: $normalizedUPN" -ForegroundColor Yellow
        try {
            # First try to get the normal account using standard API
            $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
            
            if ($normalAccount) {
                # Now check the beta API for the employeeId
                $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
                
                if ($betaUser) {
                    Write-Host "  Beta API employeeId: $($betaUser.employeeId), AdminEmployeeId: $adminEmployeeId" -ForegroundColor Yellow
                    
                    # If we have an adminEmployeeId, check if it matches
                    if ($adminEmployeeId -and $betaUser.employeeId -eq $adminEmployeeId) {
                        Write-Host "  Found matching normal account with matching employeeId in beta API: $normalizedUPN" -ForegroundColor Green
                        
                        # Add the employeeId to the normal account object
                        $normalAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $betaUser.employeeId -Force
                        return $normalAccount
                    }
                    elseif (-not $adminEmployeeId) {
                        # If we don't have an adminEmployeeId, just return the matching account by UPN
                        Write-Host "  Found matching normal account by UPN pattern: $($normalAccount.UserPrincipalName)" -ForegroundColor Green
                        return $normalAccount
                    }
                    else {
                        Write-Host "  Found account with matching UPN pattern but employeeId doesn't match" -ForegroundColor Yellow
                    }
                }
                else {
                    # If beta API doesn't return data, just use the standard account if we don't have an adminEmployeeId
                    if (-not $adminEmployeeId) {
                        Write-Host "  Found matching normal account by UPN pattern: $($normalAccount.UserPrincipalName)" -ForegroundColor Green
                        return $normalAccount
                    }
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "  Error checking normalized UPN account: $errorMessage" -ForegroundColor Red
        }
    }
    
    # Method 1: Try to find by employeeId if we have it
    if ($adminEmployeeId) {
        Write-Host "  Looking for normal account with EmployeeId: $adminEmployeeId" -ForegroundColor Yellow
        
        # If NormalAccounts array is provided, search in it
        if ($NormalAccounts) {
            $matchingAccount = $NormalAccounts | Where-Object { $_.EmployeeId -eq $adminEmployeeId }
            if ($matchingAccount) {
                Write-Host "  Found matching normal account by EmployeeId: $($matchingAccount.UserPrincipalName)" -ForegroundColor Green
                return $matchingAccount
            }
        }
        
        # Try using standard API filter
        try {
            $filter = "employeeId eq '$adminEmployeeId'"
            Write-Host "  Searching for accounts with employeeId = $adminEmployeeId" -ForegroundColor Yellow
            $matchingAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            
            Write-Host "  Found $($matchingAccounts.Count) accounts with matching employeeId" -ForegroundColor Yellow
            
            if ($matchingAccounts.Count -gt 0) {
                # Filter out any admin accounts from the results
                $nonAdminAccounts = $matchingAccounts | Where-Object { 
                    -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*') 
                }
                
                Write-Host "  Found $($nonAdminAccounts.Count) non-admin accounts with matching employeeId" -ForegroundColor Yellow
                
                if ($nonAdminAccounts.Count -gt 0) {
                    # Get the first matching account
                    $matchedAccount = $nonAdminAccounts[0]
                    
                    # Debug the matched account
                    Write-Host "  DEBUG: Matched account properties:" -ForegroundColor Magenta
                    Write-Host "    UserPrincipalName: '$($matchedAccount.UserPrincipalName)'" -ForegroundColor Magenta
                    Write-Host "    DisplayName: '$($matchedAccount.DisplayName)'" -ForegroundColor Magenta
                    Write-Host "    EmployeeId: '$($matchedAccount.EmployeeId)'" -ForegroundColor Magenta
                    Write-Host "    Id: '$($matchedAccount.Id)'" -ForegroundColor Magenta
                    
                    # If the UserPrincipalName is empty but we have an Id, try to get the account by Id
                    if ([string]::IsNullOrEmpty($matchedAccount.UserPrincipalName) -and -not [string]::IsNullOrEmpty($matchedAccount.Id)) {
                        Write-Host "  UserPrincipalName is empty, trying to get account by Id..." -ForegroundColor Yellow
                        $fullAccount = Get-MgUser -UserId $matchedAccount.Id -ErrorAction SilentlyContinue
                        
                        if ($fullAccount) {
                            Write-Host "  Found matching normal account by Id: $($fullAccount.UserPrincipalName)" -ForegroundColor Green
                            # Add the EmployeeId from the matched account
                            $fullAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $matchedAccount.EmployeeId -Force
                            return $fullAccount
                        }
                    }
                    # If the UserPrincipalName is not empty, use it
                    elseif (-not [string]::IsNullOrEmpty($matchedAccount.UserPrincipalName)) {
                        Write-Host "  Found matching normal account by EmployeeId: $($matchedAccount.UserPrincipalName)" -ForegroundColor Green
                        
                        # Get the full account details to ensure we have all properties
                        $fullAccount = Get-MgUser -UserId $matchedAccount.UserPrincipalName -ErrorAction SilentlyContinue
                        if ($fullAccount) {
                            # Add the EmployeeId from the matched account
                            $fullAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $matchedAccount.EmployeeId -Force
                            return $fullAccount
                        }
                    }
                    
                    # If we get here, return the matched account as a last resort
                    return $matchedAccount
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "  Error searching for matching normal account by EmployeeId filter: $errorMessage" -ForegroundColor Red
        }
    } else {
        Write-Host "  No AdminEmployeeId found for admin account: $adminUPN" -ForegroundColor Yellow
    }
    
    # Method 2: Try to find a matching account by UPN pattern
    if ($normalizedUPN) {
        Write-Host "  Looking for normal account with UPN: $normalizedUPN" -ForegroundColor Yellow
        
        # Try to find the normal account by the normalized UPN
        try {
            $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
            
            if ($normalAccount) {
                # If we have an adminEmployeeId, check if the normal account has the same employeeId in beta API
                if ($adminEmployeeId) {
                    try {
                        Write-Host "  Checking employeeId in beta API for: $normalizedUPN" -ForegroundColor Yellow
                        $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
                        
                        if ($betaUser -and $betaUser.employeeId -eq $adminEmployeeId) {
                            Write-Host "  Found matching normal account with matching employeeId in beta API: $normalizedUPN" -ForegroundColor Green
                            
                            # Update the EmployeeId property of the normalAccount object
                            $normalAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $betaUser.employeeId -Force
                            return $normalAccount
                        }
                        else {
                            Write-Host "  Found account with matching UPN pattern but employeeId doesn't match" -ForegroundColor Yellow
                            if ($betaUser) {
                                Write-Host "  Beta API employeeId: $($betaUser.employeeId), AdminEmployeeId: $adminEmployeeId" -ForegroundColor Yellow
                            }
                        }
                    }
                    catch {
                        $errorMessage = $_.Exception.Message
                        Write-Host "  Error checking beta API: $errorMessage" -ForegroundColor Red
                    }
                }
                else {
                    # If we don't have an adminEmployeeId, just return the matching account by UPN
                    Write-Host "  Found matching normal account by UPN pattern: $($normalAccount.UserPrincipalName)" -ForegroundColor Green
                    return $normalAccount
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "  Error or no match found when searching by UPN pattern: $errorMessage" -ForegroundColor Yellow
        }
    }
    
    # Method 3: Try to find by display name (removing the "(Admin)" prefix)
    if ($AdminAccount.DisplayName -match '\(Admin\)\s+(.+)') {
        $normalName = $matches[1]
        Write-Host "  Looking for normal account with name: $normalName" -ForegroundColor Yellow
        
        try {
            $filter = "startsWith(displayName, '$normalName')"
            $nameMatches = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            
            if ($nameMatches.Count -gt 0) {
                # Filter out any admin accounts from the results
                $nonAdminNameMatches = $nameMatches | Where-Object { 
                    -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*') 
                }
                
                if ($nonAdminNameMatches.Count -gt 0) {
                    Write-Host "  Found matching normal account by name: $($nonAdminNameMatches[0].UserPrincipalName)" -ForegroundColor Green
                    return $nonAdminNameMatches[0]
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "  Error searching for matching normal account by name: $errorMessage" -ForegroundColor Red
        }
    }
    
    Write-Host "  No matching normal account found using any method" -ForegroundColor Red
    return $null
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

# Check if we're in CheckOnly mode
if ($CheckOnly -and -not [string]::IsNullOrEmpty($AdminUPN)) {
    Write-Host "Running in CHECK ONLY mode for admin account: $AdminUPN" -ForegroundColor Cyan
    
    # Get the specific admin account
    $adminAccount = Get-SpecificAdminAccount -AdminUPN $AdminUPN
    
    if (-not $adminAccount) {
        Write-Error "Admin account '$AdminUPN' not found in Entra ID. Exiting script."
        Disconnect-FromMgGraph
        exit 1
    }
    
    # Get the AdminEmployeeId
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount
    
    # Find matching normal account
    $normalAccount = Find-MatchingNormalAccount -AdminAccount $adminAccount
    
    # Debug: Show what was returned
    Write-Host "`nDEBUG - Normal account returned:" -ForegroundColor Magenta
    if ($normalAccount) {
        Write-Host "  Type: $($normalAccount.GetType().FullName)" -ForegroundColor Magenta
        Write-Host "  UPN: $($normalAccount.UserPrincipalName)" -ForegroundColor Magenta
        Write-Host "  DisplayName: $($normalAccount.DisplayName)" -ForegroundColor Magenta
        Write-Host "  EmployeeId: $($normalAccount.EmployeeId)" -ForegroundColor Magenta
    } else {
        Write-Host "  No normal account was returned (null)" -ForegroundColor Magenta
    }
    
    # Display results
    Write-Host "`nResults for admin account: $AdminUPN" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    
    Write-Host "Admin Account Details:" -ForegroundColor Yellow
    Write-Host "  Display Name: $($adminAccount.DisplayName)" -ForegroundColor White
    Write-Host "  UPN: $($adminAccount.UserPrincipalName)" -ForegroundColor White
    Write-Host "  AdminEmployeeId: $adminEmployeeId" -ForegroundColor White
    
    if ($normalAccount) {
        Write-Host "`nMatching Normal Account Found: EXISTS" -ForegroundColor Green
        Write-Host "  Display Name: $($normalAccount.DisplayName)" -ForegroundColor White
        Write-Host "  UPN: $($normalAccount.UserPrincipalName)" -ForegroundColor White
        Write-Host "  EmployeeId: $($normalAccount.EmployeeId)" -ForegroundColor White
    }
    else {
        Write-Host "`nMatching Normal Account: DOES NOT EXIST" -ForegroundColor Red
        Write-Host "  This admin account would be deleted in a normal run." -ForegroundColor Yellow
    }
    
    # Disconnect and exit
    Disconnect-FromMgGraph
    exit 0
}

# Regular processing mode
if ($DryRun) {
    Write-Host "RUNNING IN DRY RUN MODE - No accounts will be deleted" -ForegroundColor Yellow -BackgroundColor Black
}

# Get admin accounts
if ([string]::IsNullOrEmpty($AdminUPN)) {
    # Get all admin accounts
    $adminAccounts = Get-AdminAccounts
    
    if ($adminAccounts.Count -eq 0) {
        Write-Host "No admin accounts found. Exiting script." -ForegroundColor Yellow
        Disconnect-FromMgGraph
        exit 0
    }
} 
else {
    # Get the specific admin account
    if (-not (($AdminUPN -match '^adm\.') -or ($AdminUPN -match '^ext\.adm\.') -or ($AdminUPN -match '^ext\.'))) {
        Write-Error "The specified UPN '$AdminUPN' does not appear to be an admin account (should start with 'adm.', 'ext.adm.', or 'ext.'). Exiting script."
        Disconnect-FromMgGraph
        exit 1
    }
    
    $adminAccount = Get-SpecificAdminAccount -AdminUPN $AdminUPN
    
    if (-not $adminAccount) {
        Write-Error "Admin account '$AdminUPN' not found in Entra ID. Exiting script."
        Disconnect-FromMgGraph
        exit 1
    }
    
    # Check if the account is on-premises synced
    if ($adminAccount.OnPremisesSyncEnabled -eq $true) {
        Write-Host "Admin account '$AdminUPN' is on-premises synced. Skipping." -ForegroundColor Yellow
        Disconnect-FromMgGraph
        exit 0
    }
    
    $adminAccounts = @($adminAccount)
    Write-Host "Processing single admin account: $AdminUPN" -ForegroundColor Green
}

# Get all normal accounts for bulk processing
$normalAccounts = Get-NormalAccounts

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
            Action = "Skipped"
            Reason = "On-premises synced account"
            HasMatchingNormalAccount = "Unknown"
            NormalAccountUPN = ""
        }
        
        $results += $result
        continue
    }
    
    # Find matching normal account
    $normalAccount = Find-MatchingNormalAccount -AdminAccount $adminAccount -NormalAccounts $normalAccounts
    
    if ($normalAccount) {
        # Admin account has a matching normal account, don't delete
        Write-Host "  Admin account has a matching normal account: $($normalAccount.UserPrincipalName)" -ForegroundColor Green
        $skippedCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            Action = "Skipped"
            Reason = "Has matching normal account"
            HasMatchingNormalAccount = "Yes"
            NormalAccountUPN = $normalAccount.UserPrincipalName
        }
        
        $results += $result
    }
    else {
        # Admin account doesn't have a matching normal account, delete it
        Write-Host "  Admin account doesn't have a matching normal account" -ForegroundColor Red
        
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would delete admin account: $adminUPN" -ForegroundColor Yellow
            $successCount++
            
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                Action = "Would be deleted"
                Reason = "No matching normal account"
                HasMatchingNormalAccount = "No"
                NormalAccountUPN = ""
            }
            
            $results += $result
        }
        else {
            try {
                # Delete the admin account
                Remove-MgUser -UserId $adminAccount.Id
                Write-Host "  Deleted admin account: $adminUPN" -ForegroundColor Green
                $successCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Deleted"
                    Reason = "No matching normal account"
                    HasMatchingNormalAccount = "No"
                    NormalAccountUPN = ""
                }
                
                $results += $result
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Host "  Error deleting admin account: $errorMessage" -ForegroundColor Red
                $failureCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Failed"
                    Reason = "Error: $errorMessage"
                    HasMatchingNormalAccount = "No"
                    NormalAccountUPN = ""
                }
                
                $results += $result
            }
        }
    }
}

# Display summary
Write-Host "`nSummary:" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  DRY RUN MODE - No accounts were actually deleted" -ForegroundColor Yellow
    Write-Host "  Would delete: $successCount admin accounts" -ForegroundColor Green
}
else {
    Write-Host "  Deleted: $successCount admin accounts" -ForegroundColor Green
}

Write-Host "  Skipped: $skippedCount admin accounts" -ForegroundColor Yellow
Write-Host "  Failed: $failureCount admin accounts" -ForegroundColor Red

# Export results to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = ".\EntraIDAdminAccountDeprovisioning_$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "`nResults exported to: $csvPath" -ForegroundColor Cyan

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
