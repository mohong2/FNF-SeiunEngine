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

rem optional 2nd arg: limit to one ABI (arm64-v8a / armeabi-v7a)
set ABIOPT=
if not "%2"=="" set ABIOPT=--abi %2

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

rem ---------------------------------------------------------------------------
rem Candidate discovery, the "newest DWARF-bearing copy wins" rule and the
rem coverage gate all live in gen_linemap.py. They used to live here as a fixed
rem priority list, which handed the generator the PREVIOUS build's byproduct
rem while the fresh one sat in obj\obj\<target>\ - the resulting table located
rem 1.5% of the binary and still passed every check downstream.
rem ---------------------------------------------------------------------------
python tools\gen_linemap.py --android %BUILD% %ABIOPT%
if errorlevel 1 (
    echo.
    echo [gen_linemap] FAILED - nothing was written for the ABIs above.
    echo [gen_linemap] The table is refused rather than shipped blind; see the message above.
    exit /b 1
)

echo.
echo [gen_linemap] Done. The table is a resident asset; embed it by rebuilding:  tools\build_android_symbols.ps1
echo [gen_linemap] Or push to device:
echo   adb push assets\linemap\arm64-v8a.bin /storage/emulated/0/Android/data/com.mohong.Seiunengine/files/linemap/
endlocal