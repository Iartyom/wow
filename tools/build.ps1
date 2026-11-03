# Builds docs/index.html (GitHub Pages) from index.html (the Claude artifact source).
# The artifact source has no <!doctype>/<head> because claude.ai wraps it at publish time,
# so Pages needs the same skeleton added here, or the browser renders in quirks mode.
$repo = Split-Path $PSScriptRoot -Parent
$src  = Get-Content (Join-Path $repo 'index.html') -Raw -Encoding UTF8
$head = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>:root{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style></head><body>'
$out  = $head + "`n" + $src + "`n</body></html>`n"
New-Item -ItemType Directory -Force (Join-Path $repo 'docs') | Out-Null
Set-Content (Join-Path $repo 'docs/index.html') $out -Encoding UTF8 -NoNewline
Write-Host "Built docs/index.html"
