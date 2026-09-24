@echo off
rem pure ASCII only - cmd.exe parses .cmd in the OEM codepage
chcp 65001 >nul
title Spotify lyrics overlay (debug console)
echo ============================================================
echo  Starting the lyrics overlay WITH a console, so errors show.
echo  For daily use, double-click start-lyrics.vbs instead.
echo  Quit from the tray icon (right click -^> exit).
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lyrics-overlay.ps1"
echo.
echo ---------- overlay exited ----------
echo log file: %~dp0lyrics-overlay.log
if exist "%~dp0lyrics-overlay.log" (
  echo.
  echo ---------- last log lines ----------
  powershell -NoProfile -Command "Get-Content -LiteralPath '%~dp0lyrics-overlay.log' -Tail 20"
)
pause
