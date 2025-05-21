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
$clientId = "71f6c44e-27e3-43ca-b395-630bc43f87ae"
$tenantId = "2e114308-14ec-4d77-b610-490324fa1844"
$CertificateThumbprint = "00d0850a07735ea7ce2fd7339213b89e9a0c2757"
$dryrunValue = $True

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

    Write-Host "Retrieved automation variables: ClientId and TenantId set" -ForegroundColor Cyan
    Write-Host "DryRun mode: $(if ($DryRun) { '`$true - No accounts will be deleted' } else { '`$false - Accounts will be deleted' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' })
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
            try {
                # App-only authentication with certificate (do NOT use -Scopes)
                Connect-MgGraph -ClientId $clientId -TenantId $tenantId -CertificateThumbprint $CertificateThumbprint -NoWelcome
                Write-Host "Connected to Microsoft Graph using service principal and certificate" -ForegroundColor Green
                return $true
            }
            catch {
                Write-Host "Certificate authentication failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Falling back to interactive authentication..." -ForegroundColor Yellow
                # Fall through to interactive auth
            }
        }
        
        # Interactive fallback (delegated, requires -Scopes)
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        Write-Host "Connected to Microsoft Graph using interactive authentication" -ForegroundColor Green
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
        $sendMailUrl = "https://graph.microsoft.com/v1.0/users/noreply-cloudadmindeprovision@starkgroup.dk/sendMail"
        
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
                            address = "$Recipient"
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
        
        Write-Host "Found $($cloudOnlyAdminAccounts.Count) cloud-only admin accounts out of $($allAdminAccounts.Count) total admin accounts" -ForegroundColor Cyan
        return $cloudOnlyAdminAccounts
    }
    catch {
        Write-Error "Error getting admin accounts: $_"
        return @()
    }
}

