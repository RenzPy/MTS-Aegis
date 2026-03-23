@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch_Aegis.ps1"
if %errorlevel% neq 0 (
    echo.
    echo  [ERROR] Launcher exited with code %errorlevel%
    pause
)
