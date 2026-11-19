@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "UI_SCRIPT=%~dp0CDriveGrowth-UI.ps1"
set "SCAN_SCRIPT=%~dp0CDriveGrowth.ps1"
set "OUTPUT_DIR=%~dp0CDriveGrowth-Data"

if not exist "%SCAN_SCRIPT%" (
    echo Extract all files from the ZIP before running this launcher.
    pause
    exit /b 1
)
if not exist "%UI_SCRIPT%" (
    echo The window script is missing. Extract all files to use the scan window.
    goto console
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%UI_SCRIPT%" -ScanScript "%SCAN_SCRIPT%" -OutputDir "%OUTPUT_DIR%"
if not errorlevel 1 exit /b 0

echo.
echo The scan window could not start. Its error is shown above.
:console
echo Starting the console scanner instead.
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCAN_SCRIPT%" -OutputDir "%OUTPUT_DIR%" -SelectDrives -OpenReport
if errorlevel 1 (
    echo.
    echo Scan failed. See the error above.
    pause
    exit /b 1
)
exit /b 0
