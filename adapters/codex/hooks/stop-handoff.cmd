@echo off
REM adapters/codex/hooks/stop-handoff.cmd -- thin shim for Codex Stop hook.
REM Phase 5b: delegates to shared _launcher.cmd (POSIX PATH + dirname verification).
"%~dp0_launcher.cmd" stop-handoff
exit /b %ERRORLEVEL%
