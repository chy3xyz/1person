# Public installer entrypoint. Canonical implementation lives under backend/.
# Keep this path stable — docs use scripts/install.ps1.
$ErrorActionPreference = "Stop"
$backendInstaller = Join-Path $PSScriptRoot "..\backend\scripts\install.ps1"
& $backendInstaller @args
