@echo off
REM adapters/codex/hooks/session-start.cmd -- thin shim for Codex SessionStart hook.
REM Phase 5b: delegates to shared _launcher.cmd (POSIX PATH + dirname verification).
"%~dp0_launcher.cmd" session-start
exit /b %ERRORLEVEL%
