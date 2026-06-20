@echo off
REM ============================================================================
REM setenv.bat - Defensively set HOME / TMP / TEMP for the bundled tools.
REM ============================================================================
REM Win98 SE doesn't set HOME, HOMEDRIVE, HOMEPATH, or LOCALAPPDATA by default.
REM Several bundled tools read these for ~ expansion, config-file lookup, and
REM cache directories:
REM
REM   gdb     uses XDG_CACHE_HOME / HOME / LOCALAPPDATA for the .gdb-index
REM           cache dir (warns and skips caching when none are set)
REM   sh.exe  (busybox) uses HOME for ~ expansion + lineedit history
REM   vi      (busybox) uses HOME for the swap-file directory
REM   make    uses HOME for ~ expansion in makefile paths
REM   ctags   uses HOMEDRIVE + HOMEPATH to find a user-level .ctags config
REM   muon    uses HOME (then HOMEDRIVE+HOMEPATH) for command-line history
REM
REM Run this once per session before invoking the tools, or paste the `set`
REM lines into autoexec.bat to make them permanent. Safe to re-run; only sets
REM vars that are currently empty. Safe on NT-class hosts too — typical
REM Windows installs already have HOME/HOMEDRIVE/HOMEPATH/LOCALAPPDATA, so
REM the `if "%VAR%"==""` guards skip the assignment.
REM
REM Compatible with Win98 SE command.com (single-line `if` form only;
REM no setlocal, no `goto :eof`, no `call :sub`).
REM ============================================================================

if "%HOME%"==""       set HOME=C:\HOME
if "%HOMEDRIVE%"==""  set HOMEDRIVE=C:
if "%HOMEPATH%"==""   set HOMEPATH=\HOME
if not exist %HOME%\NUL md %HOME%

REM TMP and TEMP — most Win98 installs set these from autoexec.bat (usually
REM C:\WINDOWS\TEMP), but a freshly-imaged box may not. Set both, mirrored,
REM so tools that probe either name find a path.
if "%TMP%"==""        if "%TEMP%"==""  set TMP=C:\WINDOWS\TEMP
if "%TMP%"==""        set TMP=%TEMP%
if "%TEMP%"==""       set TEMP=%TMP%
if not exist %TMP%\NUL md %TMP%

echo Win98 dev environment ready.
echo   HOME=%HOME%
echo   HOMEDRIVE=%HOMEDRIVE%   HOMEPATH=%HOMEPATH%
echo   TMP=%TMP%
echo   TEMP=%TEMP%
