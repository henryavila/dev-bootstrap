# import-mkcert-from-windows.ps1
#
# Windows-side companion to import-mkcert-windows.ps1. Use this one when
# WSL interop (binfmt_misc/WSLInterop + /mnt/c 9P) is broken — this
# script uses `wsl.exe` calls from the Windows side (VM host channel,
# independent of interop) to read the mkcert rootCA and import it into
# Windows's trust store.
#
# Run from a Windows PowerShell prompt (NOT from inside WSL):
#
#   powershell -ExecutionPolicy Bypass -File '\\wsl.localhost\Ubuntu-24.04\home\<user>\dev-bootstrap\topics\60-web-stack\scripts\import-mkcert-from-windows.ps1'
#
# Or with explicit args when auto-detection fails:
#
#   powershell -ExecutionPolicy Bypass -File '...' -Distro Ubuntu-24.04 -WslUser henry
#
# Idempotent — re-running when the cert is already imported is a no-op.

[CmdletBinding()]
param(
    [string]$Distro = '',
    [string]$WslUser = ''
)

$ErrorActionPreference = 'Stop'

# ─── Core problem: wsl.exe emits UTF-16 LE output ────────────────────
# Every `wsl.exe` call in a PowerShell script hits the same trap: the
# child process writes UTF-16 LE bytes (sometimes with a BOM, sometimes
# not), and PowerShell's default pipe handling interprets them as 8-bit
# chars with null bytes between each visible character. `-replace "`0"`
# + `.Trim()` only fix the easy case.
#
# Invoke-WslExe uses Start-Process with -RedirectStandardOutput to a
# temp file, reads the RAW bytes, and decodes them the right way based
# on BOM sniffing + heuristic null-pattern detection. Returns both raw
# bytes (for binary content like certs) and decoded text (for whoami /
# list output).

function Invoke-WslExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$WslArgs
    )

    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath 'wsl.exe' `
            -ArgumentList $WslArgs `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tmpOut `
            -RedirectStandardError  $tmpErr

        $bytes = [System.IO.File]::ReadAllBytes($tmpOut)
        $errBytes = [System.IO.File]::ReadAllBytes($tmpErr)

        [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Stdout   = _DecodeWslBytes $bytes
            Stderr   = _DecodeWslBytes $errBytes
            RawBytes = $bytes
        }
    } finally {
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpErr -ErrorAction SilentlyContinue
    }
}

function _DecodeWslBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }

    # BOM sniffing covers the two common flavours.
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        # UTF-16 LE with BOM (what `wsl.exe -l -v` emits by default)
        return [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2).Trim()
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3).Trim()
    }

    # No BOM. Heuristic: if the first ~20 bytes have a lot of 0x00 at
    # the odd positions, it's UTF-16 LE without a BOM (some wsl.exe
    # subcommands emit this). Otherwise treat as UTF-8.
    $sampleLen = [Math]::Min($Bytes.Length, 40)
    $nullsAtOdd = 0
    for ($i = 1; $i -lt $sampleLen; $i += 2) {
        if ($Bytes[$i] -eq 0) { $nullsAtOdd++ }
    }
    # More than half the odd bytes being zero → UTF-16 LE pattern.
    if ($nullsAtOdd -gt ($sampleLen / 4)) {
        return ([System.Text.Encoding]::Unicode.GetString($Bytes) -replace "`0", "").Trim()
    }
    return ([System.Text.Encoding]::UTF8.GetString($Bytes) -replace "`0", "").Trim()
}

# ─── Sanity: wsl.exe on PATH ─────────────────────────────────────────
$wslExe = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslExe) {
    Write-Error '[fail] wsl.exe not found on PATH. Install/reinstall WSL: `wsl --install`.'
    exit 1
}

