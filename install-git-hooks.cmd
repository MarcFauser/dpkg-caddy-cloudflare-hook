@echo off
setlocal

set "PS1=%~dp0install-git-hooks.ps1"

if not exist "%PS1%" (
    echo ERROR: install-git-hooks.ps1 not found next to this launcher.
    echo Expected: "%PS1%"
    exit /b 2
)

where pwsh >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh^) was not found on the PATH.
    exit /b 3
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo %cmdcmdline% | find /i "%~nx0" >nul
if not errorlevel 1 (
    echo.
    pause
)

exit /b %RC%
