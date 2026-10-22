@echo off
setlocal
title REPARO Restore Original
if "%~1"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-CGFix.ps1" -Restore
) else (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-CGFix.ps1" -GameDirectory "%~1" -Restore
)
set "patchExit=%ERRORLEVEL%"
echo.
pause
exit /b %patchExit%
