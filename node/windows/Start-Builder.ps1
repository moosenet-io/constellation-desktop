# Builder ON (the scheduled controller does the work within a minute; this just flips the switch and nudges it).
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType File -Force (Join-Path $Root 'ops\control\BUILDER_ON') | Out-Null
& (Join-Path $Root 'Controller.ps1')
