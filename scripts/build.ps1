# Builds the full Beacle stack on Windows (local-first release bundle).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$releaseDir = "$root\app\build\windows\x64\runner\Release"
$distAgent = "$root\dist\agent"

Write-Host '[1/5] backend (bundled with app, no console)' -ForegroundColor Cyan
Push-Location "$root\backend"
go build -ldflags "-H windowsgui" -o beacle-backend.exe .
Pop-Location

Write-Host '[2/5] agent linux binaries (VPS + GitHub releases)' -ForegroundColor Cyan
Push-Location "$root\agent"
$env:GOOS = 'linux'
New-Item -ItemType Directory -Force -Path "$distAgent\linux-amd64", "$distAgent\linux-arm64", "$root\backend\data\bin" | Out-Null
foreach ($pair in @{ amd64 = 'linux-amd64'; arm64 = 'linux-arm64' }.GetEnumerator()) {
    $env:GOARCH = $pair.Key
    $ghName = if ($pair.Key -eq 'arm64') { 'beacle-agent-arm64' } else { 'beacle-agent-amd64' }
    $outFolder = "$distAgent\$($pair.Value)\beacle-agent"
    $outFlat = "$distAgent\beacle-agent-linux-$($pair.Key)"
    $outGh = "$distAgent\$ghName"
    $outBackend = "$root\backend\data\bin\beacle-agent-linux-$($pair.Key)"
    go build -o $outFolder .
    Copy-Item $outFolder $outFlat -Force
    Copy-Item $outFolder $outGh -Force
    Copy-Item $outFolder "$distAgent\$($pair.Value)\$ghName" -Force
    Copy-Item $outFolder $outBackend -Force
    Write-Host "  built $($pair.Value) -> dist/agent/$ghName (upload to GitHub agentbeta)"
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
$dataDest = "$releaseDir\data"
New-Item -ItemType Directory -Force -Path "$dataDest\bin" | Out-Null
Copy-Item "$root\backend\data\bin\*" "$dataDest\bin\" -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$dataDest\state.json")) {
    '{"vps":{},"links":{},"alerts":[],"actions":[]}' | Set-Content "$dataDest\state.json" -Encoding UTF8
}

Write-Host '[5/5] agent release layout (upload to GitHub Releases):' -ForegroundColor Cyan
Get-ChildItem $distAgent -Recurse -File | ForEach-Object { Write-Host "  $($_.FullName.Replace($root, '.'))" }

# Build the Windows installer when Inno Setup is installed. Silent skip
# otherwise — the rest of the build still works without it, and a dev box
# without Inno should not fail a release build of everything else.
$iss = "$root\installer\windows\beacle.iss"
$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if (-not $iscc) {
    $isccPaths = @(
        'C:\Program Files (x86)\Inno Setup 6\iscc.exe',
        'C:\Program Files\Inno Setup 6\iscc.exe',
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\iscc.exe"
    )
    foreach ($p in $isccPaths) {
        if (Test-Path $p) { $iscc = [pscustomobject]@{ Source = $p }; break }
    }
}
if ($iscc) {
    Write-Host '[installer] building beacle.iss' -ForegroundColor Cyan
    # Pull the version out of pubspec.yaml so the installer shows the same
    # number as the app, without a second place to bump it.
    $pubspec = Get-Content "$root\app\pubspec.yaml" -Raw
    $verMatch = [regex]::Match($pubspec, '(?m)^version:\s*([^\s]+)')
    $appVer = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { '0.0.0' }
    & $iscc.Source "/DAppVersion=$appVer" $iss
    if (Test-Path "$root\dist\installer") {
        Get-ChildItem "$root\dist\installer\*.exe" | ForEach-Object {
            Write-Host "  installer: $($_.FullName.Replace($root, '.'))"
        }
    }
} else {
    Write-Host '[installer] Inno Setup not found — skipping beacle.iss (install Inno Setup 6 to build it)' -ForegroundColor Yellow
}

Write-Host 'Done.' -ForegroundColor Green
Write-Host "  Run: $releaseDir\beacle.exe"
Write-Host '  VPS install: curl -fsSL https://github.com/c-airr/beacle/releases/download/agentbeta/install.sh | sudo bash -s http://<tailscale-ip>:9930'
Write-Host '  Upload to GitHub agentbeta: dist/agent/install.sh, beacle-agent-amd64, beacle-agent-arm64'
Write-Host '  Upload to GitHub latest: dist/installer/*.exe, installer/linux/install.sh, installer/linux/uninstall.sh'
