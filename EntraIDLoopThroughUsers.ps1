#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users

<#
.SYNOPSIS
    Checks if users from a CSV file exist in Entra ID and retrieves their EmployeeID.
.DESCRIPTION
    This script reads a CSV file containing UPNs, checks if each user exists in Entra ID,
    and outputs the UPN, existence status, and EmployeeID.
.PARAMETER CsvPath
    Path to the CSV file containing UPNs. The CSV must have a header row with either 'UPN' or 'UserPrincipalName' as one of the columns.
.EXAMPLE
    .\EntraIDLoopThroughUsers.ps1 -CsvPath "C:\Temp\Users.csv"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath
)

# Azure AD App Registration details
#$clientId = "xxxx-xxx-xxx-xxx"
#$tenantId = "xxxx-xxx-xxx-xxx"

$clientId = "xxxx-xxx-xxx-xxx"
$tenantId = "xxxx-xxx-xxx-xxx"

# Check if CSV file exists
if (-not (Test-Path -Path $CsvPath)) {
    Write-Error "CSV file not found at path: $CsvPath"
    exit 1
}

# Function to authenticate user
function Connect-ToMgGraph {
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Connect-MgGraph -ClientId $clientId -TenantId $tenantId -Scopes "User.ReadWrite.All", "Directory.ReadWrite.All" -NoWelcome
        return $true
    } catch {
        Write-Host "Failed to connect to Microsoft Graph: $_"
        return $false
    }
}

function Disconnect-FromMgGraph {
    Disconnect-MgGraph
    Write-Host "Disconnected from Microsoft Graph."
}


# Read CSV file
try {
    $users = Import-Csv -Path $CsvPath
    
    # Verify CSV has UPN or UserPrincipalName column
    $upnColumnName = $null
    if ($users | Get-Member -Name "UPN") {
        $upnColumnName = "UPN"
    } elseif ($users | Get-Member -Name "UserPrincipalName") {
        $upnColumnName = "UserPrincipalName"
    } else {
        Write-Error "CSV file must contain either a 'UPN' or 'UserPrincipalName' column."
        exit 1
    }
    
    Write-Host "Successfully loaded $($users.Count) users from CSV. Using column '$upnColumnName' for UPN values." -ForegroundColor Green
}
catch {
    Write-Error "Failed to read CSV file: $_"
    exit 1
}

# Create output array
$results = @()

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
$connected = Connect-ToMgGraph
if (-not $connected) {
    Write-Error "Failed to authenticate to Microsoft Graph. Exiting script."
    exit 1
}

# Process each user
foreach ($user in $users) {
    $upn = $user.$upnColumnName
    Write-Host "Processing user: $upn" -ForegroundColor Yellow
    
    try {
        # Try to get user from Entra ID
        $entraUser = Get-MgUser -UserId $upn -Property "UserPrincipalName,EmployeeId" -ErrorAction SilentlyContinue
        
        if ($entraUser) {
            $result = [PSCustomObject]@{
                UPN = $upn
                ExistsInEntraID = "Yes"
                EmployeeID = $entraUser.EmployeeId
            }
            Write-Host "  User exists in Entra ID. EmployeeID: $($entraUser.EmployeeId)" -ForegroundColor Green
        }
        else {
            $result = [PSCustomObject]@{
                UPN = $upn
                ExistsInEntraID = "No"
                EmployeeID = $null
            }
            Write-Host "  User does not exist in Entra ID." -ForegroundColor Red
        }
    }
    catch {
        $result = [PSCustomObject]@{
            UPN = $upn
            ExistsInEntraID = "No"
            EmployeeID = $null
        }
        Write-Host "  Error checking user: $_" -ForegroundColor Red
    }
    
    $results += $result
}

# Display results in console
$results | Format-Table -AutoSize

# Export results to CSV
$outputPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($CsvPath), "EntraIDUserResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv")
$results | Export-Csv -Path $outputPath -NoTypeInformation

Write-Host "Results exported to: $outputPath" -ForegroundColor Cyan

# Disconnect from Microsoft Graph
Disconnect-FromMgGraph
Write-Host "Disconnected from Microsoft Graph." -ForegroundColor Cyan