@echo off
echo ================================================
echo SeiunEngine - Windows dependency setup
echo (run from the project root, requires Haxe 4.3.7 or newer)
echo ================================================
where haxe >nul 2>nul
if errorlevel 1 (
	echo Haxe was not found on PATH. Install Haxe 4.3.7 or newer first: https://haxe.org/download/
	pause
	exit /b 1
)
haxe -cp ./setup -main Main --interp
echo ================================================
echo Done! Now run: lime build windows -release
echo ================================================
pause
