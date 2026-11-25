' Runs a .ps1 with no window flash (used by the scheduled task and shortcuts). Usage: wscript run-hidden.vbs <script.ps1>
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & WScript.Arguments(0) & """", 0, False
