@echo off
echo Downloading course files from Moodle...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0moodle-sync.ps1"
echo.
echo Done - see log.txt for details.
pause
