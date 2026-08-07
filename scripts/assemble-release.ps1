# Assembles release/ from a finished Windows build.
# Run after scripts/build.ps1 (or at least after flutter build windows --release).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$rel = "$root\release"
$winRel = "$root\app\build\windows\x64\runner\Release"

if (-not (Test-Path "$winRel\beacle.exe")) {
    throw "No Windows build at $winRel — run scripts/build.ps1 first."
}

New-Item -ItemType Directory -Force -Path "$rel\windows","$rel\linux","$rel\agent" | Out-Null

Write-Host '[1/4] beacle-windows-x64.zip' -ForegroundColor Cyan
$staging = "$rel\_win_staging"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item "$winRel\*" $staging -Recurse -Force
Remove-Item "$staging\*.exe~","$staging\install.sh","$staging\beacle.config.json.example" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$staging\data\bin" | Out-Null
Copy-Item "$root\dist\agent\beacle-agent-amd64","$root\dist\agent\beacle-agent-arm64" "$staging\data\bin\" -Force -ErrorAction SilentlyContinue
Copy-Item "$root\backend\data\bin\*" "$staging\data\bin\" -Force -ErrorAction SilentlyContinue
$zip = "$rel\windows\beacle-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$staging\*" -DestinationPath $zip -Force
Remove-Item $staging -Recurse -Force

Write-Host '[2/4] Windows installer' -ForegroundColor Cyan
$pubspec = Get-Content "$root\app\pubspec.yaml" -Raw
$verMatch = [regex]::Match($pubspec, '(?m)^version:\s*([^\s]+)')
$appVer = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { '0.0.0' }
$iscc = $null
foreach ($p in @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\iscc.exe",
    'C:\Program Files (x86)\Inno Setup 6\iscc.exe',
    'C:\Program Files\Inno Setup 6\iscc.exe'
)) { if (Test-Path $p) { $iscc = $p; break } }
if ($iscc) {
    & $iscc "/DAppVersion=$appVer" "$root\installer\windows\beacle.iss"
    Copy-Item "$root\dist\installer\beacle-setup-$appVer.exe" "$rel\windows\" -Force
} else {
    Write-Host '  Inno Setup not found — skip' -ForegroundColor Yellow
}

Write-Host '[3/4] Linux install scripts' -ForegroundColor Cyan
Copy-Item "$root\installer\linux\install.sh","$root\installer\linux\uninstall.sh","$root\installer\linux\beacle.desktop" "$rel\linux\" -Force
if (-not (Test-Path "$rel\linux\beacle-linux-x64.tar.gz")) {
    Set-Content "$rel\linux\LINUX_TARBALL_MISSING.txt" @(
        'beacle-linux-x64.tar.gz is not built on Windows.',
        'Build via GitHub Actions or on a Linux machine with Flutter + GTK deps.',
        'See release/README.md'
    )
}

Write-Host '[4/4] Agent binaries' -ForegroundColor Cyan
Copy-Item "$root\dist\agent\beacle-agent-amd64","$root\dist\agent\beacle-agent-arm64" "$rel\agent\" -Force -ErrorAction SilentlyContinue
Copy-Item "$root\dist\agent\install_agent.sh","$root\dist\agent\install.sh","$root\dist\agent\VERSION","$root\dist\agent\README.md" "$rel\agent\" -Force -ErrorAction SilentlyContinue

Write-Host 'Done — contents of release/:' -ForegroundColor Green
Get-ChildItem $rel -Recurse -File | ForEach-Object {
    '{0,12:N0}  {1}' -f $_.Length, $_.FullName.Replace("$root\", '')
}
