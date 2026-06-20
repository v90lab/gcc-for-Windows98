@echo off
REM ============================================================================
REM check-versions.bat - Smoke-test bundled gcc-win98 tools.
REM ============================================================================
REM Runs each tool with its version flag (or equivalent) and prints the banner.
REM Drop this in a toolset root (the directory containing bin\) and run it.
REM
REM Works for both packages:
REM   - native toolset (gcc_win98\)         -> exercises gcc + binutils
REM   - extras toolset (gcc_win98_extras\)  -> exercises make/ctags/gdb/muon/etc.
REM Tools that aren't present in this zip are silently skipped via `if exist`.
REM
REM A tool prints its banner          = loads + runs to entry (good).
REM A tool errors with a system dialog = bad PE / missing import (bad).
REM A tool prints nothing             = ran but failed silently (check by hand).
REM
REM Compatible with Win98 SE command.com:
REM   - single-line `if exist file command` form only (no block if)
REM   - bare `goto label` (no `goto :eof` / `:label` with colon)
REM   - no setlocal / no 2>&1 / no `call :sub`
REM ============================================================================

echo *** Native compiler ***
echo.
if exist bin\gcc.exe bin\gcc.exe --version
if exist bin\g++.exe bin\g++.exe --version
if exist bin\cpp.exe bin\cpp.exe --version
echo.
pause

echo.
echo *** Binutils (1/2) ***
echo.
if exist bin\as.exe bin\as.exe --version
if exist bin\ld.exe bin\ld.exe --version
if exist bin\ar.exe bin\ar.exe --version
if exist bin\nm.exe bin\nm.exe --version
if exist bin\objdump.exe bin\objdump.exe --version
echo.
pause

echo.
echo *** Binutils (2/2) ***
echo.
if exist bin\objcopy.exe bin\objcopy.exe --version
if exist bin\ranlib.exe bin\ranlib.exe --version
if exist bin\strip.exe bin\strip.exe --version
if exist bin\addr2line.exe bin\addr2line.exe --version
if exist bin\c++filt.exe bin\c++filt.exe --version
if exist bin\size.exe bin\size.exe --version
if exist bin\strings.exe bin\strings.exe --version
if exist bin\dlltool.exe bin\dlltool.exe --version
if exist bin\windres.exe bin\windres.exe --version
if exist bin\readelf.exe bin\readelf.exe --version
echo.
pause

echo.
echo *** Extras (build tools) ***
echo.
if exist bin\make.exe bin\make.exe --version
if exist bin\ctags.exe bin\ctags.exe --version
if exist bin\diff.exe bin\diff.exe --version
if exist bin\patch.exe bin\patch.exe --version
if exist bin\muon.exe bin\muon.exe version
echo.
pause

echo.
echo *** Extras (debugger) ***
echo.
if exist bin\gdb.exe bin\gdb.exe --version
if exist bin\gdbserver.exe bin\gdbserver.exe --version
echo.
pause

echo.
echo *** busybox (verbose; prints applet list after version line) ***
echo.
if exist bin\busybox.exe bin\busybox.exe --help
echo.
echo Done.
pause
