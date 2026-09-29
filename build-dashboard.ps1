# Rebuilds dashboard.html from flow-runs.csv. Called by flow-runs.ps1; run alone to refresh the page.
param(
    [string]$Csv = "$PSScriptRoot/flow-runs.csv",
    [string]$Out = "$PSScriptRoot/dashboard.html"
)
$json = if (Test-Path $Csv) { @(Import-Csv $Csv) | ConvertTo-Json -Compress } else { "[]" }
if (-not $json.StartsWith('[')) { $json = "[$json]" }   # ConvertTo-Json unwraps a single row
$html = (Get-Content "$PSScriptRoot/dashboard.template.html" -Raw -Encoding UTF8).Replace('__DATA__', $json)
[IO.File]::WriteAllText($Out, $html, [Text.UTF8Encoding]::new($false))
Write-Host "Dashboard written to $Out"

# Publish to Netlify (site "support-watch") when a token is present. No CLI. A failure here never breaks the local page.
# Uses the file-digest API, not the zip API: a zip upload made Netlify tag index.html as text/plain (browser showed raw source).
$tokenFile = "$HOME/netlify-token.txt"; $siteId = 'a065a061-4530-4c70-8c12-467c27642f2f'
if ($env:NETLIFY_TOKEN -or (Test-Path $tokenFile)) {
    try {
        # NETLIFY_TOKEN env var on GitHub Actions; the DPAPI-encrypted file on the Windows PC
        $tok = if ($env:NETLIFY_TOKEN) { $env:NETLIFY_TOKEN.Trim() } else { (New-Object PSCredential 'x', (Get-Content $tokenFile | ConvertTo-SecureString)).GetNetworkCredential().Password }
        $h   = @{ Authorization = "Bearer $tok" }
        $sha = (Get-FileHash $Out -Algorithm SHA1).Hash.ToLower()
        $d   = Invoke-RestMethod -Method Post -Uri "https://api.netlify.com/api/v1/sites/$siteId/deploys" -Headers $h -ContentType 'application/json' -Body (@{ files = @{ '/index.html' = $sha } } | ConvertTo-Json)
        if ($d.required -contains $sha) { Invoke-RestMethod -Method Put -Uri "https://api.netlify.com/api/v1/deploys/$($d.id)/files/index.html" -Headers $h -ContentType 'application/octet-stream' -InFile $Out | Out-Null }
        Write-Host "Deployed to $($d.ssl_url) (deploy $($d.id))"
    } catch { Write-Warning "Netlify deploy failed: $($_.Exception.Message)" }
}
