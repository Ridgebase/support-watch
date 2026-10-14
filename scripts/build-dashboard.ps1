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
    [string]$OutDir = "$PSScriptRoot/../out/site",
    [string]$Carry  = "$PSScriptRoot/../out/carry.json"
)
$rows  = @(if (Test-Path $Csv) { @(Import-Csv $Csv) } else { @() })
$isRun = { $_.Status -ne 'NO_RUNS' -and $_.Status -ne 'UNREADABLE' }
$snapshots = @{}; $flows = @(); $days = @(); $fails = @()
$powerbi = @(if (Test-Path $PbiCsv) { @(Import-Csv $PbiCsv) } else { @() })   # last refresh per Power BI semantic model, from collect.ps1
$apps    = @(if (Test-Path $AppsCsv) { @(Import-Csv $AppsCsv) } else { @() })   # canvas apps and connections, from collect.ps1
$conns   = @(if (Test-Path $ConnCsv) { @(Import-Csv $ConnCsv) } else { @() })
$tickets = @(if (Test-Path $TicketsCsv) { @(Import-Csv $TicketsCsv) } else { @() })   # Odoo Helpdesk tickets in progress, from collect.ps1 (cloud job only, never carried over)
$pbiRuns = @(if (Test-Path $PbiRunsCsv) { @(Import-Csv $PbiRunsCsv) } else { @() })   # one row per Power BI refresh in the window, from collect.ps1
$pbidays = @(); $pbifails = @()
# Weekday clock for silent-flow detection: minutes since 2000-01-03 (a Monday) with Saturdays and Sundays removed; a weekend instant counts as Friday midnight.
$bizMin = { param([datetime]$d) $dow = [int]$d.DayOfWeek; $wk = [math]::Floor(($d.Date - [datetime]'2000-01-03').TotalDays / 7)
    $wd = if ($dow -in 0, 6) { 5 } else { $dow - 1 }; $tod = if ($dow -in 0, 6) { 0 } else { ($d - $d.Date).TotalMinutes }; ($wk * 5 + $wd) * 1440 + $tod }
$wallMin = { param([datetime]$d) ($d - [datetime]'2000-01-03').TotalMinutes }

