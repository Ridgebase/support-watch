# Run by hand, on the PC that holds the collector secrets, after the function app exists: copies the SEMO refresh token
# (from the DPAPI-protected secrets file flow-runs.ps1 uses) and a GitHub token with the gist scope into the function's
# app settings. Nothing is printed. Rerun whenever the refresh token is renewed (flow-runs.ps1 -Login SEMO).
#   pwsh -File .\azure-function\set-secrets.ps1
param([string]$Subscription = 'Microsoft Azure Sponsorship #1', [string]$ResourceGroup = 'rg-support-watch', [string]$App = 'func-support-watch-semo')
$ErrorActionPreference = 'Stop'
$secrets = Import-Clixml "$HOME\flow-watch-secrets.xml"
$rt   = ConvertFrom-SecureString $secrets['SEMO'] -AsPlainText
$gist = (Get-Content "$HOME\carry-gist.txt" -Raw).Trim()
$ghTok = "$(gh auth token)".Trim()   # the gh CLI token has the gist scope; a classic PAT with 'gist' works too
if (-not $rt -or -not $gist -or -not $ghTok) { throw 'missing refresh token, gist id or GitHub token' }
az functionapp config appsettings set --subscription $Subscription -g $ResourceGroup -n $App --settings "RT_SEMO=$rt" "GIST_ID=$gist" "GIST_TOKEN=$ghTok" --query "[?name=='RT_SEMO' || name=='GIST_ID' || name=='GIST_TOKEN'].name" -o tsv
Write-Host 'Secrets set.'
