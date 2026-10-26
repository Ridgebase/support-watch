# One-time per client: device-code sign-in (MFA in the browser) that saves the REFRESH TOKEN to a file.
# The cloud collector (collect.ps1) uses that token from a GitHub secret; nothing else needs your PC.
# Usage:  .\get-refresh-token.ps1 -Tenant seguinmorris.com -Out "$HOME\rt-SEMO.txt"
# Then:   gh secret set RT_SEMO --repo Ridgebase/support-watch < "$HOME\rt-SEMO.txt"
# The token is never printed. It lives ~90 days of continuous use and renews itself on each use; when a tenant
# policy revokes it the workflow fails and GitHub emails you: rerun this and update the secret.
# -MessageCenter: a second token per client, for the Microsoft 365 Message Center (Tech watch tab, secret MC_<NAME>). The Azure CLI app is not
# pre-authorized for that Graph permission, so this one signs in through the Microsoft Graph PowerShell app instead; the account needs a role
# that reads the Message Center (Global Reader, Message Center Reader, Global Administrator, ...) and consents to ServiceMessage.Read.All at sign-in.
param([Parameter(Mandatory)][string]$Tenant, [Parameter(Mandatory)][string]$Out, [switch]$MessageCenter)

$clientId = if ($MessageCenter) { '14d82eec-204b-4c2f-b7e8-296a70dab67e' } else { '04b07795-8ddb-461a-bbee-02f9e1bf7b46' }   # Microsoft Graph PowerShell / Azure CLI public clients: both allow device code; the Azure CLI one is pre-consented for the Flow service
$scope    = if ($MessageCenter) { 'https://graph.microsoft.com/ServiceMessage.Read.All offline_access' } else { 'https://service.flow.microsoft.com//.default offline_access' }
$base     = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0"

$dc = Invoke-RestMethod -Method Post -Uri "$base/devicecode" -Body @{ client_id = $clientId; scope = $scope }
Write-Host $dc.message
do {
    Start-Sleep -Seconds $dc.interval
    try   { $tok = Invoke-RestMethod -Method Post -Uri "$base/token" -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $clientId; device_code = $dc.device_code }; $err = $null }
    catch { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error }
    if ($err -and $err -ne 'authorization_pending' -and $err -ne 'slow_down') { throw "Sign-in failed: $err" }
} while ($err)

Set-Content -Path $Out -Value $tok.refresh_token -NoNewline -Encoding ASCII
Write-Host "Signed in. Refresh token saved to $Out (not shown)."
