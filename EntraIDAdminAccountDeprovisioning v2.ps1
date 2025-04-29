#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Beta.Users, Microsoft.Graph.Beta.DirectoryObjects

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
    .\EntraIDAdminAccountDeprovisioning.ps1
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -DryRun
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -AdminUPN "adm.john.doe@contoso.com"
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -AdminUPN "adm.john.doe@contoso.com" -DryRun
.EXAMPLE
    .\EntraIDAdminAccountDeprovisioning.ps1 -AdminUPN "adm.john.doe@contoso.com" -CheckOnly
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


# Function to authenticate user
function Connect-ToMgGraph {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # Connect to Microsoft Graph (no need to set beta profile with new SDK)
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        
        Write-Host "Connected to Microsoft Graph using beta API version" -ForegroundColor Green
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

# Define the custom extension attribute ID for AdminEmployeeId
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"

# Function to get all normal accounts (non-admin accounts)
function Get-NormalAccounts {
    try {
        Write-Host "Retrieving all normal accounts from Entra ID..." -ForegroundColor Cyan
        
        # Instead of using the 'not' operator which requires ConsistencyLevel header,
        # we'll get all users and filter client-side
        $allUsers = Get-MgBetaUser -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
        
        # Filter out admin accounts client-side
        $normalAccounts = $allUsers | Where-Object { 
            -not ($_.UserPrincipalName -like "adm.*") -and 
            -not ($_.UserPrincipalName -like "ext.adm.*") 
        }
        
        Write-Host "Found $($normalAccounts.Count) normal accounts." -ForegroundColor Green
        return $normalAccounts
    }
    catch {
        Write-Error "Failed to retrieve normal accounts: $_"
        return @()
    }
}

# Function to get all admin accounts
function Get-AdminAccounts {
    try {
        Write-Host "Retrieving all admin accounts from Entra ID..." -ForegroundColor Cyan
        
        # Get all users with 'adm.' in their UPN
        $filter = "startsWith(userPrincipalName, 'adm.')"
        $adminAccounts1 = Get-MgBetaUser -Filter $filter -All
        
        # Get all users with 'ext.adm.' in their UPN
        $filter = "startsWith(userPrincipalName, 'ext.adm.')"
        $adminAccounts2 = Get-MgBetaUser -Filter $filter -All
        
        # Combine the results
        $adminAccounts = $adminAccounts1 + $adminAccounts2
        
        Write-Host "Found $($adminAccounts.Count) admin accounts." -ForegroundColor Green
        return $adminAccounts
    }
    catch {
        Write-Error "Failed to retrieve admin accounts: $_"
        return @()
    }
}

# Function to get a specific admin account
function Get-SpecificAdminAccount {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AdminUPN
    )
    
    try {
        # Try using the beta endpoint directly
        $apiUrl = "beta/users/$AdminUPN"
        $adminAccount = Invoke-MgGraphRequest -Method GET -Uri $apiUrl -ErrorAction Stop
        
        # Convert the response to a PSObject that matches what Get-MgUser would return
        $adminObject = [PSCustomObject]@{
            Id = $adminAccount.id
            DisplayName = $adminAccount.displayName
            UserPrincipalName = $adminAccount.userPrincipalName
            Mail = $adminAccount.mail
            EmployeeId = $adminAccount.employeeId
            OnPremisesSyncEnabled = $adminAccount.onPremisesSyncEnabled
        }
        
        return $adminObject
    }
    catch {
        Write-Error "Admin account '$AdminUPN' not found in Entra ID: $_"
        return $null
    }
}

