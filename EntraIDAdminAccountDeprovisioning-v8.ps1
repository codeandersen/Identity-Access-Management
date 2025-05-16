#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Beta.Users

<#
.SYNOPSIS
    Identifies and deprovisions admin accounts without corresponding standard accounts.
.DESCRIPTION
    This script finds all admin accounts (with "adm." or "ext.adm." in the UPN), identifies their 
    corresponding standard accounts using the employeeID attribute, and deletes admin accounts if the standard accounts don't exist.
    
    The script is designed to run in Azure Automation and requires the following automation variables:
    - clientId: The Azure AD application ID
    - tenantId: The Azure AD tenant ID
    - certificateThumbprint: The certificate thumbprint for authentication
    - dryrun: Boolean value to control whether accounts are actually deleted (True) or just simulated (False)
.EXAMPLE
    This script is intended to be run in Azure Automation.
    Configure the required automation variables before running:
    - dryrun = True (to simulate deletions)
    - dryrun = False (to perform actual deletions)
.NOTES
    Author Links:
    - LinkedIn: https://www.linkedin.com/in/hanschrandersen/
    - GitHub: https://github.com/codeandersen
    - Twitter: https://x.com/dk_hcandersen
    - Homepage: https://www.hcandersen.net
#>

# Get variables from Automation Account
try {
    # Get required variables
    #$clientId = Get-AutomationVariable -Name 'clientId'
    #$tenantId = Get-AutomationVariable -Name 'tenantId'
    #$CertificateThumbprint = Get-AutomationVariable -Name 'certificateThumbprint'
    #$dryrunValue = Get-AutomationVariable -Name 'dryrun'


    # Handle different types for dryrun value
    if ($dryrunValue -is [System.Management.Automation.SwitchParameter]) {
        $DryRun = $dryrunValue.IsPresent
    } elseif ($dryrunValue -is [bool]) {
        $DryRun = $dryrunValue
    } elseif ($dryrunValue -is [string]) {
        $DryRun = $dryrunValue -eq 'True'
    } else {
        Write-Error "dryrun variable must be a boolean or string 'True'/'False'"
        throw "Invalid dryrun type: $($dryrunValue.GetType().Name)"
    }

    Write-Output "Retrieved automation variables: ClientId and TenantId set"
    Write-Output "DryRun mode: $(if ($DryRun) { '`$true - No accounts will be deleted' } else { '`$false - Accounts will be deleted' })"
} catch {
    Write-Error "Failed to get required variables from Automation Account: $_"
    throw "Missing required Automation Account variables. Please ensure clientId, tenantId, and dryrun are set."
}


# Extension attribute name for AdminEmployeeId
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"

# Function to authenticate user
function Connect-ToMgGraph {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        if ($CertificateThumbprint) {
            # App-only authentication with certificate (do NOT use -Scopes)
            Connect-MgGraph -ClientId $clientId -TenantId $tenantId -CertificateThumbprint $CertificateThumbprint -NoWelcome
            Write-Output "Connected to Microsoft Graph using service principal and certificate"
        } else {
            # Interactive fallback (delegated, requires -Scopes)
            Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
            Write-Output "Connected to Microsoft Graph using beta API version (interactive)"
        }
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
        Write-Output "Disconnected from Microsoft Graph."
    }
    catch {
        Write-Error "Error disconnecting from Microsoft Graph: $_"
    }
}

