# Aggregates flow-runs.csv (one row per run) into site/data.json (per-flow and per-day totals, failed runs) and
# renders site/index.html from dashboard.template.html with that JSON embedded. The page never carries raw runs:
# ~100 KB instead of 4 MB, which matters because it reloads itself every 10 minutes and is fetched by the collector.
# Optional carry.json (same shape as data.json) supplies clients that could not be collected this run.
# Runs on Windows PowerShell 5.1 (laptop) and PowerShell 7 (GitHub Actions).
param(
    [string]$Csv    = "$PSScriptRoot/../out/flow-runs.csv",
    [string]$PbiCsv = "$PSScriptRoot/../out/powerbi.csv",
    [string]$PbiRunsCsv = "$PSScriptRoot/../out/powerbi-runs.csv",
    [string]$AppsCsv = "$PSScriptRoot/../out/powerapps.csv",
    [string]$ConnCsv = "$PSScriptRoot/../out/connections.csv",
    [string]$TicketsCsv = "$PSScriptRoot/../out/tickets.csv",
    [string]$HelpdeskAt = '',   # when collect.ps1 read the Odoo tickets; '' = not collected
    [string]$ChangesCsv = "$PSScriptRoot/../out/changes.csv",
    [string]$LicCsv = "$PSScriptRoot/../out/licences.csv",
    [string]$TenantsCsv = "$PSScriptRoot/../out/tenants.csv",
    [string]$LicUsersCsv = "$PSScriptRoot/../out/licusers.csv",
    [string]$NewsCsv = "$PSScriptRoot/../state/news.csv",   # read once a day by collect.ps1, committed with state/
    [string]$OutDir = "$PSScriptRoot/../out/site",
    [string]$Carry  = "$PSScriptRoot/../out/carry.json"
)
$rows  = @(if (Test-Path $Csv) { @(Import-Csv $Csv) } else { @() })
$isRun = { $_.Status -ne 'NO_RUNS' -and $_.Status -ne 'UNREADABLE' }
$snapshots = @{}; $flows = @(); $days = @(); $fails = @()
$powerbi = @(if (Test-Path $PbiCsv) { @(Import-Csv $PbiCsv) } else { @() })   # last refresh per Power BI semantic model, from collect.ps1
$apps    = @(if (Test-Path $AppsCsv) { @(Import-Csv $AppsCsv) } else { @() })   # canvas apps and connections, from collect.ps1
$conns   = @(if (Test-Path $ConnCsv) { @(Import-Csv $ConnCsv) } else { @() })
$news    = @(if (Test-Path $NewsCsv) { @(Import-Csv $NewsCsv) } else { @() })   # Tech watch: blog and roadmap items, from collect.ps1 (cloud job only, never carried over)
$changes = @(if (Test-Path $ChangesCsv) { @(Import-Csv $ChangesCsv) } else { @() })   # Tech watch: Message Center changes per client, from collect.ps1 (SEMO's carried over)
$licences = @(if (Test-Path $LicCsv) { @(Import-Csv $LicCsv) } else { @() })   # Licences tab: one row per SKU per client, user counts per client, disabled accounts still licensed
$tenants  = @(if (Test-Path $TenantsCsv) { @(Import-Csv $TenantsCsv) } else { @() })
$licusers = @(if (Test-Path $LicUsersCsv) { @(Import-Csv $LicUsersCsv) } else { @() })
$tickets = @(if (Test-Path $TicketsCsv) { @(Import-Csv $TicketsCsv) } else { @() })   # Odoo Helpdesk tickets in progress, from collect.ps1 (cloud job only, never carried over)
$pbiRuns = @(if (Test-Path $PbiRunsCsv) { @(Import-Csv $PbiRunsCsv) } else { @() })   # one row per Power BI refresh in the window, from collect.ps1
$pbidays = @(); $pbifails = @()
$stuckAfterMin = 120   # a run still Running after this is stuck (the user's call: no flow legitimately takes 2 h)
# Weekday clock for silent-flow detection: minutes since 2000-01-03 (a Monday) with Saturdays, Sundays and statutory holidays removed; an instant on
# such a day counts as the previous business day's midnight. Holidays: the union of Quebec and federal ones, observed dates (a weekend holiday moved to the
# Monday), hand-listed; the cost of a missing one is a false "silent" that afternoon, of an extra one a silent flow caught a day later. Extend before 2029.
$holidays = @('2026-01-01', '2026-04-03', '2026-04-06', '2026-05-18', '2026-06-24', '2026-07-01', '2026-09-07', '2026-09-30', '2026-10-12', '2026-11-11', '2026-12-25', '2026-12-28',
              '2027-01-01', '2027-03-26', '2027-03-29', '2027-05-24', '2027-06-24', '2027-07-01', '2027-09-06', '2027-09-30', '2027-10-11', '2027-11-11', '2027-12-27', '2027-12-28',
              '2028-01-03', '2028-04-14', '2028-04-17', '2028-05-22', '2028-06-26', '2028-07-03', '2028-09-04', '2028-10-02', '2028-10-09', '2028-11-13', '2028-12-25', '2028-12-26') | ForEach-Object { [datetime]$_ }
