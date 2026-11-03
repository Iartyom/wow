# Copies addon/GrimoireSync into the WoW Forever AddOns folder.
# Forever's client folder name isn't known before launch, so by default this picks any
# folder under the WoW root whose name contains "forever"; pass -Flavor to override (e.g. _forever_).
param(
  [string]$WowRoot = "C:\Program Files (x86)\World of Warcraft",
  [string]$Flavor
)
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
