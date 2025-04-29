# Script to count and examine normal accounts in Entra ID
# This script will help us understand the volume of accounts and verify if we can properly retrieve normal accounts

# App registration credentials
$clientId = "xxxxxxxxx"
$tenantId = "xxxxxxxxx"


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

# Count normal accounts (non-admin accounts)
Write-Host "Counting normal accounts (excluding admin accounts)..." -ForegroundColor Cyan
try {
    # Get count of all users
    $allUsers = Get-MgUser -All -Count userCount -ConsistencyLevel eventual
    $totalUserCount = $allUsers.Count
    Write-Host "Total user accounts in Entra ID: $totalUserCount" -ForegroundColor Yellow
    
    # Filter admin accounts (those with UPN starting with 'adm.' or 'ext.adm.')
    $adminAccounts = $allUsers | Where-Object { 
        ($_.UserPrincipalName -like "adm.*") -or ($_.UserPrincipalName -like "ext.adm.*") 
    }
    $adminCount = $adminAccounts.Count
    Write-Host "Admin accounts (UPN starts with 'adm.' or 'ext.adm.'): $adminCount" -ForegroundColor Yellow
    
    # Calculate normal accounts
    $normalCount = $totalUserCount - $adminCount
    Write-Host "Normal accounts (non-admin): $normalCount" -ForegroundColor Green
    
    # Check for a specific normal account that should match our test admin account
    $testNormalUPN = "hans.christian.andersen@stark.dk"
    Write-Host "`nLooking for specific normal account: $testNormalUPN" -ForegroundColor Cyan
    
    try {
        $normalAccount = Get-MgUser -UserId $testNormalUPN -ErrorAction SilentlyContinue
        
        if ($normalAccount) {
            Write-Host "Found normal account:" -ForegroundColor Green
            Write-Host "  Display Name: $($normalAccount.DisplayName)" -ForegroundColor White
            Write-Host "  UPN: $($normalAccount.UserPrincipalName)" -ForegroundColor White
            Write-Host "  EmployeeId (standard API): $($normalAccount.EmployeeId)" -ForegroundColor White
            
            # Check for employeeId in beta API
            Write-Host "`nChecking employeeId in beta API..." -ForegroundColor Yellow
            try {
                $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$testNormalUPN" -ErrorAction SilentlyContinue
                
                if ($betaUser) {
                    Write-Host "  EmployeeId (beta API): $($betaUser.employeeId)" -ForegroundColor White
                    
                    # Check if this matches our admin account's employeeId
                    $adminUPN = "ext.hans.christian.andersen@stark.dk"
                    $adminAccount = Get-MgUser -UserId $adminUPN -ErrorAction SilentlyContinue
                    
                    if ($adminAccount) {
                        # Get admin employeeId from beta API
                        $adminBetaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$adminUPN" -ErrorAction SilentlyContinue
                        $adminEmployeeIdExtension = "extension_a544ff8b2a174ce0afe606d7cfa8aaa0_AdminEmployeeId"
                        
                        if ($adminBetaUser -and $adminBetaUser.$adminEmployeeIdExtension) {
                            $adminEmployeeId = $adminBetaUser.$adminEmployeeIdExtension
                            Write-Host "`nAdmin account employeeId: $adminEmployeeId" -ForegroundColor Yellow
                            
                            if ($betaUser.employeeId -eq $adminEmployeeId) {
                                Write-Host "MATCH FOUND: Normal account employeeId matches admin account employeeId!" -ForegroundColor Green
                            } else {
                                Write-Host "NO MATCH: Normal account employeeId does not match admin account employeeId" -ForegroundColor Red
                            }
                        } else {
                            Write-Host "Could not retrieve AdminEmployeeId for admin account" -ForegroundColor Red
                        }
                    }
                } else {
                    Write-Host "  Could not retrieve beta API data for normal account" -ForegroundColor Red
                }
            } catch {
                Write-Host "  Error checking beta API: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "Normal account not found: $testNormalUPN" -ForegroundColor Red
        }
    } catch {
        Write-Host "Error searching for normal account: $_" -ForegroundColor Red
    }
    
    # Sample a few normal accounts to check employeeId
    Write-Host "`nSampling 5 random normal accounts to check employeeId..." -ForegroundColor Cyan
    $sampleNormalAccounts = $allUsers | Where-Object { 
        -not (($_.UserPrincipalName -like "adm.*") -or ($_.UserPrincipalName -like "ext.adm.*"))
    } | Select-Object -First 5
    
    foreach ($account in $sampleNormalAccounts) {
        Write-Host "`nAccount: $($account.UserPrincipalName)" -ForegroundColor Yellow
        Write-Host "  Display Name: $($account.DisplayName)" -ForegroundColor White
        Write-Host "  EmployeeId (standard API): $($account.EmployeeId)" -ForegroundColor White
        
        # Check for employeeId in beta API
        try {
            $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$($account.UserPrincipalName)" -ErrorAction SilentlyContinue
            if ($betaUser) {
                Write-Host "  EmployeeId (beta API): $($betaUser.employeeId)" -ForegroundColor White
            }
        } catch {
            Write-Host "  Error checking beta API: $_" -ForegroundColor Red
        }
    }
    
} catch {
    Write-Error "Error counting accounts: $_"
}

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
