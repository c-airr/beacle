# Uruchamia panel Beacle (backend startuje automatycznie w aplikacji).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = "$root\app\build\windows\x64\runner\Release\beacle.exe"

if (-not (Test-Path $exe)) {
    & "$PSScriptRoot\build.ps1"
}

Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent)
