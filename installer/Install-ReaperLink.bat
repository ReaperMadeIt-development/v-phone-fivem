@echo off
setlocal
title ReaperLink Voice Tester Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ReaperLink-Test-Installer.ps1"
if errorlevel 1 (
  echo.
  echo ReaperLink installer exited with an error.
  pause
)
