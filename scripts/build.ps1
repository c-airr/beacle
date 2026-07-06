# Builds the full Beacle stack on Windows (local-first release bundle).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\app\build\windows\x64\runner\Release"

Write-Host '[1/4] backend (bundled with app, no console)' -ForegroundColor Cyan
Push-Location "$root\backend"
go build -ldflags "-H windowsgui" -o beacle-backend.exe .
Pop-Location

Write-Host '[2/4] agent linux binaries (served by local backend)' -ForegroundColor Cyan
Push-Location "$root\agent"
$env:GOOS = 'linux'
foreach ($arch in 'amd64', 'arm64') {
    $env:GOARCH = $arch
    go build -o "$root\backend\data\bin\beacle-agent-linux-$arch" .
}
Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
$ver = & go run . -version 2>$null
if (-not $ver) { $ver = '0.1.0' }
Set-Content "$root\backend\data\bin\VERSION" $ver
Pop-Location

Write-Host '[3/4] flutter desktop app' -ForegroundColor Cyan
Push-Location "$root\app"
flutter build windows --release
Pop-Location

Write-Host '[4/4] bundle backend + data into release folder' -ForegroundColor Cyan
Copy-Item "$root\backend\beacle-backend.exe" "$releaseDir\beacle-backend.exe" -Force
$dataDest = "$releaseDir\data"
New-Item -ItemType Directory -Force -Path "$dataDest\bin" | Out-Null
Copy-Item "$root\backend\data\bin\*" "$dataDest\bin\" -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$dataDest\state.json")) {
    '{"vps":{},"links":{},"alerts":[],"actions":[]}' | Set-Content "$dataDest\state.json" -Encoding UTF8
}

Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Run: $releaseDir\beacle.exe"
Write-Host '  Backend starts automatically with the app (local-first).'
