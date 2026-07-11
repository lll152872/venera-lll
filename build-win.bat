@echo off
setlocal
cd /d D:\mycode\venera

echo [1/4] Fix package_config (frb version)...
powershell -Command "(Get-Content .dart_tool\package_config.json) -replace 'flutter_rust_bridge-2.12.0','flutter_rust_bridge-2.11.1' | Set-Content .dart_tool\package_config.json"

echo [2/4] Build Windows...
flutter build windows --release --no-pub
if errorlevel 1 (
    echo BUILD FAILED
    pause
    exit /b 1
)

echo [3/4] Restore real sqlite3.dll...
copy /Y build\windows\x64\runner\Debug\sqlite3.dll build\windows\x64\runner\Release\sqlite3.dll >nul

echo [4/4] Done!
start "" build\windows\x64\runner\Release\venera.exe
