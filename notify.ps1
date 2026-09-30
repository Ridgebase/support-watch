# Emails support@ about flows whose LATEST run failed, Koena-style: one email per run with only the NEW failures
# (a flow keeps failing = one email until it recovers), plus one digest a day after 07:00 Eastern that doubles as
# the dead-man's switch: no digest in the morning means the job itself is broken.
# State lives in alerts.json (committed by the workflow): { open: { "Client|FlowId": "<last failed run>" }, digest: "YYYY-MM-DD" }.
# Runs on Windows PowerShell 5.1 and PowerShell 7.
# Mail goes out over SMTP (Ridgebase's mail is Google Workspace, so Microsoft Graph has no support@ mailbox to send as,
# and nobody on the team has access to the Mailgun account the SPF record authorises). Secrets:
#   SMTP_USER      the sending account, also the From address, e.g. a Workspace user with an app password
#   SMTP_PASSWORD  its app password (Google: 2-Step Verification must be on, myaccount.google.com/apppasswords)
#   MAIL_TO        recipient(s), comma-separated
#   SMTP_HOST      optional, default smtp.gmail.com (Mailgun would be smtp.mailgun.org); port 587 with STARTTLS
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
    if (-not ($env:SMTP_USER -and $env:SMTP_PASSWORD -and $env:MAIL_TO)) { Write-Warning "SMTP_USER/SMTP_PASSWORD/MAIL_TO not set: $($mails.Count) email(s) not sent."; return }   # state not saved: alert again once mail works
    $smtpHost = if ($env:SMTP_HOST) { $env:SMTP_HOST } else { 'smtp.gmail.com' }
    $cred = [pscredential]::new($env:SMTP_USER, (ConvertTo-SecureString $env:SMTP_PASSWORD -AsPlainText -Force))
    foreach ($mail in $mails) {
        # Send-MailMessage is marked obsolete but still ships in PowerShell 7 and does STARTTLS on 587; enough for a few mails a day.
        Send-MailMessage -SmtpServer $smtpHost -Port 587 -UseSsl -Credential $cred -From "Support Watch <$($env:SMTP_USER)>" -To ($env:MAIL_TO -split ',\s*') -Subject $mail.subject -Body $mail.body -Encoding UTF8 -WarningAction SilentlyContinue
        Write-Host "Sent: $($mail.subject)"
    }
}
@{ open = $open; digest = $digest } | ConvertTo-Json -Compress | Set-Content $State -Encoding UTF8
