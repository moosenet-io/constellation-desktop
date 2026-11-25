# Desktop shortcut "MooseNet: Game Mode OFF" -- lets builds resume (if Claude has the builder switched on).
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Remove-Item (Join-Path $Root 'ops\control\GAME_MODE') -ErrorAction SilentlyContinue
& (Join-Path $Root 'Controller.ps1')
