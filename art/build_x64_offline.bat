@echo off
REM Offline build: no online code is compiled, no network requests are made, and the main menu has no online entry.
REM -D SEIUN_NO_ONLINE makes Project.xml drop ONLINE_ALLOWED and CHECK_FOR_UPDATES, which is what
REM actually removes the online code paths and the launch-time update check. The offline type check
REM lives at temp/seiun_offline_check.hxml (see the task notes / docs).
cd /d %~dp0\..
set HAXELIB_PATH=%CD%\.haxelib
echo BUILDING OFFLINE GAME
echo Using HAXELIB_PATH=%HAXELIB_PATH%
haxelib run lime build windows -release -D SEIUN_NO_ONLINE %*
echo done.
pause
