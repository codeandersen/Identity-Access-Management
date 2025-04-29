# Script to debug why the normal account matching isn't working
# This script will focus specifically on finding hans.christian.andersen@stark.dk

# App registration credentials
$clientId = "xxxxxxxxx"
$tenantId = "xxxxxxxxx"


# Extension attribute name for AdminEmployeeId
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"

# Function to connect to Microsoft Graph
function Connect-ToMgGraph {
    try {
        # Connect to Microsoft Graph with app registration
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "Directory.ReadWrite.All", "User.ReadWrite.All"
        
        # Check if we're connected
        $context = Get-MgContext
        if ($context) {
            Write-Host "Connected to Microsoft Graph using beta API version" -ForegroundColor Green
            return $true
        } else {
            Write-Error "Failed to connect to Microsoft Graph"
            return $false
        }
    }
    catch {
        Write-Error "Error connecting to Microsoft Graph: $_"
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

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
$connected = Connect-ToMgGraph
if (-not $connected) {
    Write-Error "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Define the admin and normal account UPNs
$adminUPN = "ext.hans.christian.andersen@stark.dk"
$normalizedUPN = "hans.christian.andersen@stark.dk"

Write-Host "`n=== STEP 1: Get Admin Account and AdminEmployeeId ===" -ForegroundColor Cyan
try {
    # Get admin account using beta endpoint
    Write-Host "Getting admin account: $adminUPN" -ForegroundColor Yellow
    $adminBetaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$adminUPN"
    
    Write-Host "Admin account details:" -ForegroundColor Yellow
    Write-Host "  Display Name: $($adminBetaUser.displayName)" -ForegroundColor White
    Write-Host "  UPN: $($adminBetaUser.userPrincipalName)" -ForegroundColor White
    
    # Get AdminEmployeeId
    if ($adminBetaUser.$adminEmployeeIdExtension) {
        $adminEmployeeId = $adminBetaUser.$adminEmployeeIdExtension
        Write-Host "  AdminEmployeeId: $adminEmployeeId" -ForegroundColor Green
    } else {
        Write-Host "  AdminEmployeeId not found in direct property" -ForegroundColor Red
        
        # Try to find in extensions
        if ($adminBetaUser.extensions) {
            foreach ($extension in $adminBetaUser.extensions) {
                if ($extension.ContainsKey($adminEmployeeIdExtension)) {
                    $adminEmployeeId = $extension.$adminEmployeeIdExtension
                    Write-Host "  AdminEmployeeId found in extensions: $adminEmployeeId" -ForegroundColor Green
                    break
                }
            }
        }
        
        if (-not $adminEmployeeId) {
            Write-Host "  AdminEmployeeId not found in extensions either" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "Error getting admin account: $_" -ForegroundColor Red
}

Write-Host "`n=== STEP 2: Try to get Normal Account using Standard API ===" -ForegroundColor Cyan
try {
    Write-Host "Looking for normal account with UPN: $normalizedUPN" -ForegroundColor Yellow
    $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
    
    if ($normalAccount) {
        Write-Host "Normal account found in standard API:" -ForegroundColor Green
        Write-Host "  Display Name: $($normalAccount.DisplayName)" -ForegroundColor White
        Write-Host "  UPN: $($normalAccount.UserPrincipalName)" -ForegroundColor White
        Write-Host "  EmployeeId (standard API): $($normalAccount.EmployeeId)" -ForegroundColor White
        $normalAccountFound = $true
    } else {
        Write-Host "Normal account NOT found using standard API" -ForegroundColor Red
        $normalAccountFound = $false
    }
} catch {
    Write-Host "Error getting normal account using standard API: $_" -ForegroundColor Red
    $normalAccountFound = $false
}

Write-Host "`n=== STEP 3: Try to get Normal Account using Beta API ===" -ForegroundColor Cyan
try {
    Write-Host "Looking for normal account with UPN in beta API: $normalizedUPN" -ForegroundColor Yellow
    $normalBetaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
    
    if ($normalBetaUser) {
        Write-Host "Normal account found in beta API:" -ForegroundColor Green
        Write-Host "  Display Name: $($normalBetaUser.displayName)" -ForegroundColor White
        Write-Host "  UPN: $($normalBetaUser.userPrincipalName)" -ForegroundColor White
        Write-Host "  EmployeeId (beta API): $($normalBetaUser.employeeId)" -ForegroundColor White
        
        if ($adminEmployeeId -and $normalBetaUser.employeeId -eq $adminEmployeeId) {
            Write-Host "`n*** MATCH FOUND: Normal account employeeId matches admin account AdminEmployeeId ***" -ForegroundColor Green
            Write-Host "  Normal account employeeId: $($normalBetaUser.employeeId)" -ForegroundColor Green
            Write-Host "  Admin account AdminEmployeeId: $adminEmployeeId" -ForegroundColor Green
        } else {
            Write-Host "`n*** NO MATCH: Normal account employeeId does not match admin account AdminEmployeeId ***" -ForegroundColor Red
            Write-Host "  Normal account employeeId: $($normalBetaUser.employeeId)" -ForegroundColor Red
            Write-Host "  Admin account AdminEmployeeId: $adminEmployeeId" -ForegroundColor Red
        }
    } else {
        Write-Host "Normal account NOT found using beta API" -ForegroundColor Red
    }
} catch {
    Write-Host "Error getting normal account using beta API: $_" -ForegroundColor Red
}

Write-Host "`n=== STEP 4: Try to find Normal Account by EmployeeId filter ===" -ForegroundColor Cyan
if ($adminEmployeeId) {
    try {
        Write-Host "Searching for accounts with employeeId = $adminEmployeeId" -ForegroundColor Yellow
        $filter = "employeeId eq '$adminEmployeeId'"
        $matchingAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
        
        Write-Host "Found $($matchingAccounts.Count) accounts with matching employeeId in standard API" -ForegroundColor Yellow
        
        if ($matchingAccounts.Count -gt 0) {
            foreach ($account in $matchingAccounts) {
                Write-Host "  Account: $($account.UserPrincipalName)" -ForegroundColor White
                Write-Host "    Display Name: $($account.DisplayName)" -ForegroundColor White
                Write-Host "    EmployeeId: $($account.EmployeeId)" -ForegroundColor White
            }
            
            # Filter out admin accounts
            $nonAdminAccounts = $matchingAccounts | Where-Object { 
                -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*') 
            }
            
            Write-Host "Found $($nonAdminAccounts.Count) non-admin accounts with matching employeeId" -ForegroundColor Yellow
            
            if ($nonAdminAccounts.Count -gt 0) {
                foreach ($account in $nonAdminAccounts) {
                    Write-Host "  Non-admin account: $($account.UserPrincipalName)" -ForegroundColor Green
                    Write-Host "    Display Name: $($account.DisplayName)" -ForegroundColor Green
                    Write-Host "    EmployeeId: $($account.EmployeeId)" -ForegroundColor Green
                }
            }
        }
    } catch {
        Write-Host "Error searching by employeeId filter: $_" -ForegroundColor Red
    }
}

Write-Host "`n=== STEP 5: Try to create a working Find-MatchingNormalAccount function ===" -ForegroundColor Cyan

function Find-MatchingNormalAccount {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AdminUPN,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminEmployeeId
    )
    
    # Extract the normalized UPN from the admin UPN
    $normalizedUPN = $null
    
    if ($AdminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
        # Pattern: ext.adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    elseif ($AdminUPN -match '^adm\.(.*?)@(.*)$') {
        # Pattern: adm.username@domain.com -> username@domain.com
        $username = $matches[1]
        $domain = $matches[2]
        $normalizedUPN = "$username@$domain"
        Write-Host "  Extracted normalized UPN: $normalizedUPN" -ForegroundColor Yellow
    }
    
    if ($normalizedUPN) {
        # Try to get the account directly by UPN
        try {
            $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
            
            if ($normalAccount) {
                Write-Host "  Found normal account by UPN: $normalizedUPN" -ForegroundColor Green
                
                # Check if the account has the matching employeeId in beta API
                try {
                    $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$normalizedUPN" -ErrorAction SilentlyContinue
                    
                    if ($betaUser -and $betaUser.employeeId -eq $AdminEmployeeId) {
                        Write-Host "  MATCH: Normal account employeeId matches admin account AdminEmployeeId" -ForegroundColor Green
                        
                        # Create a custom object with the properties we need
                        $result = [PSCustomObject]@{
                            UserPrincipalName = $normalAccount.UserPrincipalName
                            DisplayName = $normalAccount.DisplayName
                            EmployeeId = $betaUser.employeeId
                            Id = $normalAccount.Id
                            MatchReason = "EmployeeId match in beta API"
                        }
                        
                        return $result
                    } else {
                        Write-Host "  NO MATCH: Normal account employeeId does not match admin account AdminEmployeeId" -ForegroundColor Red
                        if ($betaUser) {
                            Write-Host "    Normal account employeeId: $($betaUser.employeeId)" -ForegroundColor Red
                            Write-Host "    Admin account AdminEmployeeId: $AdminEmployeeId" -ForegroundColor Red
                        }
                    }
                } catch {
                    Write-Host "  Error checking beta API: $_" -ForegroundColor Red
                }
            } else {
                Write-Host "  Normal account not found by UPN: $normalizedUPN" -ForegroundColor Red
            }
        } catch {
            Write-Host "  Error getting normal account by UPN: $_" -ForegroundColor Red
        }
    }
    
    # Try using standard API filter
    try {
        Write-Host "  Trying to find normal account by employeeId filter..." -ForegroundColor Yellow
        $filter = "employeeId eq '$AdminEmployeeId'"
        $matchingAccounts = Get-MgUser -Filter $filter -Property "UserPrincipalName,DisplayName,EmployeeId,Id" -All
        
        if ($matchingAccounts.Count -gt 0) {
            Write-Host "  Found $($matchingAccounts.Count) accounts with matching employeeId" -ForegroundColor Yellow
            
            # Filter out admin accounts
            $nonAdminAccounts = $matchingAccounts | Where-Object { 
                -not ($_.UserPrincipalName -like 'adm.*') -and -not ($_.UserPrincipalName -like 'ext.adm.*') 
            }
            
            if ($nonAdminAccounts.Count -gt 0) {
                Write-Host "  Found matching normal account by employeeId filter: $($nonAdminAccounts[0].UserPrincipalName)" -ForegroundColor Green
                
                # Create a custom object with the properties we need
                $result = [PSCustomObject]@{
                    UserPrincipalName = $nonAdminAccounts[0].UserPrincipalName
                    DisplayName = $nonAdminAccounts[0].DisplayName
                    EmployeeId = $nonAdminAccounts[0].EmployeeId
                    Id = $nonAdminAccounts[0].Id
                    MatchReason = "EmployeeId match in standard API"
                }
                
                return $result
            }
        }
    } catch {
        Write-Host "  Error searching by employeeId filter: $_" -ForegroundColor Red
    }
    
    # If we get here, no matching normal account was found
    Write-Host "  No matching normal account found" -ForegroundColor Red
    return $null
}

# Test the function
Write-Host "Testing Find-MatchingNormalAccount function..." -ForegroundColor Yellow
$matchingAccount = Find-MatchingNormalAccount -AdminUPN $adminUPN -AdminEmployeeId $adminEmployeeId

if ($matchingAccount) {
    Write-Host "`nMATCHING NORMAL ACCOUNT FOUND:" -ForegroundColor Green
    Write-Host "  UPN: $($matchingAccount.UserPrincipalName)" -ForegroundColor Green
    Write-Host "  Display Name: $($matchingAccount.DisplayName)" -ForegroundColor Green
    Write-Host "  EmployeeId: $($matchingAccount.EmployeeId)" -ForegroundColor Green
    Write-Host "  Match Reason: $($matchingAccount.MatchReason)" -ForegroundColor Green
} else {
    Write-Host "`nNO MATCHING NORMAL ACCOUNT FOUND" -ForegroundColor Red
}

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
