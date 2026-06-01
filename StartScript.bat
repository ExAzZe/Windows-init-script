@echo off
:: Lance ScriptVM.ps1 en contournant l'ExecutionPolicy
:: Les deux fichiers doivent être dans le même dossier

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ScriptVM.ps1"
pause