$bizMin = { param([datetime]$d) $dow = [int]$d.DayOfWeek; $wk = [math]::Floor(($d.Date - [datetime]'2000-01-03').TotalDays / 7); $off = $dow -in 0, 6 -or $d.Date -in $holidays
    $wd = if ($dow -in 0, 6) { 5 } else { $dow - 1 }; $tod = if ($off) { 0 } else { ($d - $d.Date).TotalMinutes }   # business days before $d.Date = weeks * 5 + weekday - the holidays already passed
    ($wk * 5 + $wd - @($holidays | Where-Object { $_ -lt $d.Date }).Count) * 1440 + $tod }
$wallMin = { param([datetime]$d) ($d - [datetime]'2000-01-03').TotalMinutes }

# Power BI week, same shape as the flows: totals per model on its row, totals per client per day for the tab's recap and the weekly mail.
foreach ($m in $powerbi) {
    $mr = @($pbiRuns | Where-Object { $_.Client -eq $m.Client -and $_.ModelId -eq $m.ModelId })
    $m | Add-Member -NotePropertyName Refreshes -NotePropertyValue $mr.Count -Force
    $m | Add-Member -NotePropertyName Failed -NotePropertyValue @($mr | Where-Object Status -eq 'Failed').Count -Force
}
$pbifails = @($pbiRuns | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 100 Client, Workspace, Model, ModelId, Start, End, Type,   # the Power BI tab's "Failed refreshes" section
    @{ n = 'Recovered'; e = { $f = $_; "$(($pbiRuns | Where-Object { $_.ModelId -eq $f.ModelId -and $_.Status -eq 'Completed' -and $_.Start -gt $f.Start } | Sort-Object Start | Select-Object -First 1).Start)" } })   # first completed refresh after it: "working again since" in the client's recap
foreach ($g in $pbiRuns | Group-Object Client) {
    foreach ($dg in $g.Group | Group-Object { $_.Start.Substring(0, 10) }) {
        $pbidays += [pscustomobject]@{ Client = $g.Name; Day = $dg.Name; Refreshes = $dg.Count
            Succeeded = @($dg.Group | Where-Object Status -eq 'Completed').Count; Failed = @($dg.Group | Where-Object Status -eq 'Failed').Count }
    }
}

foreach ($g in $rows | Group-Object Client) {
    $snapshots[$g.Name] = ($g.Group | Sort-Object Collected -Descending)[0].Collected
    foreach ($fg in $g.Group | Group-Object Environment, FlowId, Flow) {
        $f = $fg.Group[0]; $runs = @($fg.Group | Where-Object $isRun); $last = $runs | Sort-Object Start -Descending | Select-Object -First 1
        $lf = $runs | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 1   # the latest failed run: notify.ps1 alerts when it is newer than the one it last announced
        $rec = if ($lf) { $runs | Where-Object { $_.Status -eq 'Succeeded' -and $_.Start -gt $lf.Start } | Sort-Object Start | Select-Object -First 1 }   # first success after it: "working again since" in the client's recap
        # Silent flows: Gap = the longest interval between two runs of a recurrence flow this week, in minutes (3 runs needed). An enabled
        # flow whose last run is older than 1.5x that (+15 min of collection slack) at snapshot time is Silent: it stopped running without
        # failing, which no failure count shows. The longest gap, not the median, so a business-hours schedule is not silent every night.
        # A flow with no weekend run in the window is measured on the weekday clock (Saturdays and Sundays do not exist), so a weekday
        # schedule is not silent on Sunday or on a statutory holiday ($holidays), and one that stopped on Friday is caught on Monday afternoon. A run on a weekend
        # (a manual resubmit, a schedule changed since) keeps the flow on the wall clock until it leaves the 7-day window.
        # ponytail: a flow that stopped more than 7 days ago has no runs left in the window and no gap, so the flag lasts a week at most; keep gaps in state/ if that matters.
        $starts = @($runs | ForEach-Object { [datetime]$_.Start } | Sort-Object); $gap = 0.0; $silent = $false   # 0.0: an [int] seed would make [math]::Max pick the integer overload and truncate
        if ($f.Trigger -like 'Recurrence*' -and $starts.Count -ge 3) {
            $clock = if ($starts | Where-Object { $_.DayOfWeek -in 'Saturday', 'Sunday' }) { $wallMin } else { $bizMin }
            for ($i = 1; $i -lt $starts.Count; $i++) { $gap = [math]::Max($gap, (& $clock $starts[$i]) - (& $clock $starts[$i - 1])) }; $gap = [math]::Round($gap, 1)
            $silent = $gap -gt 0 -and "$($f.Enabled)".ToLower() -ne 'false' -and ((& $clock ([datetime]$snapshots[$g.Name])) - (& $clock $starts[-1]) -gt 1.5 * $gap + 15)
        }
        # Stuck runs: still Running after $stuckAfterMin at snapshot time. The user knows the flows: none should take 2 h.
        $snapAt = [datetime]$snapshots[$g.Name]
        $hung = @($runs | Where-Object { $_.Status -eq 'Running' -and ($snapAt - [datetime]$_.Start).TotalMinutes -gt $stuckAfterMin } | Sort-Object Start)
        $flows += [pscustomobject]@{
            Client = $g.Name; Environment = $f.Environment; EnvironmentId = $f.EnvironmentId; Flow = $f.Flow; FlowId = $f.FlowId; Enabled = $f.Enabled; Trigger = $f.Trigger
            Runs = $runs.Count; Failed = @($runs | Where-Object Status -eq 'Failed').Count
            Last = $(if ($last) { $last.Start } else { '' }); LastStatus = $(if ($last) { $last.Status } else { $f.Status })
            LastFailed = "$($lf.Start)"; LastFailedRun = "$($lf.RunId)"; LastError = "$($lf.Error)"; Recovered = "$($rec.Start)"   # '' when none ($null would serialize as {} in 5.1)
            Gap = $gap; Silent = [bool]$silent
            Stuck = $hung.Count; StuckSince = "$(if ($hung) { $hung[0].Start })"; StuckRun = "$(if ($hung) { $hung[0].RunId })"   # oldest stuck run
        }
    }
    foreach ($dg in $g.Group | Where-Object $isRun | Group-Object { $_.Start.Substring(0, 10) }) {
        $days += [pscustomobject]@{
            Client = $g.Name; Day = $dg.Name; Runs = $dg.Count
            Succeeded = @($dg.Group | Where-Object Status -eq 'Succeeded').Count
            Failed    = @($dg.Group | Where-Object Status -eq 'Failed').Count
            Cancelled = @($dg.Group | Where-Object Status -eq 'Cancelled').Count
        }
    }
    $fails += @($g.Group | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 100 Client, Environment, Flow, Start, RunId, Error)
}

