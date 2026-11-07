# Builds docs/index.html (GitHub Pages) from index.html (the Claude artifact source).
# The artifact source has no <!doctype>/<head> because claude.ai wraps it at publish time,
# so Pages needs the same skeleton added here, or the browser renders in quirks mode.
$repo = Split-Path $PSScriptRoot -Parent
$src  = Get-Content (Join-Path $repo 'index.html') -Raw -Encoding UTF8
# Stamp the build time into the footer's "Site last updated" (index.html too, so the Claude page shows it).
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$src   = $src -replace 'id="siteBuilt" data-t="[^"]*"', ('id="siteBuilt" data-t="' + $stamp + '"')
[IO.File]::WriteAllText((Join-Path $repo 'index.html'), $src, (New-Object Text.UTF8Encoding $false))
$head = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style></head><body>'
$out  = $head + "`n" + $src + "`n</body></html>`n"
New-Item -ItemType Directory -Force (Join-Path $repo 'docs') | Out-Null
Set-Content (Join-Path $repo 'docs/index.html') $out -Encoding UTF8 -NoNewline
Write-Host "Built docs/index.html"
