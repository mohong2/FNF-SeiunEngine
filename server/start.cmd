@echo off
setlocal
rem SeiunEngine server - double-click launcher.
rem The real logic lives in start.ps1; this only pauses so the window does not flash shut.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
set "CODE=%ERRORLEVEL%"
echo.
echo [server] exit code = %CODE%
echo Press any key to close this window . . .
pause >nul
endlocal