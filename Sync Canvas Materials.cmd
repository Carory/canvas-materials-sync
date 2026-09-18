@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 was not found.
  echo Install PowerShell 7, then run this file again.
  echo Press X to close this window.
  choice /c X /n >nul
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\canvas-sync\Sync-Canvas.ps1" %*
set "SYNC_EXIT=%ERRORLEVEL%"
echo.
if not "%SYNC_EXIT%"=="0" echo Sync finished with errors. Please review the messages above.
echo Press X to close this window.
choice /c X /n >nul
exit /b %SYNC_EXIT%
