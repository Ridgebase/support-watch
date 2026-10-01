# Emails support@ about flows whose LATEST run failed, Koena-style: one email per run with only the NEW failures
# (a flow keeps failing = one email until it recovers), plus one weekly recap on Monday after 07:00 Eastern that doubles as
# the dead-man's switch: no recap on Monday morning means the job itself is broken.
# State lives in alerts.json (committed by the workflow): { open: { "Client|FlowId": "<last failed run>" }, digest: "YYYY-MM-DD" }.
# Runs on Windows PowerShell 5.1 and PowerShell 7.
# Mail goes out over SMTP (Ridgebase's mail is Google Workspace, so Microsoft Graph has no support@ mailbox to send as,
# and nobody on the team has access to the Mailgun account the SPF record authorises). Secrets:
#   SMTP_USER      the sending account, also the From address, e.g. a Workspace user with an app password
#   SMTP_PASSWORD  its app password (Google: 2-Step Verification must be on, myaccount.google.com/apppasswords)
#   MAIL_TO        recipient(s), comma-separated
#   SMTP_HOST      optional, default smtp.gmail.com (Mailgun would be smtp.mailgun.org); port 587 with STARTTLS
# -DryRun prints the emails instead of sending and leaves alerts.json untouched.
# -Sample marks one real flow per client as failed and sends only that alert, prefixed [Sample], without saving state:
#   gh workflow run watch.yml --repo Ridgebase/support-watch -f sample=true
# -SampleDigest sends the weekly recap now, whatever the day, prefixed [Sample], without saving state:
#   gh workflow run watch.yml --repo Ridgebase/support-watch -f digest=true
param([string]$Data = "$PSScriptRoot/site/data.json", [string]$State = "$PSScriptRoot/alerts.json", [switch]$DryRun, [switch]$Sample, [switch]$SampleDigest)
$ErrorActionPreference = 'Stop'
$page = 'https://ridgebase.github.io/support-watch/'

