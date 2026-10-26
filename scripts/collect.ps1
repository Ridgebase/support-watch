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
#   ODOO_URL, ODOO_USER, ODOO_KEY  optional: the Odoo Helpdesk tickets in progress go to tickets.csv (see the Helpdesk block)
#   WATCH_FEEDS    optional: public RSS/Atom feeds for the Tech watch tab, one per line "Label | URL | optional regex" (see the Tech watch block)
#   MC_<NAME>      optional per client: a second refresh token (get-refresh-token.ps1 -MessageCenter) that reads the client's Microsoft 365
#                  Message Center into changes.csv: the service changes section of the Tech watch tab
#   RT_<NAME>      the client's refresh token (from get-refresh-token.ps1), e.g. RT_SEMO. Also exchanged for a Graph token that reads the tenant's
#                  licences (licences.csv, tenants.csv, licusers.csv: the Licences tab), no extra consent needed
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
$why       = { param($e) $m = @(); while ($e) { $m += $e.Message; $e = $e.InnerException }; $m -join ' <- ' }   # the whole exception chain: "SSL connection could not be established" alone says nothing
$rows      = [System.Collections.Generic.List[object]]::new()
$pbi       = [System.Collections.Generic.List[object]]::new()   # one row per semantic model: its last refresh
$pbiRuns   = [System.Collections.Generic.List[object]]::new()   # one row per Power BI refresh in the window: the tab's recap and the weekly mail (same shape as flow runs)
$apps      = [System.Collections.Generic.List[object]]::new()   # one row per canvas app: owner, sharing, connectors
$conns     = [System.Collections.Generic.List[object]]::new()   # one row per connection: its status (an expired credential is the usual "the app stopped working")
$envcap    = [System.Collections.Generic.List[object]]::new()   # one row per environment of the tenant: Dataverse capacity used and rated, add-ons allocated (per-app passes...)
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
    # CARRY_CLIENTS: clients never collected from here, only taken from CARRY_URL. SEMO is collected by the Azure function:
    # its Conditional Access lets GitHub's runners through now and then, and a direct collection from here (slower, no Power BI
    # since that config lives on the function only) must not replace the function's copy.
    if ($c.Name -in @($env:CARRY_CLIENTS -split ',' | ForEach-Object Trim)) { $blocked += $c.Name; continue }
    $rt = [Environment]::GetEnvironmentVariable("RT_$($c.Name)")
    if (-not $rt) { $failures += "$($c.Name): no RT_$($c.Name) secret"; $blocked += $c.Name; continue }
    try {
        $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = $rt; scope = $scope }
    } catch {
        # AADSTS53003 = the tenant's Conditional Access blocks sign-ins from GitHub's servers (SEMO does). invalid_grant otherwise = token revoked: rerun get-refresh-token.ps1.
        $failures += "$($c.Name): token refresh failed: $(($_.ErrorDetails.Message | ConvertFrom-Json).error_description)"; $blocked += $c.Name; continue
    }
    $h = @{ Authorization = "Bearer $($tok.access_token)" }

    # The environments and flows lists are read without per-flow retries: a 60 s stall there (seen 2026-10-05, it killed the
    # whole job) makes the client blocked for this run, i.e. carried over from the gist like a failed sign-in, instead of exit 1.
    try {
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
            $cap = { param($m) $m = "$m".Trim(': ') -replace '\s+', ' '; if ($m.Length -gt 4000) { $m.Substring(0, 4000) + '...' } else { $m } }   # the user wants the whole message; 4000 only guards the CSV and the page
            # A failed run's own error is the same banner nearly every time ("ActionFailed: An action failed. No dependent actions succeeded."), so
            # the newest failed runs of the flow get two more calls each: the run's actions, where the failed leaf names what broke, then that
            # leaf's outputs (a short-lived blob URL in outputsLink, no auth), whose body carries the connector's message:
            # "List files: BadRequest - Check your request parameters to make sure the path '' exists on your file system."
            # Containers (Scope, Apply to each, Condition) fail with ActionFailed because a child did, so the leaves are the failed actions
            # with another code; a failure inside a loop iteration shows only its container.
            $err = { param($e) if ($e) { & $cap "$($e['code']): $($e['message'])" } else { '' } }
            $outMsg = { param($uri) try {
                    $b = (((Invoke-WebRequest -Uri $uri -TimeoutSec 15).Content | ConvertFrom-Json -AsHashtable))['body']
                    # A JSON body holds the cause under message / Message / ExceptionMessage / error.message / InnerException..., in no fixed shape: every message-like
                    # field is collected, outermost first ("An error has occurred. - Valeur non valide pour le champ Numero ..."); stack traces are skipped.
                    # An HTML body (a gateway's 503 page) is kept as its text. Correlation and request ids are dropped so identical errors group on the page.
                    $msgs = [System.Collections.Generic.List[string]]::new()
                    $idRx = '(?i)\s*(clientRequestId|CorrelationId)\s*:\s*[0-9a-f-]{8,}\.?'
                    $add = { param($v) $n = ($v -replace $idRx, '').Trim(); if (-not $n -or ($msgs | Where-Object { $_.Contains($n) })) { return }; foreach ($x in @($msgs | Where-Object { $n.Contains($_) })) { [void]$msgs.Remove($x) }; $msgs.Add($n) }   # ids off before comparing; a message already inside another is skipped
                    $walk = { param($h, $depth) if ($depth -gt 4) { return }; if ($h -is [hashtable]) { foreach ($k in $h.Keys) { $v = $h[$k]; if ($k -match '^(message|exceptionmessage|error_description|description|detail|details|reason)$' -and $v -is [string]) { & $add $v } elseif ($v -is [hashtable] -or $v -is [array]) { & $walk $v ($depth + 1) } } } elseif ($h -is [array]) { foreach ($x in $h) { & $walk $x ($depth + 1) } } }
                    $m = if ($b -is [hashtable] -or $b -is [array]) { & $walk $b 0; if ($msgs.Count) { $msgs -join ' - ' } else { $b | ConvertTo-Json -Compress -Depth 3 } } elseif ("$b".TrimStart() -notlike '<*') { "$b" } else { ("$b" -replace '(?is)<(script|style).*?</>', '' -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ') }
                    ($m -replace $idRx, '').Trim()
                } catch { '' } }
            $actErr = { param($runName)
                try {
                    $acts = ((Invoke-WebRequest -Uri "$api/environments/$envId/flows/$($flow['name'])/runs/$runName/actions?$ver" -Headers $h -MaximumRetryCount 2 -RetryIntervalSec 3 -TimeoutSec 30).Content | ConvertFrom-Json -AsHashtable)['value']
                    $failed = @($acts | Where-Object { $_['properties']['status'] -eq 'Failed' })
                    $leaves = @($failed | Where-Object { $_['properties']['code'] -ne 'ActionFailed' }); if (-not $leaves) { $leaves = $failed }
                    $parts = @($leaves | Select-Object -First 2 | ForEach-Object { $e = $_['properties']['error']; "$($_['name'] -replace '_', ' '): $(if ($e -and $e['message'] -and $e['code'] -ne 'ActionFailed') { $e['message'] } else { $_['properties']['code'] })" })
                    $uri = try { $leaves[0]['properties']['outputsLink']['uri'] } catch { $null }
                    if ($parts -and $uri) { $m = & $outMsg $uri; if ($m) { $parts[0] += " - $m" } }
                    & $cap ($parts -join '; ')
                } catch { '' }
            }
            $start = "$api/environments/$envId/flows/$($flow['name'])/runs?$ver"; $runs = @(); $status = $null
            # A timeout throws (-MaximumRetryCount only covers HTTP error codes), so a flow gets a second full attempt before it is UNREADABLE.
            foreach ($attempt in 1, 2) {
                $url = $start; $runs = @()
                try {
                    while ($url) {
                        $r = (Invoke-WebRequest -Uri $url -Headers $h -MaximumRetryCount 3 -RetryIntervalSec 5 -TimeoutSec 60).Content | ConvertFrom-Json -AsHashtable
                        $runs += $r['value']; $url = $r['nextLink']
                        if ($runs.Count -and (& $utc $runs[-1]['properties']['startTime']) -lt $since) { break }
                    }
                    $runs = @($runs | Where-Object { (& $utc $_['properties']['startTime']) -ge $since })
                    $status = $null; break
                } catch { $status = 'UNREADABLE' }
            }
            $tr = try { $t = $flow['properties']['definitionSummary']['triggers'][0]; "$($t['type'])/$($t['kind'])" } catch { '' }
            $base = @{ Flow = $flow['properties']['displayName']; FlowId = $flow['name']; Enabled = ($flow['properties']['state'] -eq 'Started'); Trigger = $tr }
            if ($status)             { [pscustomobject]($base + @{ Start = ''; Status = $status }) }
            elseif ($runs.Count -eq 0) { [pscustomobject]($base + @{ Start = ''; Status = 'NO_RUNS' }) }
            else { $nf = 0; foreach ($run in $runs) {   # runs come newest first: the 30 newest failed runs get the action-level error, older ones the run's banner
                $e = & $err $run['properties']['error']
                if ($run['properties']['status'] -eq 'Failed' -and $nf++ -lt 30) { $a = & $actErr $run['name']; if ($a) { $e = $a } }
                [pscustomobject]($base + @{ Start = [TimeZoneInfo]::ConvertTimeFromUtc((& $utc $run['properties']['startTime']), $tz).ToString('s'); Status = $run['properties']['status']; RunId = $run['name']; Error = $e }) } }
        }
        foreach ($fr in $flowRows) {
            $rows.Add([pscustomobject]@{ Collected = $collected; Client = $c.Name; Environment = $env['properties']['displayName']; EnvironmentId = $env['name']; Flow = $fr.Flow; FlowId = $fr.FlowId; Enabled = $fr.Enabled; Trigger = $fr.Trigger; Start = $fr.Start; Status = $fr.Status; RunId = "$($fr.RunId)"; Error = "$($fr.Error)" })
        }
    }
    } catch {
        $failures += "$($c.Name): flow collection failed: $(& $why $_.Exception)"; $blocked += $c.Name
        $rows.RemoveAll({ param($r) $r.Client -eq $c.Name }) | Out-Null   # a half-collected client would double up with its carry-over
        continue
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
                    # Refresh history, newest first (the service keeps about 60 entries): the first one is the model's row, the week's go to powerbi-runs.csv.
                    $hist = try { @((Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($g.id)/datasets/$($ds.id)/refreshes?`$top=60" -Headers $ph).value) } catch { @() }
                    $r   = if ($hist) { $hist[0] } else { $null }
                    $sch = try { Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($g.id)/datasets/$($ds.id)/refreshSchedule" -Headers $ph } catch { $null }
                    $toLocal = { param($s) if ($s) { [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::Parse($s, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal), $tz).ToString('s') } else { '' } }
                    foreach ($x in $hist) {   # Unknown = still running: not a finished refresh
                        if ($x.startTime -and $x.status -ne 'Unknown' -and [datetime]::Parse($x.startTime, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) -ge $since) {
                            $pbiRuns.Add([pscustomobject]@{ Client = $c.Name; Workspace = $g.name; Model = $ds.name; ModelId = $ds.id; Start = (& $toLocal $x.startTime); End = (& $toLocal $x.endTime); Status = $x.status; Type = "$($x.refreshType)" })
                        }
                    }
                    $pbi.Add([pscustomobject]@{ Client = $c.Name; Workspace = $g.name; WorkspaceId = $g.id; Model = $ds.name; ModelId = $ds.id
                        Start = (& $toLocal $r.startTime); End = (& $toLocal $r.endTime); Status = $(if ($r) { $r.status } else { 'NO_REFRESH' }); Type = "$($r.refreshType)"
                        Next = (& $nextRefresh $sch); Url = "https://app.powerbi.com/groups/$($g.id)/settings/datasets/$($ds.id)" })
                }
            }
            Write-Host "$($c.Name): Power BI, $(@($pbi | Where-Object Client -eq $c.Name).Count) model(s) in $($groups.Count) workspace(s)"
        } catch { $failures += "$($c.Name): Power BI collection failed: $(& $why $_.Exception)" }
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
        # Dataverse capacity and add-on allocations, for every environment of the tenant (not only the listed ones: capacity is pooled tenant-wide).
        # actualConsumption = used. (ratedConsumption is the billed figure, 1 GB minimum per production database, not an entitlement; the tenant's
        # entitlement is not readable through any API this token reaches, so the page shows what is used.) Add-ons (per-app passes, per-flow plans,
        # AI credits...) are allocated to an environment: the only place a per-app pass is ever "assigned" (Licences tab).
        $r = Invoke-RestMethod -Uri 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2021-04-01&$expand=properties.capacity,properties.addons' -Headers $ah -TimeoutSec 60
        foreach ($e in $r.value) {
            $cap = @{}; foreach ($x in $e.properties.capacity) { $cap["$($x.capacityType)"] = $x }
            $add = @{}; foreach ($x in $e.properties.addons) { $add["$($x.addonType)"] = [int]$x.allocated }
            $mb = { param($t) [math]::Round([double]$cap[$t].actualConsumption) }   # MB
            $envcap.Add([pscustomobject]@{ Client = $c.Name; Environment = "$($e.properties.displayName)"; EnvironmentId = "$($e.name)"; Type = "$($e.properties.environmentSku)"
                DbUsed = (& $mb Database); FileUsed = (& $mb File); LogUsed = (& $mb Log); AppPass = [int]$add['AppPass']; PerFlow = [int]$add['PerFlowPlan']
                Addons = (@($add.GetEnumerator() | Where-Object { $_.Value -and $_.Key -notin 'AppPass', 'PerFlowPlan' } | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') })
        }
        Write-Host "$($c.Name): $($r.value.Count) environment(s) with capacity and add-ons"
    } catch { $failures += "$($c.Name): Power Apps collection failed: $(& $why $_.Exception)" }
}

# Helpdesk: the Odoo tickets in the "In Progress" stage. One Odoo database for all clients, so collected once, from the cloud job only
# (ODOO_URL, ODOO_USER, ODOO_KEY: a user API key, which works with 2FA; the database name is the host's first label, Odoo Online's rule).
# A ticket's client: the CLIENTS_JSON entry whose optional "Odoo" field equals the customer's company in Odoo, else the one whose tenant's
# first label is contained in that company name (seguinmorris.com ~ "Séguin Morris Inc") or whose Name appears in it as a word ("... (TSMO)"). Unmatched tickets keep Client = '' (shown under All clients).
$tickets = [System.Collections.Generic.List[object]]::new(); $helpdeskAt = ''   # snapshot time of the ticket list (its own line in the page header); '' = not collected this run
if ($env:ODOO_URL -and $env:ODOO_KEY) {
    try {
        $ou = $env:ODOO_URL.TrimEnd('/'); $odb = ([uri]$ou).Host.Split('.')[0]
        $rpc = { param($svc, $m, $a)
            $r = Invoke-RestMethod -Method Post -Uri "$ou/jsonrpc" -ContentType 'application/json' -TimeoutSec 60 -Body (@{ jsonrpc = '2.0'; method = 'call'; id = 1; params = @{ service = $svc; method = $m; args = $a } } | ConvertTo-Json -Depth 10 -Compress)
            if ($r.error) { throw "$($r.error.data.message ?? $r.error.message)" }; $r.result }
        $uid = & $rpc common authenticate @($odb, $env:ODOO_USER, $env:ODOO_KEY, @{})
        if (-not $uid) { throw 'sign-in refused (ODOO_USER or ODOO_KEY)' }
        $fields = 'ticket_ref', 'name', 'commercial_partner_id', 'stage_id', 'priority', 'user_id', 'create_date', 'write_date', 'sla_deadline'
        $list = @(& $rpc object execute_kw @($odb, $uid, $env:ODOO_KEY, 'helpdesk.ticket', 'search_read', @(, @(, @('stage_id.name', '=', 'In Progress'))), @{ fields = $fields }))
        # Odoo returns false for an empty field and [id, name] for a relation; its dates are naive UTC strings.
        $m2o  = { param($v) if ($v -is [array]) { "$($v[1])" } else { '' } }
        $odt  = { param($v) if ($v -is [string] -and $v) { & $toLocal ($v.Replace(' ', 'T') + 'Z') } else { '' } }
        $norm = { param($s) (("$s".Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}') -replace '[^a-zA-Z]').ToLower() }   # "Séguin Morris Inc" -> seguinmorrisinc
        $prio = @{ '0' = 'Low'; '1' = 'Medium'; '2' = 'High'; '3' = 'Urgent' }
        foreach ($t in $list) {
            $cust = & $m2o $t.commercial_partner_id
            # ponytail: name containment is a heuristic; a client it misses gets an explicit "Odoo" field in CLIENTS_JSON.
            $cl = @($clients | Where-Object { ($_.Odoo -and $_.Odoo -eq $cust) -or ($cust -match "\b$([regex]::Escape($_.Name))\b") -or ($_.Tenant -and (& $norm $cust).Contains((& $norm $_.Tenant.Split('.')[0]))) })
            $tickets.Add([pscustomobject]@{ Client = "$(@($cl)[0].Name)"; Customer = $cust; Ref = "$($t.ticket_ref)"; Ticket = "$($t.name)"; Stage = (& $m2o $t.stage_id)
                Priority = "$($prio["$($t.priority)"])"; Assignee = (& $m2o $t.user_id); Created = (& $odt $t.create_date); Updated = (& $odt $t.write_date); Deadline = (& $odt $t.sla_deadline)
                Url = "$ou/odoo/helpdesk/$($t.id)" })
        }
        $helpdeskAt = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).ToString('s')
        Write-Host "Helpdesk: $($tickets.Count) ticket(s) in progress"
    } catch { $failures += "Helpdesk collection failed: $(& $why $_.Exception)" }
}

# Tech watch, part 1: service changes. Each client's Microsoft 365 Message Center (Graph serviceAnnouncement/messages) is the one place Microsoft
# announces retirements, licensing and policy changes, with the services affected and an action date. The Flow refresh token cannot read it (the
# Azure CLI app is not pre-authorized for ServiceMessage.Read.All), hence MC_<NAME>, a second token made by get-refresh-token.ps1 -MessageCenter
# with the Microsoft Graph PowerShell app; the signed-in account needs a role that reads the Message Center. Kept: messages changed in the last
# 60 days that are more than "Stay informed" (a plan for change, a fix to apply, a major change, a retirement, an action date) and that concern
# what we support: WATCH_SERVICES, a regex on the message's services and title (default below: Power Platform, Dataverse, Dynamics, Entra,
# and anything about licensing or pricing); the rest is the tenant admin's Teams, Exchange and Office housekeeping. One row per client and message;
# the page merges the clients that share a message id. SEMO's rows come through the function and the carry-over like the rest.
$text = { param($s) if ($s -is [System.Xml.XmlNode]) { $s = $s.InnerText }   # a CDATA or typed element (blog descriptions, Atom titles) comes as a node, not a string
    [System.Net.WebUtility]::HtmlDecode(([regex]::Replace("$s", '<[^>]+>', ' ') -replace '\s+', ' ')).Trim() }   # HTML -> one line of plain text
$local = { param($v) if (-not $v) { '' } else { $d = if ($v -is [datetime]) { $v.ToUniversalTime() } else { [datetime]::Parse("$v", [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) }
    [TimeZoneInfo]::ConvertTimeFromUtc($d, $tz).ToString('s') } }   # Invoke-RestMethod on PowerShell 7 already turns ISO dates into [datetime]; $toLocal expects strings
$changes = [System.Collections.Generic.List[object]]::new()
$svc = if ($env:WATCH_SERVICES) { $env:WATCH_SERVICES } else { 'Power (Platform|Apps|Automate|BI|Pages)|Copilot Studio|Dataverse|Dynamics|Entra|licen[cs]|pricing|billing|subscription' }   # the default also serves the function, which has no such setting; "Power " alone catches PowerPoint and PowerShell
foreach ($c in $clients) {
    $mrt = [Environment]::GetEnvironmentVariable("MC_$($c.Name)")
    if (-not $mrt -or $c.Name -in @($env:CARRY_CLIENTS -split ',' | ForEach-Object Trim)) { continue }
    try {
        $gt = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; refresh_token = $mrt; scope = 'https://graph.microsoft.com/ServiceMessage.Read.All offline_access' }).access_token
        $url = "https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/messages?`$filter=lastModifiedDateTime ge $([datetime]::UtcNow.AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ssZ'))"; $n = 0
        while ($url) {
            $r = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $gt" } -TimeoutSec 60
            foreach ($m in $r.value) {
                $act = "$(& $local $m.actionRequiredByDateTime)"
                if ($m.category -eq 'stayInformed' -and -not $m.isMajorChange -and -not $act -and @($m.tags) -notcontains 'Retirement') { continue }
                $sum = & $text $m.body.content; if ($sum.Length -gt 300) { $sum = $sum.Substring(0, 297) + '...' }
                if ("$(@($m.services) -join ', ') $($m.title)" -notmatch $svc) { continue }   # not the body: half the messages mention Entra or a subscription somewhere in it
                $changes.Add([pscustomobject]@{ Client = $c.Name; Id = "$($m.id)"; Title = "$($m.title)"; Category = "$($m.category)"; Severity = "$($m.severity)"; Major = [bool]$m.isMajorChange
                    Tags = (@($m.tags) -join ', '); Services = (@($m.services) -join ', '); Start = (& $local $m.startDateTime); ActionBy = $act; Modified = (& $local $m.lastModifiedDateTime)
                    Summary = $sum; Url = "https://admin.microsoft.com/#/MessageCenter/:/messages/$($m.id)" }); $n++
            }
            $url = $r.'@odata.nextLink'
        }
        Write-Host "$($c.Name): $n service change(s) from the Message Center"
    } catch { $failures += "$($c.Name): Message Center failed: $(& $why $_.Exception)" }
}

# Licences: per client, from Graph with the Flow refresh token (no extra consent: subscribedSkus, directory/subscriptions and users read with the
# signed-in account's directory access). licences.csv = one row per SKU: seats bought (prepaid, enabled), assigned, in grace (warning), suspended,
# and the next renewal among its enabled subscriptions; tenants.csv = one row per client with the user counts; licusers.csv = disabled accounts
# that still hold a paid licence (seats paid for nobody). A free, trial or developer plan has 10 000 seats or more: kept, muted on the page.
$licences = [System.Collections.Generic.List[object]]::new(); $tenants = [System.Collections.Generic.List[object]]::new(); $licusers = [System.Collections.Generic.List[object]]::new()
foreach ($c in $clients) {
    if ($c.Name -in $blocked) { continue }
    try {
        $gt = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($c.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'refresh_token'; client_id = $clientId; refresh_token = [Environment]::GetEnvironmentVariable("RT_$($c.Name)"); scope = 'https://graph.microsoft.com/.default offline_access' }).access_token
        $gh = @{ Authorization = "Bearer $gt"; ConsistencyLevel = 'eventual' }   # eventual: needed by $count on users
        $subs = @((Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/directory/subscriptions' -Headers $gh -TimeoutSec 60).value); $skuName = @{}
        foreach ($k in (Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $gh -TimeoutSec 60).value) {
            if ($k.prepaidUnits.enabled -gt 0 -and $k.prepaidUnits.enabled -lt 10000) { $skuName["$($k.skuId)"] = "$($k.skuPartNumber)" }   # paid plans only: a disabled account holding a free plan costs nothing
            $ks = @($subs | Where-Object { "$($_.skuId)" -eq "$($k.skuId)" -and $_.status -eq 'Enabled' -and $_.nextLifecycleDateTime })
            $next = @($ks | ForEach-Object { & $local $_.nextLifecycleDateTime } | Sort-Object)   # the earliest renewal among the SKU's live subscriptions
            $licences.Add([pscustomobject]@{ Client = $c.Name; Sku = "$($k.skuPartNumber)"; Bought = [int]$k.prepaidUnits.enabled; Assigned = [int]$k.consumedUnits; Warning = [int]$k.prepaidUnits.warning
                Suspended = [int]$k.prepaidUnits.suspended; Status = "$($k.capabilityStatus)"; Renewal = "$(if ($next) { $next[0] })"; Subscriptions = $ks.Count; Trial = [bool]($ks | Where-Object isTrial) })
        }
        $enabled = (Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users?$count=true&$filter=accountEnabled eq true&$select=id&$top=1' -Headers $gh -TimeoutSec 60).'@odata.count'
        $url = 'https://graph.microsoft.com/v1.0/users?$filter=accountEnabled eq false&$select=displayName,userPrincipalName,assignedLicenses&$top=999'; $disabled = 0
        while ($url) {
            $r = Invoke-RestMethod -Uri $url -Headers $gh -TimeoutSec 60; $disabled += @($r.value).Count
            foreach ($u in $r.value) {
                $paid = @($u.assignedLicenses | ForEach-Object { $skuName["$($_.skuId)"] } | Where-Object { $_ })
                if ($paid) { $licusers.Add([pscustomobject]@{ Client = $c.Name; User = "$($u.displayName)"; Upn = "$($u.userPrincipalName)"; Licences = $paid.Count; Skus = ($paid -join ', ') }) }
            }
            $url = $r.'@odata.nextLink'
        }
        $tenants.Add([pscustomobject]@{ Client = $c.Name; Users = [int]$enabled; Disabled = [int]$disabled })
        Write-Host "$($c.Name): licences, $($skuName.Count) SKU(s), $enabled enabled users, $disabled disabled"
    } catch { $failures += "$($c.Name): licence collection failed: $(& $why $_.Exception)" }
}

# Tech watch, part 2: a general (not per client) feed of Microsoft product news, the tab's bottom section. WATCH_FEEDS (plain env in watch.yml,
# cloud job only: the SEMO function has no such setting) lists public RSS 2.0 or Atom feeds, one per line, "Label | URL | optional regex":
# an item is kept when its title or categories match the regex (the M365 roadmap feed lists every product, the regex keeps ours).
# Newest 25 items per feed from the last 45 days, summaries cut at 300 characters, so the page grows by a few tens of KB at most.
# Blogs change daily at most, so the feeds are read once a day (the roadmap feed alone is 2.6 MB) into state/news.csv, committed by the
# workflow bot with the rest of state/ and read by build-dashboard.ps1 from there; ReadAt (Eastern, on every row) says when. A feed that
# fails is a warning; a day when every feed fails keeps the previous file (the page then shows its older ReadAt).
$newsCache = "$PSScriptRoot/../state/news.csv"
$cached = @(if (Test-Path $newsCache) { Import-Csv $newsCache })
$news = [System.Collections.Generic.List[object]]::new(); $readAt = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).ToString('s')
if ($env:WATCH_FEEDS -and -not ($cached.Count -and ([datetime]$readAt - [datetime]$cached[0].ReadAt).TotalHours -lt 24)) {
    $newsSince = [datetime]::UtcNow.AddDays(-45)
    foreach ($line in "$env:WATCH_FEEDS" -split "`n") {
        $p = $line.Split('|', 3) | ForEach-Object Trim; if ($p.Count -lt 2 -or -not $p[1]) { continue }
        $label, $url, $filter = $p[0], $p[1], "$($p[2])"
        try {
            # A browser User-Agent: microsoft.com answers 403 to the default one. Loaded from the bytes: the roadmap feed starts with a BOM, which [xml] on a string refuses.
            $x = [xml]::new(); $x.Load([IO.MemoryStream]::new((Invoke-WebRequest -Uri $url -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36' -TimeoutSec 60 -UseBasicParsing).RawContentStream.ToArray()))
            $items = @(if ($x.rss) { $x.rss.channel.item } else { $x.feed.entry })   # RSS 2.0 or Atom
            $n = 0
            foreach ($i in $items) {
                $when = "$(if ($x.rss) { $i.pubDate } else { $i.published })"; if (-not $when) { $when = "$($i.updated)" }
                $d = [datetimeoffset]::Parse($when.Replace(' Z', ' +0000'), [cultureinfo]::InvariantCulture).UtcDateTime   # "Fri, 23 Oct 2026 23:10:38 Z" (roadmap), "+0000", "GMT", or Atom's ISO
                if ($d -lt $newsSince) { continue }
                # ponytail: the roadmap tags every item with its clouds and platforms; those are dropped, the status and product tags stay. Extend the list if another feed is as noisy.
                $tags = @($i.category | ForEach-Object { if ($_ -is [string]) { $_ } else { "$($_.term)$($_.'#text')" } } | Where-Object { $_ -notmatch '^(GCC|DoD|Web|Desktop|Mac|iOS|Android|Worldwide|General Availability|Preview|Targeted Release|Current Channel|Developer|Education)' }) -join ', '
                $title = & $text $i.title
                if ($filter -and "$title $tags" -notmatch $filter) { continue }
                $link = "$(if ($i.link -is [string]) { $i.link } else { @($i.link)[0].href })"
                $sum = & $text $(if ($i.description) { $i.description } else { $i.summary }); if ($sum.Length -gt 300) { $sum = $sum.Substring(0, 297) + '...' }
                $news.Add([pscustomobject]@{ Source = $label; Date = [TimeZoneInfo]::ConvertTimeFromUtc($d, $tz).ToString('s'); Title = $title; Url = $link; Summary = $sum; Tags = $tags; ReadAt = $readAt })
                if (++$n -ge 25) { break }
            }
            Write-Host "Tech watch: $label, $n item(s)"
        } catch { $failures += "Tech watch: $label failed: $($_.Exception.Message.Substring(0, [math]::Min(200, $_.Exception.Message.Length)))" }   # cut: a parse error quotes the whole feed
    }
    if ($news.Count) { $news | Export-Csv -Path $newsCache -NoTypeInformation -Encoding UTF8 }
}
# Carry-over: a client that could not be signed in from here is taken from CARRY_URL, a data.json that the laptop
# collector (flow-runs.ps1) publishes to a gist whenever it runs. Its snapshot time is kept, so the page shows STALE
# for that client once the laptop has been off for an hour, instead of the client vanishing.
Remove-Item "$out/carry.json" -ErrorAction SilentlyContinue
if ($blocked -and $env:CARRY_URL) {
    try {
        $c = Invoke-RestMethod -Uri "$($env:CARRY_URL)?t=$(Get-Date -UFormat %s)"   # cache-buster: gist raw URLs are cached ~5 min
        $carry = @{ snapshots = @{}; flows = @(); days = @(); fails = @(); powerbi = @(); pbidays = @(); pbifails = @(); apps = @(); connections = @(); changes = @(); licences = @(); tenants = @(); licusers = @(); envcap = @() }
        foreach ($name in $blocked) {
            if ($c.snapshots.$name) { $carry.snapshots[$name] = $c.snapshots.$name }
            $carry.flows += @($c.flows | Where-Object Client -eq $name); $carry.days += @($c.days | Where-Object Client -eq $name); $carry.fails += @($c.fails | Where-Object Client -eq $name)
            $carry.powerbi += @($c.powerbi | Where-Object Client -eq $name); $carry.pbidays += @($c.pbidays | Where-Object Client -eq $name); $carry.pbifails += @($c.pbifails | Where-Object Client -eq $name); $carry.apps += @($c.apps | Where-Object Client -eq $name); $carry.connections += @($c.connections | Where-Object Client -eq $name); $carry.changes += @($c.changes | Where-Object Client -eq $name)
            $carry.licences += @($c.licences | Where-Object Client -eq $name); $carry.tenants += @($c.tenants | Where-Object Client -eq $name); $carry.licusers += @($c.licusers | Where-Object Client -eq $name); $carry.envcap += @($c.envcap | Where-Object Client -eq $name)
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
if ($pbiRuns.Count) { $pbiRuns | Export-Csv -Path "$out/powerbi-runs.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/powerbi-runs.csv" -ErrorAction SilentlyContinue }
if ($apps.Count) { $apps | Export-Csv -Path "$out/powerapps.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/powerapps.csv" -ErrorAction SilentlyContinue }
if ($conns.Count) { $conns | Export-Csv -Path "$out/connections.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/connections.csv" -ErrorAction SilentlyContinue }
if ($tickets.Count) { $tickets | Export-Csv -Path "$out/tickets.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/tickets.csv" -ErrorAction SilentlyContinue }
if ($changes.Count) { $changes | Export-Csv -Path "$out/changes.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/changes.csv" -ErrorAction SilentlyContinue }
if ($licences.Count) { $licences | Export-Csv -Path "$out/licences.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/licences.csv" -ErrorAction SilentlyContinue }
if ($tenants.Count) { $tenants | Export-Csv -Path "$out/tenants.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/tenants.csv" -ErrorAction SilentlyContinue }
if ($licusers.Count) { $licusers | Export-Csv -Path "$out/licusers.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/licusers.csv" -ErrorAction SilentlyContinue }
if ($envcap.Count) { $envcap | Export-Csv -Path "$out/envcap.csv" -NoTypeInformation -Encoding UTF8 } else { Remove-Item "$out/envcap.csv" -ErrorAction SilentlyContinue }
& "$PSScriptRoot/build-dashboard.ps1" -HelpdeskAt $helpdeskAt
$failures | ForEach-Object { Write-Warning $_ }
# Fail the job (GitHub emails the repo owner) only when nothing at all was collected: the collector itself is broken.
if ($blocked.Count -eq @($clients).Count) { exit 1 }