# Power BI week, same shape as the flows: totals per model on its row, totals per client per day for the tab's recap and the weekly mail.
foreach ($m in $powerbi) {
    $mr = @($pbiRuns | Where-Object { $_.Client -eq $m.Client -and $_.ModelId -eq $m.ModelId })
    $m | Add-Member -NotePropertyName Refreshes -NotePropertyValue $mr.Count -Force
    $m | Add-Member -NotePropertyName Failed -NotePropertyValue @($mr | Where-Object Status -eq 'Failed').Count -Force
}
$pbifails = @($pbiRuns | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 100 Client, Workspace, Model, ModelId, Start, End, Type)   # the Power BI tab's "Failed refreshes" section
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
        # Silent flows: Gap = the longest interval between two runs of a recurrence flow this week, in minutes (3 runs needed). An enabled
        # flow whose last run is older than 1.5x that (+15 min of collection slack) at snapshot time is Silent: it stopped running without
        # failing, which no failure count shows. The longest gap, not the median, so a business-hours schedule is not silent every night.
        # A flow with no weekend run in the window is measured on the weekday clock (Saturdays and Sundays do not exist), so a weekday
        # schedule is not silent on Sunday, and one that stopped on Friday is caught on Monday afternoon. Statutory holidays are not known: a flow idle on a holiday Monday is flagged that afternoon.
        # ponytail: a flow that stopped more than 7 days ago has no runs left in the window and no gap, so the flag lasts a week at most; keep gaps in state/ if that matters.
        $starts = @($runs | ForEach-Object { [datetime]$_.Start } | Sort-Object); $gap = 0.0; $silent = $false   # 0.0: an [int] seed would make [math]::Max pick the integer overload and truncate
        if ($f.Trigger -like 'Recurrence*' -and $starts.Count -ge 3) {
            $clock = if ($starts | Where-Object { $_.DayOfWeek -in 'Saturday', 'Sunday' }) { $wallMin } else { $bizMin }
            for ($i = 1; $i -lt $starts.Count; $i++) { $gap = [math]::Max($gap, (& $clock $starts[$i]) - (& $clock $starts[$i - 1])) }; $gap = [math]::Round($gap, 1)
            $silent = $gap -gt 0 -and "$($f.Enabled)".ToLower() -ne 'false' -and ((& $clock ([datetime]$snapshots[$g.Name])) - (& $clock $starts[-1]) -gt 1.5 * $gap + 15)
        }
        # Stuck runs: a run still Running for longer than twice the flow's longest finished run this week (floor 1 h): a flow that takes 10 s and has
        # been running for 2 h is hung, while an approval flow whose runs take days is not. No finished run in the window = no baseline, not flagged.
        $maxDur = 0.0; foreach ($r in $runs) { if ($r.End -and $r.Status -ne 'Running') { $maxDur = [math]::Max($maxDur, ([datetime]$r.End - [datetime]$r.Start).TotalMinutes) } }
        $snapAt = [datetime]$snapshots[$g.Name]
        $hung = @(if ($maxDur -gt 0) { $runs | Where-Object { $_.Status -eq 'Running' -and ($snapAt - [datetime]$_.Start).TotalMinutes -gt [math]::Max(2 * $maxDur, 60) } | Sort-Object Start })
        $flows += [pscustomobject]@{
            Client = $g.Name; Environment = $f.Environment; EnvironmentId = $f.EnvironmentId; Flow = $f.Flow; FlowId = $f.FlowId; Enabled = $f.Enabled; Trigger = $f.Trigger
            Runs = $runs.Count; Failed = @($runs | Where-Object Status -eq 'Failed').Count
            Last = $(if ($last) { $last.Start } else { '' }); LastStatus = $(if ($last) { $last.Status } else { $f.Status })
            LastFailed = "$($lf.Start)"; LastFailedRun = "$($lf.RunId)"; LastError = "$($lf.Error)"   # '' when none ($null would serialize as {} in 5.1)
            Gap = $gap; Silent = [bool]$silent
            Stuck = $hung.Count; StuckSince = "$(if ($hung) { $hung[0].Start })"; StuckRun = "$(if ($hung) { $hung[0].RunId })"; MaxDur = [math]::Round($maxDur, 1)   # oldest stuck run; MaxDur in minutes
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
    $flows += @($c.flows); $days += @($c.days); $fails += @($c.fails); $powerbi += @($c.powerbi); $pbidays += @($c.pbidays); if ($c.pbifails) { $pbifails += @($c.pbifails) }; $apps += @($c.apps); $conns += @($c.connections)
}

$data = [pscustomobject]@{ snapshots = $snapshots; flows = $flows; days = $days; fails = $fails; powerbi = $powerbi; pbidays = $pbidays; pbifails = $pbifails; apps = $apps; connections = $conns; tickets = $tickets; helpdesk = $HelpdeskAt } | ConvertTo-Json -Depth 5 -Compress
$data = $data.Replace('</', '<\/')   # a "</script>" inside any text (a connection error, a flow name) would end the page's data script; "<\/" is the same string in JSON
New-Item -ItemType Directory -Force $OutDir | Out-Null
$html = (Get-Content "$PSScriptRoot/dashboard.template.html" -Raw -Encoding UTF8).Replace('__DATA__', $data)
[IO.File]::WriteAllText("$OutDir/index.html", $html, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$OutDir/data.json", $data, [Text.UTF8Encoding]::new($false))
Copy-Item "$PSScriptRoot/staticwebapp.config.json", "$PSScriptRoot/forbidden.html", "$PSScriptRoot/signed-out.html" $OutDir -ErrorAction Ignore   # Azure Static Web Apps: sign-in required, invited "reader" role only. Ignore: the SEMO function fetches only the collector scripts and publishes data.json alone
Write-Host "Site written to $OutDir ($($flows.Count) flows, $($days.Count) client-days, $($fails.Count) failed runs, $([int]($html.Length / 1024)) KB)"
