@echo off
rem Convenience wrapper so the CLI can be run without touching execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gameshelf.ps1" %*
