# Emails support@ about flows whose LATEST run failed, Koena-style: one email per run with only the NEW failures
# (a flow keeps failing = one email until it recovers), plus one digest a day after 07:00 Eastern that doubles as
# the dead-man's switch: no digest in the morning means the job itself is broken.
# State lives in alerts.json (committed by the workflow): { open: { "Client|FlowId": "<last failed run>" }, digest: "YYYY-MM-DD" }.
# Runs on Windows PowerShell 5.1 and PowerShell 7.
# Mail goes out through Microsoft Graph as the shared mailbox, with an app registration (client credentials):
#   MAIL_JSON    {"Tenant":"ridgebase.com","ClientId":"<app id>","From":"support@ridgebase.com","To":["support@ridgebase.com"]}
#   MAIL_SECRET  the app's client secret (expires: max 2 years, note the date)
# -DryRun prints the emails instead of sending and leaves alerts.json untouched.
param([string]$Data = "$PSScriptRoot/site/data.json", [string]$State = "$PSScriptRoot/alerts.json", [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$page = 'https://ridgebase.github.io/support-watch/'

$d     = Get-Content $Data -Raw -Encoding UTF8 | ConvertFrom-Json
$st    = if (Test-Path $State) { Get-Content $State -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$open  = @{}; foreach ($p in @($st.open.PSObject.Properties)) { $open[$p.Name] = $p.Value }
$digest = "$($st.digest)"
$tz    = try { [TimeZoneInfo]::FindSystemTimeZoneById('America/Toronto') } catch { [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }   # IANA id on Linux, Windows id on 5.1
$now   = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
$fmt   = { param($s) if ($s) { $s.Substring(0, 16).Replace('T', ' ') } else { 'never' } }
$url   = { param($f) "https://make.powerautomate.com/environments/$($f.EnvironmentId)/flows/$($f.FlowId)/details" }
$mails = @()

# --- real-time: new failures since the last run ---------------------------------------------------------------
$failing = @($d.flows | Where-Object { $_.LastStatus -eq 'Failed' -and "$($_.Enabled)".ToLower() -ne 'false' })
$new     = @($failing | Where-Object { -not $open.ContainsKey("$($_.Client)|$($_.FlowId)") })
$open    = @{}; foreach ($f in $failing) { $open["$($f.Client)|$($f.FlowId)"] = $f.Last }   # recovered/removed flows drop out silently
if ($new) {
    $body = foreach ($g in $new | Group-Object Client) {
        "$($g.Name): $($g.Count) flow(s) whose latest run failed`n"
        foreach ($f in $g.Group) { "- $($f.Flow) ($($f.Environment))`n  failed $(& $fmt $f.Last); $($f.Failed) failed of $($f.Runs) runs in 7 days`n  $(& $url $f)`n" }
    }
    $mails += @{ subject = "[Support Watch] $(($new | Group-Object Client | ForEach-Object { "$($_.Name): $($_.Count) failing" }) -join ', ')"
                 body    = ($body -join "`n") + "`nOpen the flow, then its last run, to read the error.`nDashboard: $page" }
}

# --- daily digest after 07:00 Eastern ------------------------------------------------------------------------
$today = $now.ToString('yyyy-MM-dd'); $yday = $now.AddDays(-1).ToString('yyyy-MM-dd')
if ($now.Hour -ge 7 -and $digest -ne $today) {
    $lines = foreach ($c in ($d.snapshots.PSObject.Properties.Name | Sort-Object)) {
        $day  = $d.days | Where-Object { $_.Client -eq $c -and $_.Day -eq $yday }
        $red  = @($failing | Where-Object Client -eq $c)
        $age  = [datetime]::UtcNow - [TimeZoneInfo]::ConvertTimeToUtc([datetime]$d.snapshots.$c, $tz)
        "${c}" + $(if ($age.TotalHours -gt 1) { "  STALE: last snapshot $(& $fmt $d.snapshots.$c)" })
        "  yesterday: $(if ($day) { "$($day.Runs) runs, $($day.Failed) failed, $($day.Cancelled) cancelled" } else { 'no runs' })"
        "  failing now: $(if ($red) { ($red | ForEach-Object { $_.Flow }) -join ', ' } else { 'none' })"
        ''
    }
    $short = ($d.snapshots.PSObject.Properties.Name | Sort-Object | ForEach-Object { $n = @($failing | Where-Object Client -eq $_).Count; "$_ $(if ($n) { "$n failing" } else { 'healthy' })" }) -join ', '
    $mails += @{ subject = "[Support Watch] Digest ${today}: $short"; body = ($lines -join "`n") + "Dashboard: $page" }
    $digest = $today
}

# --- send + save ---------------------------------------------------------------------------------------------
if ($DryRun) { $mails | ForEach-Object { "=== $($_.subject)`n$($_.body)`n" }; "state: $(@{ open = $open; digest = $digest } | ConvertTo-Json -Compress)"; return }
if ($mails) {
    $m = $env:MAIL_JSON | ConvertFrom-Json
    if (-not $m -or -not $env:MAIL_SECRET) { Write-Warning "MAIL_JSON/MAIL_SECRET not set: $($mails.Count) email(s) not sent."; return }   # state not saved: alert again once mail works
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($m.Tenant)/oauth2/v2.0/token" -Body @{ grant_type = 'client_credentials'; client_id = $m.ClientId; client_secret = $env:MAIL_SECRET; scope = 'https://graph.microsoft.com/.default' }
    foreach ($mail in $mails) {
        $msg = @{ message = @{ subject = $mail.subject; body = @{ contentType = 'Text'; content = $mail.body }; toRecipients = @($m.To | ForEach-Object { @{ emailAddress = @{ address = $_ } } }) }; saveToSentItems = $false }
        Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/users/$($m.From)/sendMail" -Headers @{ Authorization = "Bearer $($tok.access_token)" } -ContentType 'application/json; charset=utf-8' -Body ($msg | ConvertTo-Json -Depth 6)
        Write-Host "Sent: $($mail.subject)"
    }
}
@{ open = $open; digest = $digest } | ConvertTo-Json -Compress | Set-Content $State -Encoding UTF8