# Function to send notification email for admin account actions
function Send-AdminAccountNotification {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Recipient,
        [Parameter(Mandatory=$true)]
        [string]$AdminUPN,
        [Parameter(Mandatory=$true)]
        [string]$Action, # 'Would be deleted' or 'Deleted'
        [Parameter(Mandatory=$false)]
        [string]$Reason
    )
    
    # Compose subject and body
    $subject = "[IAM] Admin Account ${Action}: ${AdminUPN}"
    $bodyContent = "This is an automated notification from the EntraIDAdminAccountDeprovisioning script.<br><br>"
    $bodyContent += "Admin account: $AdminUPN<br>"
    $bodyContent += "Action: $Action<br>"
    $bodyContent += "Reason: $Reason<br><br>"
    $bodyContent += "This is a test notification. Please review the account as needed."

    # Log the notification to console
    Write-Host "" -ForegroundColor Cyan
    Write-Host "  ---- EMAIL NOTIFICATION ----" -ForegroundColor Cyan
    Write-Host "  To: $Recipient" -ForegroundColor Cyan
    Write-Host "  Subject: $subject" -ForegroundColor Cyan
    Write-Host "  Body: $bodyContent" -ForegroundColor Cyan
    Write-Host "  ---- END NOTIFICATION ----" -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Cyan
    
    # Send the actual email using Microsoft Graph API
    try {
        # Configure mail settings - using delegated permissions to send mail as the user
        $sendMailUrl = "https://graph.microsoft.com/v1.0/users/hans.christian.andersen@stark.dk/sendMail"
        
        # Define the email message JSON
        $messageJson = @{
            message = @{
                subject = $subject
                body = @{
                    contentType = "HTML"
                    content = $bodyContent
                }
                toRecipients = @(
                    @{
                        emailAddress = @{
                            address = "hca@apento.com"
                        }
                    }
                )
            }
            saveToSentItems = $true
        } | ConvertTo-Json -Depth 10
        
        # Send the email using Graph API
        if (-not $DryRun) {
            Invoke-MgGraphRequest -Method POST -Uri $sendMailUrl -Body $messageJson
            Write-Host "  Notification sent for $AdminUPN ($Action) to $Recipient" -ForegroundColor Cyan
        } else {
            Write-Host "  [DRYRUN] Would send notification for $AdminUPN ($Action) to $Recipient" -ForegroundColor Yellow
            Invoke-MgGraphRequest -Method POST -Uri $sendMailUrl -Body $messageJson
        }
    }
    catch {
        Write-Error "Failed to send notification for ${AdminUPN}: $($_.Exception.Message)"
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
        
        Write-Output "Found $($cloudOnlyAdminAccounts.Count) cloud-only admin accounts out of $($allAdminAccounts.Count) total admin accounts"
        return $cloudOnlyAdminAccounts
    }
    catch {
        Write-Error "Error getting admin accounts: $_"
        return @()
    }
}

# Function to get all primary accounts
function Get-PrimaryAccounts {
    Write-Output "Getting primary accounts..."
    
    # First try using the advanced filter with ConsistencyLevel
    try {
        Write-Output "Attempting to get primary accounts using advanced filter..."
        $filter = "not(startsWith(userPrincipalName, 'adm.')) and not(startsWith(userPrincipalName, 'ext.adm.'))"
        Write-Output "Filter: $filter"
        
        $primaryAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All -ConsistencyLevel "eventual" -Count userCount -ErrorAction Stop
        
        Write-Output "Successfully retrieved $($primaryAccounts.Count) primary accounts using advanced filter"
        return $primaryAccounts
    }
    catch {
        Write-Output "Failed to get primary accounts using advanced filter: $($_.Exception.Message)"
        Write-Output "Falling back to alternative method..."
        
        # Alternative approach - get all users and filter client-side
        try {
            Write-Output "Getting all users..."
            # Get all users and filter client-side
            Write-Output "Getting all users with Get-MgUser..."
            $allUsers = Get-MgUser -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            Write-Output "Retrieved $($allUsers.Count) total users"
            
            Write-Output "Filtering out admin accounts..."
            $primaryAccounts = $allUsers | Where-Object { 
                -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*')
            }
            
            Write-Output "Successfully found $($primaryAccounts.Count) primary accounts using alternative method"
            return $primaryAccounts
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Output "Error getting primary accounts using alternative method: $errorMessage"
            Write-Output "No primary accounts could be retrieved. Returning empty array."
            return @()
        }
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
        Write-Output "  Getting AdminEmployeeId for account: $adminUPN"
        
        # Use beta endpoint to get extension attributes
        $apiUrl = "beta/users/$adminUPN"
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        
        # Check if the extension attribute exists directly
        if ($userData -and $userData.$adminEmployeeIdExtension) {
            return $userData.$adminEmployeeIdExtension
        }
        
        # If not found directly, check in the extension attributes collection
        if ($userData.extensions) {
            foreach ($extension in $userData.extensions) {
                if ($extension.ContainsKey($adminEmployeeIdExtension)) {
                    return $extension.$adminEmployeeIdExtension
                }
            }
        }
        
        Write-Output "  No AdminEmployeeId found for account: $adminUPN"
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "  Error getting AdminEmployeeId for account '$adminUPN': $errorMessage" -ForegroundColor Red
        return $null
    }
}

