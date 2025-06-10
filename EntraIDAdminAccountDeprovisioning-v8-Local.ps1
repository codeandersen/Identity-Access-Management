#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Beta.Users

param(
    [Parameter(Mandatory = $false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$NotificationRecipient = "hans.christian.andersen@stark.dk",
    
    [Parameter(Mandatory = $false)]
    [switch]$DebugMode = $false
)

<#
.SYNOPSIS
    Identifies and deprovisions admin accounts without corresponding standard accounts.
.DESCRIPTION
    This script finds all admin accounts (with "adm." or "ext.adm." in the UPN), identifies their 
    corresponding standard accounts using the employeeID attribute, and deletes admin accounts if the standard accounts don't exist.
    
    The script is designed to run in Azure Automation and requires the following automation variables:
    - clientId: The Azure AD application ID.
    - tenantId: The Azure AD tenant ID.
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

# Set up variables - prioritize script parameters over automation variables

# If running in Azure Automation, get variables from there
if ($PSPrivateMetadata.JobId) {
    try {
        # Get required variables from Automation Account
        $clientId = Get-AutomationVariable -Name 'clientId'
        $tenantId = Get-AutomationVariable -Name 'tenantId'
        $CertificateThumbprint = Get-AutomationVariable -Name 'certificateThumbprint'
        $dryrunValue = Get-AutomationVariable -Name 'dryrun'
        $NotificationRecipient = Get-AutomationVariable -Name 'NotificationRecipient'
        $responsible = Get-AutomationVariable -Name 'Responsible'
        
        # Handle different types for dryrun value from automation
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
        
    } catch {
        Write-Error "Failed to get required variables from Automation Account: $_"
        throw "Missing required Automation Account variables. Please ensure clientId, tenantId, and dryrun are set."
    }
} else {
    # Running locally - use hardcoded values or script parameters
    $clientId = "71f6c44e-27e3-43ca-b395-630bc43f87ae"
    $tenantId = "2e114308-14ec-4d77-b610-490324fa1844"
    $CertificateThumbprint = "00d0850a07735ea7ce2fd7339213b89e9a0c2757"
    $NotificationRecipient = "hans.christian.andersen@stark.dk"
    $responsible = "boon.oestergaard@stark.dk"
    
    
    # Set debug mode from parameter
    $debugMode = $DebugMode.IsPresent
}

# Display configuration information
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  ClientId and TenantId set" -ForegroundColor Cyan
Write-Host "  DryRun mode: $(if ($DryRun) { '`$true - No accounts will be deleted' } else { '`$false - Accounts will be deleted' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' })
Write-Host "  Notification recipient: $NotificationRecipient" -ForegroundColor Cyan
if ($debugMode) {
    Write-Host "  Debug mode: Enabled - Detailed logging will be shown" -ForegroundColor Cyan
}


# Extension attribute names
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"
$adminManagerMailExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminManagerMail"

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
        [string]$Recipient,
        [Parameter(Mandatory = $true)]
        [string]$AdminUPN,
        [Parameter(Mandatory = $true)]
        [string]$Action, # 'Would be deleted' or 'Deleted'
        [Parameter(Mandatory = $false)]
        [string]$Reason
    )
    

    # Compose subject and body based on whether this is a dry run or production
    if ($DryRun) {
        $subject = "Action needed - Admin Account will be deleted"
        $bodyContent = "<span style='background-color: yellow; color: red;'>This is a dry run before the actual go-live on 1 July. Please take action to prevent unintentional deletion of below admin account.</span><br><br>"
        $bodyContent += "Account name: $AdminUPN<br><br>"
        $bodyContent += "Please make sure the following:<br>"
        $bodyContent += "- Standard account is active<br>"
        $bodyContent += "- Unique employee ID is entered in standard account<br><br>"
        $bodyContent += "If you are receiving this in error, please reach out to $responsible <br><br>"
        $bodyContent += "Reference: EntraIDAdminAccountDeprovisioning script"
    } else {
        $subject = "Admin Account deleted"
        $bodyContent = "This is an automated notification from the EntraIDAdminAccountDeprovisioning script.<br><br>"
        $bodyContent += "The following cloud admin account have been deleted.<br><br>"
        $bodyContent += "Account name: $AdminUPN<br>"
        $bodyContent += "Reference: EntraIDAdminAccountDeprovisioning script"
    }

    # Log the notification to console
    Write-Host "" -ForegroundColor Cyan
    Write-Host "  ---- EMAIL NOTIFICATION ----" -ForegroundColor Cyan
    Write-Host "  To: $Recipient" -ForegroundColor Cyan
    Write-Host "  Subject: $subject" -ForegroundColor Cyan
    Write-Host "  Body: $bodyContent" -ForegroundColor Cyan
    Write-Host "  ---- END NOTIFICATION ----" -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Cyan
    
    #While testing
    $Recipient = $NotificationRecipient
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
        if ($debugMode) {
            Write-Host "Filter: $filter" -ForegroundColor Cyan
        }
        
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
        if ($debugMode) {
            Write-Host "Attempting to get primary accounts using advanced filter..." -ForegroundColor Cyan
        }
        $filter = "not(startsWith(userPrincipalName, 'adm.')) and not(startsWith(userPrincipalName, 'ext.adm.'))"
        if ($debugMode) {
            Write-Host "Filter: $filter" -ForegroundColor Cyan
        }
       
        $primaryAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All -ConsistencyLevel "eventual" -Count userCount -ErrorAction Stop
        
        # Verify that the accounts have the required properties
        $sampleAccount = $primaryAccounts | Select-Object -First 1
        if ($debugMode) {
            Write-Host "Sample primary account properties:" -ForegroundColor Cyan
            Write-Host "  UserPrincipalName: '$($sampleAccount.UserPrincipalName)'" -ForegroundColor Cyan
            Write-Host "  EmployeeId: '$($sampleAccount.EmployeeId)'" -ForegroundColor Cyan
            Write-Host "  Id: '$($sampleAccount.Id)'" -ForegroundColor Cyan
        }

        Write-Host "Successfully retrieved $($primaryAccounts.Count) primary accounts using advanced filter" -ForegroundColor Green
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
            
            Write-Host "Successfully found $($primaryAccounts.Count) primary accounts using alternative method" -ForegroundColor Green
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
        if ($debugMode) {
            Write-Host "  Getting AdminEmployeeId for account: $adminUPN"
        }
        
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
        
        if ($debugMode) {
            Write-Host "  No AdminEmployeeId found for account: $adminUPN"
        }
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "  Error getting AdminEmployeeId for account '$adminUPN': $errorMessage" -ForegroundColor Red
        return $null
    }
}

