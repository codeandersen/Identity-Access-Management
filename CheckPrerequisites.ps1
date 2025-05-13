# Check Prerequisites for Entra ID Scripts
# Author: Hans Christian Andersen
# Date: 2025-05-13

Write-Host "Checking prerequisites for Entra ID Management scripts..." -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# Define required modules
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Beta.Users",
    "Microsoft.Graph.Beta.DirectoryObjects"
)

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $($psVersion.Major).$($psVersion.Minor).$($psVersion.Patch)" -ForegroundColor Yellow
$psVersionOk = $psVersion.Major -ge 5
Write-Host "PowerShell Version Check: " -NoNewline
if ($psVersionOk) {
    Write-Host "PASSED" -ForegroundColor Green
} else {
    Write-Host "FAILED - PowerShell 5.1 or higher is required" -ForegroundColor Red
}

# Check if modules are installed
Write-Host "`nChecking required PowerShell modules:" -ForegroundColor Yellow
$allModulesInstalled = $true

foreach ($module in $requiredModules) {
    $moduleInfo = Get-Module -Name $module -ListAvailable
    Write-Host "Module: $module - " -NoNewline
    
    if ($moduleInfo) {
        $latestVersion = ($moduleInfo | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host "INSTALLED (Version: $latestVersion)" -ForegroundColor Green
        
        # Check if there's a newer version available
        try {
            $onlineModule = Find-Module -Name $module -ErrorAction SilentlyContinue
            if ($onlineModule -and $onlineModule.Version -gt $latestVersion) {
                Write-Host "  NOTE: A newer version ($($onlineModule.Version)) is available. Consider updating with:" -ForegroundColor Yellow
                Write-Host "  Update-Module -Name $module" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  Could not check for updates (requires internet connection)" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "NOT INSTALLED" -ForegroundColor Red
        Write-Host "  Install with: Install-Module -Name $module -Scope CurrentUser -Force" -ForegroundColor Yellow
        $allModulesInstalled = $false
    }
}

# Check Microsoft Graph PowerShell SDK version
$graphSDK = Get-Module -Name "Microsoft.Graph*" -ListAvailable | 
    Sort-Object Version -Descending | 
    Select-Object -First 1
    
Write-Host "`nMicrosoft Graph PowerShell SDK: " -NoNewline
if ($graphSDK) {
    Write-Host "INSTALLED (Latest version: $($graphSDK.Version))" -ForegroundColor Green
} else {
    Write-Host "NOT DETECTED" -ForegroundColor Red
}

# Check Azure AD PowerShell module (legacy)
$azureAD = Get-Module -Name "AzureAD" -ListAvailable
Write-Host "Azure AD PowerShell module (legacy): " -NoNewline
if ($azureAD) {
    $latestVersion = ($azureAD | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Host "INSTALLED (Version: $latestVersion)" -ForegroundColor Green
    Write-Host "  NOTE: Microsoft recommends migrating from AzureAD to Microsoft Graph PowerShell SDK" -ForegroundColor Yellow
} else {
    Write-Host "NOT INSTALLED" -ForegroundColor Gray
    Write-Host "  This is not required as you're using Microsoft Graph modules" -ForegroundColor Gray
}

# Summary
Write-Host "`nPrerequisites Summary:" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
if ($psVersionOk -and $allModulesInstalled) {
    Write-Host "All prerequisites are installed and ready to use!" -ForegroundColor Green
} else {
    Write-Host "Some prerequisites are missing. Please install the required components listed above." -ForegroundColor Red
}

Write-Host "`nFor more information on Microsoft Graph PowerShell SDK, visit:" -ForegroundColor Cyan
Write-Host "https://learn.microsoft.com/en-us/powershell/microsoftgraph/overview" -ForegroundColor Cyan
