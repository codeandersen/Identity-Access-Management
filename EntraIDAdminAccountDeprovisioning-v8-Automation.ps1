#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Beta.Users

param(
    [Parameter(Mandatory = $false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$NotificationRecipient = "",
    
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
} 

# Display configuration information
Write-Output "Configuration:" 
Write-Output "  ClientId and TenantId set" 
Write-Output "  DryRun mode: $(if ($DryRun) { '`$true - No accounts will be deleted' } else { '`$false - Accounts will be deleted' })" 
Write-Output "  Notification recipient: $NotificationRecipient" 


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
                Write-Output "Connected to Microsoft Graph using service principal and certificate" 
                return $true
            }
            catch {
                Write-Output "Certificate authentication failed: $($_.Exception.Message)" 
                Write-Output "Falling back to interactive authentication..." 
                # Fall through to interactive auth
            }
        }
        
        # Interactive fallback (delegated, requires -Scopes)
        Connect-MgGraph -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        Write-Output "Connected to Microsoft Graph using interactive authentication" 
        return $true
    }
    catch {
        Write-Output "Failed to connect to Microsoft Graph: $_"
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
        Write-Output "Error disconnecting from Microsoft Graph: $_"
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
    Write-Output "" 
    Write-Output "  ---- EMAIL NOTIFICATION ----" 
    Write-Output "  To: $Recipient" 
    Write-Output "  Subject: $subject" 
    Write-Output "  Body: $bodyContent" 
    Write-Output "  ---- END NOTIFICATION ----" 
    Write-Output "" 
    
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
            Write-Output "  Notification sent for $AdminUPN ($Action) to $Recipient" 
        } else {
            Write-Output "  [DRYRUN] Would send notification for $AdminUPN ($Action) to $Recipient" 
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
        
        return $cloudOnlyAdminAccounts
    }
    catch {
        Write-Output "Error getting admin accounts: $_"
        return @()
    }
}

# Function to get all primary accounts
function Get-PrimaryAccounts {
    Write-Output "Getting primary accounts..." 
    
    # First try using the advanced filter with ConsistencyLevel
    try {

        $filter = "not(startsWith(userPrincipalName, 'adm.')) and not(startsWith(userPrincipalName, 'ext.adm.'))"
       
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
        
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Output "  Error getting AdminEmployeeId for account '$adminUPN': $errorMessage" 
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
        
        return $null
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Output "  Error getting AdminManagerMail for account '$adminUPN': $errorMessage" 
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
    Write-Output "Retrieving and caching all users from Microsoft Graph..." 
    try {
        $Global:AllUsersCache = Get-MgUser -All -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop

        Write-Output "Users cached successfully" 
    } catch {
        Write-Output "Error retrieving all users: $_"
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
    {
        # TODO: Implement function logic here
    }
    
    $adminUPN = $AdminAccount.UserPrincipalName
    
    # Extract the normalized UPN from the admin UPN
    $normalizedUPN = $null
    
    # For pattern like ext.username@domain.com
    if ($adminUPN -match '^ext\.(.*?)@(.*)$') {
        # Pattern: ext.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"

    }
    # For pattern like ext.adm.username@domain.com
    elseif ($adminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
        # Pattern: ext.adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"

    }
    # For pattern like adm.username@domain.com
    elseif ($adminUPN -match '^adm\.(.*?)@(.*)$') {
        # Pattern: adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"

    }
    
    # Get the AdminEmployeeId from the admin account
    $adminEmployeeId = Get-AdminEmployeeId -AdminAccount $AdminAccount
    
    # First try to match by employeeId using the alternative approach (client-side filtering)
    if ($adminEmployeeId) {

        
        # Use the alternative approach with client-side filtering as the primary method
        try {
            
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
                
                # Minimal output for production use
                    if ($usersWithEmployeeId.Count -gt 0) {
                        Write-Output "  Found $($usersWithEmployeeId.Count) users with matching employeeId" 
                    }
                
                if ($usersWithEmployeeId.Count -gt 0) {
                    # Get the first matching user
                    $firstMatch = $usersWithEmployeeId[0]
                                      
                    Write-Output "    Object is null"
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
                        
                        Write-Output "  Found primary account match by employeeId: $upn, $($primaryAccount.EmployeeId)" 
                                               
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
                            

                        }
                    }
                }
                
                if ($matchingUsers -and $matchingUsers.Count -gt 0) {
                    $matchedUser = $matchingUsers[0]
                    
                    # Verify that the matched user has valid properties
                    if ($null -ne $matchedUser.UserPrincipalName -and $matchedUser.UserPrincipalName -ne '') {
                        Write-Output "  Found primary account using client-side filtering: $($matchedUser.UserPrincipalName)" 
                        
                        # Debug the matched account properties
                        Write-Output "  DEBUG: Returned primary account:" 
                        Write-Output "    Type: $($matchedUser.GetType().FullName)" 
                        Write-Output "    UserPrincipalName: '$($matchedUser.UserPrincipalName)'"
                        Write-Output "    DisplayName: '$($matchedUser.DisplayName)'"
                        Write-Output "    EmployeeId: '$($matchedUser.EmployeeId)'"
                        
                        return $matchedUser
                    }
                } 
            } else {
                Write-Output "  Failed to get cached users list" 
            }
        } catch {

                Write-Output "  Error in client-side filtering approach: $($_.Exception.Message)" 

        }
    } 
    
    # Fallback to UPN matching if no match by employeeId
    if ($normalizedUPN) {
        try {
            
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
                
                if ($similarUpnUsers.Count -gt 0) {
                    
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
                        
                        Write-Output "  Found primary account match by UPN: $upn" 
                        
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
                        
                    }
                }
                
                if ($upnMatches -and $upnMatches.Count -gt 0) {
                    $matchedUser = $upnMatches[0]
                    
                    # Verify that the matched user has valid properties
                    if ($null -ne $matchedUser.UserPrincipalName -and $matchedUser.UserPrincipalName -ne '') {
                        Write-Output "  Found primary account with matching UPN: $($matchedUser.UserPrincipalName)" 
                        
                        # Debug the matched account properties
                        Write-Output "  DEBUG: Returned primary account:" 
                        Write-Output "    Type: $($matchedUser.GetType().FullName)" 
                        Write-Output "    UserPrincipalName: '$($matchedUser.UserPrincipalName)'"
                        Write-Output "    DisplayName: '$($matchedUser.DisplayName)'"
                        Write-Output "    EmployeeId: '$($matchedUser.EmployeeId)'"
                        
                        return $matchedUser
                    }
                } 
            } else {
                # Fallback to direct API call if cache failed
                $filter = "userPrincipalName eq '$normalizedUPN'"
                
                $upnMatches = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -ErrorAction Stop
                
                if ($upnMatches) {
                    Write-Output "  Found primary account with matching UPN: $($upnMatches.UserPrincipalName)" 
                    
                    # Debug the matched account properties
                    Write-Output "  DEBUG: Returned primary account:" 
                    Write-Output "    Type: $($upnMatches.GetType().FullName)" 
                    Write-Output "    UserPrincipalName: '$($upnMatches.UserPrincipalName)'"
                    Write-Output "    DisplayName: '$($upnMatches.DisplayName)'"
                    Write-Output "    EmployeeId: '$($upnMatches.EmployeeId)'"
                    
                    return $upnMatches
                } 
            }
        } catch {
                Write-Output "  Error searching for primary account by UPN: $($_.Exception.Message)" 
        }
    }
    
    Write-Output "  Admin account doesn't have a matching primary account" 
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
     Write-Output "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Regular processing mode
