# Azure Function (PowerShell 7, Canada Central), every 10 minutes: collects SEMO from a Canadian IP, which its
# Conditional Access allows while GitHub's US runners are refused, and publishes data.json to the gist the cloud job
# reads. It is the laptop collector (flow-runs.ps1) without the laptop.
# The scripts are fetched from the public repo's main branch at each run, so a change there needs no redeploy here.
# App settings: CLIENTS_JSON_B64 (CLIENTS_JSON base64-encoded: az CLI parses a JSON-looking setting value and stores it
# without its quotes), RT_SEMO (as collect.ps1 expects), GIST_ID, GIST_TOKEN (a GitHub token with the gist scope).
param($Timer)
$ErrorActionPreference = 'Stop'
$env:CLIENTS_JSON = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:CLIENTS_JSON_B64))

$work = Join-Path ([IO.Path]::GetTempPath()) 'support-watch'   # wwwroot is read-only on the consumption plan
New-Item -ItemType Directory -Force (Join-Path $work 'scripts') | Out-Null
$raw = 'https://raw.githubusercontent.com/Ridgebase/support-watch/main/scripts'
foreach ($f in 'collect.ps1', 'build-dashboard.ps1', 'dashboard.template.html') {
    Invoke-WebRequest -Uri "$raw/${f}?t=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" -OutFile (Join-Path $work "scripts/$f")
}

& (Join-Path $work 'scripts/collect.ps1')   # writes out/flow-runs.csv, out/powerbi.csv, then out/site/data.json via build-dashboard.ps1
if ($LASTEXITCODE) { throw "collect.ps1 exited with $LASTEXITCODE (no client collected)" }

$json = [IO.File]::ReadAllText((Join-Path $work 'out/site/data.json'))
$body = @{ files = @{ 'data.json' = @{ content = $json } } } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Patch -Uri "https://api.github.com/gists/$($env:GIST_ID)" -Headers @{ Authorization = "Bearer $($env:GIST_TOKEN)"; Accept = 'application/vnd.github+json' } -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
Write-Host "data.json published to gist $($env:GIST_ID) ($([int]($json.Length / 1024)) KB)"
