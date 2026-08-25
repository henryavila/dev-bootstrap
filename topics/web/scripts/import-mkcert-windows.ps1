# import-mkcert-windows.ps1 — user-scope import of the mkcert rootCA into Windows.
#
# Invoked from WSL via:
#   $env:ROOTCA_PATH = (wslpath -w <path>)
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this path>
#
# Target: Cert:\CurrentUser\Root (trust store for the running user — Edge,
# Chrome, and any WinHTTP-based app read this store). No admin required.
#
# Firefox NOTE: Firefox maintains its OWN NSS store and ignores the Windows
# Certificate Store by default. Users on Firefox should either:
#   - Set `security.enterprise_roots.enabled = true` in about:config
#     (then Firefox reads CurrentUser\Root on start), OR
#   - Run `mkcert -install` from *within* Firefox's profile (rare).
#
# Idempotent: computes the cert thumbprint and skips import if already
# present in the store.

$ErrorActionPreference = "Stop"

$rootCA = $env:ROOTCA_PATH
if (-not $rootCA) {
    Write-Host "[fail] ROOTCA_PATH env var not set"
    exit 1
}
if (-not (Test-Path -LiteralPath $rootCA)) {
    Write-Host "[fail] ROOTCA_PATH points to a missing file: $rootCA"
    exit 1
}

# Load the cert (PEM or DER). Export DER .cer — Import-Certificate is picky
# about .pem and about files still sitting on `\\wsl.localhost\`.
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
        -ArgumentList $rootCA
} catch {
    Write-Host "[fail] couldn't parse $rootCA as X.509 cert: $_"
    exit 1
}

$thumbprint = $cert.Thumbprint

# Already imported?
$existing = Get-ChildItem -Path Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $thumbprint }

if ($existing) {
    Write-Host "[ok] mkcert rootCA already trusted in CurrentUser\Root"
    Write-Host "     thumbprint: $thumbprint"
    exit 0
}

# CurrentUser\Root import always raises Windows' Protected Roots confirmation
# (cannot be suppressed). Interactive sessions: click Yes. Headless / WSL
# interop: the caller wraps this in `timeout 45` and falls back to
# import-mkcert-from-windows.ps1 from a real Windows prompt.
$cerPath = Join-Path $env:TEMP ("mkcert-rootCA-" + $thumbprint + ".cer")
try {
    [System.IO.File]::WriteAllBytes($cerPath, $cert.Export(
        [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\CurrentUser\Root |
        Out-Null
} catch {
    Write-Host "[fail] Import-Certificate failed: $_"
    Write-Host "[info] CurrentUser\Root requires clicking Yes on the Windows security dialog"
    exit 1
} finally {
    Remove-Item -LiteralPath $cerPath -ErrorAction SilentlyContinue
}

Write-Host "[ok] mkcert rootCA imported into CurrentUser\Root"
Write-Host "     thumbprint: $thumbprint"
Write-Host "[info] Chrome / Edge / curl-wincrypt will trust *.localhost on next launch"
Write-Host "[info] Firefox users: set security.enterprise_roots.enabled = true in about:config"
