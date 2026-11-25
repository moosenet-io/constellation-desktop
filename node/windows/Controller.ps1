# Controller.ps1 -- runs every minute (Task Scheduler, hidden) and makes reality match the flag files in ops\control:
#   RUNNER_OFF  present -> Ops-Runner stopped   (absent -> kept running)
#   BUILDER_ON  present -> build watcher running (absent -> builder stopped safely)
#   GAME_MODE   present -> builder stopped safely, whatever BUILDER_ON says (your "I want to play" switch)
#   APPLY_WSLCONFIG present -> restart WSL to apply new caps, but only when no build job is in progress
# Claude flips these files remotely; you flip GAME_MODE with the desktop shortcuts. Log: ops\logs\controller.log
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$C = Join-Path $Root 'ops\control'; $Log = Join-Path $Root 'ops\logs\controller.log'
$Distro = 'moosenet-builder2'
$X = (Join-Path $Root 'exchange') -replace '\\','/'
function Say($m) { "$(Get-Date -Format o) $m" | Add-Content $Log }
New-Item -ItemType Directory -Force -Path $C | Out-Null

# ---- runner
$runner = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'Ops-Runner\.ps1' }
$runnerScript = Get-Item (Join-Path $Root 'Ops-Runner.ps1')
if (Test-Path (Join-Path $C 'RUNNER_OFF')) {
  if ($runner) { $runner | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Say 'runner stopped (RUNNER_OFF)' }
} else {
  if ($runner -and -not (Test-Path (Join-Path $C '.busy'))) {
    $started = $runner | ForEach-Object { $_.CreationDate } | Sort-Object | Select-Object -First 1
    if ($runnerScript.LastWriteTime -gt $started) { $runner | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; $runner = $null; Say 'runner restarted to load a newer Ops-Runner.ps1' }
  }
  if (-not $runner) {
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($runnerScript.FullName)`"" -WindowStyle Minimized -WorkingDirectory $Root
    Say 'runner started'
  }
}

# ---- builder
$want = (Test-Path (Join-Path $C 'BUILDER_ON')) -and -not (Test-Path (Join-Path $C 'GAME_MODE'))
$running = [bool]((wsl -l --running -q) -replace "`0",'' | Where-Object { $_.Trim() -eq $Distro })
$watcher = $false
if ($running) { $w = wsl -d $Distro -u root -- pgrep -f moosenet-watcher.sh; $watcher = [bool]$w }
$jobBusy = [bool](Get-ChildItem (Join-Path $Root 'exchange\inbox') -Filter *.taken -ErrorAction SilentlyContinue)
function Stop-Builder($why) {
  ("touch /x/STOP 2>/dev/null; pkill -TERM -u builder; sleep 3; pkill -KILL -u builder; pkill -f moosenet-watcher; sync`n") |
    wsl -d $Distro -u root -- sh -c "tr -d '\r' | sh -s"
  wsl --terminate $Distro | Out-Null
  Get-ChildItem (Join-Path $Root 'exchange\inbox') -Filter *.taken -ErrorAction SilentlyContinue | ForEach-Object { Rename-Item $_.FullName ($_.Name -replace '\.taken$','.cancelled') }
  Remove-Item (Join-Path $Root 'exchange\STOP') -ErrorAction SilentlyContinue
  Say "builder stopped ($why)"
}
if (-not $want -and $running) { Stop-Builder ($(if (Test-Path (Join-Path $C 'GAME_MODE')) {'GAME_MODE'} else {'BUILDER_ON absent'})) ; $running = $false }
if (Test-Path (Join-Path $C 'APPLY_VMCONFIG')) { Move-Item (Join-Path $C 'APPLY_VMCONFIG') (Join-Path $C 'APPLY_WSLCONFIG') -Force }
if ((Test-Path (Join-Path $C 'APPLY_WSLCONFIG')) -and -not $jobBusy) {
  if ($running) { Stop-Builder 'apply wslconfig' }
  wsl --shutdown; Remove-Item (Join-Path $C 'APPLY_WSLCONFIG'); Say 'wsl restarted to apply .wslconfig'; $running = $false
}
if ($want -and -not $watcher) {
  $L = Join-Path $Root 'ops\logs\builder-watcher.log'
  Start-Process wsl -ArgumentList '-d',$Distro,'-u','root','--','/opt/moosenet-watcher.sh',"$X" -WindowStyle Hidden `
    -RedirectStandardOutput $L -RedirectStandardError "$L.err"
  Say 'builder started'
}

# ---- Tdarr node (TDARR_ON, paused by GAME_MODE). Lowest priority: runs BelowNormal so games/builds win.
$tdExe = Join-Path $Root 'tdarr\Tdarr_Node\Tdarr_Node.exe'
$wantTd = (Test-Path (Join-Path $C 'TDARR_ON')) -and -not (Test-Path (Join-Path $C 'GAME_MODE'))
$td = Get-Process Tdarr_Node -ErrorAction SilentlyContinue
if ($wantTd -and -not $td -and (Test-Path $tdExe)) {
  $p = Start-Process $tdExe -WorkingDirectory (Split-Path $tdExe) -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 2; try { $p.PriorityClass = 'BelowNormal' } catch {}
  Say 'tdarr node started'
}
if (-not $wantTd -and $td) {
  & taskkill /T /F /IM Tdarr_Node.exe | Out-Null; Get-Process -Name 'ffmpeg','HandBrakeCLI' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" } | Stop-Process -Force
  Say "tdarr node stopped ($(if (Test-Path (Join-Path $C 'GAME_MODE')) {'GAME_MODE'} else {'TDARR_ON absent'}))"
}
