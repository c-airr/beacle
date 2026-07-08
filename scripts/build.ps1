# Builds the full Beacle stack on Windows (local-first release bundle).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\app\build\windows\x64\runner\Release"
$distAgent = "$root\dist\agent"

Write-Host '[1/5] backend (bundled with app, no console)' -ForegroundColor Cyan
Copy-Item "$root\scripts\install-agent.sh" "$root\backend\install-agent.sh" -Force
Push-Location "$root\backend"
go build -ldflags "-H windowsgui" -o beacle-backend.exe .
Pop-Location

Write-Host '[2/5] agent linux binaries (VPS + GitHub releases)' -ForegroundColor Cyan
Push-Location "$root\agent"
$env:GOOS = 'linux'
New-Item -ItemType Directory -Force -Path "$distAgent\linux-amd64", "$distAgent\linux-arm64", "$root\backend\data\bin" | Out-Null
foreach ($pair in @{ amd64 = 'linux-amd64'; arm64 = 'linux-arm64' }.GetEnumerator()) {
    $env:GOARCH = $pair.Key
    $outFolder = "$distAgent\$($pair.Value)\beacle-agent"
    $outFlat = "$distAgent\beacle-agent-linux-$($pair.Key)"
    $outBackend = "$root\backend\data\bin\beacle-agent-linux-$($pair.Key)"
    go build -o $outFolder .
    Copy-Item $outFolder $outFlat -Force
    Copy-Item $outFolder $outBackend -Force
    Write-Host "  built $($pair.Value) -> dist/agent/$($pair.Value)/beacle-agent"
}
Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
$ver = & go run . -version 2>$null
if (-not $ver) { $ver = '0.1.0' }
Set-Content "$root\backend\data\bin\VERSION" $ver
Set-Content "$distAgent\VERSION" $ver
Pop-Location

Write-Host '[3/5] flutter desktop app' -ForegroundColor Cyan
$flutter = if (Get-Command flutter -ErrorAction SilentlyContinue) { 'flutter' }
           elseif (Test-Path 'C:\tools\flutter\bin\flutter.bat') { 'C:\tools\flutter\bin\flutter.bat' }
           else { 'flutter' }
Push-Location "$root\app"
& $flutter build windows --release
Pop-Location

Write-Host '[4/5] bundle backend + agent into release folder' -ForegroundColor Cyan
Copy-Item "$root\backend\beacle-backend.exe" "$releaseDir\beacle-backend.exe" -Force
Copy-Item "$root\scripts\install-agent.sh" "$releaseDir\install.sh" -Force
$dataDest = "$releaseDir\data"
New-Item -ItemType Directory -Force -Path "$dataDest\bin" | Out-Null
Copy-Item "$root\backend\data\bin\*" "$dataDest\bin\" -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$dataDest\state.json")) {
    '{"vps":{},"links":{},"alerts":[],"actions":[]}' | Set-Content "$dataDest\state.json" -Encoding UTF8
}

Write-Host '[5/5] agent release layout (upload to GitHub Releases):' -ForegroundColor Cyan
Get-ChildItem $distAgent -Recurse -File | ForEach-Object { Write-Host "  $($_.FullName.Replace($root, '.'))" }

Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Run: $releaseDir\beacle.exe"
Write-Host '  VPS install: curl -fsSL http://<desktop-tailscale-ip>:8930/install | sudo bash'
Write-Host '  GitHub agent: dist/agent/beacle-agent-linux-amd64'