# Function to get the AdminManagerMail from an admin account
function Get-AdminManagerMail {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AdminAccount
    )
    
    $adminUPN = $AdminAccount.UserPrincipalName
    
    try {
        if ($debugMode) {
            Write-Host "  Getting AdminManagerMail for account: $adminUPN"
        }
        
        # Use beta endpoint to get extension attributes
        $apiUrl = "beta/users/$adminUPN"
        $userData = Invoke-MgGraphRequest -Method GET -Uri $apiUrl
        
        # Check if the extension attribute exists directly
        if ($userData -and $userData.$adminManagerMailExtension) {
            return $userData.$adminManagerMailExtension
        }
        
        # If not found directly, check in the extension attributes collection
        if ($userData.extensions) {
            foreach ($extension in $userData.extensions) {
                if ($extension.ContainsKey($adminManagerMailExtension)) {
                    return $extension.$adminManagerMailExtension
                }
            }
        }
        
        if ($debugMode) {
            Write-Host "  No AdminManagerMail found for account: $adminUPN"
        }
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "  Error getting AdminManagerMail for account '$adminUPN': $errorMessage" -ForegroundColor Red
        return $null
    }
}

# Global variable to cache all users
$Global:AllUsersCache = $null

# Function to get all users and cache them
function Get-AllUsersCache {
    # Check if the cache is already populated
    if ($null -ne $Global:AllUsersCache -and $Global:AllUsersCache.Count -gt 0) {
        return $Global:AllUsersCache
    }
    
    # Cache is not populated, retrieve all users
    Write-Host "Retrieving and caching all users from Microsoft Graph..." -ForegroundColor Cyan
    try {
        $Global:AllUsersCache = Get-MgUser -All -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
        if ($debugMode) {
            Write-Host "Successfully cached $($Global:AllUsersCache.Count) users" -ForegroundColor Green
        } else {
            Write-Host "Users cached successfully" -ForegroundColor Green
        }
    } catch {
        Write-Error "Error retrieving all users: $_"
        $Global:AllUsersCache = @()
    }
    
    return $Global:AllUsersCache
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
    if ($debugMode) {
        Write-Host "Processing admin account: $adminUPN" -ForegroundColor Yellow
    }
    
    # Extract the normalized UPN from the admin UPN
    $normalizedUPN = $null
    
    # For pattern like ext.username@domain.com
    if ($adminUPN -match '^ext\.(.*?)@(.*)$') {
        # Pattern: ext.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        if ($debugMode) {
            Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
        }
    }
    # For pattern like ext.adm.username@domain.com
    elseif ($adminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
        # Pattern: ext.adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        if ($debugMode) {
            Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
        }
    }
    # For pattern like adm.username@domain.com
    elseif ($adminUPN -match '^adm\.(.*?)@(.*)$') {
        # Pattern: adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        if ($debugMode) {
            Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
        }
    }
    
    # Get the AdminEmployeeId from the admin account
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $AdminAccount
    
    # First try to match by employeeId using the alternative approach (client-side filtering)
    if ($adminEmployeeId) {
        if ($debugMode) {
            Write-Host "  Admin account employeeId: $adminEmployeeId" -ForegroundColor Yellow
        }
        
        # Use the alternative approach with client-side filtering as the primary method
        try {
            if ($debugMode) {
                Write-Host "  Using client-side filtering to find primary account..." -ForegroundColor Yellow
            }
            
            # Get all users from cache
            $allUsers = Get-AllUsersCache
            
            if ($null -ne $allUsers) {
                # Normalize the admin employee ID (trim spaces)
                $normalizedAdminEmployeeId = $adminEmployeeId.Trim()
                
                # Find users with matching employee ID using simple string comparison
                $usersWithEmployeeId = @()
                foreach ($user in $allUsers) {
                    if ($null -ne $user.EmployeeId -and $user.EmployeeId.ToString().Trim() -eq $normalizedAdminEmployeeId) {
                        $usersWithEmployeeId += $user
                    }
                }
                
                if ($debugMode) {
                    Write-Host "  DEBUG: Found $($usersWithEmployeeId.Count) users with employeeId '$normalizedAdminEmployeeId'" -ForegroundColor Magenta
                } else {
                    # Minimal output for production use
                    if ($usersWithEmployeeId.Count -gt 0) {
                        Write-Host "  Found $($usersWithEmployeeId.Count) users with matching employeeId" -ForegroundColor Cyan
                    }
                }
                
                if ($usersWithEmployeeId.Count -gt 0) {
                    # Get the first matching user
                    $firstMatch = $usersWithEmployeeId[0]
                    
                    # Log basic info about the match only in debug mode
                    if ($debugMode) {
                        Write-Host "  DEBUG: First matching user by employeeId:" -ForegroundColor Magenta
                        
                        # Only try to access properties if the object is not null
                        if ($null -ne $firstMatch) {
                            Write-Host "    UserPrincipalName: '$($firstMatch.UserPrincipalName)'" -ForegroundColor Magenta
                            Write-Host "    DisplayName: '$($firstMatch.DisplayName)'" -ForegroundColor Magenta
                            Write-Host "    EmployeeId: '$($firstMatch.EmployeeId)'" -ForegroundColor Magenta
                        } else {
                            Write-Host "    Object is null" -ForegroundColor Red
                        }
                    }
                    
                    # Find primary accounts (non-admin) among the matching users
                    $primaryMatches = @()
                    foreach ($user in $usersWithEmployeeId) {
                        if ($null -ne $user -and $null -ne $user.UserPrincipalName) {
                            $upn = $user.UserPrincipalName.ToString()
                            if (-not [string]::IsNullOrWhiteSpace($upn) -and
                                -not ($upn -like 'adm.*') -and
                                -not ($upn -like 'ext.adm.*')) {
                                $primaryMatches += $user
                            }
                        }
                    }
                    
                    if ($primaryMatches.Count -gt 0) {
                        $primaryAccount = $primaryMatches[0]
                        $upn = $primaryAccount.UserPrincipalName.ToString()
                        
                        Write-Host "  Found primary account match by employeeId: $upn, $($primaryAccount.EmployeeId)" -ForegroundColor Green
                        
                        if ($debugMode) {
                            Write-Host "  DEBUG: Primary account details:" -ForegroundColor Green
                            Write-Host "    UserPrincipalName: '$upn'" -ForegroundColor Green
                            
                            if ($null -ne $primaryAccount.DisplayName) {
                                Write-Host "    DisplayName: '$($primaryAccount.DisplayName)'" -ForegroundColor Green
                            }
                            
                            if ($null -ne $primaryAccount.EmployeeId) {
                                Write-Host "    EmployeeId: '$($primaryAccount.EmployeeId)'" -ForegroundColor Green
                            }
                        }
                        
                        return $primaryAccount
                    }
                }
                
                # Normalize the admin employee ID (trim spaces)
                $normalizedAdminEmployeeId = $adminEmployeeId.Trim()
                
                # Filter for matching employeeId and non-admin accounts with more flexible matching
                $matchingUsers = $allUsers | Where-Object { 
                    $null -ne $_.EmployeeId -and 
                    ($_.EmployeeId.Trim() -eq $normalizedAdminEmployeeId) -and 
                    $null -ne $_.UserPrincipalName -and
                    -not ($_.UserPrincipalName -like 'adm.*') -and 
                    -not ($_.UserPrincipalName -like 'ext.adm.*')
                }
                
                # If no matches found, try a more flexible approach with the normalized UPN
                if (-not $matchingUsers -or $matchingUsers.Count -eq 0) {
                    if ($debugMode) {
                        Write-Host "  No exact employeeId matches found, trying flexible matching..." -ForegroundColor Yellow
                    }
                    
                    if ($normalizedUPN) {
                        # Extract username part for more flexible matching
                        $upnParts = $normalizedUPN -split '@'
                        if ($upnParts.Count -eq 2) {
                            $username = $upnParts[0]
                            
                            # Try to find accounts with similar username patterns
                            $matchingUsers = $allUsers | Where-Object {
                                $null -ne $_.UserPrincipalName -and
                                $_.UserPrincipalName -like "$username@*" -and
                                -not ($_.UserPrincipalName -like 'adm.*') -and 
                                -not ($_.UserPrincipalName -like 'ext.adm.*')
                            }
                            
                            if ($matchingUsers -and $matchingUsers.Count -gt 0) {
                                if ($debugMode) {
                                    Write-Host "  Found $($matchingUsers.Count) potential matches using flexible username matching" -ForegroundColor Yellow
                                }
                            }
                        }
                    }
                }
                
                if ($matchingUsers -and $matchingUsers.Count -gt 0) {
                    $matchedUser = $matchingUsers[0]
                    
                    # Verify that the matched user has valid properties
                    if ($null -ne $matchedUser.UserPrincipalName -and $matchedUser.UserPrincipalName -ne '') {
                        Write-Host "  Found primary account using client-side filtering: $($matchedUser.UserPrincipalName)" -ForegroundColor Green
                        
                        # Debug the matched account properties
                        Write-Host "  DEBUG: Returned primary account:" -ForegroundColor Magenta
                        Write-Host "    Type: $($matchedUser.GetType().FullName)" -ForegroundColor Magenta
                        Write-Host "    UserPrincipalName: '$($matchedUser.UserPrincipalName)'" -ForegroundColor Magenta
                        Write-Host "    DisplayName: '$($matchedUser.DisplayName)'" -ForegroundColor Magenta
                        Write-Host "    EmployeeId: '$($matchedUser.EmployeeId)'" -ForegroundColor Magenta
                        
                        return $matchedUser
                    }
                } else {
                    if ($debugMode) {
                        Write-Host "  No primary account found using client-side filtering" -ForegroundColor Yellow
                    }
                }
            } else {
                Write-Host "  Failed to get cached users list" -ForegroundColor Red
            }
        } catch {
            if ($debugMode) {
                Write-Host "  Error in client-side filtering approach: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } else {
        if ($debugMode) {
            Write-Host "  No AdminEmployeeId found for admin account: $adminUPN" -ForegroundColor Yellow
        }
    }
    
    # Fallback to UPN matching if no match by employeeId
    if ($normalizedUPN) {
        try {
            if ($debugMode) {
                Write-Host "  Looking for primary account with UPN: $normalizedUPN" -ForegroundColor Yellow
            }
            
            # Get all users from cache
            $allUsers = Get-AllUsersCache
            
            if ($null -ne $allUsers) {
                # Extract username and domain parts for more flexible matching
                $upnParts = $normalizedUPN -split '@'
                if ($upnParts.Count -eq 2) {
                    $username = $upnParts[0]
                    $domain = $upnParts[1]
                    
                    # Direct string comparison for UPN matching
                    $lowerNormalizedUPN = $normalizedUPN.ToLower()
                    $lowerUsername = $username.ToLower()
                    $lowerDomain = $domain.ToLower()
                    
                    # Find users with similar UPN using simple string comparison
                    $similarUpnUsers = @()
                    foreach ($user in $allUsers) {
                        if ($null -ne $user -and $null -ne $user.UserPrincipalName) {
                            $upn = $user.UserPrincipalName.ToString().ToLower()
                            if ($upn -eq $lowerNormalizedUPN -or
                                $upn -eq "$lowerUsername@$lowerDomain") {
                                $similarUpnUsers += $user
                            }
                        }
                    }
                } else {
                    # Fallback for unexpected UPN format
                    $similarUpnUsers = @()
                    foreach ($user in $allUsers) {
                        if ($null -ne $user -and $null -ne $user.UserPrincipalName) {
                            if ($user.UserPrincipalName.ToString().ToLower() -eq $normalizedUPN.ToLower()) {
                                $similarUpnUsers += $user
                            }
                        }
                    }
                }
                if ($debugMode) {
                    Write-Host "  DEBUG: Found $($similarUpnUsers.Count) users with similar UPN to '$normalizedUPN'" -ForegroundColor Magenta
                }
                
                if ($similarUpnUsers.Count -gt 0) {
                    if ($debugMode) {
                        Write-Host "  DEBUG: Top 3 similar UPN matches:" -ForegroundColor Magenta
                        $topMatches = $similarUpnUsers | Select-Object -First 3
                        foreach ($match in $topMatches) {
                            Write-Host "    UPN: '$($match.UserPrincipalName)', EmployeeId: '$($match.EmployeeId)'" -ForegroundColor Magenta
                        }
                    }
                    
                    # Find primary accounts (non-admin) among the matching users
                    $primaryMatches = @()
                    foreach ($user in $similarUpnUsers) {
                        if ($null -ne $user -and $null -ne $user.UserPrincipalName) {
                            $upn = $user.UserPrincipalName.ToString()
                            if (-not [string]::IsNullOrWhiteSpace($upn) -and
                                -not ($upn -like 'adm.*') -and
                                -not ($upn -like 'ext.adm.*')) {
                                $primaryMatches += $user
                            }
                        }
                    }
                    
                    if ($primaryMatches.Count -gt 0) {
                        $primaryAccount = $primaryMatches[0]
                        $upn = $primaryAccount.UserPrincipalName.ToString()
                        
                        Write-Host "  Found primary account match by UPN: $upn" -ForegroundColor Green
                        
                        if ($debugMode) {
                            Write-Host "  DEBUG: Primary account details:" -ForegroundColor Green
                            Write-Host "    UserPrincipalName: '$upn'" -ForegroundColor Green
                            
                            if ($null -ne $primaryAccount.DisplayName) {
                                Write-Host "    DisplayName: '$($primaryAccount.DisplayName)'" -ForegroundColor Green
                            }
                            
                            if ($null -ne $primaryAccount.EmployeeId) {
                                Write-Host "    EmployeeId: '$($primaryAccount.EmployeeId)'" -ForegroundColor Green
                            }
                        }
                        
                        return $primaryAccount
                    }
                }
                
                # Extract username and domain parts for more flexible matching
                $upnParts = $normalizedUPN -split '@'
                if ($upnParts.Count -eq 2) {
                    $username = $upnParts[0]
                    $domain = $upnParts[1]
                    
                    # Filter for matching UPN (case-insensitive) and non-admin accounts
                    $upnMatches = $allUsers | Where-Object { 
                        $null -ne $_.UserPrincipalName -and
                        ($_.UserPrincipalName -ieq $normalizedUPN -or
                         # Try matching username and domain separately to handle case differences
                         ($_.UserPrincipalName -imatch "^$username@.*$domain$" -or
                          $_.UserPrincipalName -imatch "^$username@$domain$")) -and
                        -not ($_.UserPrincipalName -like 'adm.*') -and 
                        -not ($_.UserPrincipalName -like 'ext.adm.*')
                    }
                } else {
                    # Fallback to exact matching if UPN format is unexpected
                    $upnMatches = $allUsers | Where-Object { 
                        $null -ne $_.UserPrincipalName -and
                        $_.UserPrincipalName -ieq $normalizedUPN -and
                        -not ($_.UserPrincipalName -like 'adm.*') -and 
                        -not ($_.UserPrincipalName -like 'ext.adm.*')
                    }
                }
                
                # If no exact matches found, try a more flexible approach
                if (-not $upnMatches -or $upnMatches.Count -eq 0) {
                    if ($debugMode) {
                        Write-Host "  No exact UPN matches found, trying flexible matching..." -ForegroundColor Yellow
                    }
                    
                    # Extract username part for more flexible matching
                    $upnParts = $normalizedUPN -split '@'
                    if ($upnParts.Count -eq 2) {
                        $username = $upnParts[0]
                        
                        # Try to find accounts with similar username patterns
                        $upnMatches = $allUsers | Where-Object {
                            $null -ne $_.UserPrincipalName -and
                            $_.UserPrincipalName -like "$username@*" -and
                            -not ($_.UserPrincipalName -like 'adm.*') -and 
                            -not ($_.UserPrincipalName -like 'ext.adm.*')
                        }
                        
                        if ($upnMatches -and $upnMatches.Count -gt 0) {
                            if ($debugMode) {
                                Write-Host "  Found $($upnMatches.Count) potential matches using flexible username matching" -ForegroundColor Yellow
                            }
                        }
                    }
                }
                
                if ($upnMatches -and $upnMatches.Count -gt 0) {
                    $matchedUser = $upnMatches[0]
                    
                    # Verify that the matched user has valid properties
                    if ($null -ne $matchedUser.UserPrincipalName -and $matchedUser.UserPrincipalName -ne '') {
                        Write-Host "  Found primary account with matching UPN: $($matchedUser.UserPrincipalName)" -ForegroundColor Green
                        
                        # Debug the matched account properties
                        Write-Host "  DEBUG: Returned primary account:" -ForegroundColor Magenta
                        Write-Host "    Type: $($matchedUser.GetType().FullName)" -ForegroundColor Magenta
                        Write-Host "    UserPrincipalName: '$($matchedUser.UserPrincipalName)'" -ForegroundColor Magenta
                        Write-Host "    DisplayName: '$($matchedUser.DisplayName)'" -ForegroundColor Magenta
                        Write-Host "    EmployeeId: '$($matchedUser.EmployeeId)'" -ForegroundColor Magenta
                        
                        return $matchedUser
                    }
                } else {
                    if ($debugMode) {
                        Write-Host "  No primary account found with UPN: $normalizedUPN" -ForegroundColor Yellow
                    }
                }
            } else {
                # Fallback to direct API call if cache failed
                $filter = "userPrincipalName eq '$normalizedUPN'"
                if ($debugMode) {
                    Write-Host "  Cache failed, using direct API call with filter: $filter" -ForegroundColor Yellow
                }
                
                $upnMatches = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
                
                if ($upnMatches) {
                    Write-Host "  Found primary account with matching UPN: $($upnMatches.UserPrincipalName)" -ForegroundColor Green
                    
                    # Debug the matched account properties
                    Write-Host "  DEBUG: Returned primary account:" -ForegroundColor Magenta
                    Write-Host "    Type: $($upnMatches.GetType().FullName)" -ForegroundColor Magenta
                    Write-Host "    UserPrincipalName: '$($upnMatches.UserPrincipalName)'" -ForegroundColor Magenta
                    Write-Host "    DisplayName: '$($upnMatches.DisplayName)'" -ForegroundColor Magenta
                    Write-Host "    EmployeeId: '$($upnMatches.EmployeeId)'" -ForegroundColor Magenta
                    
                    return $upnMatches
                } else {
                    if ($debugMode) {
                        Write-Host "  No primary account found with UPN: $normalizedUPN" -ForegroundColor Yellow
                    }
                }
            }
        } catch {
            if ($debugMode) {
                Write-Host "  Error searching for primary account by UPN: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # If we get here, no matching primary account was found
    if ($debugMode) {
        Write-Host "  No matching primary account found using any method" -ForegroundColor Red
    }
    Write-Host "  Admin account doesn't have a matching primary account" -ForegroundColor Red
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

# Initialize the user cache before processing admin accounts
Write-Host "Initializing user cache..." -ForegroundColor Cyan
$allUsersCache = Get-AllUsersCache

# Debug: Show some sample users from the cache to verify data
if ($debugMode) {
    Write-Host "Sample users from cache:" -ForegroundColor Cyan
    $sampleUsers = $Global:AllUsersCache | Select-Object -First 5
    foreach ($user in $sampleUsers) {
        Write-Host "  UserPrincipalName: '$($user.UserPrincipalName)', EmployeeId: '$($user.EmployeeId)'" -ForegroundColor Cyan
    }
}

# Get all primary accounts for bulk processing (this will be used as a fallback)
$primaryAccounts = Get-PrimaryAccounts

# Process each admin account
$successCount = 0
$failureCount = 0
$skippedCount = 0

foreach ($adminAccount in $adminAccounts) {
    $adminUPN = $adminAccount.UserPrincipalName
    # Get the AdminEmployeeId for this admin account
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $adminAccount
    Write-Host "Processing admin account: $adminUPN, $adminEmployeeId"
    
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
        if ($debugMode) {
            Write-Host "  DEBUG: Returned primary account:" -ForegroundColor Magenta
            Write-Host "    Type: $($primaryAccount.GetType().FullName)" -ForegroundColor Magenta
            Write-Host "    UserPrincipalName: '$($primaryAccount.UserPrincipalName)'" -ForegroundColor Magenta
            Write-Host "    DisplayName: '$($primaryAccount.DisplayName)'" -ForegroundColor Magenta
            Write-Host "    EmployeeId: '$($primaryAccount.EmployeeId)'" -ForegroundColor Magenta
        }
        
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
                
                # Get admin manager email from extension attribute
                $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
                
                # Use admin manager email if available, otherwise use the default notification recipient
                $emailRecipient = if (-not [string]::IsNullOrWhiteSpace($adminManagerMail)) { $adminManagerMail } else { $NotificationRecipient }
                
                
                # Send notification
                #Send-AdminAccountNotification -Recipient $emailRecipient -AdminUPN $adminUPN -Action "Would be deleted" -Reason "No matching primary account"
               
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
                    
                    # Get admin manager email from extension attribute
                    $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
                    
                    # Use admin manager email if available, otherwise use the default notification recipient
                    $emailRecipient = if (-not [string]::IsNullOrWhiteSpace($adminManagerMail)) { $adminManagerMail } else { $NotificationRecipient }
                    
                    # Send notification
                    #Send-AdminAccountNotification -Recipient $emailRecipient -AdminUPN $adminUPN -Action "Deleted" -Reason "No matching primary account"
                    
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
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would delete admin account: $adminUPN" -ForegroundColor Yellow
            $successCount++
            
            # Get admin manager email from extension attribute
            $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
            
            # Use admin manager email if available, otherwise use the default notification recipient
            $emailRecipient = if (-not [string]::IsNullOrWhiteSpace($adminManagerMail)) { $adminManagerMail } else { $NotificationRecipient }
            
            # Send notification email even in dry run mode
            #Send-AdminAccountNotification -Recipient $emailRecipient -AdminUPN $adminUPN -Action "Would be deleted" -Reason "No matching primary account"
            
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
                
                # Get admin manager email from extension attribute
                $adminManagerMail = Get-AdminManagerMail -AdminAccount $adminAccount
                
                # Use admin manager email if available, otherwise use the default notification recipient
                $emailRecipient = if (-not [string]::IsNullOrWhiteSpace($adminManagerMail)) { $adminManagerMail } else { $NotificationRecipient }
                
                # Send notification
                #Send-AdminAccountNotification -Recipient $emailRecipient -AdminUPN $adminUPN -Action "Deleted" -Reason "No matching primary account"
                
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
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = "./EntraIDAdminAccountDeprovisioning-$timestamp.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`nResults exported to: $csvPath" -ForegroundColor Green

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
