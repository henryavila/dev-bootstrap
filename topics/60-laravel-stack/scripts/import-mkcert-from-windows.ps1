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
# wsl.exe on Windows emits output as UTF-16 LE, which PowerShell reads
# as wide chars. When we treat them as regular strings they contain null
# bytes between the visible characters — any `-match '^\s*\*'` on the
# raw output silently fails. Strip null bytes before matching, and try
# two parse strategies (quiet list first, verbose as fallback).
if (-not $Distro) {
    # Strategy A: `wsl -l --quiet` — one distro name per line. The first
    # line is the default. Simpler to parse, no column alignment.
    try {
        $quietRaw = (& wsl.exe -l --quiet 2>$null | Out-String) -replace "`0", ""
        $quietList = $quietRaw -split "[\r\n]+" | Where-Object { $_.Trim() -ne "" }
        if ($quietList.Count -gt 0) {
            $Distro = $quietList[0].Trim()
        }
    } catch {
        # Ignored — fall through to Strategy B
    }

    # Strategy B: parse `wsl -l -v` output, finding the line marked with '*'.
    if (-not $Distro) {
        try {
            $verboseRaw = (& wsl.exe -l -v 2>$null | Out-String) -replace "`0", ""
            $defaultLine = $verboseRaw -split "[\r\n]+" |
                Where-Object { $_ -match '^\s*\*' } |
                Select-Object -First 1
            if ($defaultLine) {
                $Distro = (($defaultLine -replace '^\s*\*\s*', '') -split '\s+')[0].Trim()
            }
        } catch {
            # Give up — user must pass -Distro
        }
    }

    if (-not $Distro) {
        Write-Error @'
[fail] Could not detect default WSL distro.

List what you have installed:
    wsl -l -v

Then re-run this script with -Distro:
    powershell -ExecutionPolicy Bypass -File '<unc-path>' -Distro 'Ubuntu-24.04'
'@
        exit 1
    }
    Write-Host "[info] Using default WSL distro: $Distro"
}

# ─── Resolve WSL user ────────────────────────────────────────────────
# Same UTF-16 LE issue as distro detection: strip null bytes before trim.
if (-not $WslUser) {
    try {
        $WslUser = ((& wsl.exe -d $Distro whoami 2>$null | Out-String) -replace "`0", "").Trim()
    } catch {
        # fall through to explicit error below
    }
    if (-not $WslUser) {
        Write-Error @"
[fail] Could not determine WSL user for distro '$Distro'.

Verify the distro responds:
    wsl.exe -d '$Distro' whoami

Then re-run with -WslUser:
    powershell -ExecutionPolicy Bypass -File '<unc-path>' -Distro '$Distro' -WslUser '<username>'
"@
        exit 1
    }
    Write-Host "[info] Using WSL user: $WslUser"
}

# ─── Read the rootCA from inside WSL via `wsl.exe cat` ───────────────
# `wsl.exe cat` streams the file through the VM host channel. This path
# is distinct from the binfmt_misc interop channel and survives the
# "/mnt/c is I/O error" state — wsl.exe talks to the WSL VM service,
# not to /init inside it.
#
# IMPORTANT: PowerShell's `> file` redirect encodes the child process's
# stdout as UTF-16 LE with BOM by default. That corrupts the PEM (text
# ASCII) — bat/openssl/Import-Certificate would all reject the result.
# Start-Process -RedirectStandardOutput writes raw bytes, preserving
# the PEM exactly.
$caPathInWsl = "/home/$WslUser/.local/share/mkcert/rootCA.pem"
Write-Host "[info] Reading $caPathInWsl from $Distro via wsl.exe…"

$tmpCa  = Join-Path $env:TEMP "mkcert-rootCA-$([guid]::NewGuid()).pem"
$errLog = Join-Path $env:TEMP "mkcert-rootCA-$([guid]::NewGuid()).err"
try {
    $proc = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('-d', $Distro, '--exec', 'cat', $caPathInWsl) `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $tmpCa `
        -RedirectStandardError  $errLog `
        -PassThru

    if ($proc.ExitCode -ne 0 -or -not (Test-Path $tmpCa) -or ((Get-Item $tmpCa).Length -lt 100)) {
        Write-Error "[fail] Could not read mkcert rootCA.pem from WSL."
        Write-Error "       Expected at: $caPathInWsl (inside $Distro)"
        if (Test-Path $errLog) {
            $err = (Get-Content $errLog -Raw) -replace "`0", ""
            if ($err.Trim()) { Write-Error "       stderr: $($err.Trim())" }
        }
        Write-Error "       Verify with:  wsl.exe -d '$Distro' ls -la /home/$WslUser/.local/share/mkcert/"
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
    Remove-Item -LiteralPath $tmpCa  -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errLog -ErrorAction SilentlyContinue
}
