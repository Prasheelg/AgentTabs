@echo off
rem Starts Claude Launcher without leaving a console window open.
rem conhost.exe is used explicitly so Windows Terminal doesn't grab the window and ignore -WindowStyle Hidden.
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0ClaudeLauncher.ps1"
