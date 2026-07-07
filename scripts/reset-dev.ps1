# Reset Beacle to first-run state (dev).
$ErrorActionPreference = 'Stop'

Write-Host 'Stopping backend...' -ForegroundColor Cyan
taskkill /IM beacle-backend.exe /F 2>$null | Out-Null

$appData = Join-Path $env:APPDATA 'Beacle'
if (Test-Path $appData) {
    Remove-Item -Recurse -Force $appData
    Write-Host "Removed $appData" -ForegroundColor Green
}

$legacy = Join-Path $env:APPDATA 'beacle'
if (Test-Path $legacy) {
    Remove-Item -Recurse -Force $legacy
    Write-Host "Removed $legacy" -ForegroundColor Green
}

Write-Host 'Done. Rebuild and run beacle.exe to see onboarding.' -ForegroundColor Green
