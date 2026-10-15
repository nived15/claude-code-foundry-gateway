# The access-catalog bundle (scripts/new-scripts) is published on its own: its copies must match this
# repository, and its own checks must pass.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
& pwsh -NoProfile -File (Join-Path $root 'scripts/Export-ClaudeAccessBundle.ps1') -Check
if ($LASTEXITCODE) { $fail++ }
& pwsh -NoProfile -File (Join-Path $root 'scripts/new-scripts/Test-ClaudeAccessCatalog.ps1')
if ($LASTEXITCODE) { $fail++ }
if ($fail) { Write-Host "$fail access-catalog bundle check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The access-catalog bundle matches this repository and its checks pass.' -ForegroundColor Green
exit 0
