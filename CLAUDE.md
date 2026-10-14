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

## Rules the user set

- Test emails go to adrien.polselli@ridgebase.com only; real alerts go to support@ridgebase.com only, never to client contacts.
- The monitoring page is used from a different browser profile than the clients' tenants: no links to client resources on the page,
  copy buttons only. Links are fine in emails.
- The healthchecks.io account is support@ridgebase.com (checks `support-watch-github` and `support-watch-semo-function`).

## Design notes that are not obvious from the code

- Failed runs: the run's own error is always the same banner, so the collector reads the failed action and its outputs for a flow's
  30 newest failed runs (two extra API calls each); older ones keep the banner and the page groups them as "not inspected".
- Stuck runs: a run still Running longer than twice the flow's longest finished run this week, floor 1 h; no finished run in the window, no flag.
- Stale clients: notify.ps1 emails once per episode when a client's snapshot is over an hour old; "already announced" checks compare with the saved state ($prev), never with the state rebuilt for the run.
- Silent flows: recurrence flows only, 1.5x the longest gap between runs this week, measured on a weekday clock when the flow never ran on
  a weekend. The flag lasts a week at most because the window is 7 days; a Monday holiday produces a false positive that afternoon.
- SEMO is never collected from GitHub (`CARRY_CLIENTS`): its Conditional Access blocks US runners, so it always comes from the function's gist.
