# install-wsl.ps1 — bootstrap Windows → WSL2 + Ubuntu + Nerd Font + git + Windows Terminal.
# Run as Administrator.

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text)
    Write-Host "`n== $Text ==" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Step "Enabling WSL and Virtual Machine Platform features"
$wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
$vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform

if ($wsl.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All
}
if ($vmp.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All
}

Write-Step "Ensuring winget is available"
if (-not (Test-CommandExists winget)) {
    Write-Host "winget not found. Install 'App Installer' from the Microsoft Store and re-run." -ForegroundColor Yellow
    exit 1
}

Write-Step "Installing winget packages (git, Windows Terminal, Nerd Font)"
$packages = @(
    'Git.Git',
    'Microsoft.WindowsTerminal',
    'DEVCOM.JetBrainsMonoNerdFont'  # JetBrainsMono Nerd Font — Windows Terminal picks it up
)
foreach ($pkg in $packages) {
    winget install --id $pkg --silent --accept-package-agreements --accept-source-agreements `
        --exact --disable-interactivity 2>$null
}

Write-Step "Installing WSL2 + Ubuntu (default)"
wsl --install --no-launch 2>$null
wsl --set-default-version 2

Write-Step "Done."
Write-Host @"
Next steps:
  1. Reboot Windows to finish enabling WSL.
  2. Launch 'Ubuntu' from the Start menu; create your Linux user.
  3. In the Ubuntu shell, run:
       sudo apt-get update && sudo apt-get install -y git
       git clone https://github.com/henryavila/dev-bootstrap ~/dev-bootstrap
       bash ~/dev-bootstrap/bootstrap.sh
  4. In Windows Terminal, set the font for your Ubuntu profile to
     'JetBrainsMono Nerd Font' (Settings > Ubuntu > Appearance).
"@ -ForegroundColor Green
