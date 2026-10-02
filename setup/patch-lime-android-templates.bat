@echo off
rem ============================================================
rem SeiunEngine - Lime Android template patches
rem
rem The ACTIVE lime android template needs tweaks that cannot be
rem expressed through Project.xml:
rem   1. gradle.properties   -> android.useAndroidX=true + jetifier
rem      (extension-androidtools ships AndroidX dependencies)
rem   2. AndroidManifest.xml -> android:requestLegacyExternalStorage
rem      (keeps Android 10 users on the public /storage/emulated/0
rem       root so mods stay installable without root)
rem   3. app/build.gradle    -> lintOptions.checkReleaseBuilds=false
rem      (AGP 4.1 lint crashes on some JDK/OS combos; a game APK does
rem       not need lint)
rem
rem The patched files live in templates/android/ (versioned in this repo)
rem and are copied over the lime library that is actually in use.
rem The target is resolved with "haxelib libpath lime" instead of the old
rem hardcoded .haxelib\lime\8,0,1: that directory was NOT the active
rem library (the active one was .haxelib\lime\git), so the script patched
rem a copy nothing read and still reported success.
rem "haxelib libpath" also honours haxelib dev mode (.haxelib\lime\.dev),
rem so it always names the tree the build really reads.
rem Setting HAXELIB_PATH here would be useless: haxelib 4.0.2 keeps its
rem repository path in its own config file, not in that environment variable.
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

set "LIME_TEMPLATE=%LIME_DIR%\templates\android\template"
if not exist "%LIME_TEMPLATE%" goto :template_missing

echo [lime] target: %LIME_TEMPLATE%

copy /Y "templates\android\template\gradle.properties" "%LIME_TEMPLATE%\gradle.properties" >nul
copy /Y "templates\android\template\app\src\main\AndroidManifest.xml" "%LIME_TEMPLATE%\app\src\main\AndroidManifest.xml" >nul
copy /Y "templates\android\template\app\build.gradle" "%LIME_TEMPLATE%\app\build.gradle" >nul

rem SeiunOverlay - modern floating keyboard button (TYPE_APPLICATION_OVERLAY)
rem The Java class is registered as an android extension in Project.xml and
rem is compiled straight into the app source set (org.haxe.extension package).
if not exist "%LIME_TEMPLATE%\app\src\main\java\org\haxe\extension" mkdir "%LIME_TEMPLATE%\app\src\main\java\org\haxe\extension"
copy /Y "templates\android\java\org\haxe\extension\SeiunOverlay.java" "%LIME_TEMPLATE%\app\src\main\java\org\haxe\extension\SeiunOverlay.java" >nul

rem Material keyboard icon for the floating button.
if not exist "%LIME_TEMPLATE%\app\src\main\res\drawable" mkdir "%LIME_TEMPLATE%\app\src\main\res\drawable"
copy /Y "templates\android\template\app\src\main\res\drawable\seiun_ic_keyboard.xml" "%LIME_TEMPLATE%\app\src\main\res\drawable\seiun_ic_keyboard.xml" >nul

echo Lime android templates patched OK.
exit /b 0

:template_missing
echo ERROR: lime android template not found at "%LIME_TEMPLATE%"
echo        The resolved lime install has no templates\android\template directory.
exit /b 1

:resolve_failed
if exist "%SEIUN_LIME_PATH_FILE%" del "%SEIUN_LIME_PATH_FILE%" >nul 2>nul
echo ERROR: could not resolve the lime library directory with "haxelib libpath lime".
echo        Run install.bat first - it installs hmm.json and applies the setup patches.
exit /b 1
