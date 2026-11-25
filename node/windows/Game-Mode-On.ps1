# Desktop shortcut "MooseNet: Game Mode ON" -- stops builds right now (safely) and keeps them off until Game Mode OFF.
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType File -Force (Join-Path $Root 'ops\control\GAME_MODE') | Out-Null
& (Join-Path $Root 'Controller.ps1')
