# Sends a notification email for a would-be or actual deleted admin account
# Uses Microsoft Graph Send-Mail API
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
$subject = "[IAM] Admin Account $Action: $AdminUPN"
$body = @"
This is an automated notification from the EntraIDAdminAccountDeprovisioning script.

Admin account: $AdminUPN
Action: $Action
Reason: $Reason

This is a test notification. Please review the account as needed.
"@

# Build mail payload
$mail = @{
    Message = @{
        Subject = $subject
        Body = @{
            ContentType = "Text"
            Content = $body
        }
        ToRecipients = @(@{EmailAddress = @{Address = $Recipient}})
    }
    SaveToSentItems = $false
}

# Send mail using Microsoft Graph (requires Mail.Send permission)
try {
    Send-MgUserMail -UserId "me" -BodyParameter $mail
    Write-Host "Notification sent for $AdminUPN ($Action) to $Recipient" -ForegroundColor Cyan
}
catch {
    Write-Host "Failed to send notification for $AdminUPN: $_" -ForegroundColor Red
}