if (Test-Path $Carry) {
    $c = Get-Content $Carry -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $c.snapshots.PSObject.Properties) { $snapshots[$p.Name] = $p.Value }
    $flows += @($c.flows); $days += @($c.days); $fails += @($c.fails); $powerbi += @($c.powerbi); $pbidays += @($c.pbidays); if ($c.pbifails) { $pbifails += @($c.pbifails) }; $apps += @($c.apps); $conns += @($c.connections); if ($c.changes) { $changes += @($c.changes) }
    if ($c.licences) { $licences += @($c.licences) }; if ($c.tenants) { $tenants += @($c.tenants) }; if ($c.licusers) { $licusers += @($c.licusers) }
}

# Credentials with a fixed expiry, from EXPIRIES ("label=YYYY-MM-DD; label=YYYY-MM-DD", plain env in watch.yml, dates only, never the secrets): shown on the page, mailed by notify.ps1.
$expiries = @(foreach ($e in "$env:EXPIRIES" -split ';') { if ($e -match '^\s*(.+?)\s*=\s*(\d{4}-\d{2}-\d{2})\s*$') { [pscustomobject]@{ Name = $Matches[1]; Date = $Matches[2] } } })
$data = [pscustomobject]@{ snapshots = $snapshots; flows = $flows; days = $days; fails = $fails; powerbi = $powerbi; pbidays = $pbidays; pbifails = $pbifails; apps = $apps; connections = $conns; tickets = $tickets; helpdesk = $HelpdeskAt; changes = $changes; licences = $licences; tenants = $tenants; licusers = $licusers; news = $news; newsAt = "$(if ($news.Count) { $news[0].ReadAt })"; expiries = $expiries } | ConvertTo-Json -Depth 5 -Compress
$data = $data.Replace('</', '<\/')   # a "</script>" inside any text (a connection error, a flow name) would end the page's data script; "<\/" is the same string in JSON
New-Item -ItemType Directory -Force $OutDir | Out-Null
$html = (Get-Content "$PSScriptRoot/dashboard.template.html" -Raw -Encoding UTF8).Replace('__DATA__', $data)
[IO.File]::WriteAllText("$OutDir/index.html", $html, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$OutDir/data.json", $data, [Text.UTF8Encoding]::new($false))
Copy-Item "$PSScriptRoot/staticwebapp.config.json", "$PSScriptRoot/forbidden.html", "$PSScriptRoot/signed-out.html" $OutDir -ErrorAction Ignore   # Azure Static Web Apps: sign-in required, invited "reader" role only. Ignore: the SEMO function fetches only the collector scripts and publishes data.json alone
Write-Host "Site written to $OutDir ($($flows.Count) flows, $($days.Count) client-days, $($fails.Count) failed runs, $([int]($html.Length / 1024)) KB)"
