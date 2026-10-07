@echo off
setlocal
color 0b
cd /d %~dp0\..

REM ============================================================================
REM  Local symbol build (opt-in, command line only).
REM
REM  Project.xml deliberately contains NO HXCPP_DEBUG_LINK switch, so the normal
REM  release stays small. This script adds the define on the lime command line
REM  instead, which produces a fully symbolicated local binary for profiling
REM  (Very Sleepy / ETW) and for reading real frame names in crash reports.
REM
REM  What it does:
REM    1. moves export\release\windows\obj aside. MANDATORY: hxcpp's up-to-date
REM       check is timestamp-only (tools/hxcpp/File.hx:114 isOutOfDate) and blind
REM       to define changes, so without this the link pulls stale objects and
REM       fails with LNK2019.
REM    2. builds with -DHXCPP_DEBUG_LINK (~+17 MB exe, link.exe also turns
REM       /OPT:REF,ICF off, so the layout differs from the release build)
REM    3. copies obj\ApplicationMain.pdb -> bin\SeiunEngine.pdb, which is the
REM       exact name source/backend/native_crash.inc looks for
REM    4. prints the resulting sizes
REM
REM  Never ship bin\SeiunEngine.pdb: it is ~245 MB. The published release is the
REM  plain build (art\build_release.bat path is just "build normally"), with the
REM  embedded linemap + the separately published .map for triage.
REM
REM  Going back to a normal release build needs the obj move again - any define
REM  change does. art\clean_hxcpp_objs.bat does exactly that rename.
REM ============================================================================

set HAXELIB_PATH=%CD%\.haxelib
set STAMP=%DATE:~0,4%%DATE:~5,2%%DATE:~8,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set STAMP=%STAMP: =0%

if exist "export\release\windows\obj" (
  echo [profile] moving obj aside -^> obj_stale_%STAMP%
  move "export\release\windows\obj" "export\release\windows\obj_stale_%STAMP%" >nul
)

echo [profile] building with -DHXCPP_DEBUG_LINK ...
haxelib run lime build Project.xml windows -release -DHXCPP_DEBUG_LINK
if errorlevel 1 (
  echo [profile] BUILD FAILED - bin\SeiunEngine.exe left untouched.
  pause
  exit /b 1
)

set PDB=export\release\windows\obj\ApplicationMain.pdb
if exist "%PDB%" (
  echo [profile] copying PDB next to the exe as SeiunEngine.pdb
  copy /y "%PDB%" "export\release\windows\bin\SeiunEngine.pdb" >nul
) else (
  echo [profile] WARNING: %PDB% not found - the crash handler will report SymNone.
)

echo.
echo [profile] sizes:
for %%F in (export\release\windows\bin\SeiunEngine.exe) do echo    exe  %%~zF bytes
for %%F in (export\release\windows\bin\SeiunEngine.pdb) do echo    pdb  %%~zF bytes
echo.
echo [profile] next: profile with Very Sleepy against bin\SeiunEngine.exe, and
echo [profile]       check that a crash report prints real frame names.
echo [profile] the PDB is local-only - delete bin\SeiunEngine.pdb before packaging.
echo [profile] old object dir to delete once everything works:
echo [profile]   export\release\windows\obj_stale_%STAMP%
echo.
pause
endlocal