# Function to get all primary accounts
function Get-PrimaryAccounts {
    Write-Host "Getting primary accounts..." -ForegroundColor Cyan
    
    # First try using the advanced filter with ConsistencyLevel
    try {
        Write-Host "Attempting to get primary accounts using advanced filter..."
        $filter = "not(startsWith(userPrincipalName, 'adm.')) and not(startsWith(userPrincipalName, 'ext.adm.'))"
        Write-Host "Filter: $filter"
       
        $primaryAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All -ConsistencyLevel "eventual" -Count userCount -ErrorAction Stop
        
        # Verify that the accounts have the required properties
        $sampleAccount = $primaryAccounts | Select-Object -First 1
        Write-Host "Sample primary account properties:" -ForegroundColor Cyan
        Write-Host "  UserPrincipalName: '$($sampleAccount.UserPrincipalName)'" -ForegroundColor Cyan
        Write-Host "  EmployeeId: '$($sampleAccount.EmployeeId)'" -ForegroundColor Cyan
        Write-Host "  Id: '$($sampleAccount.Id)'" -ForegroundColor Cyan

        Write-Host "Successfully retrieved $($primaryAccounts.Count) primary accounts using advanced filter"
        return $primaryAccounts
    }
    catch {
        Write-Host "Failed to get primary accounts using advanced filter: $($_.Exception.Message)"
        Write-Host "Falling back to alternative method..."
        
        # Alternative approach - get all users and filter client-side
        try {
            Write-Host "Getting all users..."
            # Get all users and filter client-side
            Write-Host "Getting all users with Get-MgUser..."
            $allUsers = Get-MgUser -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
            Write-Host "Retrieved $($allUsers.Count) total users"
            
            Write-Host "Filtering out admin accounts..."
            $primaryAccounts = $allUsers | Where-Object { 
                -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*')
            }
            
            Write-Host "Successfully found $($primaryAccounts.Count) primary accounts using alternative method"
            return $primaryAccounts
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Host "Error getting primary accounts using alternative method: $errorMessage"
            Write-Host "No primary accounts could be retrieved. Returning empty array."
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
        Write-Host "  Getting AdminEmployeeId for account: $adminUPN"
        
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
        
        Write-Host "  No AdminEmployeeId found for account: $adminUPN"
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
    
    $adminUPN = $AdminAccount.UserPrincipalName
    Write-Host "Processing admin account: $adminUPN" -ForegroundColor Yellow
    
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
    
    # Get the AdminEmployeeId from the admin account
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $AdminAccount
    
    # First try to match by normalized UPN since this is more reliable
    if ($normalizedUPN) {
        try {
            # Use exact UPN match
            $filter = "userPrincipalName eq '$normalizedUPN'"
            Write-Host "  Looking for primary account with UPN filter: $filter" -ForegroundColor Yellow
            
            $upnMatches = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
            
            if ($upnMatches) {
                Write-Host "  Found primary account with matching UPN: $($upnMatches.UserPrincipalName)" -ForegroundColor Green
                return $upnMatches
            } else {
                Write-Host "  No primary account found with UPN: $normalizedUPN" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Error searching for primary account by UPN: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Then try to match by employeeId if available
    if ($adminEmployeeId) {
        Write-Host "  Admin account employeeId: $adminEmployeeId" -ForegroundColor Yellow
        
        try {
            # Use direct Graph API query with simple filter
            $filter = "employeeId eq '$adminEmployeeId'"
            Write-Host "  Searching for primary account with filter: $filter" -ForegroundColor Yellow
            
            $employeeIdMatches = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
            
            if ($employeeIdMatches) {
                # Check if this is an admin account
                if (-not ($employeeIdMatches.UserPrincipalName -like 'adm.*') -and -not ($employeeIdMatches.UserPrincipalName -like 'ext.adm.*')) {
                    Write-Host "  Found primary account with matching employeeId: $($employeeIdMatches.UserPrincipalName)" -ForegroundColor Green
                    return $employeeIdMatches
                } else {
                    Write-Host "  Found account with matching employeeId but it's an admin account: $($employeeIdMatches.UserPrincipalName)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  No primary account found with employeeId: $adminEmployeeId" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Error searching for primary account by employeeId: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        # If direct query failed, try getting all users with this employeeId and filter client-side
        try {
            Write-Host "  Trying alternative approach to find primary account..." -ForegroundColor Yellow
            
            # Get all users with this employeeId
            $allUsers = Get-MgUser -All -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
            
            # Filter for matching employeeId and non-admin accounts
            $matchingUsers = $allUsers | Where-Object { 
                $_.EmployeeId -eq $adminEmployeeId -and 
                -not ($_.UserPrincipalName -like 'adm.*') -and 
                -not ($_.UserPrincipalName -like 'ext.adm.*')
            }
            
            if ($matchingUsers -and $matchingUsers.Count -gt 0) {
                $matchedUser = $matchingUsers[0]
                Write-Host "  Found primary account using alternative method: $($matchedUser.UserPrincipalName)" -ForegroundColor Green
                return $matchedUser
            } else {
                Write-Host "  No primary account found using alternative method" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Error in alternative approach: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  No AdminEmployeeId found for admin account: $adminUPN" -ForegroundColor Yellow
    }
    
    # No matching primary account found using any method
    Write-Host "  No matching primary account found using any method" -ForegroundColor Red
    return $null
}

# Create output array
$results = @()

# Set encoding to UTF-8 for proper Unicode support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
$connected = Connect-ToMgGraph -CertificateThumbprint $CertificateThumbprint
if (-not $connected) {
    Write-Error "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Regular processing mode
if ($DryRun) {
    Write-Host "[WARNING] RUNNING IN DRY RUN MODE - No accounts will be deleted" -ForegroundColor Yellow
}

# Get all admin accounts
$adminAccounts = Get-AdminAccounts

if ($adminAccounts.Count -eq 0) {
    Write-Host "No admin accounts found. Exiting script." -ForegroundColor Yellow
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
    Write-Host "Processing admin account: $adminUPN"
    
    # Skip on-premises synced accounts
    if ($adminAccount.OnPremisesSyncEnabled -eq $true) {
        Write-Host "  Account is on-premises synced. Skipping."
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
    
    # Debug the returned primary account
    if ($primaryAccount) {
        Write-Host "  DEBUG: Returned primary account:" -ForegroundColor Magenta
        Write-Host "    Type: $($primaryAccount.GetType().FullName)" -ForegroundColor Magenta
        Write-Host "    UserPrincipalName: '$($primaryAccount.UserPrincipalName)'" -ForegroundColor Magenta
        Write-Host "    DisplayName: '$($primaryAccount.DisplayName)'" -ForegroundColor Magenta
        Write-Host "    EmployeeId: '$($primaryAccount.EmployeeId)'" -ForegroundColor Magenta
        
        # Check if the primary account has a valid UserPrincipalName
        if (-not [string]::IsNullOrEmpty($primaryAccount.UserPrincipalName)) {
            # Admin account has a matching primary account, don't delete
            Write-Host "  Admin account has a matching primary account: $($primaryAccount.UserPrincipalName)" -ForegroundColor Green
            $skippedCount++
            
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                Action = "Skipped"
                Reason = "Has matching primary account"
                HasMatchingPrimaryAccount = "Yes"
                PrimaryAccountUPN = $primaryAccount.UserPrincipalName
            }
            
            $results += $result
        } else {
            # Primary account object exists but has no UserPrincipalName, treat as no match
            Write-Host "  Found primary account object but it has no valid UserPrincipalName" -ForegroundColor Yellow
            Write-Host "  Admin account doesn't have a matching primary account" -ForegroundColor Red
            
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would delete admin account: $adminUPN" -ForegroundColor Yellow
                $successCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Would be deleted"
                    Reason = "No matching primary account"
                    HasMatchingPrimaryAccount = "No"
                    PrimaryAccountUPN = ""
                }
                
                $results += $result
            } else {
                # Delete the admin account
                try {
                    Remove-MgUser -UserId $adminAccount.Id
                    Write-Host "  Deleted admin account: $adminUPN" -ForegroundColor Red
                    $successCount++
                    
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
                    Write-Host "  Failed to delete admin account: $adminUPN - $($_.Exception.Message)" -ForegroundColor Red
                    $failureCount++
                    
                    $result = [PSCustomObject]@{
                        AdminUPN = $adminUPN
                        Action = "Failed to delete"
                        Reason = "Error: $($_.Exception.Message)"
                        HasMatchingPrimaryAccount = "No"
                        PrimaryAccountUPN = ""
                    }
                    
                    $results += $result
                }
            }
        }
    }
    else {
        # Admin account doesn't have a matching primary account, delete it
        Write-Host "  Admin account doesn't have a matching primary account" -ForegroundColor Red
        
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would delete admin account: $adminUPN" -ForegroundColor Yellow
            $successCount++
            
            # Send notification (test phase)
            #Send-AdminAccountNotification -Recipient "hans.christian.andersen@stark.dk" -AdminUPN $adminUPN -Action "Would be deleted" -Reason "No matching primary account"
            
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
                Remove-MgUser -UserId $adminAccount.Id
                Write-Host "  Deleted admin account: $adminUPN" -ForegroundColor Red
                $successCount++
                
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
                Write-Host "  Failed to delete admin account: $adminUPN - $($_.Exception.Message)" -ForegroundColor Red
                $failureCount++
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    Action = "Failed to delete"
                    Reason = "Error: $($_.Exception.Message)"
                    HasMatchingPrimaryAccount = "No"
                    PrimaryAccountUPN = ""
                }
                
                $results += $result
            }
        }
    }
}

# Display summary
Write-Host "`n----------------------------------------"
Write-Host "Summary:" -ForegroundColor Cyan -BackgroundColor DarkBlue
if ($DryRun) {
    Write-Host "[DRY RUN MODE] No accounts were actually deleted" -ForegroundColor Yellow
    Write-Host "Would delete: $successCount admin accounts" -ForegroundColor Yellow
}
else {
    Write-Host "[LIVE MODE] Accounts were deleted" -ForegroundColor Green
    Write-Host "Deleted: $successCount admin accounts" -ForegroundColor Green
}

Write-Host "Skipped: $skippedCount admin accounts" -ForegroundColor Cyan
Write-Host "Failed: $failureCount admin accounts" -ForegroundColor $(if ($failureCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "----------------------------------------"

# Export results to CSV and output them
Write-Host "`nDetailed Results:"
$results | ForEach-Object {
    Write-Host "----------------------------------------"
    Write-Host "Admin Account: $($_.AdminUPN)"
    Write-Host "Action: $($_.Action)"
    Write-Host "Reason: $($_.Reason)"
    Write-Host "Has Matching Normal Account: $($_.HasMatchingNormalAccount)"
    if ($_.NormalAccountUPN) {
        Write-Host "Normal Account: $($_.NormalAccountUPN)"
    }
}
Write-Host "----------------------------------------"

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
