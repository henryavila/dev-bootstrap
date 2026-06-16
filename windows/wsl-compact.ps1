#Requires -Version 5.0
<#
.SYNOPSIS
  Compact a WSL2 distro's ext4.vhdx so freed space returns to the Windows host.

.DESCRIPTION
  Deleting files inside WSL does not shrink ext4.vhdx — it grows but never
  auto-shrinks. This shuts WSL down and enables sparse mode
  (wsl --manage --set-sparse true), which compacts the disk now AND makes it
  auto-shrink going forward. No admin and no Hyper-V required on WSL 2.x.

  Pair with `mesh clean --apply --deep` INSIDE WSL first to maximise what gets
  reclaimed before compaction. This is Phase B of the disk-reclaim flow.

.PARAMETER Distro
  The distro name (see `wsl -l -q`). Default: Ubuntu.

.PARAMETER DiskPart
  Also run a one-shot diskpart 'compact vdisk' pass (needs an elevated prompt).
  Optional fallback; --set-sparse alone is usually enough.

.PARAMETER Yes
  Skip the confirmation prompt.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File wsl-compact.ps1 -Distro Ubuntu
#>
param(
  [string]$Distro = "Ubuntu",
  [switch]$DiskPart,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"

Write-Host "WSL VHDX compaction for distro: $Distro" -ForegroundColor Cyan
Write-Host "This SHUTS DOWN all WSL distros (wsl --shutdown), then enables sparse mode."

if (-not $Yes) {
  $ans = Read-Host "Proceed? [y/N]"
  if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host "Aborted."; exit 0 }
}

# Locate the distro's ext4.vhdx via the WSL registry (informational: report the
# file size before/after so the user sees the space returned).
function Get-VhdxPath {
  param([string]$Name)
  $entry = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.DistributionName -eq $Name } |
    Select-Object -First 1
  if ($entry -and $entry.BasePath) {
    $base = $entry.BasePath -replace '^\\\\\?\\', ''
    $p = Join-Path $base "ext4.vhdx"
    if (Test-Path $p) { return $p }
  }
  return $null
}

$vhdx = Get-VhdxPath -Name $Distro
if ($vhdx) {
  Write-Host ("VHDX: {0}" -f $vhdx)
  Write-Host ("Size before: {0:N1} GB" -f ((Get-Item $vhdx).Length / 1GB))
} else {
  Write-Host "WARN: could not locate ext4.vhdx for '$Distro' in the registry; continuing anyway." -ForegroundColor Yellow
}

Write-Host "Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown

Write-Host "Enabling sparse mode (compacts + auto-shrinks from now on)..." -ForegroundColor Yellow
wsl --manage $Distro --set-sparse true

if ($DiskPart -and $vhdx) {
  Write-Host "Running one-shot diskpart compact (needs an elevated prompt)..." -ForegroundColor Yellow
  $diskpartScript = @"
select vdisk file="$vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
"@
  $tmp = [System.IO.Path]::GetTempFileName()
  Set-Content -Path $tmp -Value $diskpartScript -Encoding ASCII
  diskpart /s $tmp
  Remove-Item $tmp -Force
}

if ($vhdx -and (Test-Path $vhdx)) {
  Write-Host ("Size after:  {0:N1} GB" -f ((Get-Item $vhdx).Length / 1GB)) -ForegroundColor Green
}
Write-Host "Done. Start WSL again with: wsl" -ForegroundColor Green
