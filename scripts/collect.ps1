# Cloud collector: runs on GitHub Actions (PowerShell 7 on Linux), no PC involved.
# Signs in with a refresh token per client, pulls flows + runs for the listed environments in parallel,
# writes out/flow-runs.csv, then build-dashboard.ps1 renders the page into out/site.
#
# Config comes from environment variables (GitHub secrets), never from the repo:
#   CLIENTS_JSON   [{"Name":"SEMO","Tenant":"seguinmorris.com","Environments":["..."]}, ...]
#                  optional per client: "FlowDays": {"<flow display name>": 1} shortens the window for a flow whose
#                  thousands of runs a week would otherwise take minutes to page through (its 7-day totals then cover only those days)
#                  optional per client: "PowerBI": ["<workspace name>", ...] also collects the last refresh of every semantic
#                  model in those workspaces (same refresh token, exchanged for a Power BI API token) into powerbi.csv
#                  Power Apps needs no option: every listed environment's canvas apps and connections go to powerapps.csv and
#                  connections.csv (same refresh token exchanged for a Power Apps API token, Graph for the owners' account state)
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

# All times on the page are Eastern (the clients' and the laptop collector's zone). GitHub runners are on UTC, so every
# timestamp is converted explicitly; comparisons stay in UTC. The API returns startTime as UTC ISO strings.
$tz        = [TimeZoneInfo]::FindSystemTimeZoneById('America/Toronto')
$nowUtc    = [datetime]::UtcNow
$collected = [TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $tz).ToString('s')
$since     = $nowUtc.AddDays(-$Days)
$out       = Join-Path (Split-Path $PSScriptRoot) 'out'; New-Item -ItemType Directory -Force $out | Out-Null   # everything generated lives in out/
$rows      = [System.Collections.Generic.List[object]]::new()
$pbi       = [System.Collections.Generic.List[object]]::new()   # one row per semantic model: its last refresh
$apps      = [System.Collections.Generic.List[object]]::new()   # one row per canvas app: owner, sharing, connectors
$conns     = [System.Collections.Generic.List[object]]::new()   # one row per connection: its status (an expired credential is the usual "the app stopped working")
$failures  = @()
$toLocal   = { param($s) if ($s) { [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse($s, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal), $tz).ToString('s') } else { '' } }
$blocked   = @()   # clients whose sign-in failed this run

