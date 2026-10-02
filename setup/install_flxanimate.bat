@echo off
rem SeiunEngine: install flxanimate 4.0.0 and apply the patch from setup\flxanimate_haxe425_patch\.
rem Run from the repository root. Requires haxelib on PATH.
rem
rem The patch target is resolved with "haxelib libpath flxanimate" - never a hardcoded
rem .haxelib\flxanimate\<version> path, which silently targets a library copy that is not
rem in use as soon as the active version directory changes.
cd /d "%~dp0.."

haxelib install flxanimate 4.0.0
if errorlevel 1 (
  echo Failed to install flxanimate 4.0.0. Check network / haxelib.
  exit /b 1
)

set "FLX_DIR="
set "SEIUN_FLX_PATH_FILE=%TEMP%\seiun_flxanimate_libpath.txt"
if exist "%SEIUN_FLX_PATH_FILE%" del "%SEIUN_FLX_PATH_FILE%" >nul 2>nul
haxelib libpath flxanimate > "%SEIUN_FLX_PATH_FILE%" 2>nul
if errorlevel 1 goto :no_flxanimate
set /p "FLX_DIR="<"%SEIUN_FLX_PATH_FILE%"
del "%SEIUN_FLX_PATH_FILE%" >nul 2>nul
if not defined FLX_DIR goto :no_flxanimate

rem haxelib prints a mixed-separator path with a trailing slash; cmd needs backslashes.
set "FLX_DIR=%FLX_DIR:/=\%"
if "%FLX_DIR:~-1%"=="\" set "FLX_DIR=%FLX_DIR:~0,-1%"
if not exist "%FLX_DIR%" goto :no_flxanimate

copy /Y setup\flxanimate_haxe425_patch\FlxElement.hx "%FLX_DIR%\flxanimate\animate\FlxElement.hx" >nul
copy /Y setup\flxanimate_haxe425_patch\MacroAnimationData.hx "%FLX_DIR%\flxanimate\data\MacroAnimationData.hx" >nul
copy /Y setup\flxanimate_haxe425_patch\FlxAnimateFrames.hx "%FLX_DIR%\flxanimate\frames\FlxAnimateFrames.hx" >nul

echo flxanimate 4.0.0 installed and patched.
exit /b 0

:no_flxanimate
if exist "%SEIUN_FLX_PATH_FILE%" del "%SEIUN_FLX_PATH_FILE%" >nul 2>nul
echo Failed to resolve the flxanimate library directory with "haxelib libpath flxanimate".
exit /b 1
