' Starts Claude Launcher with no console flash (wscript has no console, unlike a .bat).
' conhost --headless gives PowerShell a console without ever creating a window (and keeps Windows Terminal out of it).
Option Explicit
Dim fso, dir
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & dir & "\ClaudeLauncher.ps1""", 0, False
