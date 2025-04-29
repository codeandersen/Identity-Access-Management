# Script to check if a specific admin account has a matching normal account
# This script focuses on directly checking for the matching normal account

# App registration credentials
$clientId = "xxxxxxxxx"
$tenantId = "xxxxxxxxx"



# Extension attribute name for AdminEmployeeId
$adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"

# Admin UPN to check
$adminUPN = "ext.hans.christian.andersen@stark.dk"

# Function to connect to Microsoft Graph
function Connect-ToMgGraph {
    try {
        # Connect to Microsoft Graph with app registration
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "Directory.ReadWrite.All", "User.ReadWrite.All"
        
        Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
        return $true
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

# Step 1: Get the admin account and extract the AdminEmployeeId
Write-Host "`nStep 1: Getting admin account and AdminEmployeeId..." -ForegroundColor Cyan
try {
    $adminBetaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$adminUPN"
    
    Write-Host "Admin account details:" -ForegroundColor Yellow
    Write-Host "  Display Name: $($adminBetaUser.displayName)" -ForegroundColor White
    Write-Host "  UPN: $($adminBetaUser.userPrincipalName)" -ForegroundColor White
    
    # Get AdminEmployeeId
    if ($adminBetaUser.$adminEmployeeIdExtension) {
        $adminEmployeeId = $adminBetaUser.$adminEmployeeIdExtension
        Write-Host "  AdminEmployeeId: $adminEmployeeId" -ForegroundColor Green
    } else {
        Write-Host "  AdminEmployeeId not found" -ForegroundColor Red
        $adminEmployeeId = $null
    }
} catch {
    Write-Host "Error getting admin account: $_" -ForegroundColor Red
    exit 1
}

# Step 2: Extract the normalized UPN from the admin UPN
Write-Host "`nStep 2: Extracting normalized UPN..." -ForegroundColor Cyan
$normalizedUPN = $null

# For pattern like ext.hans.christian.andersen@stark.dk
if ($adminUPN -match '^ext\.(.*?)@(.*)$') {
    # Pattern: ext.username@domain.com -> username@domain.com
    $username = $matches[1]
    $domain = $matches[2]
    $normalizedUPN = "$username@$domain"
    Write-Host "Extracted normalized UPN: $normalizedUPN" -ForegroundColor Green
}
# For pattern like ext.adm.hans.christian.andersen@stark.dk
elseif ($adminUPN -match '^ext\.adm\.(.*?)@(.*)$') {
    # Pattern: ext.adm.username@domain.com -> username@domain.com
    $username = $matches[1]
    $domain = $matches[2]
    $normalizedUPN = "$username@$domain"
    Write-Host "Extracted normalized UPN: $normalizedUPN" -ForegroundColor Green
}
# For pattern like adm.hans.christian.andersen@stark.dk
elseif ($adminUPN -match '^adm\.(.*?)@(.*)$') {
    # Pattern: adm.username@domain.com -> username@domain.com
    $username = $matches[1]
    $domain = $matches[2]
    $normalizedUPN = "$username@$domain"
    Write-Host "Extracted normalized UPN: $normalizedUPN" -ForegroundColor Green
}
else {
    Write-Host "Could not extract normalized UPN from $adminUPN" -ForegroundColor Red
}

# Step 3: Check if the normal account exists using standard API
Write-Host "`nStep 3: Checking if normal account exists using standard API..." -ForegroundColor Cyan
if ($normalizedUPN) {
    try {
        $normalAccount = Get-MgUser -UserId $normalizedUPN -ErrorAction SilentlyContinue
        
        if ($normalAccount) {
            Write-Host "Normal account found:" -ForegroundColor Green
            Write-Host "  Display Name: $($normalAccount.DisplayName)" -ForegroundColor White
            Write-Host "  UPN: $($normalAccount.UserPrincipalName)" -ForegroundColor White
            Write-Host "  EmployeeId (standard API): $($normalAccount.EmployeeId)" -ForegroundColor White
        } else {
            Write-Host "Normal account not found using standard API" -ForegroundColor Red
        }
    } catch {
        Write-Host "Error getting normal account: $_" -ForegroundColor Red
    }
}

# Step 4: Check if the normal account exists using beta API and compare employeeId
Write-Host "`nStep 4: Checking normal account in beta API..." -ForegroundColor Cyan
if ($normalizedUPN) {
    try {
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
                
                # Create a custom result object
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    AdminDisplayName = $adminBetaUser.displayName
                    AdminEmployeeId = $adminEmployeeId
                    NormalUPN = $normalBetaUser.userPrincipalName
                    NormalDisplayName = $normalBetaUser.displayName
                    NormalEmployeeId = $normalBetaUser.employeeId
                    MatchFound = $true
                    MatchReason = "EmployeeId match in beta API"
                }
            } else {
                Write-Host "`n*** NO MATCH: Normal account employeeId does not match admin account AdminEmployeeId ***" -ForegroundColor Red
                Write-Host "  Normal account employeeId: $($normalBetaUser.employeeId)" -ForegroundColor Red
                Write-Host "  Admin account AdminEmployeeId: $adminEmployeeId" -ForegroundColor Red
                
                $result = [PSCustomObject]@{
                    AdminUPN = $adminUPN
                    AdminDisplayName = $adminBetaUser.displayName
                    AdminEmployeeId = $adminEmployeeId
                    NormalUPN = $normalBetaUser.userPrincipalName
                    NormalDisplayName = $normalBetaUser.displayName
                    NormalEmployeeId = $normalBetaUser.employeeId
                    MatchFound = $false
                    MatchReason = "EmployeeId mismatch"
                }
            }
        } else {
            Write-Host "Normal account not found using beta API" -ForegroundColor Red
            
            $result = [PSCustomObject]@{
                AdminUPN = $adminUPN
                AdminDisplayName = $adminBetaUser.displayName
                AdminEmployeeId = $adminEmployeeId
                NormalUPN = $null
                NormalDisplayName = $null
                NormalEmployeeId = $null
                MatchFound = $false
                MatchReason = "Normal account not found"
            }
        }
    } catch {
        Write-Host "Error getting normal account using beta API: $_" -ForegroundColor Red
        
        $result = [PSCustomObject]@{
            AdminUPN = $adminUPN
            AdminDisplayName = $adminBetaUser.displayName
            AdminEmployeeId = $adminEmployeeId
            NormalUPN = $null
            NormalDisplayName = $null
            NormalEmployeeId = $null
            MatchFound = $false
            MatchReason = "Error: $_"
        }
    }
}

# Step 5: Display final result
Write-Host "`nStep 5: Final result" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan

if ($result.MatchFound) {
    Write-Host "MATCH FOUND: Admin account has a matching normal account" -ForegroundColor Green
    Write-Host "  Admin Account: $($result.AdminUPN)" -ForegroundColor White
    Write-Host "  Normal Account: $($result.NormalUPN)" -ForegroundColor White
    Write-Host "  Match Reason: $($result.MatchReason)" -ForegroundColor White
    
    Write-Host "`nThis admin account should NOT be deleted." -ForegroundColor Green
} else {
    Write-Host "NO MATCH FOUND: Admin account does not have a matching normal account" -ForegroundColor Red
    Write-Host "  Admin Account: $($result.AdminUPN)" -ForegroundColor White
    Write-Host "  Match Reason: $($result.MatchReason)" -ForegroundColor White
    
    Write-Host "`nThis admin account would be deleted in a normal run." -ForegroundColor Red
}

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