# Function to get the AdminEmployeeId from an admin account
function Get-AdminEmployeeId {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount
    )
    
    Write-Host "  Getting AdminEmployeeId for account: $($AdminAccount.UserPrincipalName)" -ForegroundColor Yellow
    
    try {
        # Use the beta endpoint to access the extension attribute
        $userUPN = $AdminAccount.UserPrincipalName
        
        # Use Invoke-MgGraphRequest which uses the existing authentication context
        $apiUrl = "beta/users/$userUPN"
        
        # Get all user properties directly
        Write-Host "  Making Graph API call using beta endpoint" -ForegroundColor Yellow
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        
        # Check if the extension attribute exists
        if ($userData -and $userData.$adminEmployeeIdExtension) {
            Write-Host "  Found AdminEmployeeId: $($userData.$adminEmployeeIdExtension)" -ForegroundColor Green
            return $userData.$adminEmployeeIdExtension
        }
        else {
            # Try to find any property that might contain the AdminEmployeeId
            $extensionProps = $userData.PSObject.Properties | Where-Object { $_.Name -like "extension_*" }
            
            if ($extensionProps) {
                foreach ($prop in $extensionProps) {
                    if ($prop.Name -like "*AdminEmployeeId") {
                        Write-Host "  Found AdminEmployeeId in extension property: $($prop.Value)" -ForegroundColor Green
                        return $prop.Value
                    }
                }
            }
            
            Write-Host "  No AdminEmployeeId extension attribute found" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "  Error retrieving AdminEmployeeId: $_" -ForegroundColor Red
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
    
    if ($adminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
        # Pattern: ext.adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    elseif ($adminUPN -match '^adm\.(.*?)@(.*)$') {
        # Pattern: adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
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
        else {
            # Otherwise, query directly
            try {
                # First check if we can find a direct match using the normalized UPN in beta API
                if ($normalizedUPN) {
                    Write-Host "  Checking specific normal account in beta API: $normalizedUPN" -ForegroundColor Yellow
                    try {
                        $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
                        
                        if ($betaUser -and $betaUser.employeeId -eq $adminEmployeeId) {
                            Write-Host "  Found matching normal account with matching employeeId in beta API: $normalizedUPN" -ForegroundColor Green
                            
                            # Create a user object with the employeeId from beta API
                            $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
                            if ($normalAccount) {
                                $normalAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $betaUser.employeeId -Force
                                return $normalAccount
                            }
                        }
                    }
                    catch {
                        Write-Host "  Error checking beta API for specific account: $_" -ForegroundColor Red
                    }
                }
                
                # Try using standard API filter
                $filter = "employeeId eq '$adminEmployeeId'"
                $matchingAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
                
                if ($matchingAccounts.Count -gt 0) {
                    # Filter out any admin accounts from the results
                    $nonAdminAccounts = $matchingAccounts | Where-Object { 
                        -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*') 
                    }
                    
                    if ($nonAdminAccounts.Count -gt 0) {
                        Write-Host "  Found matching normal account by EmployeeId: $($nonAdminAccounts[0].UserPrincipalName)" -ForegroundColor Green
                        return $nonAdminAccounts[0]  # Return the first matching non-admin account
                    }
                }
            }
            catch {
                Write-Host "  Error searching for matching normal account by EmployeeId filter: $_" -ForegroundColor Red
            }
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
                            $normalAccount.EmployeeId = $betaUser.employeeId
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
                        Write-Host "  Error checking beta API: $_" -ForegroundColor Red
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
            Write-Host "  Error or no match found when searching by UPN pattern: $normalizedUPN" -ForegroundColor Yellow
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
            Write-Host "  Error searching for matching normal account by name: $_" -ForegroundColor Red
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
    Write-Host "\nDEBUG - Normal account returned:" -ForegroundColor Magenta
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
    if (-not (($AdminUPN -match '^adm\.') -or ($AdminUPN -match '^ext\.adm\.'))) {
        Write-Error "The specified UPN '$AdminUPN' does not appear to be an admin account (should start with 'adm.' or 'ext.adm.'). Exiting script."
        Disconnect-FromMgGraph
        exit 1
    }
    
    $adminAccount = Get-SpecificAdminAccount -AdminUPN $AdminUPN
    
    if (-not $adminAccount) {
        Write-Error "Admin account '$AdminUPN' not found in Entra ID. Exiting script."
        Disconnect-FromMgGraph
        exit 1
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
            AdminDisplayName = $adminAccount.DisplayName
            AdminEmployeeId = "N/A"
            NormalUPN = "N/A"
            NormalDisplayName = "N/A"
            NormalEmployeeId = "N/A"
            NormalAccountExists = "N/A"
            Action = "None"
            Status = "Skipped: On-premises synced account"
        }
        
        $results += $result
        continue
    }
    
    # Get AdminEmployeeId
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount
    
    if (-not $adminEmployeeId) {
        Write-Host "  No AdminEmployeeId found for admin account. Skipping." -ForegroundColor Red
        $failureCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminAccount.DisplayName
            AdminEmployeeId = "Not Found"
            NormalUPN = "N/A"
            NormalDisplayName = "N/A"
            NormalEmployeeId = "N/A"
            NormalAccountExists = "Unknown"
            Action = "None"
            Status = "Error: No AdminEmployeeId found"
        }
        
        $results += $result
        continue
    }
    
    # Find matching normal account
    $normalAccount = Find-MatchingNormalAccount -AdminAccount $adminAccount -NormalAccounts $normalAccounts
    
    if ($normalAccount) {
        # Normal account exists
        Write-Host "  Matching normal account found: $($normalAccount.UserPrincipalName)" -ForegroundColor Green
        Write-Host "  Admin account will be kept." -ForegroundColor Green
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminAccount.DisplayName
            AdminEmployeeId = $adminEmployeeId
            NormalUPN = $normalAccount.UserPrincipalName
            NormalDisplayName = $normalAccount.DisplayName
            NormalEmployeeId = $normalAccount.EmployeeId
            NormalAccountExists = "Yes"
            Action = "Keep"
            Status = "Normal account exists"
        }
        
        $skippedCount++
    }
    else {
        # Normal account doesn't exist
        Write-Host "  No matching normal account found. Admin account will be deleted." -ForegroundColor Red
        
        if (-not $DryRun) {
            try {
                # Delete the admin account
                Remove-MgUser -UserId $adminAccount.Id -ErrorAction Stop
                Write-Host "  Admin account deleted successfully." -ForegroundColor Green
                $successCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    AdminDisplayName = $adminAccount.DisplayName
                    AdminEmployeeId = $adminEmployeeId
                    NormalUPN = "N/A"
                    NormalDisplayName = "N/A"
                    NormalEmployeeId = "N/A"
                    NormalAccountExists = "No"
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
                    AdminEmployeeId = $adminEmployeeId
                    NormalUPN = "N/A"
                    NormalDisplayName = "N/A"
                    NormalEmployeeId = "N/A"
                    NormalAccountExists = "No"
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
                AdminEmployeeId = $adminEmployeeId
                NormalUPN = "N/A"
                NormalDisplayName = "N/A"
                NormalEmployeeId = "N/A"
                NormalAccountExists = "No"
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
