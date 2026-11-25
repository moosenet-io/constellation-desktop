# setup-windows.ps1 -- MooseNet build target #5. Run in a NORMAL PowerShell (not admin) AFTER step 1 in README.
# Creates the WSL2 distro "moosenet-builder" from the official Ubuntu 24.04 WSL image (sha256-verified),
# caps WSL resources, runs bootstrap.sh inside it, then restarts it with Windows drives unmounted.
$ErrorActionPreference = 'Stop'
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Distro  = 'moosenet-builder2'
$Store   = Join-Path $env:LOCALAPPDATA 'moosenet-builder'
$Base    = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$Img     = 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'

Write-Host '== 0. checks'
wsl --status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'WSL is not installed yet. Do README step 1 (admin: wsl --install --no-distribution), reboot, then re-run.' }
if ((wsl -l -q) -replace "`0",'' | Where-Object { $_.Trim() -eq $Distro }) { Write-Host "$Distro already exists; skipping import (re-running bootstrap only)."; $exists = $true } else { $exists = $false }

Write-Host '== 1. resource caps (%USERPROFILE%\.wslconfig; applies to ALL WSL distros)'
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) { Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"; Write-Host "backed up existing .wslconfig" }
@"
[wsl2]
processors=16
memory=48GB
swap=8GB
"@ | Set-Content -Encoding ascii $cfg

if (-not $exists) {
  Write-Host '== 2. download + verify Ubuntu 24.04 WSL image (~340 MB)'
  New-Item -ItemType Directory -Force -Path $Store | Out-Null
  $tar = Join-Path $Store $Img
  Invoke-WebRequest "$Base/SHA256SUMS" -OutFile (Join-Path $Store 'SHA256SUMS') -UseBasicParsing
  $want = ((Get-Content (Join-Path $Store 'SHA256SUMS')) | Where-Object { $_ -match [regex]::Escape($Img) }) -split '\s+' | Select-Object -First 1
  if (-not $want) { throw "no checksum for $Img in SHA256SUMS" }
  if (-not (Test-Path $tar) -or ((Get-FileHash $tar -Algorithm SHA256).Hash.ToLower() -ne $want.ToLower())) {
    Invoke-WebRequest "$Base/$Img" -OutFile $tar -UseBasicParsing
  }
  $got = (Get-FileHash $tar -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want.ToLower()) { throw "checksum mismatch: got $got want $want" }
  Write-Host "sha256 ok $got"

  Write-Host '== 3. import distro'
  wsl --shutdown
  wsl --import $Distro (Join-Path $Store 'vhd') $tar --version 2
  if ($LASTEXITCODE -ne 0) { throw 'wsl --import failed' }
}

Write-Host '== 4. bootstrap inside the distro (10-20 min: packages, musl, pgvector, rust)'
$lin = (wsl -d $Distro -u root -- wslpath -a ($Here -replace '\\','/')) -replace "`0",''
wsl -d $Distro -u root -- bash "$($lin.Trim())/bootstrap.sh"
if ($LASTEXITCODE -ne 0) { throw 'bootstrap.sh failed -- see output above; nothing else was changed' }

Write-Host '== 5. restart distro so Windows drives are no longer mounted'
wsl -d $Distro -u root -- sync
wsl --terminate $Distro
Write-Host ''
Write-Host "DONE. $Distro is ready. Start it with Start-Builder.ps1 when the PC is idle; stop with Stop-Builder.ps1."
