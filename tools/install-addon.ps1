# Copies addon/GrimoireSync into the WoW Forever AddOns folder.
# The client folder is _forever_ (live 1.60.1). By default this picks any folder under the WoW
# root whose name contains "forever"; pass -Flavor to override.
param(
  [string]$WowRoot,
  [string]$Flavor
)
# WoW root: -WowRoot wins, else Battle.net's DefaultInstallPath (this PC: D:\Games) + "World of Warcraft",
# else the stock C: path. Battle.net writes the path with "\/" separators, hence the replace.
if (-not $WowRoot) {
  $WowRoot = 'C:\Program Files (x86)\World of Warcraft'
  $cfg = Join-Path $env:APPDATA 'Battle.net\Battle.net.config'
  $m = if (Test-Path $cfg) { Select-String -Path $cfg -Pattern '"DefaultInstallPath":\s*"([^"]+)"' | Select-Object -First 1 }
  if ($m) { $p = Join-Path ($m.Matches[0].Groups[1].Value -replace '\\/', '\') 'World of Warcraft'; if (Test-Path $p) { $WowRoot = $p } }
}
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Flavor) {
  $cand = Get-ChildItem $WowRoot -Directory | Where-Object Name -match 'forever'
  if (-not $cand) {
    Write-Host "No Forever folder found in $WowRoot. Folders there:" -ForegroundColor Yellow
    Get-ChildItem $WowRoot -Directory | ForEach-Object { "  " + $_.Name }
    Write-Host "Install Forever first, or run: .\tools\install-addon.ps1 -Flavor <folder name>"
    exit 1
  }
  $Flavor = $cand[0].Name
}
$dest = Join-Path $WowRoot "$Flavor\Interface\AddOns"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $repo 'addon\GrimoireSync') $dest -Recurse -Force
Write-Host "Installed GrimoireSync to $dest" -ForegroundColor Green
Write-Host "In game: enable it in the AddOns list (tick 'Load out of date AddOns' if it is flagged)."