# Function to find a primary account matching an admin account
function Find-MatchingPrimaryAccount {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount,
        
        [Parameter()]
        [array]$PrimaryAccounts
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
        Write-Output "  Checking specific primary account in beta API: $normalizedUPN"
        try {
            # First try to get the primary account using standard API
            $primaryAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
            
            if ($primaryAccount) {
                # Now check the beta API for the employeeId
                $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
                
                if ($betaUser) {
                    Write-Host "  Beta API employeeId: $($betaUser.employeeId)" -ForegroundColor Yellow
                    
                    # If we have an adminEmployeeId, check if it matches
                    if ($adminEmployeeId -and $betaUser.employeeId -eq $adminEmployeeId) {
                        Write-Output "  Found matching primary account with matching employeeId in beta API: $normalizedUPN"
                        
                        # Add the employeeId to the primary account object
                        $primaryAccount | Add-Member -NotePropertyName "EmployeeId" -NotePropertyValue $betaUser.employeeId -Force
                        return $primaryAccount
                    }
                    elseif (-not $adminEmployeeId) {
                        # If we don't have an adminEmployeeId, just return the matching account by UPN
                        Write-Host "  Found matching primary account by UPN pattern: $($primaryAccount.UserPrincipalName)" -ForegroundColor Green
                        return $primaryAccount
                    }
                    else {
                        Write-Host "  Found account with matching UPN pattern but employeeId doesn't match" -ForegroundColor Yellow
                    }
                }
                else {
                    # If beta API doesn't return data, just use the standard account if we don't have an adminEmployeeId
                    if (-not $adminEmployeeId) {
                        Write-Host "  Found matching primary account by UPN pattern: $($primaryAccount.UserPrincipalName)" -ForegroundColor Green
                        return $primaryAccount
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
        Write-Output "  Looking for primary account with EmployeeId: $adminEmployeeId"
        
        # If PrimaryAccounts array is provided, search in it
        if ($PrimaryAccounts) {
            $matchingAccount = $PrimaryAccounts | Where-Object { $_.EmployeeId -eq $adminEmployeeId }
            if ($matchingAccount) {
                Write-Output "  Found matching primary account by EmployeeId: $($matchingAccount.UserPrincipalName)"
                return $matchingAccount
            }
        }
        
        # Get all users and filter by employeeId client-side
        try {
            Write-Host "  Searching for accounts with employeeId: $adminEmployeeId" -ForegroundColor Yellow
            
            # Get all users and filter locally since employeeId filtering is not supported in Graph API
            $allUsers = Get-MgUser -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            $matchingAccounts = $allUsers | Where-Object { $_.EmployeeId -eq $adminEmployeeId }
            
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
                                Write-Host "  Beta API employeeId: $($betaUser.employeeId)" -ForegroundColor Yellow
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

# Connect to Microsoft Graph
Write-Output "Connecting to Microsoft Graph..."
$connected = Connect-ToMgGraph -CertificateThumbprint $CertificateThumbprint
if (-not $connected) {
    Write-Error "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Regular processing mode
if ($DryRun) {
    Write-Output "[WARNING] RUNNING IN DRY RUN MODE - No accounts will be deleted"
}

# Get all admin accounts
$adminAccounts = Get-AdminAccounts

if ($adminAccounts.Count -eq 0) {
    Write-Output "No admin accounts found. Exiting script."
    Disconnect-FromMgGraph
    exit 0
}

# Get all primary accounts for bulk processing
$primaryAccounts = Get-PrimaryAccounts

# Process each admin account
$successCount = 0
$failureCount = 0
$skippedCount = 0

foreach ($adminAccount in $adminAccounts) {
    $adminUPN = $adminAccount.UserPrincipalName
    Write-Output "Processing admin account: $adminUPN"
    
    # Skip on-premises synced accounts
    if ($adminAccount.OnPremisesSyncEnabled -eq $true) {
        Write-Output "  Account is on-premises synced. Skipping."
        $skippedCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            Action = "Skipped"
            Reason = "On-premises synced account"
            HasMatchingPrimaryAccount = "Unknown"
            PrimaryAccountUPN = ""
        }
        
        $results += $result
        continue
    }
    
    # Find matching primary account
    $primaryAccount = Find-MatchingPrimaryAccount -AdminAccount $adminAccount -PrimaryAccounts $primaryAccounts
    
    if ($primaryAccount) {
        # Admin account has a matching primary account, don't delete
        Write-Output "  Admin account has a matching primary account: $($primaryAccount.UserPrincipalName)"
        $skippedCount++
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            Action = "Skipped"
            Reason = "Has matching primary account"
            HasMatchingPrimaryAccount = "Yes"
            PrimaryAccountUPN = $primaryAccount.UserPrincipalName
        }
        
        $results += $result
    }
    else {
        # Admin account doesn't have a matching primary account, delete it
        Write-Output "  Admin account doesn't have a matching primary account"
        
        if ($DryRun) {
            Write-Output "  [DRY RUN] Would delete admin account: $adminUPN"
            $successCount++
            
            # Send notification (test phase)
            Send-AdminAccountNotification -Recipient "hans.christian.andersen@stark.dk" -AdminUPN $adminUPN -Action "Would be deleted" -Reason "No matching primary account"
            
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                Action = "Would be deleted"
                Reason = "No matching primary account"
                HasMatchingPrimaryAccount = "No"
                PrimaryAccountUPN = ""
            }
            
            $results += $result
        }
        else {
            try {
                # Delete the admin account
                Remove-MgUser -UserId $adminAccount.Id
                Write-Output "  Deleted admin account: $adminUPN"
                $successCount++
                
                # Send notification (actual deletion)
                Send-AdminAccountNotification -Recipient "hans.christian.andersen@stark.dk" -AdminUPN $adminUPN -Action "Deleted" -Reason "No matching primary account"
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Deleted"
                    Reason = "No matching primary account"
                    HasMatchingPrimaryAccount = "No"
                    PrimaryAccountUPN = ""
                }
                
                $results += $result
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Error "Error deleting admin account: $errorMessage"
                $failureCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Failed"
                    Reason = "Error: $errorMessage"
                    HasMatchingPrimaryAccount = "No"
                    PrimaryAccountUPN = ""
                }
                
                $results += $result
            }
        }
    }
}

# Display summary
Write-Output "`n----------------------------------------"
Write-Output "Summary:"
if ($DryRun) {
    Write-Output "[DRY RUN MODE] No accounts were actually deleted"
    Write-Output "Would delete: $successCount admin accounts"
}
else {
    Write-Output "[LIVE MODE] Accounts were deleted"
    Write-Output "Deleted: $successCount admin accounts"
}

Write-Output "Skipped: $skippedCount admin accounts"
Write-Output "Failed: $failureCount admin accounts"
Write-Output "----------------------------------------"

# Export results to CSV and output them
Write-Output "`nDetailed Results:"
$results | ForEach-Object {
    Write-Output "----------------------------------------"
    Write-Output "Admin Account: $($_.AdminUPN)"
    Write-Output "Action: $($_.Action)"
    Write-Output "Reason: $($_.Reason)"
    Write-Output "Has Matching Normal Account: $($_.HasMatchingNormalAccount)"
    if ($_.NormalAccountUPN) {
        Write-Output "Normal Account: $($_.NormalAccountUPN)"
    }
}
Write-Output "----------------------------------------"

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
