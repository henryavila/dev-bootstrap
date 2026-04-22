# import-mkcert-from-windows.ps1
#
# Windows-side companion to import-mkcert-windows.ps1. Use this one when
# WSL interop is broken (binfmt_misc/WSLInterop not registered, 9P mount
# zombie, etc.) — it reads the mkcert rootCA from WSL via `wsl.exe cat`,
# which uses the Windows-side VM host channel and DOES NOT depend on the
# WSL→Windows interop layer that fails with os-error-5 in those states.
#
# Run from a Windows PowerShell prompt (NOT from inside WSL):
#
#   & '\\wsl.localhost\Ubuntu-24.04\home\<user>\dev-bootstrap\topics\60-laravel-stack\scripts\import-mkcert-from-windows.ps1'
#
# Or with an explicit distro when you have more than one:
#
#   & '...\import-mkcert-from-windows.ps1' -Distro Ubuntu-24.04 -WslUser henry
#
# Idempotent via thumbprint: running twice is a no-op the second time.

[CmdletBinding()]
param(
    [string]$Distro = '',
    [string]$WslUser = ''
)

$ErrorActionPreference = 'Stop'

# ─── Locate `wsl.exe` ────────────────────────────────────────────────
# Available in default Windows PATH since WSL2 GA. If missing, the user
# has a bigger issue than this script can address.
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Error '[fail] wsl.exe not found in PATH — install/reinstall WSL: `wsl --install`.'
    exit 1
}

# ─── Resolve distro (use default if not specified) ───────────────────
if (-not $Distro) {
    # `wsl -l -q --default` would be ideal; but there's no direct "get
    # default" flag. Parse `wsl -l -v`: line starting with '*' is default.
    $default = (wsl.exe -l -v 2>$null) -split "`n" |
        Where-Object { $_ -match '^\s*\*' } |
        ForEach-Object { ($_ -replace '\*', '').Trim() -split '\s+' | Select-Object -First 1 } |
        Select-Object -First 1
    if ($default) {
        $Distro = $default
        Write-Host "[info] Using default WSL distro: $Distro"
    } else {
        Write-Error '[fail] Could not detect default WSL distro. Pass -Distro explicitly.'
        exit 1
    }
}

# ─── Resolve WSL user ────────────────────────────────────────────────
if (-not $WslUser) {
    try {
        $WslUser = (wsl.exe -d $Distro whoami 2>$null | Out-String).Trim()
    } catch {
        Write-Error "[fail] Could not determine WSL user for distro '$Distro'. Pass -WslUser explicitly."
        exit 1
    }
    if (-not $WslUser) {
        Write-Error "[fail] wsl.exe -d $Distro whoami returned empty. Pass -WslUser explicitly."
        exit 1
    }
    Write-Host "[info] Using WSL user: $WslUser"
}

# ─── Read the rootCA from inside WSL via `wsl.exe cat` ───────────────
# `wsl.exe cat` streams the file through the VM host channel. This path
# is distinct from the binfmt_misc interop channel and survives the
# "/mnt/c is I/O error" state — wsl.exe talks to the WSL VM service,
# not to /init inside it.
$caPathInWsl = "/home/$WslUser/.local/share/mkcert/rootCA.pem"
Write-Host "[info] Reading $caPathInWsl from $Distro via wsl.exe…"

$tmpCa = Join-Path $env:TEMP "mkcert-rootCA-$([guid]::NewGuid()).pem"
try {
    & wsl.exe -d $Distro --exec cat $caPathInWsl > $tmpCa 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpCa) -or ((Get-Item $tmpCa).Length -lt 100)) {
        Write-Error "[fail] Could not read mkcert rootCA.pem from WSL."
        Write-Error "       Expected at: $caPathInWsl"
        Write-Error "       Re-check with: wsl.exe -d $Distro ls -la /home/$WslUser/.local/share/mkcert/"
        exit 1
    }

    # ─── Thumbprint check (idempotent) ───────────────────────────────
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $tmpCa
    $thumbprint = $cert.Thumbprint

    $existing = Get-ChildItem -Path Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $thumbprint }

    if ($existing) {
        Write-Host "[ok] mkcert rootCA already trusted in CurrentUser\Root"
        Write-Host "     thumbprint: $thumbprint"
        return
    }

    # ─── Import ──────────────────────────────────────────────────────
    Import-Certificate -FilePath $tmpCa -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Write-Host "[ok] mkcert rootCA imported into CurrentUser\Root"
    Write-Host "     thumbprint: $thumbprint"
    Write-Host "[info] Chrome / Edge / curl-wincrypt will trust *.localhost on next launch"
    Write-Host "[info] Firefox: set security.enterprise_roots.enabled = true in about:config"
} finally {
    Remove-Item -LiteralPath $tmpCa -ErrorAction SilentlyContinue
}
