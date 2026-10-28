# Working on Support Watch

README.md says what the system is and how it runs. This file is what to know before changing it.

## Where the code runs

- `scripts/collect.ps1`, `build-dashboard.ps1` and `dashboard.template.html` run in three places: GitHub Actions (PowerShell 7, Linux, every 10 min),
  the Azure function `func-support-watch-semo` (PowerShell 7.4, Canada Central, every 15 min, SEMO only) and the laptop fallback `flow-runs.ps1`
  (Windows PowerShell 5.1). The function **fetches those three files from `main` at each run**: a push is live for SEMO within 15 min, no deploy.
- `azure-function/collect-semo/run.ps1` is deployed code: a change there needs `func azure functionapp publish func-support-watch-semo --powershell`
  from `azure-function/` (Functions Core Tools are installed on this PC; the Azure CLI is signed in to "Microsoft Azure Sponsorship #1").
- `notify.ps1` and `build-dashboard.ps1` must keep running on PowerShell 5.1: keep their UTF-8 BOM (5.1 reads a BOM-less file as ANSI),
  and remember that PowerShell 7 parses ISO dates in JSON into `[datetime]` while 5.1 keeps strings (see the `$iso` and `$fmt` helpers).
- All files are LF in git; the working copy may show CRLF warnings, ignore them.

## Testing without the cloud

- Collector, end to end for SEMO (about a minute, Conditional Access allows this PC): set `RT_SEMO` from the DPAPI secrets file
  (`Import-Clixml "$HOME\flow-watch-secrets.xml"`, key `SEMO`, then `ConvertFrom-SecureString -AsPlainText`) and `CLIENTS_JSON` as in
  `flow-runs.ps1`, then run `./scripts/collect.ps1`; check `out/flow-runs.csv` and `out/site/data.json`. TSMO works the same way (key `TSMO`).
- Aggregation and page: `./scripts/build-dashboard.ps1 -Csv <csv> -OutDir <dir>` on a hand-made CSV; the page script can be exercised in
  Node with a few DOM stubs (`document.getElementById` returning objects with `innerHTML`, `querySelector`, `Option`, `fetch`, `setTimeout`).
- Mail: `./scripts/notify.ps1 -Data <data.json> -State <alerts.json> -DryRun` prints the emails and the state it would save; the state file
  must contain `{"open":{},"digest":""}` at least. `gh workflow run watch.yml -f sample=true` or `-f digest=true` sends a `[Sample]` mail.
- Parse check before pushing: `[System.Management.Automation.Language.Parser]::ParseFile(...)` on each edited `.ps1`.
- `out/` is gitignored and holds the last local run; `state/` is committed by the workflow bot.

## Git

- The workflow bot commits `state/` every 10 min: `git pull --rebase` right before `git push`, or the push is rejected.
- A dispatched run (`gh workflow run watch.yml`) is the quickest way to see a change live; watch it with `gh run watch <id>`.
- To run the SEMO function now instead of waiting for its timer: `$key = az functionapp keys list -g rg-support-watch -n func-support-watch-semo --subscription "Microsoft Azure Sponsorship #1" --query masterKey -o tsv`,
  then `Invoke-WebRequest -Method Post -Uri https://func-support-watch-semo.azurewebsites.net/admin/functions/collect-semo -Headers @{'x-functions-key'=$key;'Content-Type'='application/json'} -Body '{"input":""}'`
  (HTTP 202; the gist is updated about a minute later), then dispatch the workflow so the page reads the new gist.

## Rules the user set

- Test emails go to adrien.polselli@ridgebase.com only; real alerts go to support@ridgebase.com only, never to client contacts.
- The monitoring page is used from a different browser profile than the clients' tenants: no links to client resources on the page,
  copy buttons only. Links are fine in emails.
- The healthchecks.io account is support@ridgebase.com (checks `support-watch-github` and `support-watch-semo-function`).

## Design notes that are not obvious from the code

- Failed runs: the run's own error is always the same banner, so the collector reads the failed action and its outputs for a flow's
  30 newest failed runs (two extra API calls each); older ones keep the banner and the page groups them as "not inspected".
- Flow listing: the admin endpoint (`scopes/admin/.../v2/flows`, Started flows only), because the user listing omits most solution flows even
  when the monitoring account created them (SEMO 2026-10-26: 59 of 265). Flows owned by other people refuse the user endpoints (403
  ConnectionAuthorizationFailed: they showed as "unreachable" until 2026-10-28), so their detail and runs are read under `scopes/admin/`
  too; a run's actions have no admin route, so their failed runs keep the generic run banner.
- Stuck runs: a run still Running after 2 h (`$stuckAfterMin` in build-dashboard.ps1). The user knows the flows: none legitimately takes that long.
- Stale clients: notify.ps1 emails once per episode when a client's snapshot is over an hour old; "already announced" checks compare with the saved state ($prev), never with the state rebuilt for the run.
- Silent flows: recurrence flows only, 1.5x the longest gap between runs this week, measured on a weekday clock when the flow never ran on
  a weekend. The weekday clock also skips the statutory holidays hand-listed in build-dashboard.ps1 (`$holidays`, through 2028: extend it).
  The flag lasts a week at most because the window is 7 days. A weekend run (manual resubmit, schedule changed since) keeps the flow on
  the wall clock for 7 days: that is the alert of 2026-10-17.
- Credential expiry dates live in `EXPIRIES` in watch.yml (dates only); notify.ps1 mails at 14 days and once expired, keyed `expiry|<name>`.
- SEMO is never collected from GitHub (`CARRY_CLIENTS`): its Conditional Access blocks US runners, so it always comes from the function's gist.
- Tech watch: the Message Center needs a second token per client (`MC_<NAME>`, Microsoft Graph PowerShell app) because the Azure CLI app the
  Flow token comes from can never be granted `ServiceMessage.Read.All` (tested 2026-10-26: AADSTS65002). The blog feeds are read each morning (first run after 6 am Eastern)
  into `state/news.csv` (`ReadAt` column), committed by the bot; delete the file to force a read.