# ─── Resolve default distro ──────────────────────────────────────────
if (-not $Distro) {
    # `wsl -l --quiet` lists distros one per line, default first.
    $r = Invoke-WslExe '-l' '--quiet'
    if ($r.ExitCode -eq 0 -and $r.Stdout) {
        $Distro = ($r.Stdout -split "[\r\n]+" | Where-Object { $_.Trim() })[0].Trim()
    }

    # Fallback: parse `wsl -l -v`, find the line with '*'.
    if (-not $Distro) {
        $r = Invoke-WslExe '-l' '-v'
        if ($r.ExitCode -eq 0 -and $r.Stdout) {
            $line = ($r.Stdout -split "[\r\n]+" | Where-Object { $_ -match '^\s*\*' })[0]
            if ($line) {
                $Distro = (($line -replace '^\s*\*\s*', '') -split '\s+')[0].Trim()
            }
        }
    }

    if (-not $Distro) {
        Write-Error @'
[fail] Could not detect default WSL distro.

List installed distros:
    wsl -l -v

Then re-run with -Distro:
    powershell -ExecutionPolicy Bypass -File '<unc-path>' -Distro 'Ubuntu-24.04'
'@
        exit 1
    }
    Write-Host "[info] Using default WSL distro: $Distro"
}

# ─── Resolve WSL user ────────────────────────────────────────────────
if (-not $WslUser) {
    $r = Invoke-WslExe '-d' $Distro '--exec' 'whoami'
    if ($r.ExitCode -eq 0 -and $r.Stdout) {
        $WslUser = $r.Stdout
    }
    if (-not $WslUser) {
        $sample = if ($r.Stderr) { $r.Stderr } elseif ($r.RawBytes.Length -gt 0) {
            "raw bytes (hex): $(($r.RawBytes[0..[Math]::Min($r.RawBytes.Length - 1, 20)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')"
        } else { '(no output)' }
        Write-Error @"
[fail] Could not determine WSL user for '$Distro'.
       wsl.exe -d '$Distro' whoami returned exit=$($r.ExitCode), sample=$sample

Verify manually in an interactive PowerShell:
    wsl.exe -d '$Distro' whoami

If that works but this script doesn't, pass -WslUser explicitly:
    powershell -ExecutionPolicy Bypass -File '<unc-path>' -Distro '$Distro' -WslUser '<username>'
"@
        exit 1
    }
    Write-Host "[info] Using WSL user: $WslUser"
}

# ─── Read the rootCA via `wsl.exe --exec cat` ────────────────────────
$caPathInWsl = "/home/$WslUser/.local/share/mkcert/rootCA.pem"
Write-Host "[info] Reading $caPathInWsl from $Distro via wsl.exe…"

$r = Invoke-WslExe '-d' $Distro '--exec' 'cat' $caPathInWsl
if ($r.ExitCode -ne 0 -or -not $r.RawBytes -or $r.RawBytes.Length -lt 100) {
    Write-Error "[fail] Could not read $caPathInWsl from $Distro"
    if ($r.Stderr) { Write-Error "       stderr: $($r.Stderr)" }
    Write-Error "       Verify:  wsl.exe -d '$Distro' ls -la /home/$WslUser/.local/share/mkcert/"
    exit 1
}

# Write the raw cert bytes to a temp file for Import-Certificate.
# DO NOT use `> file` or `Out-File` — both corrupt the PEM with BOM/
# UTF-16 encoding. `WriteAllBytes` preserves the bytes exactly.
$tmpCa = Join-Path $env:TEMP "mkcert-rootCA-$([guid]::NewGuid()).pem"
try {
    [System.IO.File]::WriteAllBytes($tmpCa, $r.RawBytes)

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

    Import-Certificate -FilePath $tmpCa -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Write-Host "[ok] mkcert rootCA imported into CurrentUser\Root"
    Write-Host "     thumbprint: $thumbprint"
    Write-Host "[info] Chrome / Edge / curl-wincrypt will trust *.localhost on next launch"
    Write-Host "[info] Firefox: set security.enterprise_roots.enabled = true in about:config"
} finally {
    Remove-Item -LiteralPath $tmpCa -ErrorAction SilentlyContinue
}
