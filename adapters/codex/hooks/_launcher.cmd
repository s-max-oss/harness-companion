@echo off
REM adapters/codex/hooks/_launcher.cmd -- shared Windows launcher for all hooks.
REM
REM Phase 5b: locates Git Bash, then invokes bash.exe with a controlled
REM -c command that sets the POSIX PATH and exec's the target hook script.
REM This avoids the 3-layer quoting problem (batch, bash, paths with spaces)
REM by using single-quoted bash -c argument and passing the script path via
REM an env variable (HOOK_SCRIPT) rather than command-line argument.
REM
REM Usage:
REM   _launcher.cmd <hook-sh-name-without-ext>
REM
REM Behavior:
REM   1. Locate bash.exe (PATH search, then common install locations).
REM   2. Verify dirname.exe is reachable (proves Git for Windows install).
REM   3. Compute Git root (GIT_ROOT) from dirname.exe location.
REM   4. Set HOOK_SCRIPT to the absolute path of <hook-name>.sh (this .cmd's sibling).
REM   5. Invoke bash.exe -c 'export PATH=/usr/bin:/bin:$PATH; exec "$HOOK_SCRIPT"'
REM      with stdin passed through. The bash -c argument is single-quoted to
REM      avoid quoting issues with paths containing spaces.
REM   6. Propagate bash's exit code (without re-resolution).

setlocal enabledelayedexpansion

REM ---- Resolve the target hook name (e.g., "session-start") ----
set "HOOK_NAME=%~1"
if not defined HOOK_NAME exit /b 0
set "HOOK_SCRIPT=%~dp0%HOOK_NAME%.sh"
if not exist "%HOOK_SCRIPT%" exit /b 0

REM ---- Locate bash.exe (PATH search, then common install locations) ----
set "BASH_EXE="
for /f "delims=" %%i in ('where bash 2^>nul') do if not defined BASH_EXE set "BASH_EXE=%%i"
if not defined BASH_EXE (
    for %%d in (
        "C:\Program Files\Git\bin\bash.exe"
        "C:\Program Files (x86)\Git\bin\bash.exe"
        "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
    ) do if not defined BASH_EXE if exist %%d set "BASH_EXE=%%~d"
)
if not defined BASH_EXE exit /b 0

REM ---- Verify dirname.exe is reachable; derive GIT_ROOT from it. ----------
REM bash.exe may be in  GIT_ROOT\bin\       (Case A: bin\bash.exe)
REM             or in  GIT_ROOT\usr\bin\    (Case B: usr\bin\bash.exe)
REM dirname.exe is always in  GIT_ROOT\usr\bin\
set "GIT_ROOT="
for %%i in ("%BASH_EXE%") do (
    REM Case B: bash and dirname share the same directory (usr\bin)
    if exist "%%~dpidirname.exe" (
        for %%j in ("%%~dpi..\..") do set "GIT_ROOT=%%~fj"
    )
    REM Case A: dirname is in ..\usr\bin\ relative to bash (bin\)
    if not defined GIT_ROOT if exist "%%~dpi..\usr\bin\dirname.exe" (
        for %%j in ("%%~dpi..") do set "GIT_ROOT=%%~fj"
    )
)
if not defined GIT_ROOT exit /b 0

REM ---- Set Windows PATH so bash.exe can be found when re-launching tools ----
set "PATH=%GIT_ROOT%\usr\bin;%GIT_ROOT%\bin;%PATH%"

REM ---- Invoke bash.exe with -c, exporting POSIX PATH and exec'ing the hook.
REM      - Single-quoted bash -c argument: batch does NOT escape single quotes,
REM        bash sees a single literal string; $HOOK_SCRIPT is expanded by bash
REM        via the env var, NOT by batch, sidestepping 3-layer quoting.
REM      - stdin is inherited from this .cmd's stdin (passed through).
REM      - HOOK_SCRIPT is converted to a bash-friendly POSIX path via cygpath
REM        inside the bash -c body (uses dirname's -m flag for MSYS2 path).
"%BASH_EXE%" -c "export PATH=/usr/bin:/bin:$PATH; export HOOK_SCRIPT=""$(cygpath -u ""%HOOK_SCRIPT%"")""; exec bash ""$HOOK_SCRIPT"""
exit /b %ERRORLEVEL%
