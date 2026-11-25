# Builder OFF (safe stop: build processes ended, disk flushed, then the distro stops).
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Remove-Item (Join-Path $Root 'ops\control\BUILDER_ON') -ErrorAction SilentlyContinue
& (Join-Path $Root 'Controller.ps1')
