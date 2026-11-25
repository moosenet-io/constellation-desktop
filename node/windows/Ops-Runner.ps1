# Ops-Runner.ps1 -- lets Claude run setup/maintenance scripts on this PC, with full logging, while you watch.
# Start:  powershell -ExecutionPolicy Bypass -File .\Ops-Runner.ps1   (normal user, NOT admin)
# Stop:   close this window, or create the file ops\STOP.
# How it works: Claude drops a .ps1 into ops\inbox. This runs it (as you, no admin), saves the full
# output to ops\logs\<name>.log and a result to ops\done\<name>.json, then moves the script to ops\done.
# Every script and log stays on disk for you to read. Nothing listens on the network.
$ErrorActionPreference = 'Continue'
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ops   = Join-Path $Root 'ops'
$In    = Join-Path $Ops 'inbox'; $Done = Join-Path $Ops 'done'; $Logs = Join-Path $Ops 'logs'
New-Item -ItemType Directory -Force -Path $In,$Done,$Logs,(Join-Path $Ops 'control') | Out-Null
if (-not (Test-Path (Join-Path $Ops 'empty-stdin.txt'))) { New-Item -ItemType File (Join-Path $Ops 'empty-stdin.txt') | Out-Null }
Remove-Item (Join-Path $Ops 'STOP') -ErrorAction SilentlyContinue
$TimeoutMin = 45
"$(Get-Date -Format o) ops-runner up pid=$PID" | Add-Content (Join-Path $Logs 'runner.log')
Write-Host "Ops-Runner ON -- watching $In. Close this window to stop." -ForegroundColor Green
while ($true) {
  if (Test-Path (Join-Path $Ops 'STOP')) { Write-Host 'STOP file seen'; break }
  Get-ChildItem $In -Filter *.ps1 | Sort-Object Name | ForEach-Object {
    $name = $_.BaseName; $log = Join-Path $Logs "$name.log"
    $sha = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    $t0 = Get-Date
    Write-Host "$(Get-Date -Format T) RUN $($_.Name) sha=$($sha.Substring(0,12))" -ForegroundColor Cyan
    "$(Get-Date -Format o) RUN $($_.Name) sha=$sha" | Add-Content (Join-Path $Logs 'runner.log')
    $p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($_.FullName)`"" `
          -WorkingDirectory $Root -RedirectStandardOutput $log -RedirectStandardError "$log.err" -RedirectStandardInput (Join-Path $Ops 'empty-stdin.txt') -WindowStyle Hidden -PassThru
    $null = $p.Handle   # cache handle so ExitCode is readable after WaitForExit
    Set-Content (Join-Path $Ops 'control\.busy') $_.Name
    $rc = $null; $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while (-not $p.WaitForExit(2000)) {
      if (Test-Path (Join-Path $Ops 'control\CANCEL')) { Remove-Item (Join-Path $Ops 'control\CANCEL'); & taskkill /T /F /PID $p.Id | Out-Null; $rc = 'cancelled'; break }
      if ((Get-Date) -gt $deadline) { & taskkill /T /F /PID $p.Id | Out-Null; $rc = 'timeout'; break }
    }
    if ($rc -eq $null) { $rc = $p.ExitCode }
    Remove-Item (Join-Path $Ops 'control\.busy') -ErrorAction SilentlyContinue
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    @{ name = $_.Name; sha256 = $sha; rc = "$rc"; secs = $secs; ended = (Get-Date -Format o) } | ConvertTo-Json |
      Set-Content (Join-Path $Done "$name.json")
    Move-Item $_.FullName (Join-Path $Done $_.Name) -Force
    Write-Host "$(Get-Date -Format T) DONE $($_.Name) rc=$rc ${secs}s" -ForegroundColor Cyan
    "$(Get-Date -Format o) DONE $($_.Name) rc=$rc secs=$secs" | Add-Content (Join-Path $Logs 'runner.log')
  }
  Start-Sleep -Seconds 5
}
