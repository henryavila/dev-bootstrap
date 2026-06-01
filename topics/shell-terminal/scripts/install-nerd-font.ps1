# install-nerd-font.ps1 — user-level install of CaskaydiaCove Nerd Font on Windows.
#
# Invoked from WSL via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this path>
#
# Installs at user-level ($env:LOCALAPPDATA\Microsoft\Windows\Fonts), which
# does NOT require admin. Registered under HKCU so Windows Terminal + every
# Windows app sees it on next launch.
#
# Idempotent: checks if the font is already registered in HKCU before
# downloading. No network / no-op on subsequent runs.

$ErrorActionPreference = "Stop"

$FontFamily   = "CaskaydiaCove Nerd Font"
$ReleaseUrl   = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaCode.zip"
$FontsDir     = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$RegKey       = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"

# ─── Check if already installed ───────────────────────────────────────
$existing = Get-ItemProperty -Path $RegKey -ErrorAction SilentlyContinue
if ($existing) {
    $hit = $existing.PSObject.Properties.Name | Where-Object {
        $_ -like "CaskaydiaCove*" -or $_ -like "CaskaydiaMono*"
    }
    if ($hit) {
        Write-Host "[ok] CaskaydiaCove Nerd Font already registered ($($hit.Count) faces)"
        exit 0
    }
}

# ─── Download + extract ───────────────────────────────────────────────
Write-Host "[info] downloading CaskaydiaCove Nerd Font from $ReleaseUrl"
$tmpZip = Join-Path $env:TEMP ("nerd-font-" + [guid]::NewGuid() + ".zip")
$tmpDir = Join-Path $env:TEMP ("nerd-font-" + [guid]::NewGuid())

try {
    # TLS 1.2 explicitly — older PowerShell (5.1) defaults to 1.0.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ReleaseUrl -OutFile $tmpZip -UseBasicParsing

    Write-Host "[info] extracting → $tmpDir"
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

    # ─── Register each .ttf ───────────────────────────────────────────
    if (-not (Test-Path $FontsDir)) {
        New-Item -ItemType Directory -Path $FontsDir -Force | Out-Null
    }

    $ttfs = Get-ChildItem -Path $tmpDir -Filter "*.ttf" -Recurse | Where-Object {
        # Skip the Windows-compat "Mono" variants; the main family is enough.
        $_.Name -notlike "*Windows Compatible*"
    }

    if ($ttfs.Count -eq 0) {
        Write-Error "[fail] no .ttf files found in the extracted archive"
        exit 1
    }

    $installed = 0
    foreach ($ttf in $ttfs) {
        $target = Join-Path $FontsDir $ttf.Name
        Copy-Item -Path $ttf.FullName -Destination $target -Force

        # Read font's internal PostScript name for the registry entry.
        # Windows uses "<FamilyName> (TrueType)" as the value name; the
        # actual font file path is the value data.
        $regName = ($ttf.BaseName -replace "[-_]", " ") + " (TrueType)"
        New-ItemProperty -Path $RegKey -Name $regName -Value $target `
            -PropertyType String -Force | Out-Null
        $installed++
    }

    Write-Host "[ok] registered $installed font faces under $FontsDir"
    Write-Host "[ok] Windows Terminal will pick them up on next launch"
}
finally {
    Remove-Item -Path $tmpZip -ErrorAction SilentlyContinue
    Remove-Item -Path $tmpDir -Recurse -ErrorAction SilentlyContinue
}