$d     = Get-Content $Data -Raw -Encoding UTF8 | ConvertFrom-Json
$st    = if (Test-Path $State) { Get-Content $State -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$open  = @{}; foreach ($p in @($st.open.PSObject.Properties)) { $open[$p.Name] = $p.Value }
$digest = "$($st.digest)"
$tz    = try { [TimeZoneInfo]::FindSystemTimeZoneById('America/Toronto') } catch { [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }   # IANA id on Linux, Windows id on 5.1
$now   = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
$fmt   = { param($s) if ($s -is [datetime]) { $s.ToString('yyyy-MM-dd HH:mm') } elseif ($s) { "$s".Substring(0, 16).Replace('T', ' ') } else { 'never' } }   # pwsh 7 parses ISO strings in JSON into [datetime], 5.1 keeps strings
$url   = { param($f) "https://make.powerautomate.com/environments/$($f.EnvironmentId)/flows/$($f.FlowId)/details" }
$esc   = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
$mails = @()
if ($Sample) { $open = @{}; foreach ($g in $d.flows | Where-Object { $_.Runs -gt 0 } | Group-Object Client) { $g.Group[0].LastStatus = 'Failed'; $g.Group[0].Failed = 1 } }

# HTML with inline styles (mail clients drop stylesheets), same palette as the page. One card per client.
$col = @{ bg = '#f8f7f5'; fg = '#262e3a'; muted = '#76706a'; line = '#e4ded7'; ok = '#3c8274'; bad = '#e95664'; warn = '#c2641a'; badbg = '#fdecee'; okbg = '#e9f3ee'; warnbg = '#fdf1e6' }
$pill = { param($text, $color, $bg) "<span style=""display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600;color:$color;background:$bg"">$text</span>" }
# Mail clients run no script, so there is no click-to-copy: the flow URL is also printed as plain text to select and copy (a triple-click selects the line).
$flowRow = { param($f) "<tr><td style=""padding:10px 0;border-top:1px solid #e2e4e7""><b>$(& $esc $f.Flow)</b><br><span style=""color:$($col.muted);font-size:12px"">$(& $esc $f.Environment) &middot; last run $(& $fmt $f.Last) &middot; $($f.Failed) failed of $($f.Runs) runs in 7 days</span>" +
                         "<div style=""margin-top:6px;font:11px/1.4 Consolas,Menlo,monospace;color:$($col.muted);word-break:break-all"">$(& $url $f)</div></td>" +
                         "<td style=""padding:10px 0 10px 12px;border-top:1px solid #e2e4e7;text-align:right;white-space:nowrap""><a href=""$(& $url $f)"" style=""display:inline-block;padding:6px 12px;border-radius:4px;background:$($col.bad);color:#fff;text-decoration:none;font-size:12px;font-weight:600"">Open flow</a></td></tr>" }
$card = { param($title, $body) "<div style=""background:#fff;border:1px solid $($col.line);border-radius:6px;padding:14px 16px;margin:0 0 12px""><div style=""font-size:15px;font-weight:600;margin-bottom:6px"">$title</div>$body</div>" }
$wrap = { param($kicker, $title, $inner)
    "<!doctype html><html><body style=""margin:0;padding:24px 16px;background:$($col.bg);color:$($col.fg);font:14px/1.5 'DM Sans',system-ui,-apple-system,'Segoe UI',sans-serif"">" +
    "<div style=""max-width:600px;margin:0 auto""><div style=""color:$($col.bad);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.12em"">Ridgebase &middot; Support Watch</div>" +
    "<h1 style=""font:400 26px/1.15 'Palatino Linotype',Palatino,Georgia,serif;letter-spacing:-.01em;margin:2px 0 16px"">$title</h1>$inner" +
    "<div style=""color:$($col.muted);font-size:12px;margin-top:16px"">$kicker &middot; <a href=""$page"" style=""color:$($col.muted)"">Open the dashboard</a></div></div></body></html>" }

# --- real-time: new failures since the last run ---------------------------------------------------------------
$failing = @($d.flows | Where-Object { $_.LastStatus -eq 'Failed' -and "$($_.Enabled)".ToLower() -ne 'false' })
$new     = @($failing | Where-Object { -not $open.ContainsKey("$($_.Client)|$($_.FlowId)") })
$open    = @{}; foreach ($f in $failing) { $open["$($f.Client)|$($f.FlowId)"] = & $fmt $f.Last }   # recovered/removed flows drop out silently
if ($new -and -not $SampleDigest) {
    $cards = foreach ($g in $new | Group-Object Client) {
        & $card "$($g.Name) $(& $pill "$($g.Count) failing" $col.bad $col.badbg)" "<table style=""width:100%;border-collapse:collapse"">$(($g.Group | ForEach-Object { & $flowRow $_ }) -join '')</table>"
    }
    $mails += @{ subject = "$(if ($Sample) { '[Sample] ' })[Support Watch] $(($new | Group-Object Client | ForEach-Object { "$($_.Name): $($_.Count) failing" }) -join ', ')"
                 body    = & $wrap 'Open the flow, then its last run, to read the error' "$($new.Count) flow$(if ($new.Count -gt 1) { 's' }) whose latest run failed" ($cards -join '') }
}

# --- weekly recap, Monday after 07:00 Eastern ----------------------------------------------------------------
$today = $now.ToString('yyyy-MM-dd'); $from = $now.AddDays(-6).ToString('yyyy-MM-dd'); $to = $today   # data.json holds today and the six days before
if (($now.DayOfWeek -eq 'Monday' -and $now.Hour -ge 7 -and $digest -ne $today -and -not $Sample) -or $SampleDigest) {
    $clients = @($d.snapshots.PSObject.Properties.Name | Sort-Object)
    $cards = foreach ($c in $clients) {
        $days = @($d.days | Where-Object Client -eq $c)   # data.json already holds exactly the last 7 days
        $runs = ($days | Measure-Object Runs -Sum).Sum; $bad = ($days | Measure-Object Failed -Sum).Sum; $ok = ($days | Measure-Object Succeeded -Sum).Sum; $can = ($days | Measure-Object Cancelled -Sum).Sum
        $red  = @($failing | Where-Object Client -eq $c)
        $hit  = @($d.flows | Where-Object { $_.Client -eq $c -and $_.Failed -gt 0 } | Sort-Object { -$_.Failed }, Flow)   # every flow that failed in the week, failing-now or recovered
        $age  = [datetime]::UtcNow - [TimeZoneInfo]::ConvertTimeToUtc([datetime]$d.snapshots.$c, $tz)
        $pills = $(if ($red) { & $pill "$($red.Count) failing" $col.bad $col.badbg } else { & $pill 'Healthy' $col.ok $col.okbg }) + $(if ($age.TotalHours -gt 1) { ' ' + (& $pill "STALE since $(& $fmt $d.snapshots.$c)" $col.warn $col.warnbg) })
        $rate = if ($ok + $bad) { "$([math]::Round(100 * $ok / ($ok + $bad), 2))%" } else { '&mdash;' }
        $week = if ($runs) { "<b>$runs</b> runs &middot; <b style=""color:$(if ($bad) { $col.bad } else { $col.ok })"">$bad</b> failed &middot; $can cancelled &middot; $rate success" } else { 'no runs' }
        $rows = if ($hit) { "<div style=""color:$($col.muted);font-size:12px;margin-top:10px"">Flows with failures this week</div><table style=""width:100%;border-collapse:collapse"">$(($hit | ForEach-Object { & $flowRow $_ }) -join '')</table>" } else { '' }
        & $card "$c $pills" "<div style=""color:$($col.muted);font-size:12px"">Last 7 days</div><div>$week</div>$rows"
    }
    $short = ($clients | ForEach-Object { $n = @($failing | Where-Object Client -eq $_).Count; "$_ $(if ($n) { "$n failing" } else { 'healthy' })" }) -join ', '
    $mails += @{ subject = "$(if ($SampleDigest) { '[Sample] ' })[Support Watch] Weekly recap $from to ${to}: $short"; body = & $wrap "Recap of $from to $to, sent every Monday morning; no recap means the job is down" "Week in review: $short" ($cards -join '') }
    if (-not $SampleDigest) { $digest = $today }
}

# --- send + save ---------------------------------------------------------------------------------------------
if ($DryRun) { $mails | ForEach-Object { "=== $($_.subject)`n$($_.body)`n" }; "state: $(@{ open = $open; digest = $digest } | ConvertTo-Json -Compress)"; return }
if ($mails) {
    if (-not ($env:SMTP_USER -and $env:SMTP_PASSWORD -and $env:MAIL_TO)) { Write-Warning "SMTP_USER/SMTP_PASSWORD/MAIL_TO not set: $($mails.Count) email(s) not sent."; return }   # state not saved: alert again once mail works
    $smtpHost = if ($env:SMTP_HOST) { $env:SMTP_HOST } else { 'smtp.gmail.com' }
    $cred = [pscredential]::new($env:SMTP_USER, (ConvertTo-SecureString $env:SMTP_PASSWORD -AsPlainText -Force))
    foreach ($mail in $mails) {
        # Send-MailMessage is marked obsolete but still ships in PowerShell 7 and does STARTTLS on 587; enough for a few mails a day.
        Send-MailMessage -SmtpServer $smtpHost -Port 587 -UseSsl -Credential $cred -From "Support Watch <$($env:SMTP_USER)>" -To ($env:MAIL_TO -split ',\s*') -Subject $mail.subject -Body $mail.body -BodyAsHtml -Encoding UTF8 -WarningAction SilentlyContinue
        Write-Host "Sent: $($mail.subject)"
    }
}
if ($Sample -or $SampleDigest) { return }
@{ open = $open; digest = $digest } | ConvertTo-Json -Compress | Set-Content $State -Encoding UTF8