if ($DryRun) {
     Write-Output "[WARNING] RUNNING IN DRY RUN MODE - No accounts will be deleted" 
}

# Get all admin accounts
$adminAccounts = Get-AdminAccounts
Write-Output "Found $($adminAccounts.Count) cloud-only admin accounts" 

if ($adminAccounts.Count -eq 0) {
     Write-Output "No admin accounts found. Exiting script." 
    Disconnect-FromMgGraph
    exit 0
}

# Initialize the user cache before processing admin accounts
 Write-Output "Initializing user cache..." 
$allUsersCache = Get-AllUsersCache

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
     Write-Output "Processing admin account: $adminUPN, $adminEmployeeId"
    
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
    
    # Debug the returned primary account
    if ($primaryAccount) {
        
        # Check if the primary account has a valid UserPrincipalName
        if (-not [string]::IsNullOrEmpty($primaryAccount.UserPrincipalName)) {
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
        } else {
            # Primary account object exists but has no UserPrincipalName, treat as no match
             Write-Output "  Found primary account object but it has no valid UserPrincipalName" 
             Write-Output "  Admin account doesn't have a matching primary account" 
            
            if ($DryRun) {
                 Write-Output "  [DRY RUN] Would delete admin account: $adminUPN" 
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
                Send-AdminAccountNotification -Recipient $emailRecipient -AdminUPN $adminUPN -Action "Would be deleted" -Reason "No matching primary account"
               
                $results += $result
            } else {
                # Delete the admin account
                try {
                    Remove-MgUser -UserId $adminAccount.Id
                    Write-Output "  Deleted admin account: $adminUPN" 
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
                    Write-Output "  Failed to delete admin account: $adminUPN - $($_.Exception.Message)" 
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
             Write-Output "  [DRY RUN] Would delete admin account: $adminUPN" 
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
                Write-Output "  Deleted admin account: $adminUPN" 
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
                Write-Output "  Failed to delete admin account: $adminUPN - $($_.Exception.Message)" 
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

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
