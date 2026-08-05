@echo off
setlocal

cd /d D:\mycode\venera

REM 1. Clear pub mirror env vars (prevents FRB version corruption)
set "PUB_HOSTED_URL="
set "FLUTTER_STORAGE_BASE_URL="

REM 2. PATH must include Flutter SDK and nuget
set "PATH=D:\edge;D:\flutter_3.44.0\bin;%PATH%"

REM 3. Start logging everything to a file
echo ============================================================ > analyze_log.txt
echo   ANALYZE.BAT started: %DATE% %TIME% >> analyze_log.txt
echo   flutter used: >> analyze_log.txt
where flutter >> analyze_log.txt 2>&1
echo   PATH (first 200 chars): %PATH:~0,200% >> analyze_log.txt
echo ============================================================ >> analyze_log.txt
echo. >> analyze_log.txt

REM 4. Run analyze, append ALL output (stdout+stderr) to the log
echo [RUN] flutter analyze %* >> analyze_log.txt
flutter analyze %* < nul >> analyze_log.txt 2>&1

set "ANALYZE_EXIT=%errorlevel%"
echo. >> analyze_log.txt
echo ============================================================ >> analyze_log.txt
echo   ANALYZE EXIT CODE: %ANALYZE_EXIT% >> analyze_log.txt
echo   Finished: %DATE% %TIME% >> analyze_log.txt
echo ============================================================ >> analyze_log.txt

REM 5. Restore pubspec.lock (implicit pub get may rewrite it)
git checkout -- pubspec.lock >> analyze_log.txt 2>&1

if not "%ANALYZE_EXIT%"=="0" (
    echo. >> analyze_log.txt
    echo [ERROR] flutter analyze failed (exit %ANALYZE_EXIT%). >> analyze_log.txt
) else (
    echo [OK] analyze passed, no errors. >> analyze_log.txt
)

REM 6. Show result summary in this console window
echo.
echo ============================================================
if "%ANALYZE_EXIT%"=="0" (
    echo   ANALYZE PASSED - no errors.
) else (
    echo   ANALYZE FAILED - exit code %ANALYZE_EXIT%.
)
echo   Full log: D:\mycode\venera\analyze_log.txt
echo ============================================================
echo.

REM 7. Open the log minimized (separate window, will NOT steal focus)
start /min "" notepad.exe "D:\mycode\venera\analyze_log.txt"

REM 8. Keep this window open until a key is pressed
pause
exit /b %ANALYZE_EXIT%
