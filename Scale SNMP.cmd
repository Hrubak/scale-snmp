@echo off
REM Launches the Scale HyperCore API Toolkit (includes SNMP plus other REST functions).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ScaleAPI.ps1"
