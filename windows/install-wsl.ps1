# install-wsl.ps1 — bootstrap Windows → WSL2 + Ubuntu + Git + Windows Terminal.
# Fonts/theme are owned by mesh shell-terminal (CaskaydiaCove) after WSL setup.
# Run as Administrator.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
#   powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1 -Reboot
#
# Exit codes:
#   0  success (WSL distro registered or already present)
#   1  hard failure (winget missing/unrecoverable, package or wsl install failed)
#   2  reboot required before wsl --install can proceed (features just enabled)

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host "`n== $Text ==" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-PendingReboot {
    # Best-effort: CBS RebootPending + WSL optional-feature enable without restart.
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        return $true
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        return $true
    }
    return $false
}

function Ensure-Winget {
    if (Test-CommandExists winget) {
        return
    }

    Write-Step "winget missing — trying Desktop App Installer registration"
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch {
        Write-Host "RegisterByFamilyName failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Refresh command lookup in this session.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')

    if (Test-CommandExists winget) {
        Write-Host "winget is available after App Installer registration." -ForegroundColor Green
        return
    }

    Write-Host @"
winget is still not available.

Install 'App Installer' (Microsoft.DesktopAppInstaller) from the Microsoft Store
or from https://aka.ms/getwinget, then re-run this script as Administrator:

  powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
"@ -ForegroundColor Yellow
    exit 1
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id
    )

    Write-Host "winget install $Id ..."
    & winget install --id $Id --silent --accept-package-agreements --accept-source-agreements `
        --exact --disable-interactivity
    $code = $LASTEXITCODE

    # 0 = success. Common "already installed" / no-op codes from winget:
    #   -1978335189 (0x8A15002B) already installed
    #   -1978335135 (0x8A150061) found existing package by upgrade check
    if ($code -eq 0 -or $code -eq -1978335189 -or $code -eq -1978335135) {
        Write-Host "  ok ($Id) [winget exit $code]" -ForegroundColor Green
        return
    }

    throw "winget failed for package '$Id' (exit $code)"
}

Write-Step "Enabling WSL and Virtual Machine Platform features"
$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
$vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
$enabledNow = $false

if ($wslFeature.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All | Out-Null
    $enabledNow = $true
}
if ($vmpFeature.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
    $enabledNow = $true
}

if ($enabledNow -or (Test-PendingReboot)) {
    Write-Step "Reboot required before installing the Ubuntu distro"
    Write-Host "Windows features were enabled (or a reboot is already pending)." -ForegroundColor Yellow
    Write-Host "After reboot, re-run this same script as Administrator to finish WSL install." -ForegroundColor Yellow
    if ($Reboot) {
        Write-Host "Rebooting now (-Reboot)..." -ForegroundColor Cyan
        Restart-Computer -Force
    }
    exit 2
}

Write-Step "Ensuring winget is available"
Ensure-Winget

Write-Step "Installing winget packages (Git + Windows Terminal)"
# Nerd Font is NOT installed here — mesh shell-terminal/fonts owns CaskaydiaCove
# + Windows Terminal theme merge once Ubuntu is up.
$packages = @(
    'Git.Git',
    'Microsoft.WindowsTerminal'
)
foreach ($pkg in $packages) {
    Install-WingetPackage -Id $pkg
}

Write-Step "Installing WSL2 + Ubuntu-24.04"
# Pin the distro channel so machines do not drift across 'Ubuntu' aliases.
& wsl --install -d Ubuntu-24.04 --no-launch
if ($LASTEXITCODE -ne 0) {
    # Fallback for hosts where the Store alias is still plain 'Ubuntu'.
    Write-Host "Ubuntu-24.04 install returned $LASTEXITCODE — trying distro 'Ubuntu'" -ForegroundColor Yellow
    & wsl --install -d Ubuntu --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --install failed (exit $LASTEXITCODE)"
    }
}

& wsl --set-default-version 2
if ($LASTEXITCODE -ne 0) {
    throw "wsl --set-default-version 2 failed (exit $LASTEXITCODE)"
}

Write-Step "Verifying WSL"
& wsl -l -v
if ($LASTEXITCODE -ne 0) {
    throw "wsl -l -v failed after install (exit $LASTEXITCODE)"
}

Write-Step "Done."
Write-Host @"

Next steps:
  1. Launch 'Ubuntu' / 'Ubuntu 24.04' from the Start menu and create your Linux user.
  2. In the Ubuntu shell (Phase 0 — needed to clone over HTTPS):
       sudo apt-get update && sudo apt-get install -y git curl ca-certificates
  3. Clone and run mesh setup:
       git clone https://github.com/henryavila/mesh-workstation ~/mesh-workstation
       cd ~/mesh-workstation
       bash setup.sh
  4. Fonts + Windows Terminal theme (CaskaydiaCove Nerd Font, Catppuccin) are
     applied by the shell-terminal/fonts bundle during setup — no manual
     Settings > Appearance step.

If this was the first enable of WSL features on the machine and something looks
wrong, reboot once and re-run:
  powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
"@ -ForegroundColor Green
