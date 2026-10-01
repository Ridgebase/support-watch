# Aggregates flow-runs.csv (one row per run) into site/data.json (per-flow and per-day totals, failed runs) and
# renders site/index.html from dashboard.template.html with that JSON embedded. The page never carries raw runs:
# ~100 KB instead of 4 MB, which matters because it reloads itself every 10 minutes and is fetched by the collector.
# Optional carry.json (same shape as data.json) supplies clients that could not be collected this run.
# Runs on Windows PowerShell 5.1 (laptop) and PowerShell 7 (GitHub Actions).
param(
    [string]$Csv    = "$PSScriptRoot/flow-runs.csv",
    [string]$PbiCsv = "$PSScriptRoot/powerbi.csv",
    [string]$OutDir = "$PSScriptRoot/site",
    [string]$Carry  = "$PSScriptRoot/carry.json"
)
$rows  = if (Test-Path $Csv) { @(Import-Csv $Csv) } else { @() }
$isRun = { $_.Status -ne 'NO_RUNS' -and $_.Status -ne 'UNREADABLE' }
$snapshots = @{}; $flows = @(); $days = @(); $fails = @()
$powerbi = if (Test-Path $PbiCsv) { @(Import-Csv $PbiCsv) } else { @() }   # last refresh per Power BI semantic model, from collect.ps1

foreach ($g in $rows | Group-Object Client) {
    $snapshots[$g.Name] = ($g.Group | Sort-Object Collected -Descending)[0].Collected
    foreach ($fg in $g.Group | Group-Object Environment, FlowId, Flow) {
        $f = $fg.Group[0]; $runs = @($fg.Group | Where-Object $isRun); $last = $runs | Sort-Object Start -Descending | Select-Object -First 1
        $flows += [pscustomobject]@{
            Client = $g.Name; Environment = $f.Environment; EnvironmentId = $f.EnvironmentId; Flow = $f.Flow; FlowId = $f.FlowId; Enabled = $f.Enabled; Trigger = $f.Trigger
            Runs = $runs.Count; Failed = @($runs | Where-Object Status -eq 'Failed').Count
            Last = $(if ($last) { $last.Start } else { '' }); LastStatus = $(if ($last) { $last.Status } else { $f.Status })
            LastFailed = "$($runs | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 1 -ExpandProperty Start)"   # '' when none ($null would serialize as {} in 5.1); notify.ps1 alerts on a failed run newer than the one it last announced
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
    $fails += @($g.Group | Where-Object Status -eq 'Failed' | Sort-Object Start -Descending | Select-Object -First 100 Client, Environment, Flow, Start)
}

if (Test-Path $Carry) {
    $c = Get-Content $Carry -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $c.snapshots.PSObject.Properties) { $snapshots[$p.Name] = $p.Value }
    $flows += @($c.flows); $days += @($c.days); $fails += @($c.fails); $powerbi += @($c.powerbi)
}

$data = [pscustomobject]@{ snapshots = $snapshots; flows = $flows; days = $days; fails = $fails; powerbi = $powerbi } | ConvertTo-Json -Depth 5 -Compress
New-Item -ItemType Directory -Force $OutDir | Out-Null
$html = (Get-Content "$PSScriptRoot/dashboard.template.html" -Raw -Encoding UTF8).Replace('__DATA__', $data)
[IO.File]::WriteAllText("$OutDir/index.html", $html, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText("$OutDir/data.json", $data, [Text.UTF8Encoding]::new($false))
Write-Host "Site written to $OutDir ($($flows.Count) flows, $($days.Count) client-days, $($fails.Count) failed runs, $([int]($html.Length / 1024)) KB)"
