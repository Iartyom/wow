# Copies the addon's SavedVariables file into docs/sync/ and pushes it, so the GitHub Pages
# site picks up your latest level/zone/demons. Character name and realm lines are removed
# first because the repo is public.
#   .\tools\sync.ps1            one sync
#   .\tools\sync.ps1 -Watch     keep running; syncs each time WoW writes the file (logout or /reload)
#   .\tools\sync.ps1 -NoPush    update docs/ locally only
param(
  [string]$WowRoot,
  [switch]$Watch,
  [switch]$NoPush
)
# WoW root: -WowRoot wins, else Battle.net's DefaultInstallPath (this PC: D:\Games) + "World of Warcraft",
# else the stock C: path. Battle.net writes the path with "\/" separators, hence the replace.
if (-not $WowRoot) {
  $WowRoot = 'C:\Program Files (x86)\World of Warcraft'
  $cfg = Join-Path $env:APPDATA 'Battle.net\Battle.net.config'
  $m = if (Test-Path $cfg) { Select-String -Path $cfg -Pattern '"DefaultInstallPath":\s*"([^"]+)"' | Select-Object -First 1 }
  if ($m) { $p = Join-Path ($m.Matches[0].Groups[1].Value -replace '\\/', '\') 'World of Warcraft'; if (Test-Path $p) { $WowRoot = $p } }
}
$repo   = Split-Path $PSScriptRoot -Parent
$target = Join-Path $repo 'docs\sync\GrimoireSync.lua'

function Find-SV {
  # Account-wide SavedVariables: <WoW>\<flavor>\WTF\Account\<ACCOUNT>\SavedVariables\GrimoireSync.lua
  Get-ChildItem "$WowRoot\*\WTF\Account\*\SavedVariables\GrimoireSync.lua" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Sync-Once {
  $sv = Find-SV
  if (-not $sv) { Write-Host "GrimoireSync.lua not found yet. Log in with the addon enabled, then log out or /reload." -ForegroundColor Yellow; return }
  $clean = (Get-Content $sv.FullName -Encoding UTF8) | Where-Object { $_ -notmatch '^\s*\["(name|realm)"\]\s*=' }
  $text  = ($clean -join "`n") + "`n"
  New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
  if ((Test-Path $target) -and ((Get-Content $target -Raw -Encoding UTF8) -eq $text)) { Write-Host "No changes."; return }
  Set-Content $target $text -Encoding UTF8 -NoNewline
  & (Join-Path $PSScriptRoot 'build.ps1')
  $lvl = ([regex]::Match($text, '\["level"\]\s*=\s*(\d+)')).Groups[1].Value
  Write-Host "Synced snapshot (level $lvl) from $($sv.FullName)" -ForegroundColor Green
  if (-not $NoPush) {
    git -C $repo add docs | Out-Null
    git -C $repo commit -m "sync: level $lvl" | Out-Null
    git -C $repo push --quiet
    Write-Host "Pushed. The site updates in about a minute."
  }
}

Sync-Once
if ($Watch) {
  Write-Host "Watching for logouts / reloads. Ctrl+C to stop."
  $last = (Find-SV).LastWriteTime
  while ($true) {
    Start-Sleep -Seconds 20
    $now = (Find-SV).LastWriteTime
    if ($now -and $now -ne $last) { $last = $now; Sync-Once }
  }
}
