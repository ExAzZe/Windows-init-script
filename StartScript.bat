@echo off
net session >nul 2>&1
if %errorlevel% == 0 goto :admin
 
echo Elevation requise - relancement en administrateur...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b
 
:admin
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ScriptVM.ps1"
pause
