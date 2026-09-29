# Cloud collector: runs on GitHub Actions (PowerShell 7 on Linux), no PC involved.
# Signs in with a refresh token per client, pulls flows + runs for the listed environments in parallel,
# writes flow-runs.csv, then build-dashboard.ps1 renders the page and deploys it to Netlify.
#
# Config comes from environment variables (GitHub secrets), never from the repo:
#   CLIENTS_JSON   [{"Name":"SEMO","Tenant":"seguinmorris.com","Environments":["..."]}, ...]
#   RT_<NAME>      the client's refresh token (from get-refresh-token.ps1), e.g. RT_SEMO
#   NETLIFY_TOKEN  used by build-dashboard.ps1
param([int]$Days = 7, [int]$Parallel = 8)
$ErrorActionPreference = 'Stop'

$clientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$scope    = 'https://service.flow.microsoft.com//.default offline_access'
$api      = 'https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple'
$ver      = 'api-version=2016-11-01'
$clients  = $env:CLIENTS_JSON | ConvertFrom-Json
if (-not $clients) { throw 'CLIENTS_JSON is empty.' }

$collected = (Get-Date).ToString('s')
$since     = (Get-Date).AddDays(-$Days)
$rows      = [System.Collections.Generic.List[object]]::new()
$failures  = @()
$blocked   = @()   # clients whose sign-in failed this run

# -AsHashtable keeps keys case-sensitive: the Flow API returns keys differing only by case, which the default parser rejects.
function Get-All($url, $headers, [scriptblock]$stopWhen) {
    $out = @()
    while ($url) {
        $r = (Invoke-WebRequest -Uri $url -Headers $headers).Content | ConvertFrom-Json -AsHashtable
        $out += $r['value']; $url = $r['nextLink']
        if ($stopWhen -and $out.Count -and (& $stopWhen $out[-1])) { break }
    }
    $out
}

foreach ($c in $clients) {
    $rt = [Environment]::GetEnvironmentVariable("RT_$($c.Name)")
    if (-not $rt) { $failures += "$($c.Name): no RT_$($c.Name) secret"; $blocked += $c.Name; continue }
    try {
        $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = $rt; scope = $scope }
    } catch {
        # AADSTS53003 = the tenant's Conditional Access blocks sign-ins from GitHub's servers (SEMO does). invalid_grant otherwise = token revoked: rerun get-refresh-token.ps1.
        $failures += "$($c.Name): token refresh failed: $(($_.ErrorDetails.Message | ConvertFrom-Json).error_description)"; $blocked += $c.Name; continue
    }
    $h = @{ Authorization = "Bearer $($tok.access_token)" }

    $all   = @(Get-All "$api/environments?$ver" $h)
    $names = @($all | ForEach-Object { $_['properties']['displayName'] })
    $envs  = @($all | Where-Object { $c.Environments -contains $_['properties']['displayName'] })
    $missing = @($c.Environments | Where-Object { $_ -notin $names })
    if ($missing) { $failures += "$($c.Name): environment(s) not found: $($missing -join ', '). Available: $($names -join ', ')" }

    foreach ($env in $envs) {
        $flows = @(Get-All "$api/environments/$($env['name'])/flows?$ver" $h)
        # One runs request per flow, in parallel. Runs come newest first: stop paging once a page ends before the window.
        $flowRows = $flows | ForEach-Object -ThrottleLimit $Parallel -Parallel {
            $flow = $_; $api = $using:api; $ver = $using:ver; $h = $using:h; $since = $using:since; $envId = ($using:env)['name']
            $url = "$api/environments/$envId/flows/$($flow['name'])/runs?$ver"; $runs = @(); $status = $null
            try {
                while ($url) {
                    $r = (Invoke-WebRequest -Uri $url -Headers $h).Content | ConvertFrom-Json -AsHashtable
                    $runs += $r['value']; $url = $r['nextLink']
                    if ($runs.Count -and [datetime]$runs[-1]['properties']['startTime'] -lt $since) { break }
                }
                $runs = @($runs | Where-Object { [datetime]$_['properties']['startTime'] -ge $since })
            } catch { $status = 'UNREADABLE' }
            $tr = try { $t = $flow['properties']['definitionSummary']['triggers'][0]; "$($t['type'])/$($t['kind'])" } catch { '' }
            $base = @{ Flow = $flow['properties']['displayName']; FlowId = $flow['name']; Enabled = ($flow['properties']['state'] -eq 'Started'); Trigger = $tr }
            if ($status)             { [pscustomobject]($base + @{ Start = ''; Status = $status }) }
            elseif ($runs.Count -eq 0) { [pscustomobject]($base + @{ Start = ''; Status = 'NO_RUNS' }) }
            else { foreach ($run in $runs) { [pscustomobject]($base + @{ Start = ([datetime]$run['properties']['startTime']).ToString('s'); Status = $run['properties']['status'] }) } }
        }
        foreach ($fr in $flowRows) {
            $rows.Add([pscustomobject]@{ Collected = $collected; Client = $c.Name; Environment = $env['properties']['displayName']; Flow = $fr.Flow; FlowId = $fr.FlowId; Enabled = $fr.Enabled; Trigger = $fr.Trigger; Start = $fr.Start; Status = $fr.Status })
        }
    }
    Write-Host "$($c.Name): $($envs.Count) environment(s), $(@($rows | Where-Object Client -eq $c.Name).Count) rows"
}

# Carry-over: a client that could not be signed in keeps its rows from the live page (the laptop task also publishes there),
# so it stays on the page with its old snapshot time and turns STALE after an hour instead of vanishing.
if ($blocked) {
    try {
        $live = (Invoke-WebRequest 'https://support-watch.netlify.app/').Content
        $old  = [regex]::Match($live, '(?m)^const rows = (\[.*\]);$').Groups[1].Value | ConvertFrom-Json
        foreach ($name in $blocked) { $kept = @($old | Where-Object Client -eq $name); $kept | ForEach-Object { $rows.Add($_) }; Write-Host "$name`: carried over $($kept.Count) rows from the live page" }
    } catch { $failures += "carry-over from the live page failed: $_" }
}

if ($rows.Count) {
    $rows | Export-Csv -Path "$PSScriptRoot/flow-runs.csv" -NoTypeInformation -Encoding UTF8
    & "$PSScriptRoot/build-dashboard.ps1"
}
$failures | ForEach-Object { Write-Warning $_ }
# Fail the job (GitHub emails the repo owner) only when nothing at all was collected: the collector itself is broken.
if ($blocked.Count -eq @($clients).Count) { exit 1 }
