@echo off
REM adapters/codex/hooks/pre-tool-use.cmd -- thin shim for Codex PreToolUse hook.
REM Phase 5b: delegates to shared _launcher.cmd (POSIX PATH + dirname verification).
"%~dp0_launcher.cmd" pre-tool-use
exit /b %ERRORLEVEL%
