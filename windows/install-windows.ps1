# Install the Warren headless daemon + CLI on Windows from an extracted
# warren-headless-windows-x64 bundle. Run from an elevated PowerShell, inside
# that directory:
#
#   Expand-Archive warren-headless-windows-x64.zip
#   cd warren-headless-windows-x64
#   .\install-windows.ps1
#
# Uninstall:  .\install-windows.ps1 -Uninstall
#
# NOTE: the Warren QUIC tunnel is not yet validated on Windows. Account/CLI
# control-plane operations work; system-VPN connect is experimental.

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

$InstallDir = "$env:ProgramFiles\Warren"
$ResourceDir = "$InstallDir\resources"
$ServiceName = "warren-daemon"

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Run this script from an elevated (Administrator) PowerShell."
    }
}

Assert-Admin

if ($Uninstall) {
    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete $ServiceName | Out-Null
    }
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Host "Warren headless uninstalled."
    exit 0
}

$src = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path "$InstallDir\bin", $ResourceDir | Out-Null
Copy-Item "$src\bin\*" "$InstallDir\bin\" -Force
Copy-Item "$src\resources\*" $ResourceDir -Recurse -Force

# Make the CLI available on PATH (machine-wide).
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$InstallDir\bin*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$InstallDir\bin", "Machine")
}
[Environment]::SetEnvironmentVariable("WARREN_RESOURCE_DIR", $ResourceDir, "Machine")

Write-Host "Registering the $ServiceName service ..."
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
}
sc.exe create $ServiceName binPath= "`"$InstallDir\bin\warren-daemon.exe`" -vv" start= auto | Out-Null
sc.exe description $ServiceName "Warren VPN daemon (headless)" | Out-Null
Start-Service $ServiceName

Write-Host "Done. Open a new terminal and try:  warren account create; warren status"
