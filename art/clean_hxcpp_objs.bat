@echo off
setlocal
color 0e
cd /d %~dp0\..

REM ============================================================================
REM  Move hxcpp's object directory aside so the next build compiles everything.
REM
REM  WHY THIS EXISTS
REM    hxcpp decides "does this file need recompiling?" purely from TIMESTAMPS
REM    (the hxcpp library's tools/hxcpp/File.hx, isOutOfDate - locate that library
REM    with "haxelib libpath hxcpp", never by its version folder). Compiler flags
REM    are NOT part of that check. So after ANY define change - HXCPP_* or a
REM    feature define such as ONLINE_ALLOWED - the previous .obj files are still
REM    considered up to date and you link a binary whose translation units were
REM    built with DIFFERENT options. Symptoms: LNK2019/LNK2001 unresolved symbol,
REM    or (worse) a silent ABI mismatch that only shows up as a runtime crash.
REM
REM    Observed 2026-10-01: after adding HXCPP_CHECK_POINTER/HXCPP_STACK_LINE the
REM    build recompiled 2 of 2708 files and failed with
REM      error LNK2019: unresolved external symbol
REM      "hx::ExceptionStackFrame::ExceptionStackFrame(hx::StackFrame const &)"
REM    because obj/.../Debug.obj was still the 2026-09-13 one.
REM
REM  SAFETY
REM    This only renames export\release\windows\obj. It NEVER touches the
REM    bin directory, so mods / saves / chart_cache / crash reports are safe.
REM ============================================================================

set OBJDIR=export\release\windows\obj
set STAMP=%DATE:~0,4%%DATE:~5,2%%DATE:~8,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set STAMP=%STAMP: =0%
set BACKUP=%OBJDIR%_stale_%STAMP%

if not exist "%OBJDIR%" (
  echo [clean] nothing to do - "%OBJDIR%" does not exist.
  goto :done
)

echo [clean] moving "%OBJDIR%"
echo [clean]     ->  "%BACKUP%"
move "%OBJDIR%" "%BACKUP%" >nul
if errorlevel 1 (
  echo [clean] FAILED to move. Close the game / editor holding files in there and retry.
  exit /b 1
)

echo.
echo [clean] done. Next build will recompile everything (expect 20-40 min).
echo [clean] Rebuild with:  haxelib run lime build windows -release
echo [clean] Verify with:   findstr /C:"HXCPP_" export\release\windows\obj\Options.txt
echo [clean] Once the new build runs fine, delete:  "%BACKUP%"
echo.

:done
pause
endlocal
