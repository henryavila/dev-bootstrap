# reinstall-shell-wsl-gate.ps1 — automated e2e gate for `mesh reinstall shell`.
#
# Recreates the pre-0e30b18 failure (chsh to zsh before mesh ~/.zshrc, fzf
# only in bash-completion), asserts RED, runs `mesh reinstall shell`, asserts
# GREEN. Uses a throwaway distro; never touches Ubuntu-24.04.
#
#   powershell -ExecutionPolicy Bypass -File tests\e2e\reinstall-shell-wsl-gate.ps1
#   powershell -ExecutionPolicy Bypass -File tests\e2e\reinstall-shell-wsl-gate.ps1 -KeepDistro
#
# Not part of `bash tests/run-all.sh` (Windows+WSL only, minutes, downloads).

[CmdletBinding()]
param(
    [switch]$KeepDistro,
    [string]$Distro = 'mesh-shell-gate',
    [string]$GateUser = 'gate',
    [string]$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Helpers = Join-Path $PSScriptRoot 'reinstall-shell-wsl'
$CacheDir = 'D:\wsl-backups'
$RootfsGz = Join-Path $CacheDir 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$InstallPath = Join-Path $env:LOCALAPPDATA "WSL\$Distro"

function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$WinPath)
    $full = [System.IO.Path]::GetFullPath($WinPath)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [string]$User = 'root',
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    & wsl.exe -d $Distribution -u $User -- @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "wsl -d $Distribution -u $User failed rc=$LASTEXITCODE ($($ArgumentList -join ' '))"
    }
}

function Test-WslDistro {
    param([string]$Name)
    $names = @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return $names -contains $Name
}

function Unregister-WslDistro {
    param([string]$Name)
    if (Test-WslDistro $Name) {
        Write-Host "== unregister $Name =="
        wsl.exe --shutdown | Out-Null
        wsl.exe --unregister $Name | Out-Null
    }
}

if (-not (Test-Path $Helpers)) {
    throw "helpers missing: $Helpers"
}

Write-Host "== mesh reinstall shell WSL e2e =="
Write-Host "repo=$Repo distro=$Distro user=$GateUser"

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

if (-not (Test-Path $RootfsGz)) {
    Write-Host "== download Ubuntu 24.04 WSL rootfs =="
    Invoke-WebRequest -Uri $RootfsUrl -OutFile $RootfsGz
}

Unregister-WslDistro $Distro
Write-Host "== import $Distro =="
wsl.exe --import $Distro $InstallPath $RootfsGz
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed rc=$LASTEXITCODE" }

$helperMnt = ConvertTo-WslPath $Helpers
$repoMnt = ConvertTo-WslPath $Repo

Write-Host "== strip CRLF on helpers =="
Invoke-Wsl -Distribution $Distro -User root -ArgumentList @(
    'sed', '-i', 's/\r$//',
    "$helperMnt/apply-broken-shell-fixture.sh",
    "$helperMnt/probe-shell-gate.sh",
    "$helperMnt/copy-mesh.sh"
)

Write-Host "== apply broken-shell fixture (pre-0e30b18) =="
Invoke-Wsl -Distribution $Distro -User root -ArgumentList @(
    'env', "GATE_USER=$GateUser", 'bash', "$helperMnt/apply-broken-shell-fixture.sh"
)

wsl.exe --shutdown | Out-Null
Start-Sleep -Seconds 2

Write-Host "== RED probe =="
Invoke-Wsl -Distribution $Distro -User $GateUser -ArgumentList @(
    'env', 'MODE=red', 'bash', "$helperMnt/probe-shell-gate.sh"
)

Write-Host "== copy mesh onto ext4 (LF) =="
Invoke-Wsl -Distribution $Distro -User $GateUser -ArgumentList @(
    'env', "MESH_SRC=$repoMnt", 'bash', "$helperMnt/copy-mesh.sh"
)

Write-Host "== mesh reinstall shell =="
Invoke-Wsl -Distribution $Distro -User $GateUser -ArgumentList @(
    '/bin/bash', "/home/$GateUser/mesh-workstation/scripts/runners/reinstall.sh", 'shell'
)

Write-Host "== GREEN probe =="
Invoke-Wsl -Distribution $Distro -User $GateUser -ArgumentList @(
    'env', 'MODE=green', 'bash', "$helperMnt/probe-shell-gate.sh"
)

if (-not $KeepDistro) {
    Unregister-WslDistro $Distro
    Write-Host "== throwaway distro removed =="
} else {
    Write-Host "== keeping $Distro (-KeepDistro) =="
}

Write-Host "E2E GATE PASS"
exit 0
