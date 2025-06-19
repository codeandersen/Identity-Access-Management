#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Checks Microsoft Entra ID users for ExtensionAttribute3 usage

.DESCRIPTION
    This script connects to Microsoft Entra ID (formerly Azure AD),
    retrieves all users, and checks if ExtensionAttribute3 is populated.
    For users with this attribute set, it outputs their UPN and the attribute value to a CSV file.

.NOTES
    Author: Cloud Architect
    Date: $(Get-Date -Format "yyyy-MM-dd")
    Requires: Microsoft Graph PowerShell SDK
#>

# Define output file path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputFile = "$PSScriptRoot\ExtensionAttribute3_Report_$timestamp.csv"

# Connect to Microsoft Graph with the required permissions
Connect-MgGraph -Scopes "User.Read.All" -NoWelcome

# Get all users from Entra ID
Write-Host "Retrieving all users from Microsoft Entra ID..." -ForegroundColor Cyan
$users = Get-MgUser -All -Property "id,userPrincipalName,onPremisesExtensionAttributes"
Write-Host "Retrieved $($users.Count) users." -ForegroundColor Green

# Initialize counter and results array for users with ExtensionAttribute3
$usersWithEA3 = 0
$results = @()

# Check each user for ExtensionAttribute3
Write-Host "\nChecking for ExtensionAttribute3 usage..." -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan

foreach ($user in $users) {
    # Check if the user has onPremisesExtensionAttributes and specifically ExtensionAttribute3
    if ($user.OnPremisesExtensionAttributes -and $user.OnPremisesExtensionAttributes.ExtensionAttribute3) {
        $usersWithEA3++
        
        # Add to results array
        $results += [PSCustomObject]@{
            UPN = $user.UserPrincipalName
            ExtensionAttribute3 = $user.OnPremisesExtensionAttributes.ExtensionAttribute3
        }
        
        # Also display in console
        Write-Host "UPN: $($user.UserPrincipalName)" -ForegroundColor Yellow
        Write-Host "ExtensionAttribute3: $($user.OnPremisesExtensionAttributes.ExtensionAttribute3)" -ForegroundColor Yellow
        Write-Host "----------------------------------------" -ForegroundColor Cyan
    }
}

# Export results to CSV file
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $outputFile -NoTypeInformation
    Write-Host "\nResults exported to: $outputFile" -ForegroundColor Green
}

# Output summary
Write-Host "\nSummary:" -ForegroundColor Green
Write-Host "Total users: $($users.Count)" -ForegroundColor Green
Write-Host "Users with ExtensionAttribute3: $usersWithEA3" -ForegroundColor Green

# Disconnect from Microsoft Graph
Disconnect-MgGraph | Out-Null
Write-Host "\nDisconnected from Microsoft Graph." -ForegroundColor Cyan