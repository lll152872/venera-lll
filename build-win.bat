@echo off
setlocal

cd /d D:\mycode\venera

REM 1. Clear pub mirror env vars (prevents FRB version corruption)
set "PUB_HOSTED_URL="
set "FLUTTER_STORAGE_BASE_URL="

REM 2. PATH must include Flutter SDK and nuget
set "PATH=D:\edge;D:\flutter_3.44.0\bin;%PATH%"

REM 3. Start logging everything to a file
echo ============================================================ > build_log.txt
echo   BUILD-WIN.BAT started: %DATE% %TIME% >> build_log.txt
where flutter >> build_log.txt 2>&1
echo ============================================================ >> build_log.txt
echo. >> build_log.txt

REM 4. Build Windows release (--no-pub skips pub get, keeps current package_config)
echo [BUILD] flutter build windows --release --no-pub >> build_log.txt
flutter build windows --release --no-pub < nul >> build_log.txt 2>&1

set "BUILD_EXIT=%errorlevel%"
echo. >> build_log.txt
echo ============================================================ >> build_log.txt
echo   BUILD EXIT CODE: %BUILD_EXIT% >> build_log.txt

if not "%BUILD_EXIT%"=="0" (
    echo [BUILD FAILED] >> build_log.txt
    goto :showlog
)

REM 5. Verify sqlite3.dll is not an empty stub
for %%F in (build\windows\x64\runner\Release\sqlite3.dll) do (
    if %%~zF LSS 100000 (
        echo [ERROR] sqlite3.dll too small (%%~zF bytes), maybe empty stub >> build_log.txt
        goto :showlog
    )
)
echo [OK] build succeeded, sqlite3.dll present >> build_log.txt

REM 6. Optional launch if caller passed "run"
if "%~1"=="run" (
    echo launching exe... >> build_log.txt
    start "" build\windows\x64\runner\Release\venera.exe
)

:showlog
echo ============================================================ >> build_log.txt
echo   Finished: %DATE% %TIME% >> build_log.txt
echo ============================================================ >> build_log.txt

REM 7. Show result summary in this console window
echo.
echo ============================================================
if "%BUILD_EXIT%"=="0" (
    echo   BUILD SUCCEEDED.
    echo   EXE: D:\mycode\venera\build\windows\x64\runner\Release\venera.exe
) else (
    echo   BUILD FAILED - exit code %BUILD_EXIT%.
)
echo   Full log: D:\mycode\venera\build_log.txt
echo ============================================================
echo.

REM 8. Open the log minimized (separate window, will NOT steal focus)
start /min "" notepad.exe "D:\mycode\venera\build_log.txt"

REM 9. Keep this window open until a key is pressed
pause
exit /b %BUILD_EXIT%
