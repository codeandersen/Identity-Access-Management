# Script to get all information about an admin account
param (
    [Parameter(Mandatory = $true)]
    [string]$AdminUPN
)

# Azure AD App Registration details
$clientId = "xxxxxxxxx"
$tenantId = "xxxxxxxxx"

# Connect to Microsoft Graph
Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome

# Get the admin account
Write-Host "Getting information for admin account: $AdminUPN" -ForegroundColor Cyan
$adminUser = Get-MgUser -UserId $AdminUPN -ErrorAction Stop

# Display basic information
Write-Host "`nBasic Information:" -ForegroundColor Yellow
Write-Host "DisplayName: $($adminUser.DisplayName)"
Write-Host "UserPrincipalName: $($adminUser.UserPrincipalName)"
Write-Host "Id: $($adminUser.Id)"
Write-Host "EmployeeId: $($adminUser.EmployeeId)"
Write-Host "Mail: $($adminUser.Mail)"
Write-Host "JobTitle: $($adminUser.JobTitle)"

# Get all properties using beta endpoint
Write-Host "`nAttempting to get all properties using beta endpoint..." -ForegroundColor Yellow
try {
    $betaUser = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$AdminUPN" -ErrorAction Stop
    
    # Convert to formatted JSON for better readability
    $betaUserJson = ConvertTo-Json -InputObject $betaUser -Depth 5
    
    # Display all properties
    Write-Host "`nAll Properties (Beta):" -ForegroundColor Green
    Write-Host $betaUserJson
    
    # Look for any extension attributes
    Write-Host "`nLooking for extension attributes..." -ForegroundColor Yellow
    $extensionProps = $betaUser.PSObject.Properties | Where-Object { $_.Name -like "extension_*" }
    
    if ($extensionProps) {
        Write-Host "Found extension attributes:" -ForegroundColor Green
        foreach ($prop in $extensionProps) {
            Write-Host "  $($prop.Name): $($prop.Value)"
        }
    } else {
        Write-Host "No extension attributes found." -ForegroundColor Red
    }
} catch {
    Write-Host "Error getting beta properties: $_" -ForegroundColor Red
}

# Disconnect from Microsoft Graph
Disconnect-MgGraph
