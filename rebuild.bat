@echo off
rem ---------------------------------------------------------------------------
rem Builds the emoji set from YOUR _chat.asi and YOUR Segoe UI Emoji,
rem so the icons look exactly like in the Arizona RP chat.
rem
rem Run by double click, or with explicit paths:
rem     rebuild.bat --asi "C:\...\bin\arizona\_chat.asi"
rem     rebuild.bat --emoji "C:\Windows\Fonts\seguiemj.ttf"
rem
rem ASCII only, on purpose: cmd.exe reads a batch file in the console code
rem page, so any non-ASCII byte here breaks command parsing. All the real
rem work and all the Russian text live in tools\rebuild.py instead.
rem ---------------------------------------------------------------------------

cd /d "%~dp0"

set PY=
where py >nul 2>&1 && set PY=py -3
if "%PY%"=="" where python >nul 2>&1 && set PY=python
if "%PY%"=="" (
    echo [!] Python not found.
    echo     Install it from https://www.python.org/downloads/
    echo     and tick "Add Python to PATH".
    pause
    exit /b 1
)

%PY% -c "import PIL" >nul 2>&1
if errorlevel 1 (
    echo Installing Pillow...
    %PY% -m pip install --quiet --upgrade pillow
    if errorlevel 1 (
        echo [!] Could not install Pillow.
        pause
        exit /b 1
    )
)

%PY% tools\rebuild.py %*
pause
