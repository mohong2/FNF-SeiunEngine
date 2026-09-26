@echo off
setlocal
rem ============================================================
rem gen_linemap.bat - after "lime build android", generate the
rem crash-time address->cpp-line map from the unstripped .so files.
rem
rem Requires python on PATH. pyelftools is installed automatically.
rem Usage:  tools\gen_linemap.bat [release^|debug]   (default: release)
rem
rem Outputs -> assets\linemap\arm64-v8a.bin + armeabi-v7a.bin
rem   * push to device:  adb push assets\linemap\arm64-v8a.bin
rem       /storage/emulated/0/Android/data/com.mohong.Seiunengine/files/linemap/
rem   * the .bin files are a resident asset in Project.xml, so simply rebuilding
rem     the APK (tools\build_android_symbols.ps1) embeds them
rem ============================================================
cd /d "%~dp0.."

set BUILD=%1
if "%BUILD%"=="" set BUILD=release

where python >nul 2>nul
if errorlevel 1 (
    echo [gen_linemap] python not found on PATH.
    exit /b 1
)

python -c "import elftools" >nul 2>nul
if errorlevel 1 (
    echo [gen_linemap] installing pyelftools...
    python -m pip install pyelftools || exit /b 1
)

rem -DHXCPP_DEBUG_LINK_AND_STRIP keeps the unstripped link output in
rem obj\obj\android-64 (and android-v7); obj\libApplicationMain-*.so next to it is
rem the stripped deployment copy. Prefer the unstripped one, fall back to the
rem flat path for older layouts.
set SO64=
if exist "export\%BUILD%\android\obj\obj\android-64\libApplicationMain.so" set SO64=export\%BUILD%\android\obj\obj\android-64\libApplicationMain.so
if "%SO64%"=="" if exist "export\%BUILD%\android\obj\libApplicationMain-64.so" set SO64=export\%BUILD%\android\obj\libApplicationMain-64.so
if "%SO64%"=="" (
    echo [gen_linemap] no arm64 .so found.
    echo Run "haxelib run lime build android -DHXCPP_DEBUG_LINK_AND_STRIP" first.
    exit /b 1
)

echo [gen_linemap] arm64-v8a
python tools\gen_linemap.py "%SO64%" "assets\linemap\arm64-v8a.bin" || exit /b 1

set SO7=
if exist "export\%BUILD%\android\obj\obj\android-v7\libApplicationMain.so" set SO7=export\%BUILD%\android\obj\obj\android-v7\libApplicationMain.so
if "%SO7%"=="" if exist "export\%BUILD%\android\obj\libApplicationMain-v7.so" set SO7=export\%BUILD%\android\obj\libApplicationMain-v7.so
if not "%SO7%"=="" (
    echo [gen_linemap] armeabi-v7a
    python tools\gen_linemap.py "%SO7%" "assets\linemap\armeabi-v7a.bin" || exit /b 1
)

echo.
echo [gen_linemap] Done. The table is a resident asset; embed it by rebuilding:  tools\build_android_symbols.ps1
echo [gen_linemap] Or push to device:
echo   adb push assets\linemap\arm64-v8a.bin /storage/emulated/0/Android/data/com.mohong.Seiunengine/files/linemap/
endlocal
