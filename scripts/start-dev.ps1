# Uruchamia backend + lokalny agent symulacyjny (Windows dev).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Must match BEACLE_BACKEND dart-define when running Flutter.
$base = 'http://127.0.0.1:8930'
$env:BEACLE_PUBLIC_URL = $base

Write-Host "Backend: $base" -ForegroundColor Cyan

# Backend
$backend = Get-Process beacle-backend -ErrorAction SilentlyContinue
if (-not $backend) {
    Push-Location "$root\backend"
    if (-not (Test-Path .\beacle-backend.exe)) { go build -o beacle-backend.exe . }
    Start-Process -FilePath .\beacle-backend.exe -ArgumentList '-addr','0.0.0.0:8930','-data',"$root\backend\data" -WorkingDirectory "$root\backend" -WindowStyle Hidden
    Pop-Location
    Start-Sleep 2
}

# Agent (jeśli jest dev-config.json)
$cfg = "$root\agent\dev-config.json"
if (Test-Path $cfg) {
    $running = Get-Process beacle-agent -ErrorAction SilentlyContinue
    if (-not $running) {
        Push-Location "$root\agent"
        if (-not (Test-Path .\beacle-agent.exe)) { go build -o beacle-agent.exe . }
        Start-Process -FilePath .\beacle-agent.exe -ArgumentList '-config',$cfg -WindowStyle Hidden
        Pop-Location
    }
}

# Flutter app
$env:PATH = "C:\tools\flutter\bin;$env:PATH"
Write-Host "Uruchamiam panel Flutter..." -ForegroundColor Cyan
Push-Location "$root\app"
flutter run -d windows --dart-define=BEACLE_BACKEND=$base
Pop-Location
