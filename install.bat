@echo off
echo ================================================
echo SeiunEngine - HaxeLib Installation Script
echo ================================================

set HAXELIB_PATH=%CD%\.haxelib

where haxe >nul 2>nul
if errorlevel 1 (
	echo Haxe was not found on PATH. Install Haxe 4.3.7 or newer first: https://haxe.org/download/
	pause
	exit /b 1
)

echo Installing libraries from hmm.json (see setup/Main.hx)...
haxe -cp ./setup -main Main --interp

echo ================================================
echo Installation completed!
echo ================================================
echo.
echo Installed libraries:
haxelib list

echo.
echo Patching Lime android templates...
call setup\patch-lime-android-templates.bat
echo Patching Lime iOS templates...
call setup\patch-lime-ios-templates.bat

pause
