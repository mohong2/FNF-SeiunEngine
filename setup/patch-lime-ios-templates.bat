@echo off
rem ============================================================
rem SeiunEngine - Lime iOS template patches
rem
rem The ACTIVE lime iOS Info.plist template gets two extra keys so
rem the app's Documents folder shows up in the system Files app:
rem   UIFileSharingEnabled                 -> allow file sharing
rem   LSSupportsOpeningDocumentsInPlace    -> keep files in place
rem This lets players drop charts into the app and export saves
rem without a computer.
rem
rem The patched file lives in templates/ios/ (versioned in this repo)
rem and is copied over the lime library that is actually in use.
rem The target is resolved with "haxelib libpath lime" instead of the old
rem hardcoded .haxelib\lime\8,0,1, which was NOT the active library, so the
rem old script patched a copy nothing read and still reported success.
rem "haxelib libpath" also honours haxelib dev mode (.haxelib\lime\.dev),
rem so it always names the tree the build really reads.
rem Setting HAXELIB_PATH here would be useless: haxelib 4.0.2 keeps its
rem repository path in its own config file, not in that environment variable.
rem
rem NOTE: the code-signing pbxproj patch applied by .github/actions/build-ios
rem is NOT applied here - it needs perl and is a CI/release concern. For a
rem local unsigned device build, copy that perl command out of
rem .github/actions/build-ios/action.yml (step: Apply iOS template patches).
rem
rem Run this again after `haxelib update lime` or after reinstalling the deps.
rem ============================================================

cd /d "%~dp0.."

set "LIME_DIR="
set "SEIUN_LIME_PATH_FILE=%TEMP%\seiun_lime_libpath.txt"
if exist "%SEIUN_LIME_PATH_FILE%" del "%SEIUN_LIME_PATH_FILE%" >nul 2>nul
haxelib libpath lime > "%SEIUN_LIME_PATH_FILE%" 2>nul
if errorlevel 1 goto :resolve_failed
set /p "LIME_DIR="<"%SEIUN_LIME_PATH_FILE%"
del "%SEIUN_LIME_PATH_FILE%" >nul 2>nul
if not defined LIME_DIR goto :resolve_failed

rem haxelib prints a mixed-separator path with a trailing slash; cmd's copy
rem and mkdir want backslashes and no trailing separator.
set "LIME_DIR=%LIME_DIR:/=\%"
if "%LIME_DIR:~-1%"=="\" set "LIME_DIR=%LIME_DIR:~0,-1%"

set "LIME_IOS_TEMPLATE=%LIME_DIR%\templates\ios\template"
if not exist "%LIME_IOS_TEMPLATE%" goto :template_missing
if not exist "%LIME_IOS_TEMPLATE%\{{app.file}}" goto :template_missing

echo [lime] target: %LIME_IOS_TEMPLATE%

copy /Y "templates\ios\template\{{app.file}}\{{app.file}}-Info.plist" "%LIME_IOS_TEMPLATE%\{{app.file}}\{{app.file}}-Info.plist" >nul

echo Lime iOS templates patched OK.
exit /b 0

:template_missing
echo ERROR: lime iOS template not found at "%LIME_IOS_TEMPLATE%"
echo        The resolved lime install has no templates\ios\template app folder.
exit /b 1

:resolve_failed
if exist "%SEIUN_LIME_PATH_FILE%" del "%SEIUN_LIME_PATH_FILE%" >nul 2>nul
echo ERROR: could not resolve the lime library directory with "haxelib libpath lime".
echo        Run install.bat first - it installs hmm.json and applies the setup patches.
exit /b 1