# -AsHashtable keeps keys case-sensitive: the Flow API returns keys differing only by case, which the default parser rejects.
# -TimeoutSec: a stalled Flow API connection otherwise hangs the whole run until the function's 10-min kill (seen 2026-10-05); with it the flow comes out UNREADABLE and the rest publishes.
function Get-All($url, $headers, [scriptblock]$stopWhen) {
    $out = @()
    while ($url) {
        $r = (Invoke-WebRequest -Uri $url -Headers $headers -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 60).Content | ConvertFrom-Json -AsHashtable
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
    Write-Host "$($c.Name): signed in, $($envs.Count) environment(s) found"   # progress marks: a run killed by the function's 10-min limit then shows where it stalled

    foreach ($env in $envs) {
        $flows = @(Get-All "$api/environments/$($env['name'])/flows?$ver" $h)
        Write-Host "$($c.Name): $($env['properties']['displayName']): $($flows.Count) flows listed, reading runs"
        # One runs request per flow, in parallel. Runs come newest first: stop paging once a page ends before the window.
        # The Flow API returns 503/504 timeouts now and then; without retries the flow lost all its runs for that build and showed UNREADABLE.
        $flowRows = $flows | ForEach-Object -ThrottleLimit $Parallel -Parallel {
            $flow = $_; $api = $using:api; $ver = $using:ver; $h = $using:h; $since = $using:since; $tz = $using:tz; $envId = ($using:env)['name']
            $fd = ($using:c).FlowDays; $fdName = $flow['properties']['displayName']; if ($fd -and $fd.$fdName) { $since = ($using:nowUtc).AddDays(-$fd.$fdName) }
            $utc = { param($s) [datetime]::Parse($s, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) }
            $url = "$api/environments/$envId/flows/$($flow['name'])/runs?$ver"; $runs = @(); $status = $null
            try {
                while ($url) {
                    $r = (Invoke-WebRequest -Uri $url -Headers $h -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 60).Content | ConvertFrom-Json -AsHashtable
                    $runs += $r['value']; $url = $r['nextLink']
                    if ($runs.Count -and (& $utc $runs[-1]['properties']['startTime']) -lt $since) { break }
                }
                $runs = @($runs | Where-Object { (& $utc $_['properties']['startTime']) -ge $since })
            } catch { $status = 'UNREADABLE' }
            $tr = try { $t = $flow['properties']['definitionSummary']['triggers'][0]; "$($t['type'])/$($t['kind'])" } catch { '' }
            $base = @{ Flow = $flow['properties']['displayName']; FlowId = $flow['name']; Enabled = ($flow['properties']['state'] -eq 'Started'); Trigger = $tr }
            if ($status)             { [pscustomobject]($base + @{ Start = ''; Status = $status }) }
            elseif ($runs.Count -eq 0) { [pscustomobject]($base + @{ Start = ''; Status = 'NO_RUNS' }) }
            else { foreach ($run in $runs) { [pscustomobject]($base + @{ Start = [TimeZoneInfo]::ConvertTimeFromUtc((& $utc $run['properties']['startTime']), $tz).ToString('s'); Status = $run['properties']['status'] }) } }
        }
        foreach ($fr in $flowRows) {
            $rows.Add([pscustomobject]@{ Collected = $collected; Client = $c.Name; Environment = $env['properties']['displayName']; EnvironmentId = $env['name']; Flow = $fr.Flow; FlowId = $fr.FlowId; Enabled = $fr.Enabled; Trigger = $fr.Trigger; Start = $fr.Start; Status = $fr.Status })
        }
    }
    Write-Host "$($c.Name): $($envs.Count) environment(s), $(@($rows | Where-Object Client -eq $c.Name).Count) rows"

    # Power BI: last refresh per semantic model in the listed workspaces. Refresh times come back as UTC ISO strings.
    if ($c.PowerBI) {
        try {
            $pt = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = $rt; scope = 'https://analysis.windows.net/powerbi/api/.default offline_access' }
            $ph = @{ Authorization = "Bearer $($pt.access_token)" }
            $groups = @((Invoke-RestMethod -Uri 'https://api.powerbi.com/v1.0/myorg/groups' -Headers $ph).value | Where-Object { $_.name -in $c.PowerBI })
            foreach ($missing in @($c.PowerBI | Where-Object { $_ -notin $groups.name })) { $failures += "$($c.Name): Power BI workspace not found: $missing" }
            # Next scheduled refresh: the schedule gives weekdays (empty = every day), "HH:mm" times and its own time zone.
            $nextRefresh = { param($sch)
                if (-not $sch -or -not $sch.enabled -or -not $sch.times) { return '' }
                $stz = try { [TimeZoneInfo]::FindSystemTimeZoneById($sch.localTimeZoneId) } catch { $tz }
                $nowS = [TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $stz); $days = if ($sch.days) { @($sch.days) } else { [Enum]::GetNames([DayOfWeek]) }; $best = $null
                foreach ($d in 0..7) { $day = $nowS.Date.AddDays($d); if ($days -notcontains $day.DayOfWeek.ToString()) { continue }
                    foreach ($t in $sch.times) { $cand = $day.Add([TimeSpan]::Parse($t)); if ($cand -gt $nowS -and (-not $best -or $cand -lt $best)) { $best = $cand } } }
                if ($best) { [TimeZoneInfo]::ConvertTimeFromUtc([TimeZoneInfo]::ConvertTimeToUtc($best, $stz), $tz).ToString('s') } else { '' }
            }
            foreach ($g in $groups) {
                foreach ($ds in (Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($g.id)/datasets" -Headers $ph).value) {
                    $r   = try { @((Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($g.id)/datasets/$($ds.id)/refreshes?`$top=1" -Headers $ph).value)[0] } catch { $null }
                    $sch = try { Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($g.id)/datasets/$($ds.id)/refreshSchedule" -Headers $ph } catch { $null }
                    $toLocal = { param($s) if ($s) { [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse($s, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal), $tz).ToString('s') } else { '' } }
                    $pbi.Add([pscustomobject]@{ Client = $c.Name; Workspace = $g.name; WorkspaceId = $g.id; Model = $ds.name; ModelId = $ds.id
                        Start = (& $toLocal $r.startTime); End = (& $toLocal $r.endTime); Status = $(if ($r) { $r.status } else { 'NO_REFRESH' }); Type = "$($r.refreshType)"
                        Next = (& $nextRefresh $sch); Url = "https://app.powerbi.com/groups/$($g.id)/settings/datasets/$($ds.id)" })
                }
            }
            Write-Host "$($c.Name): Power BI, $(@($pbi | Where-Object Client -eq $c.Name).Count) model(s) in $($groups.Count) workspace(s)"
        } catch { $failures += "$($c.Name): Power BI collection failed: $($_.Exception.Message)" }
    }

    # Power Apps: canvas apps and connections of the listed environments. The admin scope lists everything in the environment
    # (needs a Power Platform admin role); otherwise what the signed-in account can see: its own apps and connections.
    # Owner accounts are looked up in Entra: an app whose owner is disabled or deleted is orphaned (nobody gets its errors, nobody can edit it).
    try {
        $at   = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = $rt; scope = 'https://service.powerapps.com//.default offline_access' }
        $ah   = @{ Authorization = "Bearer $($at.access_token)" }
        $papi = 'https://api.powerapps.com/providers/Microsoft.PowerApps'
        $gt   = try { (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = $rt; scope = 'https://graph.microsoft.com/.default offline_access' }).access_token } catch { $null }
        # Connections are kept only for the integration account, i.e. the one signed in (its UPN is in the token): those are the
        # connections the flows and the supported apps run on; other users' personal connections are not ours to watch.
        $me = try { $cl = $at.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/'); $cl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cl.PadRight($cl.Length + (4 - $cl.Length % 4) % 4, '='))) | ConvertFrom-Json; "$($cl.upn ?? $cl.preferred_username ?? $cl.unique_name)" } catch { '' }
        $ownerState = @{}
        $stateOf = { param($upn)
            if (-not $upn) { return 'Unknown' }
            if (-not $ownerState.ContainsKey($upn)) {
                $ownerState[$upn] = if (-not $gt) { 'Unknown' } else {
                    try { if ((Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=accountEnabled" -Headers @{ Authorization = "Bearer $gt" }).accountEnabled) { 'Active' } else { 'Disabled' } }
                    catch { if ($_.Exception.Response.StatusCode -eq 404) { 'Deleted' } else { 'Unknown' } }
                }
            }
            $ownerState[$upn]
        }
        $scopeNote = ''
        foreach ($env in $envs) {
            $envId = $env['name']; $envName = $env['properties']['displayName']
            $list = try { @(Get-All "$papi/scopes/admin/environments/$envId/apps?$ver" $ah) } catch { $scopeNote = ' (own apps and connections only: no admin role)'; @(Get-All "$papi/apps?$ver&`$filter=environment eq '$envId'" $ah) }
            foreach ($a in $list) {
                # Property access ($x.key) on a missing hashtable is $null; indexing ($x['key']) throws. Owners, statuses and errors can all be missing.
                $p = $a['properties']; $refs = @(if ($p['connectionReferences']) { $p['connectionReferences'].Values }); $o = $p['owner']   # @($null.Values) would be @($null), and $null['x'] throws
                # Skipped: platform-owned apps (owner SYSTEM: Dataverse sample apps and the like) and apps owned by the client's former
                # integrator (Createch), which are not supported here. -match is case-insensitive.
                if ("$($o.displayName)" -eq 'SYSTEM' -or "$($o.displayName) $($o.email) $($o.userPrincipalName)" -match 'createch') { continue }
                $apps.Add([pscustomobject]@{ Client = $c.Name; Environment = $envName; EnvironmentId = $envId; App = $p['displayName']; AppId = $a['name']
                    Owner = "$($o.displayName)"; OwnerEmail = "$($o.email)"; OwnerState = (& $stateOf ($o.userPrincipalName ?? $o.email))
                    Shared = [int]$p['sharedUsersCount'] + [int]$p['sharedGroupsCount']; Connectors = (@($refs | ForEach-Object { $_['displayName'] } | Sort-Object -Unique) -join ', ')
                    Premium = [bool]($refs | Where-Object { $_['apiTier'] -eq 'Premium' }); Created = (& $toLocal $p['createdTime']); Modified = (& $toLocal $p['lastModifiedTime']); Published = (& $toLocal $p['appVersion'])
                    Url = "https://make.powerapps.com/environments/$envId/apps/$($a['name'])/details" })
            }
            $list = try { @(Get-All "$papi/scopes/admin/environments/$envId/connections?$ver" $ah) } catch { @(Get-All "$papi/connections?$ver&`$filter=environment eq '$envId'" $ah) }
            foreach ($k in $list) {
                $p = $k['properties']; $apiName = ("$($p['apiId'])" -split '/')[-1]; $st = @($p['statuses'])[0]; $by = $p['createdBy']
                if ($me -and "$($by.email)" -ne $me -and "$($by.userPrincipalName)" -ne $me) { continue }   # string -ne is case-insensitive
                $conns.Add([pscustomobject]@{ Client = $c.Name; Environment = $envName; EnvironmentId = $envId; Connection = $p['displayName']; Connector = ($apiName -replace '^shared_', '')
                    Owner = "$($by.displayName)"; OwnerEmail = "$($by.email)"; Status = "$($st.status)"; Error = "$($st.error.message)"; Modified = (& $toLocal $p['lastModifiedTime'])
                    Url = "https://make.powerapps.com/environments/$envId/connections/$apiName/$($k['name'])/details" })
            }
        }
        Write-Host "$($c.Name): Power Apps, $(@($apps | Where-Object Client -eq $c.Name).Count) app(s), $(@($conns | Where-Object Client -eq $c.Name).Count) connection(s)$scopeNote"
    } catch { $failures += "$($c.Name): Power Apps collection failed: $($_.Exception.Message)" }
}

# Carry-over: a client that could not be signed in from here is taken from CARRY_URL, a data.json that the laptop
# collector (flow-runs.ps1) publishes to a gist whenever it runs. Its snapshot time is kept, so the page shows STALE
# for that client once the laptop has been off for an hour, instead of the client vanishing.
Remove-Item "$out/carry.json" -ErrorAction SilentlyContinue
if ($blocked -and $env:CARRY_URL) {
    try {
        $c = Invoke-RestMethod -Uri "$($env:CARRY_URL)?t=$(Get-Date -UFormat %s)"   # cache-buster: gist raw URLs are cached ~5 min
        $carry = @{ snapshots = @{}; flows = @(); days = @(); fails = @(); powerbi = @(); apps = @(); connections = @() }
        foreach ($name in $blocked) {
            if ($c.snapshots.$name) { $carry.snapshots[$name] = $c.snapshots.$name }
            $carry.flows += @($c.flows | Where-Object Client -eq $name); $carry.days += @($c.days | Where-Object Client -eq $name); $carry.fails += @($c.fails | Where-Object Client -eq $name)
            $carry.powerbi += @($c.powerbi | Where-Object Client -eq $name); $carry.apps += @($c.apps | Where-Object Client -eq $name); $carry.connections += @($c.connections | Where-Object Client -eq $name)
            Write-Host "$name`: carried over $(@($c.flows | Where-Object Client -eq $name).Count) flows from $($c.snapshots.$name)"
        }
        $carry | ConvertTo-Json -Depth 5 -Compress | Set-Content "$out/carry.json" -Encoding UTF8
    } catch { $failures += "carry-over failed: $_" }
}

# Stamp the snapshot when the collection ends: on the laptop it takes minutes, and a run that started meanwhile
# would otherwise show a start later than its own snapshot on the page.
$collected = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).ToString('s'); foreach ($r in $rows) { $r.Collected = $collected }
if ($rows.Count) { $rows | Export-Csv -Path "$out/flow-runs.csv" -NoTypeInformation -Encoding UTF8 }
if ($pbi.Count)  { $pbi  | Export-Csv -Path "$out/powerbi.csv"   -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/powerbi.csv" -ErrorAction SilentlyContinue }
if ($apps.Count) { $apps | Export-Csv -Path "$out/powerapps.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/powerapps.csv" -ErrorAction SilentlyContinue }
if ($conns.Count) { $conns | Export-Csv -Path "$out/connections.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/connections.csv" -ErrorAction SilentlyContinue }
& "$PSScriptRoot/build-dashboard.ps1"
$failures | ForEach-Object { Write-Warning $_ }
# Fail the job (GitHub emails the repo owner) only when nothing at all was collected: the collector itself is broken.
if ($blocked.Count -eq @($clients).Count) { exit 1 }
